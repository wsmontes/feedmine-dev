#!/usr/bin/env python3
"""Build a museum list for every country in countries.json using Wikidata.

Queries the Wikidata SPARQL endpoint to find art + culture museums per country:
  - Q207694  art museum
  - Q188509  history museum
  - Q1747686  science museum
  - Q16735822 natural history museum
  - Q33506   museum (generic catch-all)

Extracts: name, official website, YouTube channel, Instagram, Twitter, Wikipedia.

Output: scripts/feed_discovery/data/museums/by_country/{slug}.json
         scripts/feed_discovery/data/museums/all_museums.json

Usage:
    python3 scripts/build_museum_list.py                  # all countries
    python3 scripts/build_museum_list.py --country brazil  # single country
    python3 scripts/build_museum_list.py --fresh           # no cache
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

# Wikidata Q-IDs for museums we care about
MUSEUM_QIDS = [
    "Q207694",    # art museum
    "Q188509",    # history museum
    "Q1747686",   # science museum
    "Q16735822",  # natural history museum
    "Q33506",     # museum (generic)
]

# SPARQL endpoint
SPARQL_ENDPOINT = "https://query.wikidata.org/sparql"

# Country Q-ID cache (reuse university cache if available)
COUNTRY_QID_CACHE = Path(__file__).resolve().parent / "feed_discovery/data/universities/country_qids.json"

# Museum data output
DATA_DIR = Path(__file__).resolve().parent / "feed_discovery/data/museums"


def _load_countries() -> dict:
    """Load countries.json, return {slug: country_data}."""
    path = Path(__file__).resolve().parent / "feed_discovery/data/countries.json"
    return json.loads(path.read_text(encoding="utf-8"))


def _get_country_qid(iso2: str, country_name: str) -> str | None:
    """Resolve a country ISO2 code to its Wikidata Q-ID via SPARQL."""
    query = f"""
    SELECT ?country WHERE {{
      ?country wdt:P297 "{iso2.upper()}".
      SERVICE wikibase:label {{ bd:serviceParam wikibase:language "en". }}
    }}
    LIMIT 1
    """
    url = f"{SPARQL_ENDPOINT}?format=json&query={urllib.parse.quote(query)}"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "FeedmineMuseumBot/1.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
        bindings = data.get("results", {}).get("bindings", [])
        if bindings:
            qid_url = bindings[0]["country"]["value"]
            return qid_url.rstrip("/").split("/")[-1]
    except Exception as e:
        print(f"  ⚠ Failed to resolve Q-ID for {country_name} ({iso2}): {e}", file=sys.stderr)
    return None


def _build_country_qid_map(countries: dict, fresh: bool = False) -> dict[str, str]:
    """Build or load the {{iso2: wikidata_qid}} mapping for all countries.
    Reuses the university cache if available."""
    COUNTRY_QID_CACHE.parent.mkdir(parents=True, exist_ok=True)

    if not fresh and COUNTRY_QID_CACHE.exists():
        cached = json.loads(COUNTRY_QID_CACHE.read_text(encoding="utf-8"))
        needed = {c["iso2"].upper() for c in countries.values()}
        if needed.issubset(set(cached.keys())):
            return cached
        print(f"Cache has {len(cached)} Q-IDs, need {len(needed)}. Resolving missing...", file=sys.stderr)

    qid_map: dict[str, str] = {}
    if not fresh and COUNTRY_QID_CACHE.exists():
        qid_map = json.loads(COUNTRY_QID_CACHE.read_text(encoding="utf-8"))

    total = len(countries)
    for i, (slug, cdata) in enumerate(countries.items()):
        iso2 = cdata["iso2"].upper()
        if iso2 in qid_map:
            continue
        name = cdata["name"]
        print(f"  [{i+1}/{total}] Resolving Q-ID for {name} ({iso2})...", file=sys.stderr)
        qid = _get_country_qid(iso2, name)
        if qid:
            qid_map[iso2] = qid
            COUNTRY_QID_CACHE.write_text(json.dumps(qid_map, indent=2, sort_keys=True), encoding="utf-8")
        time.sleep(0.3)

    return qid_map


def _load_cached(path: Path) -> list[dict]:
    """Return the last valid cached payload for a country, or [] when there is none."""
    if not path.exists():
        return []
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []


def _fetch_museums_for_country(
    country_qid: str, country_name: str, country_slug: str
) -> list[dict] | None:
    """Query Wikidata for art + culture museums in a given country.

    Returns list of {name, wikidata_id, website, youtube, instagram, twitter, wikipedia_url},
    or None when the SPARQL request failed — a transient failure must not be cached
    as "this country has no museums".
    """
    # Build UNION clauses for each museum type
    union_parts = []
    for qid in MUSEUM_QIDS:
        union_parts.append(f"{{ ?item wdt:P31 wd:{qid}. }}")
    union_clauses = " UNION ".join(union_parts)

    query = f"""
    SELECT DISTINCT ?item ?itemLabel ?website ?youtube ?instagram ?twitter ?wikipedia
    WHERE {{
      {{
        {union_clauses}
      }}
      ?item wdt:P17 wd:{country_qid}.
      OPTIONAL {{ ?item wdt:P856 ?website. }}
      OPTIONAL {{ ?item wdt:P2397 ?youtube. }}
      OPTIONAL {{ ?item wdt:P2003 ?instagram. }}
      OPTIONAL {{ ?item wdt:P2002 ?twitter. }}
      OPTIONAL {{
        ?wikipedia schema:about ?item.
        ?wikipedia schema:inLanguage "en".
        ?wikipedia schema:isPartOf <https://en.wikipedia.org/>.
      }}
      SERVICE wikibase:label {{ bd:serviceParam wikibase:language "en,{country_slug}". }}
    }}
    ORDER BY ?itemLabel
    """
    url = f"{SPARQL_ENDPOINT}?format=json&query={urllib.parse.quote(query)}"

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "FeedmineMuseumBot/1.0"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        print(f"  ✗ SPARQL query failed for {country_name}: {e}", file=sys.stderr)
        return None

    bindings = data.get("results", {}).get("bindings", [])
    museums: list[dict] = []
    seen: set[str] = set()

    for b in bindings:
        name = b.get("itemLabel", {}).get("value", "")
        if not name:
            continue
        # Deduplicate by Wikidata item ID
        item_url = b.get("item", {}).get("value", "")
        item_id = item_url.rstrip("/").split("/")[-1] if item_url else name
        if item_id in seen:
            continue
        seen.add(item_id)

        museum = {
            "name": name,
            "wikidata_id": item_id,
            "website": b.get("website", {}).get("value", ""),
            "youtube": b.get("youtube", {}).get("value", ""),
            "instagram": b.get("instagram", {}).get("value", ""),
            "twitter": b.get("twitter", {}).get("value", ""),
            "wikipedia_url": b.get("wikipedia", {}).get("value", ""),
        }
        museums.append(museum)

    return museums


def build_museum_list(
    countries: dict | None = None,
    target_country: str | None = None,
    fresh: bool = False,
) -> dict[str, list[dict]]:
    """Main entry point: build museum lists for all (or one) countries.

    Returns {country_slug: [museum_dict, ...]}.
    """
    if countries is None:
        countries = _load_countries()

    # Filter to target country if specified
    if target_country:
        target = target_country.lower().strip()
        if target not in countries:
            match = None
            for slug, cdata in countries.items():
                if cdata["name"].lower() == target or cdata["iso2"].lower() == target:
                    match = slug
                    break
            if match:
                countries = {match: countries[match]}
            else:
                print(f"✗ Country '{target_country}' not found in countries.json", file=sys.stderr)
                sys.exit(1)
        else:
            countries = {target: countries[target]}

    # Build Q-ID map (reuses university cache)
    print(f"Building country Q-ID map for {len(countries)} countries...", file=sys.stderr)
    qid_map = _build_country_qid_map(countries, fresh=fresh)

    # Fetch museums per country
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    by_country_dir = DATA_DIR / "by_country"
    by_country_dir.mkdir(parents=True, exist_ok=True)

    all_results: dict[str, list[dict]] = {}
    total_countries = len(countries)

    for i, (slug, cdata) in enumerate(countries.items()):
        iso2 = cdata["iso2"].upper()
        country_qid = qid_map.get(iso2)
        cache_path = by_country_dir / f"{slug}.json"

        if not country_qid:
            print(f"  [{i+1}/{total_countries}] ⚠ {cdata['name']}: no Q-ID, skipping", file=sys.stderr)
            all_results[slug] = _load_cached(cache_path)
            continue

        # Check cache
        if not fresh and cache_path.exists():
            cached = json.loads(cache_path.read_text(encoding="utf-8"))
            print(f"  [{i+1}/{total_countries}] ✓ {cdata['name']}: {len(cached)} museums (cached)", file=sys.stderr)
            all_results[slug] = cached
            continue

        print(f"  [{i+1}/{total_countries}] Fetching museums in {cdata['name']}...", file=sys.stderr)
        museums = _fetch_museums_for_country(country_qid, cdata["name"], slug)
        if museums is None:
            # Transient failure: keep the last valid answer, never cache [].
            print(f"    ✗ fetch failed — keeping previous data for {cdata['name']}", file=sys.stderr)
            all_results[slug] = _load_cached(cache_path)
            continue
        print(f"    → {len(museums)} museums found", file=sys.stderr)

        # Save per-country cache
        cache_path.write_text(json.dumps(museums, indent=2, ensure_ascii=False), encoding="utf-8")
        all_results[slug] = museums

        if i < total_countries - 1:
            time.sleep(0.5)  # Rate limit

    # Write combined file — merged over countries this run did not process, so a
    # single-country run (--country X) never drops the rest of the aggregate.
    combined_path = DATA_DIR / "all_museums.json"
    combined: dict[str, list[dict]] = {}
    if combined_path.exists():
        try:
            combined = json.loads(combined_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            combined = {}
    combined.update(all_results)
    combined_path.write_text(json.dumps(combined, indent=2, ensure_ascii=False), encoding="utf-8")

    # Stats
    total = sum(len(v) for v in combined.values())
    with_websites = sum(1 for v in combined.values() for m in v if m["website"])
    with_youtube = sum(1 for v in combined.values() for m in v if m["youtube"])
    with_social = sum(1 for v in combined.values() for m in v if m["instagram"] or m["twitter"])
    countries_with_data = sum(1 for v in combined.values() if len(v) > 0)

    print(f"\n{'='*60}", file=sys.stderr)
    print(f"Total: {total} museums across {countries_with_data}/{len(combined)} countries", file=sys.stderr)
    print(f"  With websites: {with_websites} ({with_websites/total*100:.1f}%)" if total else "  With websites: 0", file=sys.stderr)
    print(f"  With YouTube:  {with_youtube} ({with_youtube/total*100:.1f}%)" if total else "  With YouTube: 0", file=sys.stderr)
    print(f"  With social:   {with_social} ({with_social/total*100:.1f}%)" if total else "  With social: 0", file=sys.stderr)
    print(f"  Output: {combined_path}", file=sys.stderr)

    return all_results


def main():
    parser = argparse.ArgumentParser(description="Build museum list from Wikidata")
    parser.add_argument("--country", type=str, help="Process a single country (slug or name)")
    parser.add_argument("--fresh", action="store_true", help="Ignore caches and re-fetch everything")
    args = parser.parse_args()

    countries = _load_countries()
    build_museum_list(countries, target_country=args.country, fresh=args.fresh)


if __name__ == "__main__":
    main()
