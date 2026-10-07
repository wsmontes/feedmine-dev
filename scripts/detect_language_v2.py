#!/usr/bin/env python3
"""Detect per-feed language using fetched article content.

Strategy:
  1. Load article text from feeds_corpus_merged_parts/ (fetched content).
  2. Fall back to feed_title + feed_description from parquet if no articles.
  3. Run langdetect on the combined text for each feed.
  4. Write language attribute on each <outline type="rss"> element in OPMLs.
  5. The corpus parquet is read-only here: feed_reported_language is refreshed by
     the fetch/enrich pipeline, not by this script.
  6. Only write when confidence >= 0.9; weaker inferences are reported as proposals.

Usage:
  python3 scripts/detect_language_v2.py          # dry-run
  python3 scripts/detect_language_v2.py --write  # apply changes
"""

import json
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

import pyarrow.parquet as pq
from langdetect import DetectorFactory, detect_langs

DetectorFactory.seed = 0

ROOT = Path(__file__).resolve().parent.parent
FEEDS_DIR = ROOT / "feedmine" / "Resources" / "Feeds"
PARQUET_PATH = ROOT / "feeds_corpus_sources.parquet"
PARTS_DIR = ROOT / "feeds_corpus_merged_parts"

MIN_CONFIDENCE = 0.9
MIN_TEXT_LENGTH = 30  # chars — below this, keep existing language if any

# Map country dir names to their primary languages (used as prior, not override)
COUNTRY_DIR_TO_LANG = {
    "algeria": "ar", "angola": "pt", "argentina": "es", "armenia": "hy",
    "australia": "en", "austria": "de", "azerbaijan": "az", "bangladesh": "bn",
    "belarus": "be", "belgium": "nl", "bolivia": "es", "brazil": "pt",
    "bulgaria": "bg", "cambodia": "km", "canada": "en", "chile": "es",
    "china": "zh", "colombia": "es", "costa_rica": "es", "croatia": "hr",
    "cuba": "es", "cyprus": "el", "czech_republic": "cs", "denmark": "da",
    "dominican_republic": "es", "ecuador": "es", "egypt": "ar",
    "el_salvador": "es", "estonia": "et", "ethiopia": "am", "finland": "fi",
    "france": "fr", "georgia": "ka", "germany": "de", "ghana": "en",
    "greece": "el", "guatemala": "es", "haiti": "ht", "honduras": "es",
    "hungary": "hu", "iceland": "is", "india": "hi", "indonesia": "id",
    "iran": "fa", "iraq": "ar", "ireland": "en", "israel": "he",
    "italy": "it", "ivory_coast": "fr", "jamaica": "en", "japan": "ja",
    "kazakhstan": "kk", "kenya": "en", "latvia": "lv", "lithuania": "lt",
    "luxembourg": "fr", "malaysia": "ms", "malta": "mt", "mexico": "es",
    "morocco": "ar", "myanmar": "my", "nepal": "ne", "netherlands": "nl",
    "new_zealand": "en", "nicaragua": "es", "nigeria": "en", "norway": "no",
    "pakistan": "ur", "panama": "es", "paraguay": "es", "peru": "es",
    "philippines": "tl", "poland": "pl", "portugal": "pt",
    "puerto_rico": "es", "qatar": "ar", "romania": "ro", "russia": "ru",
    "saudi_arabia": "ar", "serbia": "sr", "singapore": "en",
    "slovakia": "sk", "slovenia": "sl", "south_africa": "en",
    "south_korea": "ko", "spain": "es", "sri_lanka": "si", "sudan": "ar",
    "sweden": "sv", "switzerland": "de", "taiwan": "zh", "thailand": "th",
    "tunisia": "ar", "turkey": "tr", "uae": "ar", "ukraine": "uk",
    "united_kingdom": "en", "uruguay": "es", "usa": "en",
    "venezuela": "es", "vietnam": "vi",
}


