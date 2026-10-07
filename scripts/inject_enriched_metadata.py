#!/usr/bin/env python3
"""Inject AI-generated descriptions and tags from enriched parquet into OPML files.

Reads an enriched parquet (after fetch + enrich steps), finds the corresponding
<outline> elements in the production OPML tree, and updates them with:
  - AI description + tags
  - Recalculated quality_score
  - Activity level (from latest_item_at)
  - Nature classification
  - default_enabled flag

Usage:
    python3 scripts/inject_enriched_metadata.py \
      --parquet build/youtube-isolated/feeds_corpus_sources.parquet \
      --feeds-root feedmine/Resources/Feeds
"""

from __future__ import annotations

import argparse
import re
import shutil
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pyarrow.parquet as pq

try:
    from scripts.catalog_identity import compute_source_id
except ModuleNotFoundError:
    from catalog_identity import compute_source_id


# ---------------------------------------------------------------------------
# Helpers (mirroring curate_opml_catalog.py logic)
# ---------------------------------------------------------------------------

def _as_aware_utc(value: datetime) -> datetime:
    """Normalize a datetime to timezone-aware UTC (naive values are read as UTC)."""
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _parse_now(value: str | None) -> datetime:
    """Parse the --now argument (ISO-8601) into an aware UTC datetime."""
    if not value:
        return datetime.now(timezone.utc)
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return _as_aware_utc(datetime.fromisoformat(text))
    except ValueError as exc:
        raise SystemExit(f"--now is not a valid ISO-8601 timestamp: {value!r}") from exc


def activity_for(latest_item_at_str: str | None, articles_fetched: int, now: datetime) -> str:
    """Classify activity: prolific, active, quiet, dormant."""
    if not latest_item_at_str or articles_fetched < 1:
        return "dormant"
    try:
        ts = latest_item_at_str
        if ts.endswith("Z"):
            ts = ts[:-1] + "+00:00"
        latest = _as_aware_utc(datetime.fromisoformat(ts))
    except (ValueError, TypeError):
        return "dormant"

    age = _as_aware_utc(now) - latest
    if age <= timedelta(days=14) and articles_fetched >= 5:
        return "prolific"
    if age <= timedelta(days=90):
        return "active"
    if age <= timedelta(days=365):
        return "quiet"
    return "dormant"


def classify_nature(topic: str, tags: str) -> str:
    """Determine content freshness nature."""
    t = f"{topic} {tags}".lower()
    current_sensitive = (
        "news", "current events", "politics", "government", "election",
        "geopolitics", "markets", "stock market", "financial news", "sports",
        "weather", "gossip", "celebrity", "entertainment news", "local news",
        "journalism", "breaking news",
    )
    if any(kw in t for kw in current_sensitive):
        return "current-sensitive"
    return "evergreen"


def quality_score(description: str, tags: str, articles_fetched: int, activity: str) -> int:
    """Compute 0-100 quality score."""
    score = 35  # base
    desc_words = len(description.split()) if description else 0
    if desc_words >= 10:
        score += 10
    elif desc_words >= 5:
        score += 5
    tag_count = len([t.strip() for t in tags.split(",") if t.strip()]) if tags else 0
    if tag_count >= 4:
        score += 15
    elif tag_count >= 2:
        score += 10
    elif tag_count >= 1:
        score += 5
    if articles_fetched >= 15:
        score += 15
    elif articles_fetched >= 5:
        score += 10
    elif articles_fetched >= 1:
        score += 5
    if activity == "prolific":
        score += 15
    elif activity == "active":
        score += 10
    elif activity == "quiet":
        score += 5
    return min(100, score)


def default_enabled_for(nature: str, activity: str) -> bool:
    """Dormant current-sensitive or personal sources are disabled."""
    if activity in ("dormant",) and nature in ("current-sensitive", "personal"):
        return False
    return True


