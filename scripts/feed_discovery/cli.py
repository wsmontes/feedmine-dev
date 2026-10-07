from __future__ import annotations

import argparse
import asyncio
from pathlib import Path

import aiohttp

from ..catalog_collections import PRODUCTION_COUNTRY_COLLECTION
from . import registry, report
from .opml import emit_opml, existing_feed_urls
from .pipeline import Config, candidates_to_opml_map, process_country

PKG_DIR = Path(__file__).resolve().parent
DATA = PKG_DIR / "data"
REPO_ROOT = PKG_DIR.parents[1]
COUNTRIES_DIR = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / PRODUCTION_COUNTRY_COLLECTION


def _parse_args(argv):
    p = argparse.ArgumentParser(prog="python -m scripts.feed_discovery")
    p.add_argument("--country", action="append", default=[], help="country slug (repeatable)")
    p.add_argument("--all", action="store_true", help="process all countries")
    p.add_argument("--category", action="append", default=[], help="restrict to category (repeatable)")
    p.add_argument("--max-results", type=int, default=12)
    p.add_argument("--concurrency", type=int, default=50)
    p.add_argument("--timeout", type=int, default=15)
    p.add_argument("--delay", type=float, default=2.0)
    p.add_argument("--fresh", action="store_true")
    p.add_argument("--out", type=Path, default=PKG_DIR / "candidates")
    return p.parse_args(argv)


async def _run(args) -> int:
    countries = registry.load_countries(DATA / "countries.json")
    keywords = registry.load_keywords(DATA / "category_keywords.json")
    blocklist = registry.load_blocklist(DATA / "blocklist.txt")
    categories = args.category or registry.CATEGORIES

    if args.all:
        slugs = sorted(countries)
    else:
        slugs = args.country
    if not slugs:
        print("Nothing to do: pass --country SLUG or --all")
        return 1

    cfg = Config(max_results=args.max_results, timeout=args.timeout,
                 delay=args.delay, fresh=args.fresh, concurrency=args.concurrency)
    args.out.mkdir(parents=True, exist_ok=True)
    summaries = []

    connector = aiohttp.TCPConnector(limit=cfg.concurrency, limit_per_host=5)
    async with aiohttp.ClientSession(connector=connector) as session:
        for slug in slugs:
            country = countries.get(slug)
            if country is None:
                print(f"skip unknown country: {slug}")
                continue
            existing = existing_feed_urls(COUNTRIES_DIR / slug)
            print(f"[{slug}] searching {len(categories)} categories…")
            cands = await process_country(
                country, categories, keywords, blocklist, existing, session, cfg
            )
            opml_map = candidates_to_opml_map(cands)
            xml = emit_opml(country.name, opml_map, registry.CATEGORIES)
            (args.out / f"{slug}.opml").write_text(xml, encoding="utf-8")
            summary = report.summarize(slug, cands)
            summaries.append(summary)
            print(f"[{slug}] new national feeds: {summary['new']} → {args.out / (slug + '.opml')}")

    report.write_reports(args.out, summaries)
    print(f"Report: {args.out / 'report.md'}")
    return 0


def main(argv=None) -> int:
    args = _parse_args(argv)
    return asyncio.run(_run(args))
