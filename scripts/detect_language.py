#!/usr/bin/env python3
"""Detect feed language and write <language> tags into OPML <head> sections.

Strategy:
  1. Extract text from <head><title> + feed <outline title="..."> attributes.
  2. Run langdetect on the combined text.
  3. Use country directory as a low-confidence prior (doesn't override detection).
  4. Only write when confidence >= 0.9.
  5. Generate a JSON report of all changes.

Usage:
  python3 detect_language.py          # dry-run — print what would change
  python3 detect_language.py --write  # apply changes to OPML files
"""

import os
import sys
import json
import xml.etree.ElementTree as ET
from pathlib import Path
from collections import defaultdict

from langdetect import DetectorFactory, detect_langs

DetectorFactory.seed = 0

FEEDS_ROOT = Path(__file__).resolve().parent.parent / "feedmine" / "Resources" / "Feeds"

# Map country slugs to expected primary language (ISO 639-1).
# Used as a confidence booster, not an override.
COUNTRY_LANGUAGE = {
    "angola": "pt", "argentina": "es", "armenia": "hy", "australia": "en",
    "austria": "de", "azerbaijan": "az", "bangladesh": "bn", "belarus": "ru",
    "belgium": "nl", "bolivia": "es", "brazil": "pt", "bulgaria": "bg",
    "cambodia": "km", "canada": "en", "chile": "es", "china": "zh",
    "colombia": "es", "costa-rica": "es", "croatia": "hr", "cuba": "es",
    "cyprus": "el", "czech-republic": "cs", "denmark": "da",
    "dominican-republic": "es", "ecuador": "es", "egypt": "ar",
    "el-salvador": "es", "estonia": "et", "ethiopia": "am", "finland": "fi",
    "france": "fr", "georgia": "ka", "germany": "de", "ghana": "en",
    "greece": "el", "guatemala": "es", "haiti": "fr", "honduras": "es",
    "hungary": "hu", "iceland": "is", "india": "hi", "indonesia": "id",
    "iran": "fa", "iraq": "ar", "ireland": "en", "israel": "he",
    "italy": "it", "ivory-coast": "fr", "jamaica": "en", "japan": "ja",
    "kazakhstan": "kk", "kenya": "en", "latvia": "lv", "lithuania": "lt",
    "luxembourg": "fr", "malaysia": "ms", "malta": "mt", "mexico": "es",
    "morocco": "ar", "myanmar": "my", "nepal": "ne", "netherlands": "nl",
    "new-zealand": "en", "nicaragua": "es", "nigeria": "en", "norway": "no",
    "pakistan": "ur", "panama": "es", "paraguay": "es", "peru": "es",
    "philippines": "tl", "poland": "pl", "portugal": "pt",
    "puerto-rico": "es", "qatar": "ar", "romania": "ro", "russia": "ru",
    "saudi-arabia": "ar", "serbia": "sr", "singapore": "en",
    "slovakia": "sk", "slovenia": "sl", "south-africa": "en",
    "south-korea": "ko", "spain": "es", "sri-lanka": "si", "sudan": "ar",
    "sweden": "sv", "switzerland": "de", "taiwan": "zh", "thailand": "th",
    "tunisia": "ar", "turkey": "tr", "uae": "ar", "ukraine": "uk",
    "united-kingdom": "en", "uruguay": "es", "usa": "en",
    "venezuela": "es", "vietnam": "vi",
    "algeria": "ar", "finland": "fi",
}

MIN_CONFIDENCE = 0.9
MIN_TEXT_LENGTH = 20  # characters — below this, detection is unreliable


def extract_text(opml_path: Path) -> str:
    """Extract language-bearing text from an OPML file: <head><title> + feed titles."""
    try:
        tree = ET.parse(opml_path)
    except ET.ParseError:
        return ""

    parts = []
    root = tree.getroot()

    # <head><title>
    head = root.find("head")
    if head is not None:
        title_el = head.find("title")
        if title_el is not None and title_el.text:
            parts.append(title_el.text.strip())

    # <body><outline title="..."> (feed entries — skip category containers without xmlUrl)
    body = root.find("body")
    if body is not None:
        for outline in body.iter("outline"):
            title = outline.get("title", "")
            xml_url = outline.get("xmlUrl", "")
            # Only collect titles of actual feed entries (they have xmlUrl)
            if xml_url and title.strip():
                parts.append(title.strip())

    return " ".join(parts)


def detect_language(text: str, opml_path: Path) -> tuple[str | None, float, str]:
    """Detect language from text. Returns (lang, confidence, method).

    method is one of: 'detect', 'country_prior', 'fallback_en', 'insufficient_text'
    """
    if len(text) < MIN_TEXT_LENGTH:
        # Try country prior for short text
        country = country_from_path(opml_path)
        if country and country in COUNTRY_LANGUAGE:
            return COUNTRY_LANGUAGE[country], 0.5, "country_prior_short"
        return None, 0.0, "insufficient_text"

    try:
        results = detect_langs(text)
    except Exception:
        # Fallback: try country prior
        country = country_from_path(opml_path)
        if country and country in COUNTRY_LANGUAGE:
            return COUNTRY_LANGUAGE[country], 0.5, "country_prior_error"
        return None, 0.0, "detect_error"

    if not results:
        country = country_from_path(opml_path)
        if country and country in COUNTRY_LANGUAGE:
            return COUNTRY_LANGUAGE[country], 0.5, "country_prior_no_result"
        return None, 0.0, "no_result"

    best = results[0]
    if best.prob >= MIN_CONFIDENCE:
        return best.lang, best.prob, "detect"

    # Low confidence — check if country prior matches top result
    country = country_from_path(opml_path)
    if country and country in COUNTRY_LANGUAGE:
        country_lang = COUNTRY_LANGUAGE[country]
        for result in results:
            if result.lang == country_lang and result.prob >= 0.5:
                return country_lang, result.prob, "country_boosted"

    # If any result is high enough, use it
    if best.prob >= 0.5:
        return best.lang, best.prob, "detect_low_confidence"

    # Very low confidence — fall back to country prior if available
    if country and country in COUNTRY_LANGUAGE:
        return COUNTRY_LANGUAGE[country], 0.4, "country_prior_fallback"

    return None, best.prob, "low_confidence"


