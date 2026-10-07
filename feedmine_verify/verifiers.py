from __future__ import annotations

import re
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

import aiohttp

from .constants import FEED_ROOT_TAGS, MAX_BODY_BYTES, STALE_THRESHOLD_DAYS


# ---------------------------------------------------------------------------
# Depth 1 — Reachability
# ---------------------------------------------------------------------------

async def check_reachability(
    session: aiohttp.ClientSession,
    url: str,
    timeout_sec: int,
) -> dict:
    """HEAD (fallback GET) → status, redirect chain, response time."""
    t0 = time.monotonic()
    redirect_chain: list[str] = []
    final_url = url

    try:
        # Try HEAD first
        async with session.head(
            url,
            timeout=aiohttp.ClientTimeout(total=timeout_sec),
            allow_redirects=True,
        ) as resp:
            status = resp.status
            redirect_chain = [str(r.url) for r in resp.history]
            final_url = str(resp.url)
            if resp.history:
                redirect_chain = [str(r.url) for r in resp.history]

        # Some servers reject HEAD — fall back to a tiny GET
        if status in (405, 501):
            status, redirect_chain, final_url = await _get_reachability(session, url, timeout_sec)

    except aiohttp.ClientError:
        # Catch-all for connection / DNS / TLS issues — try GET once
        try:
            status, redirect_chain, final_url = await _get_reachability(session, url, timeout_sec)
        except aiohttp.ClientError:
            status = 0
            redirect_chain = []
            final_url = url

    elapsed = (time.monotonic() - t0) * 1000

    return {
        "status_code": status,
        "redirect_chain": redirect_chain,
        "final_url": final_url,
        "response_time_ms": round(elapsed, 1),
    }


async def _get_reachability(
    session: aiohttp.ClientSession,
    url: str,
    timeout_sec: int,
) -> tuple[int, list[str], str]:
    """Small GET as fallback when HEAD is rejected."""
    async with session.get(
        url,
        timeout=aiohttp.ClientTimeout(total=timeout_sec),
        allow_redirects=True,
    ) as resp:
        # Read a tiny chunk just to trigger any connection errors
        await resp.content.read(1)
        return resp.status, [str(r.url) for r in resp.history], str(resp.url)


# ---------------------------------------------------------------------------
# Depth 2 — Content Validity
# ---------------------------------------------------------------------------

async def _read_capped(content: aiohttp.StreamReader, limit: int) -> bytes:
    """Read up to *limit* bytes, tolerating short reads from the stream."""
    chunks: list[bytes] = []
    remaining = limit
    while remaining > 0:
        chunk = await content.read(remaining)
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


async def check_content_validity(
    session: aiohttp.ClientSession,
    url: str,
    timeout_sec: int,
) -> dict:
    """Fetch first 64 KB of body and verify it looks like RSS/Atom XML."""
    try:
        async with session.get(
            url,
            timeout=aiohttp.ClientTimeout(total=timeout_sec),
            allow_redirects=True,
        ) as resp:
            body = await _read_capped(resp.content, MAX_BODY_BYTES)
            content_type = resp.content_type or ""
            body_size = len(body)
            is_valid = _is_feed_xml(body)

        return {
            "content_type": content_type,
            "body_size": body_size,
            "is_valid_feed": is_valid,
        }
    except aiohttp.ClientError:
        return {"content_type": "", "body_size": 0, "is_valid_feed": False}


def _is_feed_xml(data: bytes) -> bool:
    """Check the document's first element without requiring the whole body.

    Only the root start tag is inspected, so a feed larger than
    ``MAX_BODY_BYTES`` (truncated by design) is still recognised.  XML bytes
    are handed to the parser unchanged, so the encoding declared by the
    document is honoured instead of forcing UTF-8.
    """
    if not data:
        return False
    parser = ET.XMLPullParser(events=("start",))
    try:
        parser.feed(data[:MAX_BODY_BYTES])
        for _event, element in parser.read_events():
            tag = element.tag.lower().split("}")[-1]  # strip namespace
            return tag in FEED_ROOT_TAGS
    except (ET.ParseError, UnicodeDecodeError, LookupError, ValueError):
        return False
    return False