def load_article_texts():
    """Load article text per source_id from merged parts."""
    if not PARTS_DIR.exists():
        print("  WARNING: merged_parts dir not found, using parquet metadata only")
        return {}

    texts = defaultdict(list)
    for path in sorted(PARTS_DIR.glob("*.parquet")):
        try:
            parquet = pq.ParquetFile(path)
            columns_needed = ["source_id", "title", "content_text"]
            available = [c for c in columns_needed if c in parquet.schema.names]
            if "source_id" not in available:
                continue
            for batch in parquet.iter_batches(columns=available, batch_size=1024):
                data = batch.to_pydict()
                for i, sid in enumerate(data["source_id"]):
                    sid = str(sid)
                    parts = []
                    for col in available:
                        if col != "source_id":
                            val = str(data[col][i] or "").strip()
                            if val:
                                parts.append(val)
                    if parts:
                        texts[sid].append(" ".join(parts)[:500])
        except Exception:
            continue

    return texts


def load_parquet_metadata():
    """Load feed metadata per source_id from parquet."""
    sources = pq.read_table(str(PARQUET_PATH))
    df = sources.to_pandas()

    meta = {}
    for _, row in df.iterrows():
        sid = str(row["source_id"])
        title = str(row.get("feed_title") or row.get("source_title") or "")
        desc = str(row.get("feed_description") or "")
        reported_lang = str(row.get("feed_reported_language") or "")
        meta[sid] = {
            "title": title,
            "description": desc,
            "reported_language": reported_lang if reported_lang and reported_lang != "nan" else "",
        }
    return meta


def lang_base(code):
    """Extract base language from code like 'pt-BR' → 'pt'."""
    if not code:
        return ""
    return code.lower().split("-")[0]


def detect_feed_language(source_id, feed_title, existing_lang, article_texts, parquet_meta):
    """Detect language for a single feed using article content + metadata.

    Returns (lang_code, confidence, method) or (None, 0, reason).
    """
    parts = []

    # 1. Article content (best signal)
    if source_id in article_texts:
        for text in article_texts[source_id][:5]:
            parts.append(text)

    # 2. Parquet metadata (fallback)
    if source_id in parquet_meta:
        meta = parquet_meta[source_id]
        if meta["title"]:
            parts.append(meta["title"])
        if meta["description"]:
            parts.append(meta["description"])

    # 3. OPML title (weakest signal, but better than nothing)
    if feed_title and feed_title not in " ".join(parts):
        parts.append(feed_title)

    text = " ".join(parts).strip()

    if len(text) < MIN_TEXT_LENGTH:
        if existing_lang:
            return existing_lang, 1.0, "kept_existing"
        return None, 0.0, "insufficient_text"

    try:
        results = detect_langs(text)
    except Exception:
        if existing_lang:
            return existing_lang, 1.0, "kept_existing"
        return None, 0.0, "detect_error"

    if not results:
        if existing_lang:
            return existing_lang, 1.0, "kept_existing"
        return None, 0.0, "no_result"

    best = results[0]
    if best.prob >= MIN_CONFIDENCE:
        # Keep existing region code if base language matches
        if existing_lang and lang_base(existing_lang) == best.lang:
            return existing_lang, best.prob, "detect_articles" if source_id in article_texts else "detect_metadata"
        return best.lang, best.prob, "detect_articles" if source_id in article_texts else "detect_metadata"

    # Low confidence — keep existing if we have it
    if existing_lang:
        return existing_lang, 1.0, "kept_existing_low_conf"

    if best.prob >= 0.5:
        return best.lang, best.prob, "detect_low_confidence"

    return None, best.prob, "low_confidence"


def extract_country_from_path(opml_path):
    """Extract country slug from OPML path."""
    parts = opml_path.parts
    try:
        idx = parts.index("90_countries") if "90_countries" in parts else parts.index("countries")
        if idx + 1 < len(parts):
            return parts[idx + 1]
    except (ValueError, IndexError):
        pass
    return None


