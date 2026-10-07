#!/usr/bin/env python3
"""Build name→channel_id cache from Kaggle Youtube-Channels-Dataset.

Scrapes youtube.com/channel/UC... page titles to extract channel names.
Uses concurrent requests for speed (~1 hour for 37K channels).
Output: name_cache.json → {normalized_name: channel_id}
"""

import argparse
import hashlib
import io
import json
import pickle
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import requests

DATA_DIR = Path(__file__).resolve().parent.parent / "scripts/feed_discovery/data"
# Point this at a commit-pinned raw URL (``/<commit-sha>/data/id_2_url.pkl``)
# so the download source cannot move under the pinned digest.
PICKLE_URL = "https://raw.githubusercontent.com/chen-zhitao/Youtube-Channels-Dataset/master/data/id_2_url.pkl"
OUTPUT_PATH = DATA_DIR / "youtube_channels_kaggle_cache.json"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
}

def normalize(name: str) -> str:
    """Normalize a channel name for matching."""
    return re.sub(r'\s+', '', name.lower().strip())


class _SafeUnpickler(pickle.Unpickler):
    """Unpickler that refuses to resolve any global or persistent id.

    The dataset is a plain ``{channel_id: url}`` mapping, so loading it needs
    no classes or callables.  Rejecting ``find_class`` removes the arbitrary
    code execution that ``pickle.loads`` would otherwise grant to whoever
    controls the remote file.
    """

    def find_class(self, module, name):
        raise pickle.UnpicklingError(f"refusing to load global {module}.{name}")

    def persistent_load(self, pid):
        raise pickle.UnpicklingError("refusing persistent_id payload")


def load_id_to_url(pickle_path: Path, expected_sha256: str | None = None) -> dict:
    """Load the id→url mapping, validating the pinned digest first."""
    raw = pickle_path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    if expected_sha256 and digest.lower() != expected_sha256.lower():
        raise SystemExit(
            f"refusing to deserialise {pickle_path.name}: sha256 {digest} does not "
            f"match the pinned {expected_sha256}"
        )
    print(f"   {pickle_path.name} sha256={digest}", file=sys.stderr)
    try:
        data = _SafeUnpickler(io.BytesIO(raw)).load()
    except pickle.UnpicklingError as exc:
        raise SystemExit(f"refusing to deserialise {pickle_path.name}: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit(
            f"unexpected {pickle_path.name} payload: {type(data).__name__} (expected a dict)"
        )
    return data


def download_pickle(path: Path, url: str, expected_sha256: str) -> None:
    """Download *url* to *path*, keeping it only if the digest matches."""
    print(f"Downloading {url}...", file=sys.stderr)
    temporary = path.with_suffix(path.suffix + ".part")
    digest = hashlib.sha256()
    with requests.get(url, timeout=30, stream=True) as resp:
        resp.raise_for_status()
        with open(temporary, "wb") as handle:
            for chunk in resp.iter_content(chunk_size=65536):
                if not chunk:
                    continue
                handle.write(chunk)
                digest.update(chunk)
    if digest.hexdigest().lower() != expected_sha256.lower():
        temporary.unlink(missing_ok=True)
        raise SystemExit(
            f"refusing to keep {url}: sha256 {digest.hexdigest()} does not match the "
            f"pinned {expected_sha256}"
        )
    temporary.replace(path)


def fetch_name(channel_id: str) -> tuple[str, str] | None:
    """Scrape youtube.com/channel/UC... for the channel name from <title> tag.
    Returns (normalized_name, channel_id) or None on failure.
    """
    url = f"https://www.youtube.com/channel/{channel_id}"
    try:
        with requests.get(url, timeout=10, headers=HEADERS, stream=True) as resp:
            resp.raise_for_status()
            # Read only first 8KB — title is in the first few hundred bytes
            chunk = next(resp.iter_content(chunk_size=8192), b"").decode("utf-8", errors="ignore")
        match = re.search(r'<title>([^<]*)</title>', chunk)
        if match:
            title = match.group(1)
            # Strip " - YouTube" suffix
            name = re.sub(r'\s*-\s*YouTube\s*$', '', title).strip()
            if name and name != "YouTube":
                return (normalize(name), channel_id)
    except Exception:
        pass
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pickle-url", default=PICKLE_URL)
    parser.add_argument(
        "--pickle-sha256", default=None,
        help="sha256 of the reviewed id_2_url.pkl; required to download it.",
    )
    args = parser.parse_args(argv)

    # Download pickle if needed — only against a pinned digest.
    pickle_path = DATA_DIR / "id_2_url.pkl"
    if not pickle_path.exists():
        if not args.pickle_sha256:
            print(
                "ERROR: id_2_url.pkl is missing. Re-run with --pickle-sha256 <digest> "
                "of the reviewed artifact so the download can be verified.",
                file=sys.stderr,
            )
            return 1
        download_pickle(pickle_path, args.pickle_url, args.pickle_sha256)

    id_to_url = load_id_to_url(pickle_path, args.pickle_sha256)
    channel_ids = list(id_to_url.keys())
    print(f"Channel IDs loaded: {len(channel_ids)}", file=sys.stderr)

    # Load existing cache
    cache: dict[str, str] = {}
    if OUTPUT_PATH.exists():
        cache = json.loads(OUTPUT_PATH.read_text(encoding="utf-8"))
        print(f"Existing cache: {len(cache)} entries", file=sys.stderr)

    # The cache is keyed by channel *name*; resume must ask whether the channel
    # id itself was already resolved, not whether it appears as a key.
    resolved_ids = set(cache.values())
    pending = [cid for cid in channel_ids if cid not in resolved_ids]
    print(f"Pending: {len(pending)}", file=sys.stderr)

    if not pending:
        print("All channels already cached!", file=sys.stderr)
        return 0

    # Concurrent fetch
    workers = 8  # Be polite — 8 concurrent connections
    completed = 0
    batch = []
    start = time.time()

    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(fetch_name, cid): cid for cid in pending}

        for future in as_completed(futures):
            result = future.result()
            if result:
                name_key, cid = result
                cache[name_key] = cid
                batch.append(result)

            completed += 1
            if completed % 500 == 0:
                elapsed = time.time() - start
                rate = completed / elapsed if elapsed > 0 else 0
                pct = completed / len(pending) * 100
                print(f"  [{completed}/{len(pending)}] {pct:.0f}% — "
                      f"{len(batch)} new names, {rate:.0f}/s", file=sys.stderr)
                # Save incrementally
                OUTPUT_PATH.write_text(
                    json.dumps(cache, indent=2, ensure_ascii=False),
                    encoding="utf-8",
                )
                batch = []

    # Final save
    OUTPUT_PATH.write_text(
        json.dumps(cache, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    print(f"\n✓ Cache saved: {len(cache)} name→ID mappings → {OUTPUT_PATH}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
