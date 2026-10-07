#!/usr/bin/env python3
"""
Merge ALL remaining staging feeds into production, even unfetched ones.

Feeds already in production are skipped. Unfetched feeds get minimal metadata
with feedmineNature="unverified" so they're clearly distinguishable from
fully-curated feeds.

Usage:
    python scripts/merge_remaining_staging.py --dry-run
    python scripts/merge_remaining_staging.py --write
"""

from __future__ import annotations
import hashlib, json, sys
from pathlib import Path
from collections import defaultdict
import xml.etree.ElementTree as ET

try:
    from scripts.catalog_identity import compute_source_id
except ModuleNotFoundError:
    from catalog_identity import compute_source_id

REPO_ROOT = Path(__file__).resolve().parents[1]
STAGING = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "_staging"
PRODUCTION = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "90_countries"
ENRICHED_PATH = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "countries_enriched.json"


def _indent_xml(elem: ET.Element, level: int = 0) -> None:
    indent = "\n" + "  " * level
    if len(elem):
        if not elem.text or not elem.text.strip(): elem.text = indent + "  "
        if not elem.tail or not elem.tail.strip(): elem.tail = indent
        for sub in elem: _indent_xml(sub, level + 1)
        if not elem[-1].tail or not elem[-1].tail.strip(): elem[-1].tail = indent
    else:
        if level and (not elem.tail or not elem.tail.strip()): elem.tail = indent


def infer_lang(slug: str, enriched: dict) -> str:
    meta = enriched.get(slug.replace("_", "-"), {}) or enriched.get(slug, {})
    return meta.get("lang", "")


def main():
    write_mode = "--write" in sys.argv
    if not write_mode:
        print("🔍 DRY RUN — use --write to apply\n")

    with open(ENRICHED_PATH, encoding="utf-8") as f:
        enriched = json.load(f)

    total_added = 0
    countries_updated = 0
    skipped_existing = 0

    for staging_dir in sorted(STAGING.iterdir()):
        if not staging_dir.is_dir(): continue
        slug = staging_dir.name
        staging_opml = staging_dir / f"{slug}.opml"
        if not staging_opml.exists(): continue

        prod_opml = PRODUCTION / slug / f"{slug}.opml"
        if not prod_opml.exists(): continue

        # Read staging feeds
        try:
            s_tree = ET.parse(str(staging_opml))
        except ET.ParseError:
            continue
        s_body = s_tree.getroot().find("body")
        if s_body is None: continue

        staging_feeds = []
        for feed in s_body.iter("outline"):
            url = feed.get("xmlUrl", "")
            if url:
                staging_feeds.append({
                    "url": url,
                    "title": feed.get("title", ""),
                    "category": feed.get("category", ""),
                })

        if not staging_feeds: continue

        # Read production OPML
        try:
            p_tree = ET.parse(str(prod_opml))
        except ET.ParseError:
            continue
        p_root = p_tree.getroot()
        p_body = p_root.find("body")
        if p_body is None: continue

        # Canonical source identity: dedupe against production *and* within this batch.
        existing_ids = set()
        for o in p_body.iter("outline"):
            u = o.get("xmlUrl", "")
            if u: existing_ids.add(compute_source_id(u))

        truly_new = []
        for f in staging_feeds:
            sid = compute_source_id(f["url"])
            if sid in existing_ids:
                skipped_existing += 1
                continue
            existing_ids.add(sid)
            truly_new.append(f)
        if not truly_new: continue

        lang = infer_lang(slug, enriched)

        # Group by topic
        by_topic = defaultdict(list)
        for f in truly_new:
            cat = (f.get("category") or "").lower()
            topic = "General Interests"
            if "news" in cat or "politics" in cat: topic = "News & Current Affairs"
            elif "business" in cat or "invest" in cat: topic = "Business & Industry"
            elif "tech" in cat or "science" in cat: topic = "Technology & Science"
            elif "sport" in cat or "soccer" in cat: topic = "Sports"
            elif "music" in cat: topic = "Music & Audio"
            elif "comedy" in cat or "entertain" in cat: topic = "Entertainment"
            elif "educat" in cat or "learn" in cat: topic = "Education & Knowledge"
            elif "health" in cat or "fitness" in cat: topic = "Health & Wellness"
            elif "religion" in cat or "islam" in cat: topic = "Religion & Spirituality"
            elif "art" in cat or "book" in cat or "cultur" in cat: topic = "Arts & Culture"
            by_topic[topic].append(f)

        country_written = 0
        for topic, feeds in by_topic.items():
            topic_elem = None
            for child in p_body:
                if child.get("text") == topic: topic_elem = child; break
            if topic_elem is None:
                topic_elem = ET.SubElement(p_body, "outline")
                topic_elem.set("text", topic); topic_elem.set("title", topic)

            subcat = None
            for child in topic_elem:
                if child.get("text") == "Unverified Feeds" and child.get("xmlUrl") is None:
                    subcat = child; break
            if subcat is None:
                subcat = ET.SubElement(topic_elem, "outline")
                subcat.set("text", "Unverified Feeds"); subcat.set("title", "Unverified Feeds")

            for f in feeds:
                url = f["url"]
                sid = compute_source_id(url)
                elem = ET.SubElement(subcat, "outline")
                elem.set("text", f["title"] or url)
                elem.set("title", f["title"] or url)
                elem.set("type", "rss")
                elem.set("xmlUrl", url)
                elem.set("description", "Unverified feed — pending content analysis.")
                elem.set("language", lang)
                elem.set("category", f.get("category", ""))
                elem.set("feedmineSourceId", sid)
                elem.set("feedmineTopic", topic)
                elem.set("feedmineSubcategory", "Unverified Feeds")
                elem.set("feedmineNature", "unverified")
                elem.set("feedmineActivity", "unknown")
                elem.set("feedmineArticlesFetched", "0")
                elem.set("feedmineQualityScore", "0")
                elem.set("feedmineDefaultEnabled", "false")
                elem.set("feedmineMediaKind", "mixed")
                elem.set("htmlUrl", url)
                country_written += 1

        if write_mode and country_written > 0:
            _indent_xml(p_root)
            raw = ET.tostring(p_root, encoding="unicode")
            prod_opml.write_text(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                + raw.split("?>", 1)[-1].lstrip(), encoding="utf-8")

        if country_written > 0:
            total_added += country_written
            countries_updated += 1
            status = "✅" if write_mode else "🔧"
            print(f"  {status} {slug}: +{country_written} unverified feeds")

    print(f"\n{'='*60}")
    print(f"Countries: {countries_updated} | Feeds: {total_added:,} | Skipped: {skipped_existing:,}")
    if not write_mode:
        print("🔍 DRY RUN complete. Use --write to apply.")
    else:
        print("✅ Merge complete.")


if __name__ == "__main__":
    main()
