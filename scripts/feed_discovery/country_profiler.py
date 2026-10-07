from __future__ import annotations

import asyncio
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import aiohttp

from .profiles._registry import load_profile, save_profile
from .profiles._schema import CountryProfile, SourceConfig, SourceMetrics
from .sources._base import ProbeResult

# Degradation thresholds
DEGRADE_AFTER_N_FAILURES = 3
DISABLE_AFTER_N_FAILURES = 5
PRIORITY_PENALTY = 5
# A disabled source is re-probed after this window so it can recover.
RECOVERY_BACKOFF_HOURS = 24


class CountryProfiler:
    """Generates and maintains CountryProfiles automatically.

    Flow:
    1. BOOTSTRAP: load profile (global + regional), probe all sources
    2. UPDATE: after each discovery run, record metrics, adjust
    3. SAVE: persist the learned profile
    """

    def __init__(self, profiles_dir: Path | None = None):
        self.profiles_dir = profiles_dir
        self._source_instances: dict[str, object] = {}
        self._init_sources()

    def _init_sources(self):
        """Instantiate all available sources."""
        try:
            from .sources.podcast_index import PodcastIndexSource
            self._source_instances["podcast_index"] = PodcastIndexSource()
        except Exception:
            pass
        try:
            from .sources.deezer import DeezerSource
            self._source_instances["deezer"] = DeezerSource()
        except Exception:
            pass
        try:
            from .sources.youtube_api import YouTubeAPISource
            self._source_instances["youtube_api"] = YouTubeAPISource()
        except Exception:
            pass
        try:
            from .sources.youtube_trending import YouTubeTrendingSource
            self._source_instances["youtube_trending"] = YouTubeTrendingSource()
        except Exception:
            pass
        try:
            from .sources.reddit import RedditSource
            self._source_instances["reddit"] = RedditSource()
        except Exception:
            pass
        try:
            from .sources.google_news import GoogleNewsSource
            self._source_instances["google_news"] = GoogleNewsSource()
        except Exception:
            pass
        try:
            from .sources.itunes_charts import ITunesChartsSource
            self._source_instances["itunes_charts"] = ITunesChartsSource()
        except Exception:
            pass
        try:
            from .sources.ddg_text import DDGTextSource
            self._source_instances["ddg_text"] = DDGTextSource()
        except Exception:
            pass
        try:
            from .sources.podcasts import ITunesSource
            self._source_instances["itunes"] = ITunesSource()
        except Exception:
            pass
        try:
            from .sources.youtube_top_subscribed import YouTubeTopSubscribedSource
            self._source_instances["youtube_top_subscribed"] = YouTubeTopSubscribedSource()
        except Exception:
            pass
        try:
            from .sources.youtube_awards import YouTubeAwardsSource
            self._source_instances["youtube_awards"] = YouTubeAwardsSource()
        except Exception:
            pass
        try:
            from .sources.youtube_kaggle import YouTubeKaggleSource
            self._source_instances["youtube_kaggle"] = YouTubeKaggleSource()
        except Exception:
            pass
        try:
            from .sources.youtube_socialblade import YouTubeSocialBladeSource
            self._source_instances["youtube_socialblade"] = YouTubeSocialBladeSource()
        except Exception:
            pass
        try:
            from .sources.youtube_diamond import YouTubeDiamondSource
            self._source_instances["youtube_diamond"] = YouTubeDiamondSource()
        except Exception:
            pass

    def bootstrap_sync(self, country_slug: str) -> CountryProfile:
        """Synchronous wrapper for bootstrap."""
        return asyncio.run(self.bootstrap(country_slug))

    async def bootstrap(self, country_slug: str) -> CountryProfile:
        """Generate an initial profile for a country.

        1. Load base profile (global + regional merge)
        2. Probe all active sources
        3. Disable sources that fail immediately
        4. Save and return
        """
        profile = load_profile(country_slug, profiles_dir=self.profiles_dir)
        profile.generated_at = datetime.now(timezone.utc).isoformat()
        profile.generation_version = 1

        # Probe all sources
        connector = aiohttp.TCPConnector(limit=10)
        async with aiohttp.ClientSession(connector=connector) as session:
            results = await self.probe_all_sources(profile, session)

        # Apply probe results
        for source_name, result in results.items():
            self._record_probe(
                profile, source_name,
                success=result.success,
                result_count=result.result_count,
                latency_ms=result.latency_ms,
            )

        # Save
        save_profile(profile, output_dir=self.profiles_dir)
        return profile

    async def update(
        self,
        profile: CountryProfile,
        session: aiohttp.ClientSession,
    ) -> CountryProfile:
        """Update a profile after a discovery run.

        Records metrics, degrades/disables failing sources, saves.
        """
        profile.generation_version += 1
        profile.generated_at = datetime.now(timezone.utc).isoformat()

        # Re-probe degraded sources — and disabled ones whose backoff elapsed —
        # so a source that recovers is not blocked forever.
        now = datetime.now(timezone.utc)
        for name, metrics in profile.source_performance.items():
            disabled = name in profile.disabled_sources
            if disabled:
                if not self._recovery_due(metrics, now):
                    continue
            elif metrics.success_rate >= 0.5 or metrics.total_calls == 0:
                continue
            source = self._source_instances.get(name)
            if source and hasattr(source, "enabled") and source.enabled:
                cfg = profile.sources.get(name, SourceConfig(priority=99))
                try:
                    result = await source.probe(profile, cfg, session)
                    self._record_probe(
                        profile, name, result.success, result.result_count, result.latency_ms
                    )
                except Exception:
                    self._record_probe(profile, name, False, 0)

        save_profile(profile, output_dir=self.profiles_dir)
        return profile

    async def probe_all_sources(
        self,
        profile: CountryProfile,
        session: aiohttp.ClientSession,
    ) -> dict[str, ProbeResult]:
        """Test all active sources for a country in parallel."""
        results: dict[str, ProbeResult] = {}
        tasks = []

        for name, cfg in profile.sources.items():
            if name in profile.disabled_sources:
                continue
            source = self._source_instances.get(name)
            if source is None:
                continue
            if hasattr(source, "enabled") and not source.enabled:
                results[name] = ProbeResult(
                    source_name=name, success=False, result_count=0,
                    latency_ms=0, error="disabled",
                )
                continue
            tasks.append(self._probe_one(name, source, profile, cfg, session))

        gathered = await asyncio.gather(*tasks, return_exceptions=True)
        for item in gathered:
            if isinstance(item, Exception):
                continue
            name, result = item
            results[name] = result

        return results

    async def _probe_one(self, name, source, profile, cfg, session):
        t0 = time.monotonic()
        try:
            result = await source.probe(profile, cfg, session)
        except Exception as e:
            elapsed = (time.monotonic() - t0) * 1000
            result = ProbeResult(
                source_name=name, success=False, result_count=0,
                latency_ms=elapsed, error=str(e)[:200],
            )
        return name, result

    def _record_probe(
        self,
        profile: CountryProfile,
        source_name: str,
        success: bool,
        result_count: int,
        latency_ms: float = 0.0,
    ):
        """Record a probe result and apply degradation logic."""
        if source_name not in profile.source_performance:
            profile.source_performance[source_name] = SourceMetrics()

        m = profile.source_performance[source_name]
        m.total_calls += 1
        m.total_results += result_count
        m.total_latency_ms += latency_ms
        if success:
            m.success_count += 1
            m.consecutive_failures = 0
        else:
            m.failure_count += 1
            m.consecutive_failures += 1
        m.last_probe = datetime.now(timezone.utc).isoformat()

        # Degradation logic
        if source_name in profile.disabled_sources:
            if success:
                # The failure streak is what disabled it; a healthy probe clears
                # the streak and restarts the backoff clock.
                profile.disabled_sources.discard(source_name)
            return

        consecutive_failures = self._consecutive_zero_results(profile, source_name)

        if consecutive_failures >= DISABLE_AFTER_N_FAILURES:
            profile.disabled_sources.add(source_name)
        elif consecutive_failures >= DEGRADE_AFTER_N_FAILURES:
            if source_name in profile.sources:
                cfg = profile.sources[source_name]
                # Penalize priority — push to bottom
                max_priority = max((s.priority for s in profile.sources.values()), default=0)
                cfg.priority = max_priority + PRIORITY_PENALTY

    def _consecutive_zero_results(self, profile: CountryProfile, source_name: str) -> int:
        """Consecutive failed probes for a source; a success resets the streak."""
        m = profile.source_performance.get(source_name)
        if m is None:
            return 0
        return m.consecutive_failures

    @staticmethod
    def _recovery_due(metrics: SourceMetrics, now: datetime) -> bool:
        """True when a disabled source may be probed again."""
        if not metrics.last_probe:
            return True
        try:
            last_probe = datetime.fromisoformat(metrics.last_probe)
        except ValueError:
            return True
        if last_probe.tzinfo is None:
            last_probe = last_probe.replace(tzinfo=timezone.utc)
        return now - last_probe >= timedelta(hours=RECOVERY_BACKOFF_HOURS)
