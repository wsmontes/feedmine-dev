#!/usr/bin/env python3
"""Add newly discovered writer feeds to feeds_corpus_sources.parquet.

Reads validated JSON files from writer_cache/, canonicalizes URLs,
deduplicates against existing sources in the parquet, and appends
new feeds with status="pending" for the fetch→enrich→inject pipeline.
"""

from __future__ import annotations

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
except ModuleNotFoundError:
    from catalog_identity import canonical_url, compute_source_id, request_url

ROOT = Path(__file__).resolve().parent.parent
PARQUET_PATH = ROOT / "feeds_corpus_sources.parquet"
BACKUP_PATH = ROOT / "feeds_corpus_sources.backup.parquet"
CACHE_DIR = ROOT / "scripts" / "feed_discovery" / "data" / "writer_cache"


def compute_canonical_xml_url(url: str) -> str:
    return canonical_url(url)


def main():
    if not PARQUET_PATH.exists():
        print(f"ERROR: {PARQUET_PATH} not found")
        sys.exit(1)

    # Backup
    shutil.copy2(PARQUET_PATH, BACKUP_PATH)
    print(f"Backup: {BACKUP_PATH}")

    # Read existing parquet
    table = pq.read_table(PARQUET_PATH)
    df = table.to_pandas()
    print(f"Existing rows: {len(df)}")

    # Dedup by canonical_xml_url.  ``canonical_url`` already case-folds the
    # host; the case of path/query is part of the feed's identity, so it must
    # not be folded again here.
    existing_canonical = {str(url).strip() for url in df["canonical_xml_url"]}

    # Collect writer feeds from cache
    new_rows = []
    seen = set()
    total_cache = 0

    for cache_file in sorted(CACHE_DIR.glob("*_validated.json")):
        feeds = json.loads(cache_file.read_text(encoding="utf-8"))
        total_cache += len(feeds)
        for feed in feeds:
            url = feed.get("url", "").strip()
            if not url:
                continue
            canonical = compute_canonical_xml_url(url)
            if canonical in existing_canonical or canonical in seen:
                continue
            seen.add(canonical)

            title = (feed.get("title") or url)[:300]

            new_rows.append({
                "source_id": compute_source_id(url),
                "source_title": str(title),
                "xml_url": request_url(url),
                "canonical_xml_url": str(canonical),
                "site_url": "",
                "feed_title": str(title),
                "feed_description": "",
                "feed_reported_language": "",
                "status": "pending",
                "error_message": "",
                "articles_fetched": 0,
                "latest_item_at": "",
                "ai_description": "",
                "ai_tags": "",
                "attempt_count": 0,
                "http_status": 0,
                "final_url": "",
                "content_type": "",
            })

    print(f"Cache feeds: {total_cache}")
    print(f"New (not in parquet): {len(new_rows)}")

    if not new_rows:
        print("Nothing to add!")
        return

    # Build new dataframe with explicit types matching the parquet schema
    new_df = pd.DataFrame(new_rows)
    new_df = new_df.astype({
        "articles_fetched": "int64",
        "attempt_count": "int64",
        "http_status": "int64",
    })

    # Ensure all columns present in same order
    for col in df.columns:
        if col not in new_df.columns:
            new_df[col] = ""
    new_df = new_df[df.columns]

    # Convert string columns to match large_string type
    merged = pd.concat([df, new_df], ignore_index=True)
    print(f"Merged rows: {len(merged)} (+{len(new_rows)})")

    # Write using pyarrow schema from existing table
    merged_table = pa.Table.from_pandas(
        merged,
        schema=table.schema  # reuse exact schema to avoid type mismatches
    )
    tmp = PARQUET_PATH.with_name(f".{PARQUET_PATH.name}.tmp")
    pq.write_table(merged_table, tmp, compression="zstd")
    os.replace(tmp, PARQUET_PATH)
    print(f"✅ Written to {PARQUET_PATH}")


if __name__ == "__main__":
    main()
