from __future__ import annotations

import asyncio
from typing import Callable

import aiohttp

from .constants import (
    DEFAULT_CONCURRENCY,
    DEFAULT_RETRIES,
    DEFAULT_TIMEOUT,
    NO_RETRY_STATUSES,
    RATE_LIMIT_STATUS,
    USER_AGENT,
)
from .models import CheckResult, Feed
from .verifiers import check_content_validity, check_freshness, check_reachability

# Shared semaphore slot — set by run_checks, read by signal handler for
# graceful Ctrl+C shutdown.
_semaphore: asyncio.Semaphore | None = None


async def run_checks(
    feeds: list[Feed],
    *,
    depth: int,
    concurrency: int = DEFAULT_CONCURRENCY,
    timeout: int = DEFAULT_TIMEOUT,
    retries: int = DEFAULT_RETRIES,
    user_agent: str = USER_AGENT,
    on_progress: Callable[[int, int], None] | None = None,
    cancelled: asyncio.Event | None = None,
) -> list[CheckResult]:
    """Check every feed concurrently and return one ``CheckResult`` per unique URL.

    Duplicate URLs (same URL appearing in multiple OPML files) are checked
    once and the result is shared across all source locations.
    """
    # ------------------------------------------------------------------
    # Deduplicate — group identical URLs
    # ------------------------------------------------------------------
    dedup: dict[str, list[Feed]] = {}
    for feed in feeds:
        dedup.setdefault(feed.url, []).append(feed)

    unique_urls = list(dedup.keys())
    total = len(unique_urls)
    results: list[CheckResult] = []
    completed = 0

    if cancelled is None:
        cancelled = asyncio.Event()

    global _semaphore
    _semaphore = asyncio.Semaphore(concurrency)

    connector = aiohttp.TCPConnector(limit=concurrency, limit_per_host=10)
    headers = {"User-Agent": user_agent}

    async with aiohttp.ClientSession(
        connector=connector,
        headers=headers,
        timeout=aiohttp.ClientTimeout(total=timeout),
    ) as session:

        async def check_one(url: str) -> CheckResult:
            nonlocal completed

            async with _semaphore:  # type: ignore[union-attr]
                if cancelled.is_set():
                    return _skip_result(dedup[url])

                for attempt in range(retries + 1):
                    result = await _check_single(session, url, dedup[url], depth, timeout)
                    if result.status != "dead" and result.status != "error":
                        break
                    if result.status_code in NO_RETRY_STATUSES:
                        break
                    if result.status_code == RATE_LIMIT_STATUS and attempt < retries:
                        await asyncio.sleep(1)
                    elif result.status == "dead" and attempt < retries:
                        await asyncio.sleep(1)

                completed += 1
                if on_progress:
                    on_progress(completed, total)
                return result

        gathered = await asyncio.gather(*[check_one(url) for url in unique_urls], return_exceptions=True)
        for item in gathered:
            if isinstance(item, BaseException):
                results.append(CheckResult(
                    url="unknown", title="unknown", source_files=[], categories=[],
                    status="error", error_message=str(item),
                ))
            elif item is not None:
                results.append(item)

    _semaphore = None
    return results


async def _check_single(
    session: aiohttp.ClientSession,
    url: str,
    feed_group: list[Feed],
    depth: int,
    timeout: int,
) -> CheckResult:
    """Run the depth pipeline against a single URL."""
    titles = [f.title for f in feed_group]
    source_files = [f.source_file for f in feed_group]
    categories = list({f.category for f in feed_group if f.category})

    result = CheckResult(
        url=url,
        title=titles[0] if len(titles) == 1 else ", ".join(titles),
        source_files=source_files,
        categories=categories,
    )

    # ---- Depth 1: Reachability ------------------------------------------------
    reach = await check_reachability(session, url, timeout)
    result.response_time_ms = reach["response_time_ms"]
    result.status_code = reach["status_code"]
    result.redirect_chain = reach["redirect_chain"]
    result.final_url = reach["final_url"]

    if reach["status_code"] == 0:
        result.status = "dead"
        return result

    # Determine redirect status
    if reach["redirect_chain"]:
        result.status = "redirected"
    else:
        result.status = "ok"

    if not (200 <= reach["status_code"] < 300):
        result.status = "dead"
        if depth == 1:
            return result
        # Depth > 1: still mark dead but keep going for diagnostics

    if depth == 1:
        return result

    # ---- Depth 2: Content Validity --------------------------------------------
    content = await check_content_validity(session, url, timeout)
    result.content_type = content["content_type"]
    result.body_size = content["body_size"]
    result.is_valid_feed = content["is_valid_feed"]

    if not content["is_valid_feed"] and result.status != "dead":
        result.status = "invalid"
        if depth == 2:
            return result

    if depth == 2:
        return result

    # ---- Depth 3: Freshness ---------------------------------------------------
    fresh = await check_freshness(session, url, timeout)
    result.newest_post_date = fresh.get("newest_post_date")
    result.days_since_last_post = fresh.get("days_since_last_post")
    result.freshness_status = fresh["freshness_status"]

    if fresh["freshness_status"] == "stale" and result.status not in ("dead", "invalid"):
        result.status = "stale"

    return result


def _skip_result(feed_group: list[Feed]) -> CheckResult:
    titles = [f.title for f in feed_group]
    url = feed_group[0].url
    return CheckResult(
        url=url,
        title=titles[0] if len(titles) == 1 else ", ".join(titles),
        source_files=[f.source_file for f in feed_group],
        categories=list({f.category for f in feed_group if f.category}),
        status="error",
        error_message="cancelled",
    )


def _error_result(feed_group: list[Feed], message: str) -> CheckResult:
    if not feed_group:
        return CheckResult(url="unknown", title="unknown", source_files=[], categories=[], status="error", error_message=message)
    titles = [f.title for f in feed_group]
    url = feed_group[0].url
    return CheckResult(
        url=url,
        title=titles[0] if len(titles) == 1 else ", ".join(titles),
        source_files=[f.source_file for f in feed_group],
        categories=list({f.category for f in feed_group if f.category}),
        status="error",
        error_message=message,
    )
