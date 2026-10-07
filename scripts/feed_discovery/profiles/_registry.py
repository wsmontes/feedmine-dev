# scripts/feed_discovery/profiles/_registry.py

from __future__ import annotations

import json
from dataclasses import replace
from pathlib import Path

from ._schema import CountryProfile, SourceConfig, SourceMetrics

# NOTE: importlib is required because 'global' is a Python keyword,
# so 'from .global import ...' is a SyntaxError at parse time.
import importlib
_global_mod = importlib.import_module(".global", __package__)
GLOBAL_PROFILE = _global_mod.GLOBAL_PROFILE

# Country -> region mapping. Every country with sub-region OPMLs must be here.
# Countries not listed get GLOBAL_PROFILE directly.
REGION_MAP: dict[str, str | None] = {
    # Africa
    "nigeria": "africa", "kenya": "africa", "south-africa": "africa",
    "ghana": "africa", "ethiopia": "africa", "egypt": "africa",
    "algeria": "africa", "morocco": "africa", "tunisia": "africa",
    "angola": "africa", "ivory-coast": "africa", "sudan": "africa",
    "cameroon": "africa", "uganda": "africa", "tanzania": "africa",
    "rwanda": "africa", "senegal": "africa", "zimbabwe": "africa",
    "zambia": "africa", "malawi": "africa", "burkina-faso": "africa",
    "mozambique": "africa", "mali": "africa", "benin": "africa",
    # LatAm
    "brazil": "latam", "mexico": "latam", "argentina": "latam",
    "colombia": "latam", "peru": "latam", "chile": "latam",
    "venezuela": "latam", "ecuador": "latam", "bolivia": "latam",
    "paraguay": "latam", "uruguay": "latam", "costa-rica": "latam",
    "panama": "latam", "cuba": "latam", "dominican-republic": "latam",
    "haiti": "latam", "honduras": "latam", "el-salvador": "latam",
    "nicaragua": "latam", "guatemala": "latam", "puerto-rico": "latam",
    # Asia
    "india": "asia", "china": "asia", "japan": "asia",
    "south-korea": "asia", "taiwan": "asia", "nepal": "asia",
    "bangladesh": "asia", "sri-lanka": "asia", "pakistan": "asia",
    # Europe East
    "russia": "europe_east", "romania": "europe_east",
    "poland": "europe_east", "ukraine": "europe_east",
    "czech-republic": "europe_east", "hungary": "europe_east",
    "bulgaria": "europe_east", "serbia": "europe_east",
    "slovakia": "europe_east", "croatia": "europe_east",
    "slovenia": "europe_east", "lithuania": "europe_east",
    "latvia": "europe_east", "estonia": "europe_east",
    "belarus": "europe_east", "georgia": "europe_east",
    "armenia": "europe_east", "azerbaijan": "europe_east",
    "kazakhstan": "europe_east",
    # MENA
    "uae": "mena", "saudi-arabia": "mena", "turkey": "mena",
    "israel": "mena", "iran": "mena", "iraq": "mena",
    "qatar": "mena", "jordan": "mena", "lebanon": "mena",
    "syria": "mena", "cyprus": "mena",
    # Southeast Asia
    "indonesia": "southeast_asia", "thailand": "southeast_asia",
    "vietnam": "southeast_asia", "malaysia": "southeast_asia",
    "philippines": "southeast_asia", "singapore": "southeast_asia",
    "myanmar": "southeast_asia", "cambodia": "southeast_asia",
    # Western Europe (fallback to global -- well-covered by all sources)
    "united-kingdom": None, "france": None, "germany": None,
    "italy": None, "spain": None, "portugal": None,
    "netherlands": None, "belgium": None, "switzerland": None,
    "austria": None, "sweden": None, "norway": None,
    "denmark": None, "finland": None, "ireland": None,
    "iceland": None, "luxembourg": None, "malta": None,
    "greece": None, "canada": None, "australia": None,
    "new-zealand": None, "usa": None,
    # Small island nations -- global fallback
    "jamaica": None, "bahamas": None, "barbados": None,
    "trinidad-tobago": None, "mauritius": None, "fiji": None,
}


def _copy_sources(sources: dict[str, SourceConfig]) -> dict[str, SourceConfig]:
    """Copy SourceConfig values so no two country profiles share one instance."""
    return {name: replace(cfg, params=dict(cfg.params)) for name, cfg in sources.items()}


def _copy_metrics(metrics: dict[str, SourceMetrics]) -> dict[str, SourceMetrics]:
    """Copy SourceMetrics values so streaks and counters stay per-country."""
    return {name: replace(metric) for name, metric in metrics.items()}


