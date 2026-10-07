#!/usr/bin/env python3
"""Crawl all university websites in a country to discover RSS/Atom feeds,
YouTube channels, and podcasts.

Uses the Wikidata-generated university list (from build_university_list.py)
then crawls each university's official website for feeds.

Output: JSON feed list + OPML file per country.

Usage:
    python3 scripts/crawl_university_feeds.py --country brazil
    python3 scripts/crawl_university_feeds.py --country brazil --max 10 --fresh
    python3 scripts/crawl_university_feeds.py --all  # all countries (LONG!)
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

import aiohttp

# Path hack to import feed_discovery modules
_SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(_SCRIPT_DIR))

from feed_discovery.models import Candidate, Country
from feed_discovery.sources.universities import (
    _crawl_one_university, _normalize_url, _fetch_html,
    _find_feeds_from_a_hrefs, _find_feed_hub_urls, _is_live_feed,
    _extract_youtube_channels, _extract_podcast_links,
    _probe_feed_paths, FEED_PROBE_PATHS,
)
from feed_discovery import discover as _discover

COUNTRIES_PATH = _SCRIPT_DIR / "feed_discovery/data/countries.json"
UNIS_DIR = _SCRIPT_DIR / "feed_discovery/data/universities/by_country"
OUTPUT_DIR = _SCRIPT_DIR / "feed_discovery/data/universities/output"

CONCURRENT_UNIVERSITIES = 8  # per-country internal concurrency


def _host_of(url: str) -> str:
    return urlparse(url).hostname or ""


def _load_countries() -> dict:
    return json.loads(COUNTRIES_PATH.read_text(encoding="utf-8"))


async def _verify_feed(
    session: aiohttp.ClientSession, url: str, timeout: int
) -> tuple[bool, str]:
    """Verify a feed URL is live and parse its title. Returns (is_live, title)."""
    from feed_discovery.verify import parse_feed

    try:
        async with session.get(
            url,
            headers={"User-Agent": "FeedmineDiscovery/1.0"},
            timeout=aiohttp.ClientTimeout(total=min(timeout, 10)),
            allow_redirects=True,
        ) as resp:
            if resp.status != 200:
                return False, ""
            body = await resp.content.read(128 * 1024)
    except (aiohttp.ClientError, TimeoutError, asyncio.TimeoutError):
        return False, ""

    ok, title = parse_feed(body)
    return ok, title


async def crawl_country(
    country_slug: str,
    max_universities: int | None = None,
    fresh: bool = False,
    timeout: int = 20,
) -> dict:
    """Crawl all universities in a country and return discovered feeds.

    Returns:
        {
            "country": country_slug,
            "universities_processed": int,
            "feeds": [{url, title, category, genre, university_name, university_website}],
            "youtube": [...],
            "podcasts": [...],
        }
    """
    countries = _load_countries()
    if country_slug not in countries:
        print(f"✗ Country '{country_slug}' not found in countries.json", file=sys.stderr)
        sys.exit(1)

    country_data = countries[country_slug]
    country = Country(
        slug=country_slug,
        name=country_data["name"],
        cctld=country_data["cctld"],
        use_cctld=country_data.get("use_cctld", False),
        lang=country_data["lang"],
        ddg_region=country_data.get("ddg_region", f'{country_data["cctld"]}-{country_data["lang"]}'),
        iso2=country_data.get("iso2", country_data["cctld"]),
        iso3=country_data.get("iso3", ""),
        cities=country_data.get("cities", []),
    )

    # Load university list
    uni_file = UNIS_DIR / f"{country_slug}.json"
    if not uni_file.exists():
        print(f"✗ No university data for {country.name}. "
              f"Run: python3 scripts/build_university_list.py --country {country_slug}",
              file=sys.stderr)
        return {"country": country_slug, "universities_processed": 0,
                "feeds": [], "youtube": [], "podcasts": []}

    universities = json.loads(uni_file.read_text(encoding="utf-8"))

    # Filter to universities with websites
    with_sites = [u for u in universities if u.get("website", "").strip()]
    if max_universities:
        with_sites = with_sites[:max_universities]

    total = len(with_sites)
    if total == 0:
        print(f"✗ No universities with websites for {country.name}", file=sys.stderr)
        return {"country": country_slug, "universities_processed": 0,
                "feeds": [], "youtube": [], "podcasts": []}

    print(f"\n{'='*60}", file=sys.stderr)
    print(f"Crawling {total} universities in {country.name}...", file=sys.stderr)
    print(f"{'='*60}", file=sys.stderr)

    # Cache directory for crawl results
    cache_dir = _SCRIPT_DIR / "feed_discovery/data/universities/crawl_cache" / country_slug
    cache_dir.mkdir(parents=True, exist_ok=True)

    sem = asyncio.Semaphore(CONCURRENT_UNIVERSITIES)
    conn = aiohttp.TCPConnector(force_close=True, limit_per_host=4, limit=50)
    async with aiohttp.ClientSession(connector=conn) as session:

        async def _crawl_cached(uni: dict) -> dict:
            name_slug = "".join(ch if ch.isalnum() else "_" for ch in uni.get("name", "unknown"))
            cache_file = cache_dir / f"{name_slug}.json"

            if not fresh and cache_file.exists():
                try:
                    cached = json.loads(cache_file.read_text(encoding="utf-8"))
                    return cached
                except Exception:
                    pass

            async with sem:
                result = await _crawl_one_university(uni, country, session, timeout)

            # Convert Candidates to serializable dicts
            serialized = {"feeds": [], "youtube": [], "podcasts": [], "university": uni}
            for key in ["feeds", "youtube", "podcasts"]:
                for c in result[key]:
                    serialized[key].append({
                        "url": c.url,
                        "category": c.category,
                        "title": c.title,
                        "genre": c.genre,
                        "source_page": c.source_page,
                        "national": c.national,
                        "national_reason": c.national_reason,
                    })
            cache_file.write_text(json.dumps(serialized, indent=2, ensure_ascii=False), encoding="utf-8")
            return serialized

        # Process all universities concurrently
        all_results = await asyncio.gather(*(_crawl_cached(u) for u in with_sites))

    # Aggregate results
    all_feeds: list[dict] = []
    all_youtube: list[dict] = []
    all_podcasts: list[dict] = []
    unis_with_feeds = 0
    unis_with_yt = 0
    unis_with_podcasts = 0

    for r in all_results:
        uni_name = r["university"].get("name", "Unknown")
        uni_web = r["university"].get("website", "")

        if r["feeds"]:
            unis_with_feeds += 1
        if r["youtube"]:
            unis_with_yt += 1
        if r["podcasts"]:
            unis_with_podcasts += 1

        for f in r["feeds"]:
            f["university_name"] = uni_name
            f["university_website"] = uni_web
        for y in r["youtube"]:
            y["university_name"] = uni_name
            y["university_website"] = uni_web
        for p in r["podcasts"]:
            p["university_name"] = uni_name
            p["university_website"] = uni_web

        all_feeds.extend(r["feeds"])
        all_youtube.extend(r["youtube"])
        all_podcasts.extend(r["podcasts"])

    print(f"\nResults for {country.name}:", file=sys.stderr)
    print(f"  Universities processed: {total}", file=sys.stderr)
    print(f"  With RSS/Atom feeds:   {unis_with_feeds} ({len(all_feeds)} total feeds)", file=sys.stderr)
    print(f"  With YouTube channels: {unis_with_yt}", file=sys.stderr)
    print(f"  With Podcast links:    {unis_with_podcasts}", file=sys.stderr)

    # Write output
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    result = {
        "country": country_slug,
        "country_name": country_data["name"],
        "universities_total": len(universities),
        "universities_with_websites": total,
        "universities_processed": total,
        "universities_with_feeds": unis_with_feeds,
        "universities_with_youtube": unis_with_yt,
        "universities_with_podcasts": unis_with_podcasts,
        "feeds": all_feeds,
        "youtube": all_youtube,
        "podcasts": all_podcasts,
    }

    output_path = OUTPUT_DIR / f"{country_slug}_feeds.json"
    output_path.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"  Output: {output_path}", file=sys.stderr)

    return result


async def crawl_all_countries(
    max_per_country: int | None = None,
    fresh: bool = False,
    timeout: int = 12,
    skip_existing: bool = True,
    parallel_countries: int = 12,
) -> None:
    """Crawl all countries that have university data, processing countries in parallel.

    Processes countries in parallel batches so that slow countries (poor connectivity)
    don't block fast ones. Total connection pool is shared across all countries.
    """
    countries = _load_countries()

    # Collect countries to process
    to_process: list[tuple[str, dict]] = []
    skipped = 0
    for slug in sorted(countries.keys()):
        uni_file = UNIS_DIR / f"{slug}.json"
        if not uni_file.exists():
            continue

        output_file = OUTPUT_DIR / f"{slug}_feeds.json"
        # --fresh invalidates both cache levels: the per-country output files and
        # the per-university crawl cache used below.
        if skip_existing and not fresh and output_file.exists():
            skipped += 1
            continue

        # Quick pre-check: count universities with websites
        try:
            unis = json.loads(uni_file.read_text(encoding="utf-8"))
            with_sites = [u for u in unis if u.get("website", "").strip()]
            if max_per_country:
                with_sites = with_sites[:max_per_country]
            if with_sites:
                to_process.append((slug, countries[slug]))
        except Exception:
            continue

    if skipped:
        print(f"  ({skipped} countries already completed, skipping)", file=sys.stderr)

    total_countries = len(to_process)
    total_unis = 0
    print(f"\n{'='*60}", file=sys.stderr)
    print(f"Processing {total_countries} countries in batches of {parallel_countries}...", file=sys.stderr)
    print(f"{'='*60}\n", file=sys.stderr)

    # Global semaphore for total concurrent university crawls
    global_sem = asyncio.Semaphore(parallel_countries * CONCURRENT_UNIVERSITIES)
    conn = aiohttp.TCPConnector(force_close=True, limit_per_host=4, limit=80)

    async with aiohttp.ClientSession(connector=conn) as session:
        # Process countries in parallel batches
        batches = [to_process[i:i + parallel_countries]
                   for i in range(0, len(to_process), parallel_countries)]

        grand_total_feeds = 0
        grand_total_uni = 0

        for batch_idx, batch in enumerate(batches):
            print(f"\n--- Batch {batch_idx + 1}/{len(batches)} "
                  f"({len(batch)} countries) ---", file=sys.stderr)

            async def _process_country(slug: str, cdata: dict) -> dict | None:
                country_data = cdata
                country = Country(
                    slug=slug,
                    name=country_data["name"],
                    cctld=country_data["cctld"],
                    use_cctld=country_data.get("use_cctld", False),
                    lang=country_data["lang"],
                    ddg_region=country_data.get("ddg_region",
                                                f'{country_data["cctld"]}-{country_data["lang"]}'),
                    iso2=country_data.get("iso2", country_data["cctld"]),
                    iso3=country_data.get("iso3", ""),
                    cities=country_data.get("cities", []),
                )

                uni_file = UNIS_DIR / f"{slug}.json"
                try:
                    universities = json.loads(uni_file.read_text(encoding="utf-8"))
                except Exception:
                    return None

                with_sites = [u for u in universities if u.get("website", "").strip()]
                if max_per_country:
                    with_sites = with_sites[:max_per_country]

                if not with_sites:
                    return None

                total = len(with_sites)

                # Per-country semaphore for fine-grained control
                country_sem = asyncio.Semaphore(3)

                # Cache directory
                cache_dir = (_SCRIPT_DIR /
                             "feed_discovery/data/universities/crawl_cache" / slug)
                cache_dir.mkdir(parents=True, exist_ok=True)

                async def _crawl_cached(uni: dict) -> dict:
                    name_slug = "".join(ch if ch.isalnum() else "_"
                                       for ch in uni.get("name", "unknown"))
                    cache_file = cache_dir / f"{name_slug}.json"

                    if not fresh and cache_file.exists():
                        try:
                            return json.loads(cache_file.read_text(encoding="utf-8"))
                        except Exception:
                            pass

                    async with global_sem, country_sem:
                        result = await _crawl_one_university(uni, country, session, timeout)

                    serialized = {"feeds": [], "youtube": [], "podcasts": [],
                                  "university": uni}
                    for key in ["feeds", "youtube", "podcasts"]:
                        for c in result[key]:
                            serialized[key].append({
                                "url": c.url, "category": c.category,
                                "title": c.title, "genre": c.genre,
                                "source_page": c.source_page,
                                "national": c.national,
                                "national_reason": c.national_reason,
                            })
                    cache_file.write_text(
                        json.dumps(serialized, indent=2, ensure_ascii=False),
                        encoding="utf-8")
                    return serialized

                all_results = await asyncio.gather(
                    *(_crawl_cached(u) for u in with_sites))

                # Aggregate
                all_feeds = []
                all_youtube = []
                all_podcasts = []
                unis_with_feeds = 0

                for r in all_results:
                    uni_name = r["university"].get("name", "Unknown")
                    uni_web = r["university"].get("website", "")
                    if r["feeds"]:
                        unis_with_feeds += 1
                    for f in r["feeds"]:
                        f["university_name"] = uni_name
                        f["university_website"] = uni_web
                    for y in r["youtube"]:
                        y["university_name"] = uni_name
                        y["university_website"] = uni_web
                    for p in r["podcasts"]:
                        p["university_name"] = uni_name
                        p["university_website"] = uni_web
                    all_feeds.extend(r["feeds"])
                    all_youtube.extend(r["youtube"])
                    all_podcasts.extend(r["podcasts"])

                result = {
                    "country": slug,
                    "country_name": country_data["name"],
                    "universities_total": len(universities),
                    "universities_with_websites": total,
                    "universities_processed": total,
                    "universities_with_feeds": unis_with_feeds,
                    "universities_with_youtube": sum(1 for r in all_results if r["youtube"]),
                    "universities_with_podcasts": sum(1 for r in all_results if r["podcasts"]),
                    "feeds": all_feeds,
                    "youtube": all_youtube,
                    "podcasts": all_podcasts,
                }

                OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
                output_path = OUTPUT_DIR / f"{slug}_feeds.json"
                output_path.write_text(
                    json.dumps(result, indent=2, ensure_ascii=False),
                    encoding="utf-8")

                print(f"  ✓ {country_data['name']}: {unis_with_feeds}/{total} unis "
                      f"→ {len(all_feeds)} feeds, {len(all_youtube)} YT, "
                      f"{len(all_podcasts)} podcasts",
                      file=sys.stderr)

                return result

            # Process entire batch concurrently
            batch_results = await asyncio.gather(*(
                _process_country(slug, cdata) for slug, cdata in batch
            ))

            for r in batch_results:
                if r:
                    grand_total_uni += r["universities_processed"]
                    grand_total_feeds += len(r["feeds"])

    print(f"\n{'='*60}", file=sys.stderr)
    print(f"ALL DONE: {total_countries} countries, {grand_total_uni} universities, "
          f"{grand_total_feeds} feeds", file=sys.stderr)
    print(f"{'='*60}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(
        description="Crawl university websites for RSS/Atom feeds, YouTube, and podcasts"
    )
    parser.add_argument("--country", type=str, help="Process a single country (slug or name)")
    parser.add_argument("--all", action="store_true", help="Process all countries")
    parser.add_argument("--max", type=int, help="Max universities per country")
    parser.add_argument("--fresh", action="store_true", help="Ignore caches and re-crawl")
    parser.add_argument("--timeout", type=int, default=20, help="Per-request timeout in seconds")
    parser.add_argument("--skip-existing", action=argparse.BooleanOptionalAction, default=True,
                        help="Skip countries that already have output files "
                             "(use --no-skip-existing to force a re-crawl)")
    args = parser.parse_args()

    if args.all:
        asyncio.run(crawl_all_countries(
            max_per_country=args.max,
            fresh=args.fresh,
            timeout=args.timeout,
            skip_existing=args.skip_existing,
        ))
    elif args.country:
        # Match by slug or name
        countries = _load_countries()
        target = args.country.lower().strip()
        slug = target
        if target not in countries:
            for s, cdata in countries.items():
                if cdata["name"].lower() == target or cdata["iso2"].lower() == target:
                    slug = s
                    break
            else:
                print(f"✗ Country '{args.country}' not found", file=sys.stderr)
                sys.exit(1)

        asyncio.run(crawl_country(slug, args.max, args.fresh, args.timeout))
    else:
        parser.print_help()
        print("\nExamples:", file=sys.stderr)
        print("  python3 scripts/crawl_university_feeds.py --country brazil", file=sys.stderr)
        print("  python3 scripts/crawl_university_feeds.py --country brazil --max 10 --fresh", file=sys.stderr)
        print("  python3 scripts/crawl_university_feeds.py --all", file=sys.stderr)


if __name__ == "__main__":
    main()