def language_label(lang: str | None) -> str:
    """Normalize language code."""
    if not lang:
        return ""
    lang = lang.lower().strip()
    aliases = {
        "english": "en", "portuguese": "pt", "brazilian portuguese": "pt-BR",
        "spanish": "es", "french": "fr", "german": "de", "italian": "it",
    }
    return aliases.get(lang, lang)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def inject(args: argparse.Namespace) -> dict:
    sources_path: Path = args.parquet
    feeds_root: Path = args.feeds_root
    now = _parse_now(args.now)

    if not sources_path.exists():
        raise FileNotFoundError(f"Parquet not found: {sources_path}")
    if not feeds_root.exists():
        raise FileNotFoundError(f"Feeds root not found: {feeds_root}")

    # ── 1. Read enriched parquet ──────────────────────────────────────────
    table = pq.read_table(sources_path)
    df = table.to_pandas()
    done = df[df["status"] == "done"].copy()

    # Build TWO lookups: by canonical source_id AND by raw xmlUrl
    enriched: dict[str, dict] = {}
    enriched_by_url: dict[str, dict] = {}
    for _, row in done.iterrows():
        url = str(row.get("xml_url", "") or row.get("canonical_xml_url", ""))
        key = compute_source_id(url)
        data = {
            "description": str(row.get("ai_description", "") or ""),
            "tags": str(row.get("ai_tags", "") or ""),
            "articles_fetched": int(row.get("articles_fetched", 0) or 0),
            "latest_item_at": str(row.get("latest_item_at", "") or ""),
            "language": str(row.get("feed_reported_language", "") or ""),
            "site_url": str(row.get("site_url", "") or ""),
            "xml_url": url,
        }
        enriched[key] = data
        # Also index by raw xmlUrl for feeds whose feedmineSourceId uses raw URL hash
        enriched_by_url[url.strip().lower()] = data

    print(f"Loaded {len(enriched)} enriched sources from parquet")

    # ── 2. Scan OPML files and update ─────────────────────────────────────
    updated_count = 0
    unchanged_count = 0
    skipped_count = 0
    not_found = 0
    files_touched = set()

    # Backup first. A dry run writes nothing, so it takes no backup and restores nothing.
    if args.dry_run:
        print("Dry run: the feeds tree will not be touched")
    elif not args.no_backup:
        backup_dir = feeds_root.parent / "Feeds.backup.inject"
        if backup_dir.exists():
            shutil.rmtree(backup_dir)
        shutil.copytree(feeds_root, backup_dir)
        print(f"Backup: {backup_dir}")

    for opml_path in sorted(feeds_root.rglob("*.opml")):
        if not opml_path.is_file():
            continue

        content = opml_path.read_text(encoding="utf-8")
        modified = False

        # Find all outline elements and check if they match our enriched sources
        def replace_outline(match):
            nonlocal modified, updated_count, unchanged_count, skipped_count
            element_str = match.group(0)

            # Extract xmlUrl
            url_match = re.search(r'xmlUrl="([^"]*)"', element_str)
            if not url_match:
                return element_str

            url = url_match.group(1)
            source_id = compute_source_id(url)

            # Try matching by canonical source_id first, then by raw URL
            data = enriched.get(source_id) or enriched_by_url.get(url.strip().lower())
            if data is None:
                return element_str

            # Keep a substantial, non-generic curated description; every other attribute
            # is derived from the parquet and is refreshed field by field below.
            desc_match = re.search(r'description="([^"]*)"', element_str)
            existing_desc = desc_match.group(1) if desc_match else ""
            # Generic placeholders that should be replaced
            is_generic = (
                existing_desc.startswith("Writer/author blog") or
                existing_desc.startswith("Journalist blog") or
                existing_desc.startswith("Artist blog") or
                len(existing_desc) < 30
            )
            keep_description = bool(existing_desc) and not is_generic and len(existing_desc) >= 30
            if keep_description:
                skipped_count += 1

            # Compute metadata
            activity = activity_for(data["latest_item_at"], data["articles_fetched"], now)
            topic_match = re.search(r'feedmineTopic="([^"]*)"', element_str)
            topic = topic_match.group(1) if topic_match else ""
            nature = classify_nature(topic, data["tags"])
            score = quality_score(data["description"], data["tags"], data["articles_fetched"], activity)
            enabled = "true" if default_enabled_for(nature, activity) else "false"
            lang_match = re.search(r'language="([^"]*)"', element_str)
            lang = language_label(data["language"] or (lang_match.group(1) if lang_match else ""))

            # Build new attributes (name, value) — existing values are replaced in place
            new_attrs: list[tuple[str, str]] = []
            if not keep_description:
                new_attrs.append(("description", _escape_xml(data["description"])))
            new_attrs.append(("category", _escape_xml(data["tags"])))
            new_attrs.append(("feedmineNature", nature))
            new_attrs.append(("feedmineActivity", activity))
            new_attrs.append(("feedmineArticlesFetched", str(data["articles_fetched"])))
            new_attrs.append(("feedmineQualityScore", str(score)))
            new_attrs.append(("feedmineDefaultEnabled", enabled))
            if lang:
                new_attrs.append(("language", lang))
            if data["site_url"] and "htmlUrl=" not in element_str:
                new_attrs.append(("htmlUrl", _escape_xml(data["site_url"])))

            attr_str = element_str
            for attr_name, attr_value in new_attrs:
                attr_str = _set_attr(attr_str, attr_name, attr_value)

            if attr_str == element_str:
                unchanged_count += 1
                return element_str
            modified = True
            updated_count += 1
            return attr_str

        # Apply replacements
        new_content = re.sub(r'<outline[^>]+/>', replace_outline, content)

        if modified:
            files_touched.add(str(opml_path.relative_to(feeds_root)))
            if not args.dry_run:
                opml_path.write_text(new_content, encoding="utf-8")

    # ── 3. Report ─────────────────────────────────────────────────────────
    # Check for not-found
    all_opml_urls = set()
    for opml_path in feeds_root.rglob("*.opml"):
        content = opml_path.read_text(encoding="utf-8")
        for m in re.finditer(r'xmlUrl="([^"]+)"', content):
            all_opml_urls.add(compute_source_id(m.group(1)))

    for sid in enriched:
        if sid not in all_opml_urls:
            not_found += 1

    print(f"\n{'='*60}")
    print(f"INJECTION RESULTS:")
    print(f"  Updated:  {updated_count}")
    print(f"  Unchanged: {unchanged_count}")
    print(f"  Kept editorial desc: {skipped_count}")
    print(f"  Not found in OPML: {not_found}")
    print(f"  Files touched: {len(files_touched)}")

    if args.dry_run:
        print("\n  DRY RUN — no files were modified (nothing written, deleted or restored)")

    return {
        "updated": updated_count,
        "unchanged": unchanged_count,
        "skipped": skipped_count,
        "not_found": not_found,
    }


def _escape_xml(s: str) -> str:
    """Escape special XML characters."""
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def _set_attr(element_str: str, name: str, value: str) -> str:
    """Replace an attribute value in place, or append the attribute before ``/>``."""
    pattern = re.compile(rf'(?<=\s){re.escape(name)}="[^"]*"')
    if pattern.search(element_str):
        return pattern.sub(f'{name}="{value}"', element_str, count=1)
    return element_str.rstrip("/>").rstrip() + f' {name}="{value}" />'


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--parquet", type=Path, required=True)
    parser.add_argument("--feeds-root", type=Path, default=Path("feedmine/Resources/Feeds"))
    parser.add_argument("--now", help="ISO-8601 reference time")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-backup", action="store_true")
    return parser.parse_args()


if __name__ == "__main__":
    result = inject(parse_args())
    print(f"\nDone: {result}")