# ---------------------------------------------------------------------------
# Depth 3 — Freshness
# ---------------------------------------------------------------------------

# RSS: <pubDate>Mon, 01 Jan 2024 12:00:00 GMT</pubDate>
# Atom: <published>2024-01-01T12:00:00Z</published>  or  <updated>…</updated>

_DATE_PATTERNS = [
    # RSS pubDate (RFC 2822)
    re.compile(r"<pubDate>(.*?)</pubDate>", re.DOTALL),
    # Atom published
    re.compile(r"<published>(.*?)</published>", re.DOTALL),
    # Atom updated
    re.compile(r"<updated>(.*?)</updated>", re.DOTALL),
]

_RFC2822_FORMATS = [
    "%a, %d %b %Y %H:%M:%S %z",   # Mon, 01 Jan 2024 12:00:00 +0000
    "%a, %d %b %Y %H:%M:%S %Z",   # Mon, 01 Jan 2024 12:00:00 GMT
]

_ISO_FORMATS = [
    "%Y-%m-%dT%H:%M:%SZ",
    "%Y-%m-%dT%H:%M:%S%z",
    "%Y-%m-%dT%H:%M:%S.%fZ",
    "%Y-%m-%dT%H:%M:%S.%f%z",
]


async def check_freshness(
    session: aiohttp.ClientSession,
    url: str,
    timeout_sec: int,
) -> dict:
    """Fetch feed body and extract the newest post date."""
    try:
        async with session.get(
            url,
            timeout=aiohttp.ClientTimeout(total=timeout_sec),
            allow_redirects=True,
        ) as resp:
            body = await _read_capped(resp.content, MAX_BODY_BYTES)
    except aiohttp.ClientError:
        return {"newest_post_date": None, "days_since_last_post": None, "freshness_status": ""}

    text = body.decode("utf-8", errors="replace")
    newest = _extract_newest_date(text)

    if newest is None:
        return {"newest_post_date": None, "days_since_last_post": None, "freshness_status": "no_dates"}

    now = datetime.now(timezone.utc)
    delta = (now - newest).days

    status = "stale" if delta > STALE_THRESHOLD_DAYS else "fresh"
    return {
        # Kept as ``datetime`` — serialisation is the reporter's/CLI's job.
        "newest_post_date": newest,
        "days_since_last_post": delta,
        "freshness_status": status,
    }


def _extract_newest_date(text: str) -> datetime | None:
    """Scan *text* for feed dates and return the most recent one."""
    candidates: list[datetime] = []

    for pattern in _DATE_PATTERNS:
        for match in pattern.finditer(text):
            date_str = match.group(1).strip()
            parsed = _try_parse_date(date_str)
            if parsed:
                candidates.append(parsed)

    return max(candidates) if candidates else None


def _try_parse_date(s: str) -> datetime | None:
    """Try a battery of date formats against *s*.

    Every returned value is timezone-aware (UTC when the source carries a
    zone abbreviation such as ``GMT`` that ``strptime`` cannot resolve), so
    dates from mixed RSS/Atom formats remain comparable.
    """
    # Atom ISO formats
    for fmt in _ISO_FORMATS:
        try:
            dt = datetime.strptime(s, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc)
        except ValueError:
            continue

    # RSS RFC 2822 formats
    for fmt in _RFC2822_FORMATS:
        try:
            dt = datetime.strptime(s, fmt)
            if dt.tzinfo is None:
                # ``%Z`` yields a naive datetime for "GMT"/"UTC".
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc)
        except ValueError:
            continue

    # Last resort: ISO via fromisoformat (Python 3.11+ handles more cases)
    try:
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except ValueError:
        return None