def main():
    write_mode = "--write" in sys.argv

    print("=" * 60)
    print("FeedMine — Per-feed Language Detection v2 (article content)")
    print("=" * 60)

    # Load data
    print("\n[1/3] Loading article content from merged_parts...")
    article_texts = load_article_texts()
    sources_with_articles = len(article_texts)
    print(f"  {sources_with_articles} sources have article text")

    print("\n[2/3] Loading parquet metadata...")
    parquet_meta = load_parquet_metadata()
    print(f"  {len(parquet_meta)} sources in parquet")

    print("\n[3/3] Scanning OPMLs and detecting languages...\n")
    opml_files = sorted(FEEDS_DIR.rglob("*.opml"))

    report = {
        "total_feeds": 0,
        "detected": 0,
        "kept_existing": 0,
        "unchanged": 0,
        "skipped": 0,
        "by_language": defaultdict(int),
        "by_method": defaultdict(int),
        "changes": [],
        "proposals": [],
    }

    for opml_path in opml_files:
        rel = opml_path.relative_to(FEEDS_DIR)
        country = extract_country_from_path(opml_path)

        try:
            tree = ET.parse(str(opml_path))
        except ET.ParseError:
            continue

        root = tree.getroot()
        body = root.find("body")
        if body is None:
            continue

        modified = False

        def walk(parent):
            nonlocal modified
            for child in list(parent):
                if child.tag == "outline" and child.get("type") == "rss":
                    report["total_feeds"] += 1

                    feed_title = child.get("title") or child.get("text") or ""
                    existing_lang = child.get("language", "").strip()
                    source_id = child.get("feedmineSourceId", "")

                    lang, confidence, method = detect_feed_language(
                        source_id, feed_title, existing_lang, article_texts, parquet_meta
                    )

                    if lang is None:
                        report["skipped"] += 1
                        if report["skipped"] <= 5:
                            print(f"  SKIP  [{country or 'topic':20s}] {feed_title[:60]}")
                        continue

                    # Documented contract: only write at or above MIN_CONFIDENCE.
                    # Weaker inferences are proposals for review, never mutations.
                    if confidence < MIN_CONFIDENCE:
                        report["skipped"] += 1
                        report["proposals"].append({
                            "country": country or "topic",
                            "title": feed_title[:100],
                            "old_lang": existing_lang,
                            "proposed_language": lang,
                            "confidence": round(confidence, 3),
                            "method": method,
                        })
                        if len(report["proposals"]) <= 5:
                            print(f"  PROPOSE [{country or 'topic':20s}] {feed_title[:60]}  "
                                  f"→ {lang} conf={confidence:.2f} ({method}, below {MIN_CONFIDENCE})")
                        continue

                    if lang_base(lang) == lang_base(existing_lang):
                        report["unchanged"] += 1
                        continue

                    report["detected"] += 1
                    report["by_language"][lang] += 1
                    report["by_method"][method] += 1
                    report["changes"].append({
                        "country": country or "topic",
                        "title": feed_title[:100],
                        "old_lang": existing_lang,
                        "new_lang": lang,
                        "confidence": round(confidence, 3),
                        "method": method,
                    })

                    if write_mode:
                        child.set("language", lang)
                        modified = True

                    if report["detected"] <= 10:
                        arrow = f"{existing_lang}→{lang}" if existing_lang and lang_base(existing_lang) != lang_base(lang) else f"keep {existing_lang}"
                        print(f"  DETECT [{country or 'topic':20s}] {feed_title[:60]}  {arrow:12s} conf={confidence:.2f} ({method})")

                elif child.tag == "outline":
                    walk(child)

        walk(body)

        if modified:
            ET.indent(root, space="  ")
            tree.write(str(opml_path), encoding="utf-8", xml_declaration=True)

    # Summary
    print(f"\n{'='*60}")
    print(f"Total feeds:    {report['total_feeds']:6d}")
    print(f"Detected:       {report['detected']:6d} (new/changed language)")
    print(f"Unchanged:      {report['unchanged']:6d}")
    print(f"Skipped:        {report['skipped']:6d} (insufficient text / below conf {MIN_CONFIDENCE})")
    print(f"Proposals:      {len(report['proposals']):6d} (not written)")
    print(f"\nBy method:")
    for method, count in sorted(report["by_method"].items(), key=lambda x: -x[1]):
        print(f"  {method}: {count:5d}")
    print(f"\nBy language:")
    for lang, count in sorted(report["by_language"].items(), key=lambda x: -x[1]):
        print(f"  {lang}: {count:5d}")

    if not write_mode:
        print(f"\n⚠️  DRY-RUN. Run with --write to apply changes.")

    # Save report
    report_path = ROOT / "scripts" / "language_detection_v2_report.json"
    # Convert defaultdicts for JSON
    report["by_language"] = dict(report["by_language"])
    report["by_method"] = dict(report["by_method"])
    with open(report_path, "w") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)
    print(f"\nReport saved to {report_path}")


if __name__ == "__main__":
    main()
