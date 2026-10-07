from __future__ import annotations

import json
from pathlib import Path

# Population data for all 101 countries (2024 estimates, millions -> raw).
# Used to sort processing order: most-populous first.
POPULATION: dict[str, int] = {
    "india": 1_441_000_000, "china": 1_410_000_000, "indonesia": 277_000_000,
    "pakistan": 231_000_000, "nigeria": 216_000_000, "brazil": 214_000_000,
    "bangladesh": 169_000_000, "russia": 144_000_000, "mexico": 128_000_000,
    "ethiopia": 126_000_000, "japan": 125_000_000, "philippines": 115_000_000,
    "egypt": 109_000_000, "vietnam": 103_000_000, "iran": 89_000_000,
    "turkey": 85_000_000, "germany": 84_000_000, "thailand": 71_000_000,
    "united-kingdom": 68_000_000, "france": 68_000_000, "italy": 59_000_000,
    "south-africa": 59_000_000, "tanzania": 65_000_000, "myanmar": 54_000_000,
    "south-korea": 51_000_000, "colombia": 51_000_000, "spain": 47_000_000,
    "argentina": 46_000_000, "algeria": 45_000_000, "sudan": 48_000_000,
    "iraq": 44_000_000, "uganda": 48_000_000, "ukraine": 37_000_000,
    "canada": 39_000_000, "poland": 38_000_000, "morocco": 37_000_000,
    "saudi-arabia": 36_000_000, "angola": 36_000_000, "uzbekistan": 35_000_000,
    "peru": 34_000_000, "malaysia": 34_000_000, "ghana": 33_000_000,
    "mozambique": 33_000_000, "nepal": 30_000_000, "venezuela": 28_000_000,
    "ivory-coast": 28_000_000, "australia": 26_000_000, "north-korea": 26_000_000,
    "taiwan": 23_000_000, "burkina-faso": 23_000_000, "mali": 23_000_000,
    "syria": 22_000_000, "sri-lanka": 22_000_000, "malawi": 21_000_000,
    "zambia": 20_000_000, "romania": 19_000_000, "chile": 19_000_000,
    "kazakhstan": 19_000_000, "ecuador": 18_000_000, "guatemala": 17_000_000,
    "senegal": 17_000_000, "netherlands": 17_000_000, "cambodia": 16_000_000,
    "zimbabwe": 16_000_000, "guinea": 14_000_000, "rwanda": 14_000_000,
    "benin": 13_000_000, "burundi": 13_000_000, "tunisia": 12_000_000,
    "belgium": 11_000_000, "haiti": 11_000_000, "jordan": 11_000_000,
    "cuba": 11_000_000, "south-sudan": 11_000_000, "dominican-republic": 11_000_000,
    "czech-republic": 10_000_000, "sweden": 10_000_000, "greece": 10_000_000,
    "portugal": 10_000_000, "azerbaijan": 10_000_000, "hungary": 9_700_000,
    "israel": 9_300_000, "austria": 9_100_000, "belarus": 9_200_000,
    "switzerland": 8_800_000, "serbia": 6_600_000, "bulgaria": 6_400_000,
    "denmark": 5_900_000, "finland": 5_500_000, "norway": 5_500_000,
    "slovakia": 5_400_000, "ireland": 5_200_000, "new-zealand": 5_200_000,
    "costa-rica": 5_200_000, "singapore": 5_100_000, "croatia": 3_800_000,
    "georgia": 3_700_000, "moldova": 2_500_000, "uruguay": 3_400_000,
    "bosnia": 3_200_000, "armenia": 2_700_000, "lithuania": 2_700_000,
    "qatar": 2_700_000, "jamaica": 2_800_000, "botswana": 2_600_000,
    "namibia": 2_600_000, "slovenia": 2_100_000, "latvia": 1_800_000,
    "estonia": 1_300_000, "cyprus": 1_200_000, "luxembourg": 660_000,
    "malta": 530_000, "iceland": 380_000, "panama": 4_400_000,
    "el-salvador": 6_300_000, "honduras": 10_000_000, "nicaragua": 6_800_000,
    "paraguay": 6_800_000, "bolivia": 12_000_000, "puerto-rico": 3_200_000,
    "kenya": 55_000_000, "uae": 9_500_000,
}


# Known compound proper nouns where the hyphen is part of the official name
# (e.g. "Cluj-Napoca" in Romania) rather than a word separator.
_HYPHENATED_SUBREGIONS: dict[str, str] = {
    "cluj-napoca": "Cluj-Napoca",
}


def humanize_slug(slug: str) -> str:
    """Convert 'nigeria-akwa-ibom' -> 'Akwa Ibom'.

    Strips the country prefix (everything before and including the first hyphen),
    splits the remainder by hyphen, and capitalizes each word.

    Known compound proper nouns (e.g. "Cluj-Napoca") preserve their hyphen.
    """
    # Find first hyphen -- everything before it is the country prefix.
    idx = slug.find("-")
    if idx == -1:
        return slug.replace("-", " ").title()
    remainder = slug[idx + 1:]
    # Check for known hyphenated compound names first
    if remainder in _HYPHENATED_SUBREGIONS:
        return _HYPHENATED_SUBREGIONS[remainder]
    return " ".join(word.capitalize() for word in remainder.split("-"))


def _country_slug_from_subregion_slug(sub_slug: str) -> str:
    """Extract country slug from a sub-region slug like 'usa-texas' -> 'usa'."""
    idx = sub_slug.find("-")
    return sub_slug[:idx] if idx != -1 else sub_slug


def enrich(opml_base: Path, countries_json: Path, output_path: Path) -> dict:
    """Scan OPML directories and produce countries_enriched.json.

    Args:
        opml_base: Path to feedmine/Resources/Feeds/90_countries/
        countries_json: Path to countries.json
        output_path: Where to write countries_enriched.json

    Returns:
        The enriched dict (also written to output_path as JSON).
    """
    countries = json.loads(Path(countries_json).read_text(encoding="utf-8"))
    result: dict[str, dict] = {}

    for country_slug, meta in countries.items():
        country_dir = Path(opml_base) / country_slug
        if not country_dir.is_dir():
            continue

        subregions: list[dict] = []
        for opml_file in sorted(country_dir.iterdir()):
            name = opml_file.name
            # Skip the national file (e.g. nigeria.opml), keep sub-regions only
            if not name.startswith(f"{country_slug}-") or not name.endswith(".opml"):
                continue
            sub_slug = name[:-5]  # strip ".opml"
            sub_name = humanize_slug(sub_slug)
            subregions.append({
                "slug": sub_slug,
                "name": sub_name,
                "parent_country": country_slug,
                "iso2": meta["iso2"],
                "iso3": meta["iso3"],
                "ddg_region": meta.get("ddg_region", f'{meta["cctld"]}-{meta["lang"]}'),
                "opml_path": str(country_dir / name),
            })

        pop = POPULATION.get(country_slug, 0)
        result[country_slug] = {
            "name": meta["name"],
            "native_name": meta.get("native_name", meta["name"]),
            "cctld": meta["cctld"],
            "use_cctld": meta["use_cctld"],
            "lang": meta["lang"],
            "ddg_region": meta.get("ddg_region", f'{meta["cctld"]}-{meta["lang"]}'),
            "iso2": meta["iso2"],
            "iso3": meta["iso3"],
            "population": pop,
            "subregions": subregions,
        }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    return result
