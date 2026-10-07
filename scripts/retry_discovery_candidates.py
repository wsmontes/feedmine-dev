#!/usr/bin/env python3
"""Retry failed/empty feeds from discovery-candidates.opml and promote successes.

Reads the 6,129 non-production identities from discovery-candidates.opml, refetches
each feed (HTTP GET + RSS/Atom parse), and promotes feeds that now return content
back to their original OPML files. Feeds that still fail remain in staging.

Usage:
    python3 scripts/retry_discovery_candidates.py --dry-run        # count + report only
    python3 scripts/retry_discovery_candidates.py                  # full run
    python3 scripts/retry_discovery_candidates.py --limit 100      # test first 100
    python3 scripts/retry_discovery_candidates.py --reset          # fresh start

Candidates are identified by ``feedmineSourceId`` when present and by the
identity computed from ``xmlUrl`` otherwise (the curation generator leaves the
attribute empty for unattempted candidates).  Fetched results are checkpointed
so an interrupted run resumes without refetching, while a candidate only
leaves staging — and is only marked processed — after its promotion has been
written to production and re-read.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import time
import xml.etree.ElementTree as ET
from collections import Counter
from copy import deepcopy
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

import feedparser
import httpx

try:
    from scripts.catalog_identity import compute_source_id
except ModuleNotFoundError:  # Direct ``python scripts/...`` execution.
    from catalog_identity import compute_source_id

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

ROOT = Path(__file__).resolve().parent.parent
FEEDS_ROOT = ROOT / "feedmine" / "Resources" / "Feeds"
DISCOVERY_OPML = ROOT / "editorial" / "feed-curation" / "staging" / "discovery-candidates.opml"
DISCOVERY_BACKUP = DISCOVERY_OPML.with_suffix(".opml.bak")
PROGRESS_PATH = ROOT / "build" / "discovery_retry_progress.json"
RESULTS_PATH = ROOT / "build" / "discovery_retry_results.json"
REPORT_PATH = ROOT / "build" / "discovery_retry_report.md"

# ---------------------------------------------------------------------------
# HTTP config
# ---------------------------------------------------------------------------

REQUEST_TIMEOUT = 30.0
MAX_RETRIES = 3
CONCURRENCY_DELAY = 0.3
USER_AGENT = "FeedMine/2.0 discovery-retry"

# Staging-only attributes to strip on promotion
STAGING_ATTRS = {
    "feedmineCandidate", "feedmineDisposition", "feedmineCorpusStatus",
    "feedmineCandidateKind", "feedmineAttemptCount", "feedmineHTTPStatus",
    "feedmineContentType", "feedmineFinalURL", "feedmineLastError",
}

# Attributes to update from fresh fetch
UPDATE_ATTRS = {
    "feedmineArticlesFetched", "feedmineLatestItemAt", "feedmineActivity",
}


# ---------------------------------------------------------------------------
# Activity classification
# ---------------------------------------------------------------------------

def classify_activity(articles_fetched: int, latest_item_at: str | None) -> str:
    """Classify posting frequency from fetch data."""
    if articles_fetched == 0:
        return "dormant"
    if not latest_item_at:
        return "active" if articles_fetched >= 10 else "quiet"

    try:
        latest = parsedate_to_datetime(latest_item_at)
        age_days = (datetime.now(timezone.utc) - latest).days
        if age_days <= 3:
            return "prolific"
        elif age_days <= 14:
            return "active"
        elif age_days <= 90:
            return "quiet"
        else:
            return "dormant"
    except Exception:
        return "active" if articles_fetched >= 10 else "quiet"


def determine_default_enabled(activity: str, articles_fetched: int) -> bool:
    """Decide whether to enable by default after retry."""
    if activity == "dormant":
        return articles_fetched >= 5
    return True


# ---------------------------------------------------------------------------
# OPML I/O
# ---------------------------------------------------------------------------

def parse_opml(path: Path) -> tuple[ET.ElementTree, ET.Element]:
    """Parse an OPML file, return (tree, body_element)."""
    tree = ET.parse(str(path))
    body = tree.find("body")
    if body is None:
        raise ValueError(f"No <body> in {path}")
    return tree, body


def candidate_key(outline: ET.Element) -> str:
    """Stable identity of a staging candidate.

    The curation generator leaves ``feedmineSourceId`` empty for candidates
    with no corpus record (``unattempted``), so fall back to the identity
    computed from the feed URL — the same formula used everywhere else.
    """
    source_id = outline.get("feedmineSourceId", "")
    if source_id:
        return source_id
    xml_url = outline.get("xmlUrl", "").strip()
    return compute_source_id(xml_url) if xml_url else ""


def save_opml(tree: ET.ElementTree, path: Path) -> None:
    """Save OPML with backup, writing through a temporary file."""
    backup = path.with_suffix(".opml.retry-bak")
    if path.exists():
        shutil.copy2(path, backup)
    ET.indent(tree, space="      ", level=0)
    temporary = path.with_suffix(path.suffix + ".tmp")
    tree.write(str(temporary), encoding="utf-8", xml_declaration=True)
    temporary.replace(path)


def confirm_promotion(path: Path, outlines: list[ET.Element]) -> None:
    """Re-read *path* and fail if a promoted feed is not on disk."""
    expected = {outline.get("xmlUrl", "").strip() for outline in outlines}
    expected.discard("")
    present = {
        element.get("xmlUrl", "").strip()
        for element in ET.parse(str(path)).getroot().iter("outline")
    }
    missing = sorted(expected - present)
    if missing:
        raise ValueError(
            f"{len(missing)} promoted feed(s) missing after save (e.g. {missing[0]})"
        )


def prune_empty_groups(element: ET.Element) -> None:
    """Recursively drop category containers left without children."""
    for child in list(element):
        prune_empty_groups(child)
        if child.tag == "outline" and len(child) == 0 and child.get("xmlUrl") is None:
            element.remove(child)


def find_or_create_outline_path(body: ET.Element, text_path: list[str]) -> ET.Element:
    """Traverse/create nested <outline text="..."> elements in body.

    For country OPMLs, path is like ["News & Current Affairs", "Brazilian Content"].
    For topic OPMLs, path is like ["Travel"].
    Each segment creates/finds an <outline text="segment">.
    """
    current = body
    for segment in text_path:
        found = None
        for child in current:
            if child.get("text") == segment and child.tag == "outline":
                found = child
                break
        if found is None:
            found = ET.SubElement(current, "outline", {"text": segment, "title": segment})
        current = found
    return current


# ---------------------------------------------------------------------------
# Feed retry
# ---------------------------------------------------------------------------

def retry_feed(xml_url: str) -> dict | None:
    """Fetch + parse a feed URL. Returns metadata dict on success, None on failure."""
    headers = {"User-Agent": USER_AGENT}
    for attempt in range(MAX_RETRIES):
        try:
            resp = httpx.get(xml_url, headers=headers, timeout=REQUEST_TIMEOUT, follow_redirects=True)
            if resp.status_code != 200:
                if attempt < MAX_RETRIES - 1:
                    time.sleep(2 ** attempt)
                    continue
                return None

            content = resp.text
            feed = feedparser.parse(content)

            # Check for parse errors
            if feed.bozo and not feed.entries:
                if attempt < MAX_RETRIES - 1:
                    time.sleep(2 ** attempt)
                    continue
                return None

            entries = feed.entries
            if not entries:
                return None

            # Determine latest item
            latest_at = ""
            if entries:
                pub = entries[0].get("published_parsed") or entries[0].get("updated_parsed")
                if pub:
                    latest_at = time.strftime("%Y-%m-%d %H:%M:%S%z", pub)

            articles_fetched = len(entries)

            return {
                "articles_fetched": articles_fetched,
                "latest_item_at": latest_at,
                "activity": classify_activity(articles_fetched, latest_at),
                "http_status": resp.status_code,
                "final_url": str(resp.url),
                "content_type": resp.headers.get("content-type", ""),
            }
        except Exception:
            if attempt < MAX_RETRIES - 1:
                time.sleep(2 ** attempt)
            else:
                return None
    return None


# ---------------------------------------------------------------------------
# Outline promotion
# ---------------------------------------------------------------------------

def clean_outline(outline: ET.Element) -> ET.Element:
    """Remove staging-only attributes from an outline element."""
    cleaned = deepcopy(outline)
    for attr in STAGING_ATTRS:
        if attr in cleaned.attrib:
            del cleaned.attrib[attr]
    # Also remove any XML-namespace remnants from the staging file
    for key in list(cleaned.attrib.keys()):
        if key.startswith("{"):
            del cleaned.attrib[key]
    return cleaned


def update_outline_from_fetch(outline: ET.Element, result: dict) -> None:
    """Update outline attributes with fresh fetch data."""
    outline.set("feedmineArticlesFetched", str(result["articles_fetched"]))
    if result.get("latest_item_at"):
        outline.set("feedmineLatestItemAt", result["latest_item_at"])
    outline.set("feedmineActivity", result.get("activity", "quiet"))
    activity = result.get("activity", "quiet")
    enabled = determine_default_enabled(activity, result["articles_fetched"])
    outline.set("feedmineDefaultEnabled", "true" if enabled else "false")


def resolve_original_opml(outline: ET.Element) -> Path | None:
    """Map feedmineOriginalFile to a real OPML path under Resources/Feeds."""
    orig = outline.get("feedmineOriginalFile", "")
    if not orig:
        return None

    # The original file is like "General/general_english.opml" or "Arts_Culture/folklore.opml"
    # Try to find it under the Feeds root
    # First, try direct path
    candidate = FEEDS_ROOT / orig
    if candidate.exists():
        return candidate

    # Try with folder prefix (numeric ordering)
    # The OPML structure uses numbered folders like 01_News_&_Current_Affairs
    # We need to map "General" → "17_General_Interests", "Arts_Culture" → "02_Arts_&_Culture", etc.
    FOLDER_MAP = {
        "Arts_Culture": "02_Arts_&_Culture",
        "Entertainment": "03_Entertainment",
        "Tech_Science": "04_Technology_&_Science",
        "Technology_Science": "04_Technology_&_Science",
        "Business_Industry": "05_Business_&_Industry",
        "Health_Wellness": "06_Health_&_Wellness",
        "Sports": "07_Sports",
        "Food_Drink": "08_Food_&_Drink",
        "Home_Living": "09_Home_&_Living",
        "Travel_Transport": "10_Travel_&_Transport",
        "Education_Knowledge": "11_Education_&_Knowledge",
        "Society_Identity": "12_Society_&_Identity",
        "Religion_Spirituality": "13_Religion_&_Spirituality",
        "Games_Hobbies": "14_Games_&_Hobbies",
        "Nature_Animals": "15_Nature_&_Animals",
        "Music_Audio": "16_Music_&_Audio",
        "General": "17_General_Interests",
        "Knowledge": "11_Education_&_Knowledge",
        "News": "01_News_&_Current_Affairs",
        "Finance": "05_Business_&_Industry",
        "Science": "04_Technology_&_Science",
        "cars_motorcycles": "10_Travel_&_Transport",
        "aviation": "10_Travel_&_Transport",
    }

    parts = orig.split("/")
    if len(parts) >= 2:
        old_folder = parts[0]
        filename = parts[-1]
        new_folder = FOLDER_MAP.get(old_folder)
        if new_folder:
            candidate = FEEDS_ROOT / new_folder / filename
            if candidate.exists():
                return candidate
            # Some files were merged into topic.opml
            topic_file = FEEDS_ROOT / new_folder / f"{new_folder}.opml"
            if topic_file.exists():
                return topic_file

    # Last resort: search for the filename anywhere under Feeds
    filename = orig.split("/")[-1] if "/" in orig else orig
    for f in FEEDS_ROOT.rglob(filename):
        return f

    return None


# ---------------------------------------------------------------------------
# Progress
# ---------------------------------------------------------------------------

def load_progress() -> set[str]:
    """Return set of candidate ids already committed (or permanently failed)."""
    if PROGRESS_PATH.exists():
        with open(PROGRESS_PATH) as f:
            data = json.load(f)
            return set(data.get("processed", []))
    return set()


def load_results() -> dict[str, dict]:
    """Fetch results checkpointed by a previous run, keyed by candidate id.

    A result here is an *intention*, not a commit: the candidate is still in
    staging until its promotion has been written and verified.
    """
    if RESULTS_PATH.exists():
        try:
            with open(RESULTS_PATH) as f:
                return json.load(f).get("results", {})
        except (OSError, ValueError):
            return {}
    return {}


def save_results(results: dict[str, dict]) -> None:
    """Checkpoint fetched results so an interrupted run resumes without refetch."""
    RESULTS_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = RESULTS_PATH.with_suffix(".tmp")
    with open(tmp, "w") as f:
        json.dump({"results": results}, f, indent=1, sort_keys=True)
    tmp.replace(RESULTS_PATH)


def save_progress(processed: set[str]) -> None:
    """Save progress for resume."""
    PROGRESS_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = PROGRESS_PATH.with_suffix(".tmp")
    with open(tmp, "w") as f:
        json.dump({"processed": sorted(processed)}, f)
    tmp.replace(PROGRESS_PATH)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def collect_candidates(tree: ET.ElementTree) -> list[ET.Element]:
    """Extract all feed outline elements with xmlUrl from the discovery OPML."""
    candidates = []
    for outline in tree.iter("outline"):
        if outline.get("xmlUrl"):
            candidates.append(outline)
    return candidates


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="Report only, no changes")
    parser.add_argument("--limit", type=int, default=0, help="Process at most N candidates")
    parser.add_argument("--reset", action="store_true", help="Ignore saved progress and checkpointed results")
    args = parser.parse_args()

    if not DISCOVERY_OPML.exists():
        print(f"❌ Discovery OPML not found: {DISCOVERY_OPML}")
        return 1

    # Parse discovery OPML
    print(f"📂 Loading {DISCOVERY_OPML.name}...")
    disc_tree = ET.parse(str(DISCOVERY_OPML))
    candidates = collect_candidates(disc_tree)
    print(f"   Found {len(candidates):,} feed candidates")

    # Breakdown by disposition
    dispos = Counter(c.get("feedmineDisposition", "unknown") for c in candidates)
    print(f"\n📊 By disposition:")
    for d, cnt in dispos.most_common():
        print(f"   {cnt:>6,}  {d}")

    kinds = Counter(c.get("feedmineCandidateKind", "unknown") for c in candidates)
    print(f"\n📊 By candidate kind:")
    for k, cnt in kinds.most_common():
        print(f"   {cnt:>6,}  {k}")

    # Skip policy-excluded — they stay excluded
    actionable = [c for c in candidates if c.get("feedmineDisposition") != "excluded_policy"]
    skipped_policy = len(candidates) - len(actionable)
    if skipped_policy:
        print(f"\n   ⏭️  Skipping {skipped_policy} policy-excluded feeds (they stay excluded)")

    if args.dry_run:
        print(f"\n🏁 DRY RUN — {len(actionable):,} feeds would be retried. No changes made.")
        return 0

    # Resume from committed progress + checkpointed fetch results
    processed = set() if args.reset else load_progress()
    fetched: dict[str, dict] = {} if args.reset else load_results()
    todo: list[tuple[str, ET.Element]] = []
    for c in actionable:
        key = candidate_key(c)
        if key and key not in processed:
            todo.append((key, c))
    if args.limit > 0:
        todo = todo[:args.limit]

    print(f"\n🚀 Retrying {len(todo):,} feeds ({len(processed):,} already committed, "
          f"{len(fetched):,} results checkpointed)...")

    # Track results per original OPML file (to batch-insert at the end)
    promoted: list[tuple[Path, ET.Element]] = []  # (target_opml_path, cleaned_outline)
    still_failed: list[ET.Element] = []
    results: list[dict] = []

    for i, (key, outline) in enumerate(todo):
        xml_url = outline.get("xmlUrl", "")
        title = outline.get("text", outline.get("title", "?"))

        if i % 100 == 0 and i > 0:
            print(f"\n--- [{i}/{len(todo)}] {len(promoted)} promoted, {len(still_failed)} failed so far ---")

        # Fetch
        print(f"   [{i+1}/{len(todo)}] {title[:70]} ...", end=" ")
        result = fetched.get(key) or retry_feed(xml_url)

        if result:
            fetched[key] = result
            print(f"✅ {result['articles_fetched']} articles, {result.get('activity','?')}")
            # Find original OPML
            orig_path = resolve_original_opml(outline)
            if orig_path:
                cleaned = clean_outline(outline)
                update_outline_from_fetch(cleaned, result)
                promoted.append((orig_path, cleaned))
                results.append({
                    "title": title,
                    "xml_url": xml_url,
                    "status": "promoted",
                    "target_opml": str(orig_path.relative_to(ROOT)),
                    "articles": result["articles_fetched"],
                    "activity": result.get("activity", ""),
                })
            else:
                print(f"   ⚠️  Could not resolve original OPML for: {outline.get('feedmineOriginalFile','?')}")
                still_failed.append(outline)
                results.append({"title": title, "xml_url": xml_url, "status": "no_opml_path"})
        else:
            print(f"❌ still failing")
            still_failed.append(outline)
            results.append({"title": title, "xml_url": xml_url, "status": "still_failed"})

        # Checkpoint fetch results only — nothing is marked processed, and no
        # candidate leaves staging, until its promotion is written to disk.
        if i % 50 == 0 and i > 0:
            save_results(fetched)

        time.sleep(CONCURRENCY_DELAY)

    # -----------------------------------------------------------------------
    # Apply promotions — batch by target OPML
    # -----------------------------------------------------------------------
    print(f"\n{'='*60}")
    print(f"📝 Applying {len(promoted)} promotions...")

    # Group by target OPML
    by_opml: dict[Path, list[ET.Element]] = {}
    for path, outline in promoted:
        by_opml.setdefault(path, []).append(outline)

    # A promotion is committed only once its file was written and re-read.
    committed: set[str] = set()
    failed_paths: list[Path] = []

    for opml_path, outlines in sorted(by_opml.items()):
        print(f"\n   {opml_path.relative_to(ROOT)}: {len(outlines)} new outlines")
        try:
            tree, body = parse_opml(opml_path)
            existing_urls = {el.get("xmlUrl", "").strip() for el in body.iter("outline")}
            for outline in outlines:
                url = outline.get("xmlUrl", "").strip()
                if url and url in existing_urls:
                    # Already written by an earlier partially-applied run.
                    continue
                topic = outline.get("feedmineTopic", "")
                subcat = outline.get("feedmineSubcategory", "")
                # Navigate to the right place
                path_parts = []
                if topic:
                    path_parts.append(topic)
                if subcat and subcat != topic:
                    path_parts.append(subcat)
                if path_parts:
                    parent = find_or_create_outline_path(body, path_parts)
                else:
                    parent = body
                parent.append(outline)
                existing_urls.add(url)
            save_opml(tree, opml_path)
            confirm_promotion(opml_path, outlines)
            committed.update(candidate_key(outline) for outline in outlines)
            print(f"   ✅ Saved")
        except Exception as e:
            print(f"   ❌ Error: {e}")
            failed_paths.append(opml_path)

    # Remove promoted outlines from discovery OPML — only the ones written.
    if committed:
        print(f"\n🧹 Removing {len(committed)} promoted outlines from discovery-candidates.opml...")
        # Backup
        shutil.copy2(DISCOVERY_OPML, DISCOVERY_BACKUP)

        body = disc_tree.find("body")
        if body is not None:
            parents = {child: parent for parent in body.iter() for child in list(parent)}
            to_remove = [
                outline for outline in body.iter("outline")
                if candidate_key(outline) in committed
            ]
            for el in to_remove:
                parent = parents.get(el)
                if parent is not None:
                    parent.remove(el)

            # Clean up category containers left without children
            prune_empty_groups(body)

            save_opml(disc_tree, DISCOVERY_OPML)
            print(f"   ✅ Cleaned discovery OPML")

    # Commit: only now is it safe to skip these candidates on a future run.
    for key in committed:
        fetched.pop(key, None)
    processed.update(committed)
    for outline in still_failed:
        key = candidate_key(outline)
        if key:
            processed.add(key)
    save_results(fetched)
    save_progress(processed)

    # -----------------------------------------------------------------------
    # Report
    # -----------------------------------------------------------------------
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)

    promoted_count = len(committed)
    failed_count = len(still_failed)
    unapplied_paths = [path for path in failed_paths]
    unapplied_count = sum(len(by_opml[path]) for path in unapplied_paths)
    total = promoted_count + failed_count + unapplied_count

    lines = [
        "# Discovery Candidates Retry Report",
        f"\n**Date:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        f"\n## Summary",
        f"\n| Metric | Count |",
        f"|--------|-------|",
        f"| Total retried | {total:,} |",
        f"| ✅ Promoted | {promoted_count:,} ({promoted_count/total*100:.1f}%)" if total else "| ✅ Promoted | 0 |",
        f"| ❌ Still failing | {failed_count:,} ({failed_count/total*100:.1f}%)" if total else "| ❌ Still failing | 0 |",
        f"| ⏸️ Not applied (save failed) | {unapplied_count:,} |" if unapplied_count else "",
        f"| ⏭️ Policy excluded (skipped) | {skipped_policy:,} |",
    ]

    lines.append(f"\n## ✅ Promoted — by target OPML")
    for opml_path, outlines in sorted(by_opml.items()):
        if opml_path in unapplied_paths:
            lines.append(f"- **{opml_path.relative_to(ROOT)}**: {len(outlines)} feeds — ❌ not applied")
        else:
            lines.append(f"- **{opml_path.relative_to(ROOT)}**: {len(outlines)} feeds")

    if failed_count > 0:
        lines.append(f"\n## ❌ Still failing ({failed_count})")
        # Group by original file
        by_orig = Counter(
            c.get("feedmineOriginalFile", "unknown") for c in still_failed
        )
        for orig, cnt in by_orig.most_common(20):
            lines.append(f"- {cnt:>4}  {orig}")

    with open(REPORT_PATH, "w") as f:
        f.write("\n".join(line for line in lines if line) + "\n")

    print(f"\n{'='*60}")
    print(f"✅ DONE — {promoted_count:,} promoted, {failed_count:,} still failing")
    print(f"📄 Report: {REPORT_PATH}")
    if failed_paths:
        print(
            f"❌ {len(failed_paths)} OPML file(s) could not be updated; their candidates "
            f"stay in staging and will be retried.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