def country_from_path(opml_path: Path) -> str | None:
    """Extract country slug from an OPML path like .../90_countries/brazil/brazil.opml."""
    parts = opml_path.parts
    for idx, part in enumerate(parts):
        if part == "countries" or part.endswith("_countries"):
            if idx + 1 < len(parts):
                return parts[idx + 1]
            return None
    return None


def write_language(opml_path: Path, lang: str) -> bool:
    """Insert <language> tag into OPML <head> without reformatting the file.

    Uses surgical string insertion: finds </title> and inserts <language>
    right after. This preserves all existing whitespace and formatting.
    Returns True on success.
    """
    try:
        content = opml_path.read_text(encoding="utf-8")
    except Exception:
        return False

    # Already has <language> — skip
    if "<language>" in content:
        return True

    # Find </title> in <head> and insert <language> right after it
    title_end = content.find("</title>")
    if title_end == -1:
        # No title — insert after <head>
        head_start = content.find("<head>")
        if head_start == -1:
            return False
        insert_at = head_start + len("<head>")
        tag = f"\n    <language>{lang}</language>\n  "
    else:
        # Find end of </title> line
        line_end = content.find("\n", title_end)
        if line_end == -1:
            line_end = title_end + len("</title>")
        insert_at = line_end
        tag = f"\n    <language>{lang}</language>"

    new_content = content[:insert_at] + tag + content[insert_at:]
    try:
        opml_path.write_text(new_content, encoding="utf-8")
        return True
    except Exception:
        return False


def main():
    write_mode = "--write" in sys.argv

    opml_files = sorted(FEEDS_ROOT.rglob("*.opml"))
    print(f"Scanning {len(opml_files)} OPML files...\n")

    report = {
        "total": len(opml_files),
        "already_tagged": 0,
        "detected": 0,
        "skipped_low_confidence": 0,
        "skipped_insufficient_text": 0,
        "errors": 0,
        "by_language": defaultdict(int),
        "changes": [],
        "proposals": [],
    }

    for opml_path in opml_files:
        rel = opml_path.relative_to(FEEDS_ROOT)

        text = extract_text(opml_path)
        lang, confidence, method = detect_language(text, opml_path)

        if lang is None:
            report["skipped_low_confidence" if method != "insufficient_text" else "skipped_insufficient_text"] += 1
            if confidence > 0:
                print(f"  SKIP  {rel!s:70s}  no-lang  conf={confidence:.2f}  ({method})")
            else:
                print(f"  SKIP  {rel!s:70s}  no-lang  {method}")
            continue

        # Documented contract: only write at or above MIN_CONFIDENCE. Anything below
        # the floor is reported as a proposal for review and never written.
        if confidence < MIN_CONFIDENCE:
            report["skipped_low_confidence"] += 1
            report["proposals"].append({
                "path": str(rel),
                "proposed_language": lang,
                "confidence": round(confidence, 3),
                "method": method,
                "text_len": len(text),
            })
            print(f"  PROPOSE {rel!s:70s} → {lang:4s}  conf={confidence:.2f}  ({method}, below {MIN_CONFIDENCE})")
            continue

        report["by_language"][lang] += 1
        report["detected"] += 1
        entry = {
            "path": str(rel),
            "language": lang,
            "confidence": round(confidence, 3),
            "method": method,
            "text_len": len(text),
        }
        report["changes"].append(entry)

        status = "WRITE" if write_mode else "DRY-RUN"
        print(f"  {status:7s} {rel!s:70s} → {lang:4s}  conf={confidence:.2f}  ({method})")

        if write_mode:
            if not write_language(opml_path, lang):
                report["errors"] += 1
                print(f"          ERROR writing {rel}")

    # Summary
    print(f"\n{'='*60}")
    print(f"Total:       {report['total']:5d}")
    print(f"Detected:    {report['detected']:5d}")
    print(f"Skipped:     {report['skipped_low_confidence']:5d} (low confidence)")
    print(f"Proposals:   {len(report['proposals']):5d} (below conf {MIN_CONFIDENCE}, not written)")
    print(f"No text:     {report['skipped_insufficient_text']:5d} (insufficient text)")
    print(f"Errors:      {report['errors']:5d}")
    print(f"\nBy language:")
    for lang, count in sorted(report["by_language"].items(), key=lambda x: -x[1]):
        print(f"  {lang}: {count:5d}")

    if not write_mode:
        print("\n⚠️  DRY-RUN. Run with --write to apply changes.")

    # Save report
    report_path = FEEDS_ROOT.parent.parent.parent / ".superpowers" / "sdd" / "language-report.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    # Convert defaultdict for JSON
    report["by_language"] = dict(report["by_language"])
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(f"\nReport saved to {report_path}")


if __name__ == "__main__":
    main()
