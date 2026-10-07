from __future__ import annotations

import json
from pathlib import Path

from ...catalog_collections import PRODUCTION_COUNTRY_COLLECTION
from .country_meta import COUNTRY_META, CITIES, display_name, native_name

REPO_ROOT = Path(__file__).resolve().parents[3]
COUNTRIES_DIR = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / PRODUCTION_COUNTRY_COLLECTION
OUT = Path(__file__).parent / "countries.json"

# ccTLD differs from ISO 3166-1 alpha-2 for a handful of countries.
CCTLD_TO_ISO2 = {"uk": "gb"}


def _iso_codes(cctld: str, slug: str) -> tuple[str, str]:
    import pycountry
    iso2 = CCTLD_TO_ISO2.get(cctld, cctld)
    rec = pycountry.countries.get(alpha_2=iso2.upper())
    if rec is None:
        raise SystemExit(f"no ISO record for {slug} (cctld={cctld}, iso2={iso2})")
    return iso2.lower(), rec.alpha_3


def build() -> dict:
    folders = sorted(p.name for p in COUNTRIES_DIR.iterdir() if p.is_dir())
    result: dict[str, dict] = {}
    missing: list[str] = []
    for slug in folders:
        meta = COUNTRY_META.get(slug)
        if meta is None:
            missing.append(slug)
            continue
        cctld, lang, use_cctld = meta
        iso2, iso3 = _iso_codes(cctld, slug)
        result[slug] = {
            "name": display_name(slug),
            "native_name": native_name(slug),
            "cctld": cctld,
            "use_cctld": use_cctld,
            "lang": lang,
            "ddg_region": f"{cctld}-{lang}",
            "iso2": iso2,
            "iso3": iso3,
            "cities": CITIES.get(slug, []),
            "allowlist": [],
        }
    if missing:
        raise SystemExit(f"COUNTRY_META missing entries for: {missing}")
    return result


if __name__ == "__main__":
    OUT.write_text(json.dumps(build(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {OUT} with {len(build())} countries")
