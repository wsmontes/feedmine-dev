#!/usr/bin/env python3
"""Turn entity-decoding quarantine rows into an explicit pending recrawl.

The source Parquet is never modified.  The output can be passed to
``fetch_new_feeds.py --parquet ...`` and then back to reconciliation after the
corrected endpoint has real crawl evidence.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import os
from datetime import datetime, timezone
from pathlib import Path

try:
    from scripts.catalog_identity import canonical_url, compute_source_id, request_url
    from scripts.fetch_new_feeds import FETCH_EVIDENCE_COLUMNS
except ModuleNotFoundError:
    from catalog_identity import canonical_url, compute_source_id, request_url
    from fetch_new_feeds import FETCH_EVIDENCE_COLUMNS


# Additional columns that carry evidence of the old fetch and must be cleared.
_ADDITIONAL_EVIDENCE_COLUMNS = [
    "content_length", "fetch_duration_ms", "fetched_at", "last_modified",
]


def prepare(sources: Path, quarantine: Path, output: Path) -> int:
    import pyarrow as pa
    import pyarrow.parquet as pq

    table = pq.read_table(sources)
    source_digest = hashlib.sha256(sources.read_bytes()).hexdigest()
    rows = table.to_pylist()

    # ── Build stable-key lookup ──
    by_source_id: dict[str, int] = {}
    for i, row in enumerate(rows):
        sid = row.get("source_id", "")
        if sid:
            if sid in by_source_id:
                raise ValueError(
                    f"duplicate source_id in parquet: {sid} at indices "
                    f"{by_source_id[sid]} and {i}"
                )
            by_source_id[sid] = i
        else:
            # Allow rows without source_id (e.g. legacy data); they just
            # can't be matched.
            pass

    # ── Parse quarantine, resolve by old_source_id ──
    queued: list[tuple[int, str, dict]] = []   # (index, fetch_url, csv_row)
    unmatched: list[dict] = []

    with quarantine.open(newline="", encoding="utf-8") as handle:
        for item in csv.DictReader(handle):
            if item.get("reason") != "url_entities_decoded_requires_refetch":
                continue

            old_source_id = item.get("old_source_id", "").strip()
            raw_url = item.get("xml_url", "").strip()
            fetch_url = request_url(raw_url)

            if not old_source_id:
                raise ValueError(
                    f"quarantine row missing old_source_id: {item}"
                )

            # Resolve by stable key — old_source_id, not row_index.
            if old_source_id not in by_source_id:
                unmatched.append(item)
                continue

            index = by_source_id[old_source_id]
            row = rows[index]

            # Verify xml_url matches between CSV and parquet row.
            row_xml_url = row.get("xml_url", "")
            if row_xml_url != raw_url:
                raise ValueError(
                    f"xml_url mismatch for old_source_id {old_source_id}: "
                    f"parquet row has {row_xml_url!r}, quarantine has {raw_url!r}"
                )

            queued.append((index, fetch_url, item))

    if unmatched:
        raise ValueError(
            f"{len(unmatched)} quarantine rows could not be resolved to parquet "
            f"rows: " + ", ".join(r.get("old_source_id", "?") for r in unmatched)
        )

    if not queued:
        print("  no entity-recrawl rows to prepare")
        return 0

    # ── P1-08: Detect identity collisions BEFORE mutating rows ──
    # Compute every proposed new ID and check for collisions against
    # untouched rows AND within the queue itself.
    proposed_ids: dict[str, list[int]] = {}  # new_id → [indices]
    for index, fetch_url, _item in queued:
        new_id = compute_source_id(fetch_url)
        proposed_ids.setdefault(new_id, []).append(index)

    queued_indices = {index for index, _fetch_url, _item in queued}
    collision_indices: set[int] = set()
    for new_id, indices in proposed_ids.items():
        # Queued-vs-queued collision
        if len(indices) > 1:
            print(f"  WARNING: {len(indices)} queued rows collapse to source_id {new_id}")
            collision_indices.update(indices[1:])  # keep first, flag rest
        # Queued-vs-untouched collision — ``by_source_id`` holds every row
        # (including the last one), so no line of the corpus is missed.
        other_idx = by_source_id.get(new_id)
        if other_idx is not None and other_idx not in queued_indices:
            print(f"  WARNING: queued row(s) {indices} collide with untouched row {other_idx} (source_id={new_id})")
            collision_indices.update(indices)

    if collision_indices:
        # Write collision quarantine before aborting
        quarantine_path = output.with_suffix(".collisions.csv")
        with open(quarantine_path, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            for idx in sorted(collision_indices):
                writer.writerow({k: str(v) for k, v in rows[idx].items()})
        raise ValueError(
            f"{len(collision_indices)} source_id collision(s) detected. "
            f"Details written to {quarantine_path}. "
            f"Review and resolve collisions manually before re-running."
        )

    # ── Clear old evidence and set new identity + provenance ──
    for index, fetch_url, item in queued:
        row = rows[index]

        # Clear ALL fetch-derived evidence from the previous crawl (P0-02).
        for col in FETCH_EVIDENCE_COLUMNS:
            row[col] = None
        for col in _ADDITIONAL_EVIDENCE_COLUMNS:
            if col in row:
                row[col] = None

        # Set new identity.
        row["source_id"] = compute_source_id(fetch_url)
        row["xml_url"] = fetch_url
        row["canonical_xml_url"] = canonical_url(fetch_url)
        row["status"] = "pending"
        row["error_message"] = None
        row["final_url"] = None
        row["attempt_count"] = 0

        # P0-02 / P1-03: provenance of the recrawl.
        row["recrawl_reason"] = "url_entities_decoded_requires_refetch"
        row["previous_source_id"] = item.get("old_source_id", "")
        row["prepared_at"] = datetime.now(timezone.utc).isoformat()
        row["input_digest"] = source_digest

    # ── Atomic write ──
    # Extend schema with provenance columns not in the original parquet.
    provenance_fields = [
        pa.field("recrawl_reason", pa.string()),
        pa.field("previous_source_id", pa.string()),
        pa.field("prepared_at", pa.string()),
        pa.field("input_digest", pa.string()),
    ]
    extended_schema = table.schema
    for field in provenance_fields:
        try:
            _ = extended_schema.field(field.name)
        except KeyError:
            extended_schema = extended_schema.append(field)

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    pq.write_table(
        pa.Table.from_pylist(rows, schema=extended_schema),
        temporary,
        compression="zstd",
    )
    os.replace(temporary, output)
    return len(queued)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sources", type=Path, default=Path("feeds_corpus_sources.parquet")
    )
    parser.add_argument(
        "--quarantine", type=Path,
        default=Path("build/catalog-reconciliation/quarantine.csv"),
    )
    parser.add_argument(
        "--output", type=Path,
        default=Path("build/catalog-reconciliation/entity-recrawl-input.parquet"),
    )
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_args()
    count = prepare(arguments.sources, arguments.quarantine, arguments.output)
    print(
        f"prepared {count} entity-corrected source rows for recrawl: "
        f"{arguments.output}"
    )
