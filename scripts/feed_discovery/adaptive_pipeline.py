# scripts/feed_discovery/adaptive_pipeline.py

from __future__ import annotations

import asyncio
import time
from pathlib import Path

import aiohttp

from ..catalog_collections import PRODUCTION_COUNTRY_COLLECTION
from . import verify
from .models import Candidate, SubRegion
from .opml import normalize_url
from .pipeline import Config, _bounded_gather
from .profiles._registry import load_profile, save_profile, REGION_MAP
from .subregion.opml_writer import read_existing_feeds, write_subregion_opml
from .subregion.enrich_countries import POPULATION, enrich
from .country_profiler import CountryProfiler

PROGRESS_FILE = Path(__file__).parent / "subregion" / "progress.json"


async def discover_with_profile(
    subregion: SubRegion,
    country_name: str,
    native_name: str,
    profile,
    existing_urls: set[str],
    session: aiohttp.ClientSession,
    cfg: Config,
) -> list[Candidate]:
    """Discover feeds for a sub-region using ALL active sources in the profile.

    Sources are called in priority order. Higher-priority sources that
    return >= min_results short-circuit lower-priority ones.
    """
    all_candidates: list[Candidate] = []
    seen_urls: set[str] = set()

    # Sort sources by priority
    sorted_sources = sorted(
        [(name, scfg) for name, scfg in profile.sources.items()
         if name not in profile.disabled_sources],
        key=lambda x: x[1].priority,
    )

    for source_name, source_config in sorted_sources:
        # Skip if we already have enough results from higher-priority sources
        if len(all_candidates) >= source_config.min_results * 3:
            break

        source = _get_source_instance(source_name)
        if source is None:
            continue
        if hasattr(source, "enabled") and not source.enabled:
            continue

        # Build query from subregion name + country
        query = f"{subregion.name} {country_name}"
        if native_name != country_name:
            query += f" {native_name}"

        try:
            candidates = await source.search(query, profile, source_config, session)
        except Exception:
            continue

        for c in candidates:
            # Sources may return national/global outlets (Google News headlines,
            # global lists) for a sub-region query; those are not local feeds.
            if not c.national:
                continue
            norm = normalize_url(c.url)
            if norm in seen_urls or norm in existing_urls:
                continue
            seen_urls.add(norm)
            all_candidates.append(c)

    if not all_candidates:
        return []

    # Validate before persisting: a source may hand back an HTML page or a dead
    # endpoint instead of a feed (Deezer show pages, for instance), and the
    # sub-region OPML must only receive real feeds.
    verdicts = await _bounded_gather(
        cfg.concurrency,
        [verify.verify_feed(session, c.url, cfg.timeout) for c in all_candidates],
    )
    verified: list[Candidate] = []
    for candidate, (is_live, status, title) in zip(all_candidates, verdicts):
        candidate.is_live, candidate.status_code = is_live, status
        if title:
            candidate.title = title
        if is_live:
            verified.append(candidate)
    return verified


async def populate_country_adaptive(
    country_slug: str,
    cfg: Config | None = None,
) -> dict:
    """Populate all sub-regions for one country using adaptive multi-source discovery.

    1. Load or bootstrap CountryProfile
    2. Discover feeds for each sub-region using all active sources
    3. Write results to OPMLs
    4. Update profile with metrics
    """
    if cfg is None:
        cfg = Config()

    # Load enriched country data
    enriched_path = Path(__file__).parent / "data" / "countries_enriched.json"
    if not enriched_path.exists():
        opml_base = Path(__file__).resolve().parents[2] / "feedmine" / "Resources" / "Feeds" / PRODUCTION_COUNTRY_COLLECTION
        countries_json = Path(__file__).parent / "data" / "countries.json"
        enrich(opml_base, countries_json, enriched_path)

    import json
    enriched = json.loads(enriched_path.read_text(encoding="utf-8"))
    country_data = enriched.get(country_slug)
    if not country_data:
        return {"country": country_slug, "error": "not in enriched data"}

    sub_data = country_data.get("subregions", [])
    if not sub_data:
        return {"country": country_slug, "total_subregions": 0, "populated": 0, "total_feeds": 0}

    # Load CountryProfile
    profiler = CountryProfiler()
    profile = load_profile(country_slug)

    country_name = country_data["name"]
    native_name = country_data.get("native_name", country_name)

    # Collect existing URLs across all sub-regions
    all_existing: set[str] = set()
    for sd in sub_data:
        opml_path = Path(sd["opml_path"])
        if opml_path.exists():
            all_existing |= read_existing_feeds(opml_path)

    connector = aiohttp.TCPConnector(limit=cfg.concurrency)
    async with aiohttp.ClientSession(connector=connector) as session:
        sem = asyncio.Semaphore(cfg.concurrency)

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
                    cands = await discover_with_profile(
                        sub, country_name, native_name,
                        profile, all_existing, session, cfg,
                    )
                except Exception:
                    return (sd["slug"], -1)

            if cands:
                written = write_subregion_opml(Path(sd["opml_path"]), cands)
                if written:
                    # Sub-regions run concurrently; registering what was just
                    # written keeps a later region from repeating the same feed.
                    all_existing.update(normalize_url(c.url) for c in cands)
                return (sd["slug"], written)
            return (sd["slug"], 0)

        results = await asyncio.gather(*(_process_one(sd) for sd in sub_data))

        # Update profile with metrics
        await profiler.update(profile, session)

    summary = {
        "country": country_slug,
        "total_subregions": len(sub_data),
        "populated": sum(1 for _, count in results if count > 0),
        "failed": sum(1 for _, count in results if count < 0),
        "total_feeds": sum(max(0, count) for _, count in results),
    }
    return summary