def merge_profiles(base: CountryProfile, override: CountryProfile) -> CountryProfile:
    """Deep merge two profiles. Override takes precedence.

    - sources: override replaces entire SourceConfig for matching keys
    - disabled_sources: set union
    - media_domains, local_directories: combined, deduplicated
    - languages: override replaces
    - dominant_platforms: override replaces
    - internet_penetration: override replaces
    - source_performance: override replaces matching keys
    """
    merged = CountryProfile(
        country=override.country if override.country != "*" else base.country,
        internet_penetration=override.internet_penetration or base.internet_penetration,
        dominant_platforms=override.dominant_platforms or base.dominant_platforms,
        languages=override.languages or base.languages,
        sources=_copy_sources({**base.sources, **override.sources}),
        local_directories=list(dict.fromkeys(base.local_directories + override.local_directories)),
        media_domains=list(dict.fromkeys(base.media_domains + override.media_domains)),
        disabled_sources=base.disabled_sources | override.disabled_sources,
        source_performance=_copy_metrics({**base.source_performance, **override.source_performance}),
    )
    return merged


def load_profile(
    country_slug: str,
    profiles_dir: Path | None = None,
) -> CountryProfile:
    """Load a CountryProfile with regional merge.

    Order: GLOBAL_PROFILE -> regional mixin -> country-specific JSON

    Args:
        country_slug: e.g. "nigeria"
        profiles_dir: Where country JSON profiles are stored.
                       Defaults to data/country_profiles/

    Returns:
        Merged CountryProfile ready for discovery.
    """
    # Start with global
    profile = CountryProfile(
        country=country_slug,
        internet_penetration=GLOBAL_PROFILE.internet_penetration,
        dominant_platforms=list(GLOBAL_PROFILE.dominant_platforms),
        languages=list(GLOBAL_PROFILE.languages),
        sources=_copy_sources(GLOBAL_PROFILE.sources),
        local_directories=list(GLOBAL_PROFILE.local_directories),
        media_domains=list(GLOBAL_PROFILE.media_domains),
        disabled_sources=set(GLOBAL_PROFILE.disabled_sources),
        source_performance=_copy_metrics(GLOBAL_PROFILE.source_performance),
    )

    # Apply regional mixin
    region = REGION_MAP.get(country_slug)
    if region:
        regional = _load_regional_mixin(region)
        if regional:
            profile = merge_profiles(profile, regional)

    # Apply country-specific JSON if it exists
    if profiles_dir is None:
        profiles_dir = Path(__file__).resolve().parents[1] / "data" / "country_profiles"
    country_json = profiles_dir / f"{country_slug}.json"
    if country_json.exists():
        data = json.loads(country_json.read_text(encoding="utf-8"))
        country_override = _profile_from_dict(data)
        profile = merge_profiles(profile, country_override)

    profile.country = country_slug
    return profile


def save_profile(
    profile: CountryProfile,
    output_dir: Path | None = None,
) -> None:
    """Persist a CountryProfile to JSON."""
    if output_dir is None:
        output_dir = Path(__file__).resolve().parents[1] / "data" / "country_profiles"
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / f"{profile.country}.json"
    data = _profile_to_dict(profile)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(path)


def _profile_from_dict(data: dict) -> CountryProfile:
    """Deserialize a JSON dict back to CountryProfile."""
    sources = {}
    for name, cfg in data.get("sources", {}).items():
        sources[name] = SourceConfig(
            priority=cfg.get("priority", 1),
            enabled=cfg.get("enabled", True),
            params=cfg.get("params", {}),
            min_results=cfg.get("min_results", 3),
            max_results=cfg.get("max_results", 50),
            timeout=cfg.get("timeout", 15),
        )
    perf = {}
    for name, m in data.get("source_performance", {}).items():
        perf[name] = SourceMetrics(
            total_calls=m.get("total_calls", 0),
            total_results=m.get("total_results", 0),
            success_count=m.get("success_count", 0),
            failure_count=m.get("failure_count", 0),
            consecutive_failures=m.get("consecutive_failures", 0),
            total_latency_ms=m.get("total_latency_ms", 0.0),
            last_probe=m.get("last_probe", ""),
        )
    return CountryProfile(
        country=data.get("country", ""),
        internet_penetration=data.get("internet_penetration", 0.0),
        dominant_platforms=data.get("dominant_platforms", []),
        languages=data.get("languages", []),
        sources=sources,
        local_directories=data.get("local_directories", []),
        media_domains=data.get("media_domains", []),
        disabled_sources=set(data.get("disabled_sources", [])),
        source_performance=perf,
        generated_at=data.get("generated_at", ""),
        generation_version=data.get("generation_version", 1),
    )


def _profile_to_dict(profile: CountryProfile) -> dict:
    """Serialize CountryProfile to a JSON-safe dict."""
    from dataclasses import asdict
    d = asdict(profile)
    d["disabled_sources"] = sorted(profile.disabled_sources)
    return d


def _load_regional_mixin(region: str) -> CountryProfile | None:
    """Import and return a regional mixin by name."""
    import importlib
    try:
        mod = importlib.import_module(f".{region}", __package__)
        # Handle multi-word: southeast_asia -> SOUTHEAST_ASIA_PROFILE
        attr = region.upper().replace("-", "_") + "_PROFILE"
        return getattr(mod, attr, None)
    except (ImportError, AttributeError):
        return None
