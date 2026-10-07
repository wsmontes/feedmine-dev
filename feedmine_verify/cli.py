"""CLI entry-point — argparse setup, dispatch, graceful shutdown."""

from __future__ import annotations

import argparse
import asyncio
import signal
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from .checker import run_checks
from .cleaner import clean_dead_feeds
from .constants import (
    DEFAULT_CONCURRENCY,
    DEFAULT_RETRIES,
    DEFAULT_TIMEOUT,
    PERMANENT_DEAD_STATUSES,
    USER_AGENT,
)
from .models import CheckResult, Report
from .reporter import print_terminal_report, write_json_report
from .scanner import scan_directory


def main(argv: list[str] | None = None) -> None:
    parser = _build_parser()
    args = parser.parse_args(argv)

    root = Path(args.path).resolve()
    if not root.exists():
        print(f"Error: path does not exist — {root}", file=sys.stderr)
        sys.exit(1)

    # ---- Scan ----------------------------------------------------------------
    print(f"🔍 Scanning {root} …", file=sys.stderr)
    feeds, scan_errors = scan_directory(root, recursive=not args.no_recursive)

    if not feeds:
        print("No feeds found.", file=sys.stderr)
        if scan_errors:
            for e in scan_errors:
                print(f"  Error in {e['file']}: {e['error']}", file=sys.stderr)
            # Nothing was readable — a gate must not report success.
            sys.exit(1)
        sys.exit(0)

    print(f"   {len(feeds)} feeds across {len({f.source_file for f in feeds})} OPML files.\n",
          file=sys.stderr)

    # ---- Check ---------------------------------------------------------------
    cancelled = asyncio.Event()
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    t0 = time.monotonic()

    def _progress(completed: int, total: int) -> None:
        if completed % 10 != 0 and completed != total:
            return
        pct = completed / total * 100
        bar = "█" * (completed * 30 // total) + "░" * ((total - completed) * 30 // total)
        print(f"\r  [{bar}] {completed}/{total} ({pct:.0f}%)", end="", file=sys.stderr, flush=True)

    # Ctrl+C → graceful
    def _on_sigint(*_: object) -> None:
        cancelled.set()
        print("\n⚠️  Interrupted — saving partial results …", file=sys.stderr)

    try:
        loop.add_signal_handler(signal.SIGINT, _on_sigint)
    except NotImplementedError:
        pass  # Windows

    try:
        results = loop.run_until_complete(
            run_checks(
                feeds,
                depth=args.depth,
                concurrency=args.concurrency,
                timeout=args.timeout,
                retries=args.retries,
                user_agent=args.user_agent,
                on_progress=_progress,
                cancelled=cancelled,
            )
        )
    except KeyboardInterrupt:
        print("\n⚠️  Interrupted.", file=sys.stderr)
        results = []
    finally:
        loop.close()

    duration = time.monotonic() - t0
    print("", file=sys.stderr)  # newline after progress bar

    # ---- Report --------------------------------------------------------------
    counts: dict[str, int] = {}
    for r in results:
        counts[r.status] = counts.get(r.status, 0) + 1

    report = Report(
        timestamp=datetime.now(timezone.utc).isoformat(),
        depth=args.depth,
        concurrency=args.concurrency,
        timeout=args.timeout,
        total_feeds=len(results),
        duration_seconds=round(duration, 1),
        summary=counts,
        results=[_checkresult_to_dict(r) for r in results],
        errors=scan_errors,
    )

    report_meta = {
        "depth": args.depth,
        "concurrency": args.concurrency,
        "timeout": args.timeout,
        "duration_seconds": round(duration, 1),
    }

    print_terminal_report(results, scan_errors, report_meta, args.format)

    if args.output:
        write_json_report(report, Path(args.output))
        print(f"📄 JSON report → {args.output}")

    # ---- Clean ---------------------------------------------------------------
    if args.clean:
        # A single-file scan stores ``source_file`` relative to the file's
        # parent, so the cleaner must resolve against that same base.
        clean_root = root.parent if root.is_file() else root
        modified = clean_dead_feeds(results, clean_root)
        print(f"🧹 Cleaned {modified} OPML file(s) — dead feeds removed.")
        deferred = sum(
            1 for r in results
            if r.status == "dead" and r.status_code not in PERMANENT_DEAD_STATUSES
        )
        if deferred:
            print(
                f"   ⏸️  {deferred} unreachable feed(s) kept (no confirmed 404/410) — review manually.",
                file=sys.stderr,
            )

    # Exit code — non-zero on any unreadable OPML file or on dead/error/invalid
    # results.  ``stale``/``redirected`` feeds are still usable.
    failed = (
        counts.get("dead", 0)
        + counts.get("error", 0)
        + counts.get("invalid", 0)
        + len(scan_errors)
    )
    if failed > 0:
        sys.exit(1)


def _positive_int(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError(f"must be a positive integer (got {value})")
    return number


def _non_negative_int(value: str) -> int:
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError(f"must be zero or greater (got {value})")
    return number


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="feedmine-verify",
        description="Verify RSS/Atom feed URLs in OPML files.  Checks reachability, "
        "content validity, and freshness.  Can remove dead feeds in-place.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  feedmine-verify                                    # default depth-3 scan
  feedmine-verify --depth 1 --output report.json     # quick reachability
  feedmine-verify --depth 3 --clean --output r.json  # deep check + clean
  feedmine-verify feeds/tech.opml --depth 2 --format minimal
  feedmine-verify --concurrency 200 --timeout 10
        """,
    )

    p.add_argument(
        "path", nargs="?", default="feedmine/Resources/Feeds",
        help="Directory (or single .opml file) to scan",
    )
    p.add_argument(
        "--depth", type=int, choices=(1, 2, 3), default=3,
        help="1=reachability  2=+content-validity  3=+freshness (default: 3)",
    )
    p.add_argument(
        "--concurrency", type=_positive_int, default=DEFAULT_CONCURRENCY,
        help=f"Max simultaneous requests (default: {DEFAULT_CONCURRENCY})",
    )
    p.add_argument(
        "--timeout", type=_positive_int, default=DEFAULT_TIMEOUT,
        help=f"Per-request timeout in seconds (default: {DEFAULT_TIMEOUT})",
    )
    p.add_argument(
        "--clean", action="store_true",
        help="Remove dead feeds from OPML files in-place",
    )
    p.add_argument(
        "--output", type=str, default=None, metavar="FILE.json",
        help="Write JSON report to FILE",
    )
    p.add_argument(
        "--format", type=str, choices=("full", "minimal", "summary"), default="full",
        help="Terminal output detail: full | minimal | summary (default: full)",
    )
    p.add_argument(
        "--user-agent", type=str, default=USER_AGENT,
        help="Custom User-Agent header",
    )
    p.add_argument(
        "--retries", type=_non_negative_int, default=DEFAULT_RETRIES,
        help=f"Retries per URL on failure (default: {DEFAULT_RETRIES})",
    )
    p.add_argument(
        "--no-recursive", action="store_true",
        help="Skip subdirectories (e.g. countries/)",
    )
    return p


def _checkresult_to_dict(r: CheckResult) -> dict:
    return {
        "url": r.url,
        "title": r.title,
        "source_files": r.source_files,
        "categories": r.categories,
        "status": r.status,
        "status_code": r.status_code,
        "response_time_ms": r.response_time_ms,
        "redirect_chain": r.redirect_chain,
        "final_url": r.final_url,
        "content_type": r.content_type,
        "body_size": r.body_size,
        "is_valid_feed": r.is_valid_feed,
        "newest_post_date": r.newest_post_date.isoformat() if r.newest_post_date else None,
        "days_since_last_post": r.days_since_last_post,
        "freshness_status": r.freshness_status,
        "error_message": r.error_message,
    }