async def populate_all_adaptive(cfg: Config | None = None) -> None:
    """Run adaptive discovery for ALL countries, sorted by population."""
    import json
    if cfg is None:
        cfg = Config()

    enriched_path = Path(__file__).parent / "data" / "countries_enriched.json"
    if not enriched_path.exists():
        opml_base = Path(__file__).resolve().parents[2] / "feedmine" / "Resources" / "Feeds" / PRODUCTION_COUNTRY_COLLECTION
        countries_json = Path(__file__).parent / "data" / "countries.json"
        enrich(opml_base, countries_json, enriched_path)

    enriched = json.loads(enriched_path.read_text(encoding="utf-8"))
    sorted_countries = sorted(
        enriched.keys(),
        key=lambda s: enriched[s].get("population", 0),
        reverse=True,
    )

    for country_slug in sorted_countries:
        print(f"\n{'='*60}")
        print(f"[{country_slug}] Starting {enriched[country_slug]['name']}")
        t0 = time.monotonic()
        summary = await populate_country_adaptive(country_slug, cfg)
        elapsed = time.monotonic() - t0
        print(f"[{country_slug}] Done in {elapsed:.0f}s — "
              f"{summary['populated']}/{summary['total_subregions']} populated, "
              f"{summary['total_feeds']} feeds")


# Source instance cache
_source_cache: dict[str, object] = {}

def _get_source_instance(name: str):
    """Lazy-load source instances."""
    if name in _source_cache:
        return _source_cache[name]
    try:
        if name == "podcast_index":
            from .sources.podcast_index import PodcastIndexSource
            inst = PodcastIndexSource()
        elif name == "deezer":
            from .sources.deezer import DeezerSource
            inst = DeezerSource()
        elif name == "youtube_api":
            from .sources.youtube_api import YouTubeAPISource
            inst = YouTubeAPISource()
        elif name == "reddit":
            from .sources.reddit import RedditSource
            inst = RedditSource()
        elif name == "google_news":
            from .sources.google_news import GoogleNewsSource
            inst = GoogleNewsSource()
        elif name == "itunes_charts":
            from .sources.itunes_charts import ITunesChartsSource
            inst = ITunesChartsSource()
        elif name == "youtube_trending":
            from .sources.youtube_trending import YouTubeTrendingSource
            inst = YouTubeTrendingSource()
        elif name == "ddg_text":
            from .sources.ddg_text import DDGTextSource
            inst = DDGTextSource()
        elif name == "itunes":
            from .sources.podcasts import ITunesSource
            inst = ITunesSource()
        elif name == "youtube_top_subscribed":
            from .sources.youtube_top_subscribed import YouTubeTopSubscribedSource
            inst = YouTubeTopSubscribedSource()
        elif name == "youtube_awards":
            from .sources.youtube_awards import YouTubeAwardsSource
            inst = YouTubeAwardsSource()
        elif name == "youtube_kaggle":
            from .sources.youtube_kaggle import YouTubeKaggleSource
            inst = YouTubeKaggleSource()
        elif name == "youtube_socialblade":
            from .sources.youtube_socialblade import YouTubeSocialBladeSource
            inst = YouTubeSocialBladeSource()
        elif name == "youtube_diamond":
            from .sources.youtube_diamond import YouTubeDiamondSource
            inst = YouTubeDiamondSource()
        elif name == "influencers":
            from .sources.influencers import InfluencersSource
            inst = InfluencersSource()
        else:
            return None
        _source_cache[name] = inst
        return inst
    except Exception:
        return None


if __name__ == "__main__":
    import sys
    fresh = "--fresh" in sys.argv
    cfg = Config(fresh=fresh, concurrency=50)
    asyncio.run(populate_all_adaptive(cfg))
