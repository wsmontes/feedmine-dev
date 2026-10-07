# scripts/feed_discovery/tests/test_country_profiler.py

from pathlib import Path

import pytest
from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig, SourceMetrics
from scripts.feed_discovery.country_profiler import CountryProfiler
from scripts.feed_discovery.profiles._registry import load_profile


@pytest.fixture
def isolated_profiler(tmp_path, monkeypatch):
    """A profiler whose probes never touch the network and whose profile store
    is temporary: bootstrap must not call real services nor write the versioned
    data/country_profiles/testland.json."""
    profiler = CountryProfiler(profiles_dir=tmp_path)

    async def _no_probe(profile, session):
        return {}

    monkeypatch.setattr(profiler, "probe_all_sources", _no_probe)
    return profiler


def test_profiler_creates_profile_for_new_country(isolated_profiler):
    profile = isolated_profiler.bootstrap_sync("testland")
    assert profile.country == "testland"
    assert len(profile.sources) >= 3  # at least the Phase 1+2 sources
    assert profile.generation_version >= 1


def test_bootstrap_writes_only_the_temporary_profile_dir(isolated_profiler, tmp_path):
    versioned = Path(__file__).resolve().parents[1] / "data" / "country_profiles" / "testland.json"
    before = versioned.stat().st_mtime_ns if versioned.exists() else None

    isolated_profiler.bootstrap_sync("testland")

    assert (tmp_path / "testland.json").exists()
    after = versioned.stat().st_mtime_ns if versioned.exists() else None
    assert before == after, "bootstrap must not touch the versioned profile store"


def test_profiler_marks_source_as_degraded():
    profiler = CountryProfiler()
    profile = CountryProfile(
        country="test",
        sources={"test_source": SourceConfig(priority=1)},
    )
    # Simulate 3 consecutive rounds with 0 results
    for _ in range(3):
        profiler._record_probe(profile, "test_source", success=False, result_count=0)

    metrics = profile.source_performance.get("test_source")
    assert metrics is not None
    assert metrics.total_calls == 3
    assert metrics.success_count == 0
    assert metrics.success_rate == 0.0


def test_profiler_disables_source_after_five_failures():
    profiler = CountryProfiler()
    profile = CountryProfile(
        country="test",
        sources={"bad_source": SourceConfig(priority=1)},
    )
    # 5 consecutive failures -> disabled
    for _ in range(5):
        profiler._record_probe(profile, "bad_source", success=False, result_count=0)
    assert "bad_source" in profile.disabled_sources


def test_profiler_does_not_disable_after_three_failures():
    profiler = CountryProfiler()
    profile = CountryProfile(
        country="test",
        sources={"slow_source": SourceConfig(priority=1)},
    )
    for _ in range(3):
        profiler._record_probe(profile, "slow_source", success=False, result_count=0)
    # 3 failures -> degraded (lower priority) but NOT disabled
    assert "slow_source" not in profile.disabled_sources
    assert profile.sources["slow_source"].priority > 1


def test_profiler_updates_success_metrics():
    profiler = CountryProfiler()
    profile = CountryProfile(
        country="test",
        sources={"good_source": SourceConfig(priority=1)},
    )
    profiler._record_probe(profile, "good_source", success=True, result_count=42)
    metrics = profile.source_performance["good_source"]
    assert metrics.success_count == 1
    assert metrics.total_results == 42
    assert metrics.success_rate == 1.0


def test_bootstrap_includes_active_sources_only(isolated_profiler):
    """Bootstrap should track disabled sources separately without removing them from sources.

    Disabled sources stay in profile.sources (so they can be re-enabled later)
    but are also listed in profile.disabled_sources (so the pipeline skips them).
    """
    profile = isolated_profiler.bootstrap_sync("testland")
    # Verify that all sources have a SourceConfig
    for name, cfg in profile.sources.items():
        assert cfg.priority > 0, f"{name} has invalid priority"
    # Disabled sources should be a subset of known sources
    for name in profile.disabled_sources:
        assert name in profile.sources, f"{name} is disabled but not in sources"


def test_interleaved_failures_do_not_disable_a_healthy_source():
    """The streak counts consecutive failures, not the lifetime failure count."""
    profiler = CountryProfiler()
    profile = CountryProfile(country="test", sources={"flaky": SourceConfig(priority=1)})

    for _ in range(4):
        profiler._record_probe(profile, "flaky", success=False, result_count=0)
        profiler._record_probe(profile, "flaky", success=True, result_count=5)

    assert "flaky" not in profile.disabled_sources
    assert profile.source_performance["flaky"].failure_count == 4
    assert profile.source_performance["flaky"].consecutive_failures == 0


def test_five_consecutive_failures_disable_and_a_success_recovers():
    profiler = CountryProfiler()
    profile = CountryProfile(country="test", sources={"bad": SourceConfig(priority=1)})

    for _ in range(5):
        profiler._record_probe(profile, "bad", success=False, result_count=0)
    assert "bad" in profile.disabled_sources

    profiler._record_probe(profile, "bad", success=True, result_count=7)
    assert "bad" not in profile.disabled_sources
    assert profile.source_performance["bad"].consecutive_failures == 0


def test_recovery_backoff_waits_for_the_window():
    from datetime import datetime, timedelta, timezone

    metrics = SourceMetrics(last_probe=datetime.now(timezone.utc).isoformat())
    now = datetime.now(timezone.utc)
    assert CountryProfiler._recovery_due(metrics, now) is False
    assert CountryProfiler._recovery_due(metrics, now + timedelta(hours=25)) is True


def test_record_probe_accumulates_latency():
    profiler = CountryProfiler()
    profile = CountryProfile(country="test", sources={"timed": SourceConfig(priority=1)})

    profiler._record_probe(profile, "timed", success=True, result_count=3, latency_ms=120.0)
    profiler._record_probe(profile, "timed", success=True, result_count=3, latency_ms=80.0)

    metrics = profile.source_performance["timed"]
    assert metrics.total_latency_ms == 200.0
    assert metrics.avg_latency_ms == 100.0
