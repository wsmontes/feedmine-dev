from __future__ import annotations

from pathlib import Path

from scripts.catalog_collections import PRODUCTION_COUNTRY_COLLECTION
from scripts.feed_discovery import registry

DATA = Path(__file__).resolve().parents[1] / "data"
COUNTRIES_DIR = (
    Path(__file__).resolve().parents[3]
    / "feedmine" / "Resources" / "Feeds" / PRODUCTION_COUNTRY_COLLECTION
)


def test_every_country_folder_has_metadata():
    countries = registry.load_countries(DATA / "countries.json")
    folders = {p.name for p in COUNTRIES_DIR.iterdir() if p.is_dir()}
    assert folders <= set(countries), f"missing: {folders - set(countries)}"


def test_every_country_has_two_letter_cctld_and_lang():
    countries = registry.load_countries(DATA / "countries.json")
    for slug, c in countries.items():
        assert len(c.cctld) >= 2, slug
        assert c.lang, slug
        assert c.ddg_region == f"{c.cctld}-{c.lang}", slug


def test_every_category_has_english_pack():
    kw = registry.load_keywords(DATA / "category_keywords.json")
    for cat in registry.CATEGORIES:
        assert kw.get(cat, {}).get("en"), f"no en keywords for {cat}"


def test_every_country_has_native_name_and_cities():
    countries = registry.load_countries(DATA / "countries.json")
    for slug, c in countries.items():
        assert c.native_name, slug
        assert len(c.cities) >= 1, slug


def test_blocklist_loads_nonempty():
    assert len(registry.load_blocklist(DATA / "blocklist.txt")) > 5


def test_every_country_has_iso2_and_iso3():
    countries = registry.load_countries(DATA / "countries.json")
    assert countries, "no countries loaded"
    for slug, c in countries.items():
        assert len(c.iso2) == 2 and c.iso2.islower(), f"{slug}: bad iso2 {c.iso2!r}"
        assert len(c.iso3) == 3 and c.iso3.isupper(), f"{slug}: bad iso3 {c.iso3!r}"
