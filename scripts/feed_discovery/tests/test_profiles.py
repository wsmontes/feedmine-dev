from dataclasses import asdict
from scripts.feed_discovery.profiles._schema import (
    CountryProfile, SourceConfig, SourceMetrics,
)
from scripts.feed_discovery.sources._base import ProbeResult


def test_source_config_defaults():
    c = SourceConfig(priority=1)
    assert c.priority == 1
    assert c.enabled is True
    assert c.params == {}
    assert c.min_results == 3
    assert c.max_results == 50
    assert c.timeout == 15


def test_source_config_custom():
    c = SourceConfig(priority=2, enabled=False, params={"lang": "en"}, min_results=5, max_results=20, timeout=30)
    assert c.priority == 2
    assert c.enabled is False
    assert c.params == {"lang": "en"}
    assert c.min_results == 5
    assert c.max_results == 20
    assert c.timeout == 30


def test_source_metrics_defaults():
    m = SourceMetrics()
    assert m.total_calls == 0
    assert m.total_results == 0
    assert m.success_count == 0
    assert m.failure_count == 0
    assert m.success_rate == 1.0  # 0/0 = 1.0 per spec
    assert m.avg_results == 0.0
    assert m.avg_latency_ms == 0.0


def test_source_metrics_computed():
    m = SourceMetrics(
        total_calls=10, total_results=45,
        success_count=8, failure_count=2,
        total_latency_ms=2300.0,
    )
    assert m.success_rate == 0.8
    assert m.avg_results == 4.5
    assert m.avg_latency_ms == 230.0


def test_source_metrics_success_rate_zero_calls():
    m = SourceMetrics(total_calls=0, success_count=0)
    assert m.success_rate == 1.0


def test_probe_result_success():
    r = ProbeResult(source_name="test", success=True, result_count=42, latency_ms=150.0)
    assert r.source_name == "test"
    assert r.success is True
    assert r.result_count == 42
    assert r.latency_ms == 150.0
    assert r.error == ""


def test_probe_result_failure():
    r = ProbeResult(source_name="test", success=False, result_count=0, latency_ms=5000.0, error="timeout")
    assert r.success is False
    assert r.error == "timeout"


def test_country_profile_defaults():
    p = CountryProfile(country="nigeria")
    assert p.country == "nigeria"
    assert p.internet_penetration == 0.0
    assert p.dominant_platforms == []
    assert p.languages == []
    assert p.sources == {}
    assert p.local_directories == []
    assert p.media_domains == []
    assert p.disabled_sources == set()
    assert p.source_performance == {}
    assert p.generated_at == ""
    assert p.generation_version == 1


def test_country_profile_with_sources():
    p = CountryProfile(
        country="brazil",
        internet_penetration=0.75,
        dominant_platforms=["whatsapp", "youtube", "deezer"],
        languages=["pt"],
        sources={
            "deezer": SourceConfig(priority=1),
            "podcast_index": SourceConfig(priority=2, params={"lang": "pt"}),
        },
        media_domains=["globo.com", "uol.com.br"],
        disabled_sources={"itunes"},
    )
    assert p.country == "brazil"
    assert len(p.sources) == 2
    assert p.sources["deezer"].priority == 1
    assert p.sources["podcast_index"].params == {"lang": "pt"}
    assert "itunes" in p.disabled_sources
    assert p.internet_penetration == 0.75


def test_country_profile_serialization():
    p = CountryProfile(
        country="test",
        sources={"deezer": SourceConfig(priority=1)},
        disabled_sources={"itunes"},
    )
    d = asdict(p)
    assert d["country"] == "test"
    assert d["sources"]["deezer"]["priority"] == 1
    assert "itunes" in d["disabled_sources"]


# ---- GLOBAL_PROFILE tests ----
# NOTE: importlib is required because 'global' is a Python keyword,
# so 'from profiles.global import ...' is a SyntaxError at parse time.

import importlib
_global_mod = importlib.import_module(
    "scripts.feed_discovery.profiles.global"
)
GLOBAL_PROFILE = _global_mod.GLOBAL_PROFILE


def test_global_profile_is_country_profile():
    from scripts.feed_discovery.profiles._schema import CountryProfile
    assert isinstance(GLOBAL_PROFILE, CountryProfile)


def test_global_profile_country_is_wildcard():
    assert GLOBAL_PROFILE.country == "*"


def test_global_profile_has_sources():
    assert len(GLOBAL_PROFILE.sources) == 17


def test_global_profile_sources_ordered_by_priority():
    priorities = [(name, cfg.priority) for name, cfg in GLOBAL_PROFILE.sources.items()]
    sorted_by_priority = sorted(priorities, key=lambda x: x[1])
    assert priorities == sorted_by_priority


def test_global_profile_source_names():
    expected = {
        "podcast_index", "itunes_charts", "deezer", "youtube_api", "youtube_trending",
        "ddg_text", "itunes", "youtube_top_subscribed",
        "listen_notes", "spotify", "feedly", "google_news", "reddit", "youtube_awards",
        "youtube_kaggle", "youtube_socialblade", "youtube_diamond",
    }
    assert set(GLOBAL_PROFILE.sources.keys()) == expected


def test_global_profile_youtube_scrape_disabled():
    pass  # placeholder -- youtube_scrape not in GLOBAL_PROFILE yet


def test_global_profile_no_disabled_sources_initially():
    assert GLOBAL_PROFILE.disabled_sources == set()


def test_global_profile_media_domains_empty():
    assert GLOBAL_PROFILE.media_domains == []


def test_global_profile_generation_version():
    assert GLOBAL_PROFILE.generation_version == 1


# ---- Per-country copies: configs and metrics are never shared (TOOL-20) ----

def test_load_profile_copies_shared_source_configs():
    from scripts.feed_discovery.profiles._registry import load_profile

    nigeria = load_profile("nigeria")
    kenya = load_profile("kenya")
    # Not in REGION_MAP and without a country JSON: built straight from GLOBAL.
    plain = load_profile("not-a-real-country-slug")

    for name, cfg in nigeria.sources.items():
        assert cfg is not kenya.sources[name]
        assert cfg is not plain.sources[name]
        assert cfg is not GLOBAL_PROFILE.sources[name]
        assert cfg.params is not GLOBAL_PROFILE.sources[name].params


def test_degrading_one_country_does_not_touch_another_country_or_global():
    from scripts.feed_discovery.country_profiler import CountryProfiler
    from scripts.feed_discovery.profiles._registry import load_profile

    nigeria = load_profile("nigeria")
    kenya = load_profile("kenya")
    kenya_priority = kenya.sources["itunes"].priority
    global_priority = GLOBAL_PROFILE.sources["itunes"].priority

    profiler = CountryProfiler()
    for _ in range(3):
        profiler._record_probe(nigeria, "itunes", success=False, result_count=0)

    assert nigeria.sources["itunes"].priority > kenya_priority
    assert kenya.sources["itunes"].priority == kenya_priority
    assert GLOBAL_PROFILE.sources["itunes"].priority == global_priority


def test_probe_metrics_are_not_shared_between_countries():
    from scripts.feed_discovery.country_profiler import CountryProfiler
    from scripts.feed_discovery.profiles._registry import load_profile

    nigeria = load_profile("nigeria")
    kenya = load_profile("kenya")

    CountryProfiler()._record_probe(nigeria, "deezer", success=False, result_count=0)

    assert "deezer" in nigeria.source_performance
    assert "deezer" not in kenya.source_performance
    assert "deezer" not in GLOBAL_PROFILE.source_performance
