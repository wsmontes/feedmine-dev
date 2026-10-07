#!/usr/bin/env python3
"""
Inject curated JSON feeds into feeds_corpus_sources.parquet + memberships.

Reads curated JSONs from scripts/feed_discovery/data/curated/{artists,museums,universities}/
that are NOT already in the parquet and injects them as status="pending" with proper
country memberships. This ensures they survive the next curate_opml_catalog.py rebuild.

The injected feeds then flow through the normal pipeline:
  fetch_new_feeds.py → enrich → curate_opml_catalog.py

Usage:
  python scripts/inject_curated_to_parquet.py --dry-run
  python scripts/inject_curated_to_parquet.py --write
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq

try:
    from scripts.catalog_identity import canonical_url, compute_source_id, request_url
except ModuleNotFoundError:  # Direct ``python scripts/...`` execution.
    from catalog_identity import canonical_url, compute_source_id, request_url

REPO_ROOT = Path(__file__).resolve().parents[1]
CURATED_DIR = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "curated"
SOURCES_PATH = REPO_ROOT / "feeds_corpus_sources.parquet"
MEMBERSHIPS_PATH = REPO_ROOT / "feeds_corpus_source_memberships.parquet"
SOURCES_BACKUP = REPO_ROOT / "feeds_corpus_sources.backup.parquet"
MEMBERSHIPS_BACKUP = REPO_ROOT / "feeds_corpus_source_memberships.backup.parquet"

# Category → OPML mapping (must match merge_curated_jsons_to_opml.py)
CATEGORY_CONFIG = {
    "artists": {
        "topic": "Arts & Culture",
        "subcategory": "Artist Blogs",
        "media_kind": "text",
    },
    "museums": {
        "topic": "Arts & Culture",
        "subcategory": "Museums",
        "media_kind": "video",
    },
    "universities": {
        "topic": "Education & Knowledge",
        "subcategory": "Universities",
        "media_kind": "video",
    },
    "news": {
        "topic": "News & Current Affairs",
        "subcategory": "News",
        "media_kind": "text",
    },
    "influencers": {
        "topic": "General Interests",
        "subcategory": "Influencers",
        "media_kind": "mixed",
    },
}


def stable_id(namespace: str, value: str) -> str:
    """Mirrors fetch_all_feeds_v2.py:stable_id."""
    return hashlib.sha256(f"{namespace}:{value}".encode("utf-8")).hexdigest()


def compute_canonical_xml_url(url: str) -> str:
    """Compatibility wrapper around the shared identity contract."""
    return canonical_url(url)


def make_membership_id(source_id: str, collection: str, topic: str, subcategory: str,
                       claimed_language: str, region: str, claimed_country: str,
                       opml_file: str, opml_title: str, claimed_media_kind: str) -> str:
    """Mirrors fetch_all_feeds_v2.py membership_id computation."""
    identity = "|".join([
        collection, topic, subcategory,
        claimed_language, region, claimed_country,
        opml_file, opml_title, claimed_media_kind,
    ])
    return stable_id("membership", f"{source_id}|{identity}")


def resolve_country_slug(country: str) -> str:
    """Convert country name to filesystem slug used in 90_countries/."""
    return country.replace("-", "_")


def main():
    write_mode = "--write" in sys.argv
    if not write_mode:
        print("🔍 DRY RUN — use --write to apply\n")

    # --- Load existing data ---
    sources_table = pq.read_table(SOURCES_PATH)
    sources_df = sources_table.to_pandas()
    memberships_table = pq.read_table(MEMBERSHIPS_PATH)
    memberships_df = memberships_table.to_pandas()

    print(f"Existing sources: {len(sources_df):,}")
    print(f"Existing memberships: {len(memberships_df):,}")

    existing_canonical = set(canonical_url(u) for u in sources_df["canonical_xml_url"])
    existing_source_ids = set(str(s) for s in sources_df["source_id"])

    # Next source_id (even though source_id is hash-based, we still need sequential for safety)
    # Actually, source_id IS the hash, so no sequential needed
    # But the schema has source_id as string, so we just use the hash

    # Collect new feeds
    new_sources = []
    new_memberships = []
    seen_canonical = set(existing_canonical)
    seen_membership = set()

    # Build seen memberships for dedup
    for _, row in memberships_df.iterrows():
        seen_membership.add(str(row["membership_id"]))

    stats_by_cat = {}

    for cat, config in CATEGORY_CONFIG.items():
        cat_dir = CURATED_DIR / cat
        if not cat_dir.is_dir():
            continue

        cat_sources = 0
        cat_memberships = 0

        for json_path in sorted(cat_dir.glob("*.json")):
            if json_path.name == ".progress":
                continue

            country_slug = json_path.stem  # e.g. "brazil"
            country_fs = resolve_country_slug(country_slug)

            try:
                feeds = json.loads(json_path.read_text(encoding="utf-8"))
            except Exception as e:
                print(f"  ⚠️  {json_path.name}: {e}")
                continue

            if not isinstance(feeds, list):
                continue

            for feed in feeds:
                if not isinstance(feed, dict):
                    continue
                url = feed.get("url", "").strip()
                if not url:
                    continue

                canonical = compute_canonical_xml_url(url)
                sid = compute_source_id(url)
                fetch_url = request_url(url)
                title = (feed.get("title") or url)[:300]
                source_page = feed.get("source_page", "") or ""
                genre = feed.get("genre", "") or config["subcategory"]

                # Source row — one per canonical URL, built regardless of placement.
                source_row = {
                    "source_id": sid,
                    "source_title": str(title),
                    "xml_url": fetch_url,
                    "canonical_xml_url": canonical,
                    "site_url": str(source_page)[:500],
                    "feed_title": str(title),
                    "feed_description": f"{genre} — discovered for {country_slug}",
                    "feed_reported_language": "",
                    "status": "pending",
                    "error_message": "",
                    "parser_warning": "",
                    "articles_fetched": 0,
                    "attempt_count": 0,
                    "attempted_at": None,
                    "fetched_at": None,
                    "fetch_duration_ms": None,
                    "response_time_ms": None,
                    "ttfb_ms": None,
                    "http_status": 0,
                    "response_bytes": None,
                    "final_url": "",
                    "content_type": "",
                    "latest_item_at": None,
                    "oldest_item_at": None,
                    "ai_description": "",
                    "ai_tags": "",
                }

                if canonical not in seen_canonical:
                    seen_canonical.add(canonical)
                    new_sources.append(source_row)
                    cat_sources += 1

                # Membership row — every unique placement is emitted, including one
                # that adds a second country/category to an already-known source.
                opml_file = f"90_countries/{country_fs}/{country_fs}.opml"
                mid = make_membership_id(
                    source_id=sid,
                    collection="90_countries",
                    topic=config["topic"],
                    subcategory=config["subcategory"],
                    claimed_language="",
                    region="global",
                    claimed_country=country_slug,
                    opml_file=opml_file,
                    opml_title=country_fs,
                    claimed_media_kind=config["media_kind"],
                )

                if mid in seen_membership:
                    continue
                seen_membership.add(mid)

                new_memberships.append({
                    "membership_id": mid,
                    "source_id": sid,
                    "collection": "90_countries",
                    "topic": config["topic"],
                    "subcategory": config["subcategory"],
                    "claimed_language": "",
                    "region": "global",
                    "claimed_country": country_slug,
                    "opml_file": opml_file,
                    "opml_title": country_fs,
                    "claimed_media_kind": config["media_kind"],
                })
                cat_memberships += 1

        stats_by_cat[cat] = {"sources": cat_sources, "memberships": cat_memberships}

    # --- Report ---
    print()
    total_sources = sum(s["sources"] for s in stats_by_cat.values())
    total_memberships = sum(s["memberships"] for s in stats_by_cat.values())

    for cat, stats in stats_by_cat.items():
        print(f"  {cat}: +{stats['sources']} sources, +{stats['memberships']} memberships")
    print(f"\n  TOTAL: +{total_sources} sources, +{total_memberships} memberships")

    if total_sources == 0 and total_memberships == 0:
        print("\n  Nothing to inject!")
        return

    if not write_mode:
        print("\n🔍 DRY RUN complete. Use --write to apply.")
        return

    # --- Write ---
    print(f"\n  Backing up...")
    shutil.copy2(SOURCES_PATH, SOURCES_BACKUP)
    shutil.copy2(MEMBERSHIPS_PATH, MEMBERSHIPS_BACKUP)
    print(f"  Backups: {SOURCES_BACKUP.name}, {MEMBERSHIPS_BACKUP.name}")

    # Write sources
    new_sources_df = pd.DataFrame(new_sources)
    for col in sources_df.columns:
        if col not in new_sources_df.columns:
            new_sources_df[col] = None
    new_sources_df = new_sources_df[sources_df.columns]

    merged_sources = pd.concat([sources_df, new_sources_df], ignore_index=True)
    merged_sources_table = pa.Table.from_pandas(merged_sources, schema=sources_table.schema)
    tmp_src = SOURCES_PATH.with_name(f".{SOURCES_PATH.name}.tmp")
    pq.write_table(merged_sources_table, tmp_src, compression="zstd")
    os.replace(tmp_src, SOURCES_PATH)
    print(f"  ✅ Sources: {len(merged_sources):,} rows (+{len(new_sources_df):,})")

    # Write memberships
    new_mem_df = pd.DataFrame(new_memberships)
    for col in memberships_df.columns:
        if col not in new_mem_df.columns:
            new_mem_df[col] = ""
    new_mem_df = new_mem_df[memberships_df.columns]

    merged_mem = pd.concat([memberships_df, new_mem_df], ignore_index=True)
    merged_mem_table = pa.Table.from_pandas(merged_mem, schema=memberships_table.schema)
    tmp_mem = MEMBERSHIPS_PATH.with_name(f".{MEMBERSHIPS_PATH.name}.tmp")
    pq.write_table(merged_mem_table, tmp_mem, compression="zstd")
    os.replace(tmp_mem, MEMBERSHIPS_PATH)
    print(f"  ✅ Memberships: {len(merged_mem):,} rows (+{len(new_mem_df):,})")

    print(f"\n✅ Injection complete. Run fetch_new_feeds.py to fetch these feeds.")


if __name__ == "__main__":
    main()
