# scripts/feed_discovery/subregion/populate.py

from __future__ import annotations

import asyncio
import json
import time
from pathlib import Path

import aiohttp

from ...catalog_collections import PRODUCTION_COUNTRY_COLLECTION
from ..models import SubRegion
from ..opml import normalize_url
from ..pipeline import Config
from .discover_subregion import discover_subregion
from .enrich_countries import POPULATION, enrich
from .opml_writer import read_existing_feeds, write_subregion_opml

PROGRESS_FILE = Path(__file__).parent / "progress.json"


def load_progress() -> dict:
    """Load progress tracking, returning empty dict if no progress file exists."""
    if PROGRESS_FILE.exists():
        return json.loads(PROGRESS_FILE.read_text(encoding="utf-8"))
    return {}


def save_progress(progress: dict) -> None:
    """Atomically write progress to disk."""
    tmp = PROGRESS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(progress, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(PROGRESS_FILE)


async def populate_country(
    country_slug: str,
    enriched: dict,
    cfg: Config,
    session: aiohttp.ClientSession,
    pending_slugs: set[str] | None = None,
) -> dict:
    """Populate all sub-region OPMLs for one country.

    Args:
        country_slug: e.g. "nigeria"
        enriched: Full enriched countries dict.
        cfg: Discovery config.
        session: Shared aiohttp session.
        pending_slugs: When given, only these sub-regions are attempted (resume).

    Returns:
        Summary dict: {country_slug, total_subregions, populated, failed, total_feeds, status}
        where ``status`` maps each attempted sub-region slug to "done"/"failed".
    """
    country_data = enriched.get(country_slug)
    if not country_data:
        return {"country": country_slug, "error": "not in enriched data", "status": {}}

    sub_data = country_data.get("subregions", [])
    if not sub_data:
        return {"country": country_slug, "total_subregions": 0, "populated": 0, "failed": 0,
                "total_feeds": 0, "status": {}}

    country_name = country_data["name"]
    native_name = country_data.get("native_name", country_name)

    # Collect all existing URLs across all sub-regions to feed dedup
    all_existing: set[str] = set()
    for sd in sub_data:
        opml_path = Path(sd["opml_path"])
        if opml_path.exists():
            all_existing |= read_existing_feeds(opml_path)

    sem = asyncio.Semaphore(cfg.concurrency)

    targets = [sd for sd in sub_data
               if pending_slugs is None or sd["slug"] in pending_slugs]

    async def _process_one(sd: dict) -> tuple[str, int]:
        sub = SubRegion(
            slug=sd["slug"], name=sd["name"],
            parent_country=sd["parent_country"],
            iso2=sd["iso2"], iso3=sd["iso3"],
            ddg_region=sd["ddg_region"],
            opml_path=sd["opml_path"],
        )
        async with sem:
            try:
                cands = await discover_subregion(
                    sub, country_name, native_name, all_existing, session, cfg
                )
            except Exception:
                return (sd["slug"], -1)

        opml_path = Path(sd["opml_path"])
        if cands:
            written = write_subregion_opml(opml_path, cands)
            if written:
                # Sub-regions run concurrently; registering what was just
                # written keeps a later region from repeating the same feed.
                all_existing.update(normalize_url(c.url) for c in cands)
            return (sd["slug"], written)
        return (sd["slug"], 0)

    results = await asyncio.gather(*(_process_one(sd) for sd in targets))

    summary = {
        "country": country_slug,
        "total_subregions": len(sub_data),
        "populated": 0,
        "failed": 0,
        "total_feeds": 0,
        "status": {},
    }
    for slug, count in results:
        if count < 0:
            summary["failed"] += 1
            summary["status"][slug] = "failed"
        else:
            summary["status"][slug] = "done"
            if count > 0:
                summary["populated"] += 1
        summary["total_feeds"] += max(0, count)

    return summary


async def populate_all(
    enriched_path: Path,
    opml_base: Path,
    cfg: Config | None = None,
) -> None:
    """Run the full sub-region population pipeline for all countries.

    Processes countries in descending population order. Progress is saved
    after each country to `progress.json` so the pipeline can be resumed.

    Args:
        enriched_path: Path to countries_enriched.json.
        opml_base: Path to feedmine/Resources/Feeds/90_countries/.
        cfg: Optional Config override.
    """
    if cfg is None:
        cfg = Config()

    enriched = json.loads(Path(enriched_path).read_text(encoding="utf-8"))
    progress = load_progress()

    # Sort countries by population descending
    sorted_countries = sorted(
        enriched.keys(),
        key=lambda s: enriched[s].get("population", 0),
        reverse=True,
    )

    connector = aiohttp.TCPConnector(limit=cfg.concurrency)
    async with aiohttp.ClientSession(connector=connector) as session:
        for country_slug in sorted_countries:
            recorded = progress.get(country_slug) or {}
            pending = {slug for slug, status in recorded.items() if status != "done"}
            if recorded and not pending:
                print(f"[SKIP] {country_slug} — already complete")
                continue

            print(f"\n{'='*60}")
            print(f"[{country_slug}] Starting {enriched[country_slug].get('name', country_slug)} "
                  f"(pop: {enriched[country_slug].get('population', 0):,})")
            print(f"{'='*60}")

            t0 = time.monotonic()
            summary = await populate_country(
                country_slug, enriched, cfg, session,
                pending if recorded else None,
            )
            elapsed = time.monotonic() - t0

            # Update progress from the per-sub-region result, keeping the
            # sub-regions that were already complete and not attempted here.
            country_progress = dict(recorded)
            country_progress.update(summary.get("status", {}))
            progress[country_slug] = country_progress
            save_progress(progress)

            print(f"[{country_slug}] Done in {elapsed:.0f}s — "
                  f"{summary['populated']}/{summary['total_subregions']} populated, "
                  f"{summary['total_feeds']} feeds, "
                  f"{summary['failed']} failed")


if __name__ == "__main__":
    import sys

    REPO_ROOT = Path(__file__).resolve().parents[3]
    OPML_BASE = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / PRODUCTION_COUNTRY_COLLECTION
    COUNTRIES_JSON = Path(__file__).resolve().parents[1] / "data" / "countries.json"
    ENRICHED_PATH = Path(__file__).resolve().parents[1] / "data" / "countries_enriched.json"

    if not ENRICHED_PATH.exists():
        print("Generating countries_enriched.json ...")
        enrich(OPML_BASE, COUNTRIES_JSON, ENRICHED_PATH)
        print(f"  -> wrote {ENRICHED_PATH}")

    fresh = "--fresh" in sys.argv
    commit = "--commit" in sys.argv
    cfg = Config(fresh=fresh, concurrency=50)

    asyncio.run(populate_all(ENRICHED_PATH, OPML_BASE, cfg))

    if commit:
        import subprocess
        subprocess.run(["git", "-C", str(REPO_ROOT), "add", str(OPML_BASE)])
        subprocess.run(["git", "-C", str(REPO_ROOT), "commit", "-m",
                        f"data: sub-region OPML population run"])
