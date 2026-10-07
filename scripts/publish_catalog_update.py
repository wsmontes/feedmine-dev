#!/usr/bin/env python3
"""Publish the bundled OPML tree as a versioned FeedMine update snapshot."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

try:
    from scripts.catalog_identity import canonical_url, compute_source_id, decode_url_entities
except ModuleNotFoundError:  # Direct ``python scripts/...`` execution.
    from catalog_identity import canonical_url, compute_source_id, decode_url_entities


SCHEMA_VERSION = 1


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _revision_of(path: Path) -> int | None:
    """Revision encoded in a ``<name>.staging-rN``/``<name>.backup-rN`` sibling."""
    suffix = path.name.rsplit("-r", 1)[-1]
    return int(suffix) if suffix.isdigit() else None


def sibling_revisions(destination: Path) -> list[int]:
    """Revisions of the staging/backup directories an interrupted run left."""
    revisions = []
    for pattern in (".staging-r*", ".backup-r*"):
        for path in destination.parent.glob(destination.name + pattern):
            revision = _revision_of(path)
            if revision is not None:
                revisions.append(revision)
    return sorted(revisions)


def manifest_revision(manifest_path: Path) -> int | None:
    if not manifest_path.exists():
        return None
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    revision = manifest.get("revision")
    return revision if isinstance(revision, int) and revision >= 1 else None


def last_known_revision(destination: Path) -> int | None:
    """Highest revision the destination tree proves, even when the destination
    is absent because a swap was interrupted after the first rename."""
    candidates = [
        revision
        for revision in (manifest_revision(destination / "manifest.json"),)
        if revision is not None
    ]
    candidates.extend(sibling_revisions(destination))
    return max(candidates) if candidates else None


def next_revision(destination: Path) -> int:
    last = last_known_revision(destination)
    return 1 if last is None else last + 1


def recover_destination(destination: Path) -> None:
    """Undo an interrupted swap.

    A crash between the two renames leaves the destination absent with its
    content under ``<destination>.backup-rN``. Restoring the newest backup is
    what the on-disk state says happened; deriving the revision from a missing
    destination would look for the wrong backup.
    """
    backups = sorted(
        (path for path in destination.parent.glob(destination.name + ".backup-r*") if path.is_dir()),
        key=lambda path: _revision_of(path) or 0,
    )
    if destination.exists():
        for path in backups:
            shutil.rmtree(path, ignore_errors=True)
        return
    if not backups:
        return
    backups[-1].rename(destination)
    for path in backups[:-1]:
        shutil.rmtree(path, ignore_errors=True)


def read_signing_key(value: str) -> str:
    """The signing key is either hex or a path to a file containing it."""
    candidate = Path(value)
    if candidate.is_file():
        return candidate.read_text(encoding="utf-8").strip()
    return value.strip()


def sign_manifest(manifest_path: Path, signing_key: str) -> None:
    """Sign the staged manifest before it is activated.

    ``scripts/sign_manifest.swift`` signs the canonical unsigned payload and
    self-checks the signature, so an unusable signature fails publishing
    instead of exposing an unsigned snapshot.
    """
    signer = Path(__file__).resolve().parent / "sign_manifest.swift"
    if not signer.exists():
        raise ValueError(f"manifest signer not found: {signer}")
    result = subprocess.run(
        ["swift", str(signer), "--sign", str(manifest_path), signing_key],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise ValueError(f"manifest signing failed: {detail}")
    signed = json.loads(result.stdout)
    signature = signed.get("signature")
    if not isinstance(signature, str) or len(signature) != 128:
        raise ValueError("signer returned no usable Ed25519 signature")
    write_json_atomic(manifest_path, signed)


def sync_opml_tree(source_root: Path, destination_root: Path, source_files: list[Path]) -> list[Path]:
    """Replace the complete Feeds tree with rollback on any failure."""
    destination_root.parent.mkdir(parents=True, exist_ok=True)
    stage_parent = Path(tempfile.mkdtemp(
        prefix=".feedmine-publish-stage-", dir=destination_root.parent
    ))
    staged_root = stage_parent / "Feeds"
    rollback_root = stage_parent / "previous-Feeds"
    try:
        for source_path in source_files:
            relative = source_path.relative_to(source_root)
            staged_path = staged_root / relative
            staged_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_path, staged_path)
        # Verify staged bytes before the old tree is moved.
        for source_path in source_files:
            relative = source_path.relative_to(source_root)
            if sha256(source_path) != sha256(staged_root / relative):
                raise IOError(f"staged copy hash mismatch: {relative}")

        had_previous = destination_root.exists()
        if had_previous:
            os.replace(destination_root, rollback_root)
        try:
            os.replace(staged_root, destination_root)
        except Exception:
            if had_previous and rollback_root.exists():
                os.replace(rollback_root, destination_root)
            raise
        if rollback_root.exists():
            shutil.rmtree(rollback_root)
    finally:
        shutil.rmtree(stage_parent, ignore_errors=True)
    return [destination_root / path.relative_to(source_root) for path in source_files]


def canonical_catalog_url(raw: str) -> str:
    return canonical_url(raw)


def validate_sources(paths: list[Path]) -> int:
    sources: set[str] = set()
    errors: list[str] = []
    for path in paths:
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as error:
            errors.append(f"{path}: invalid XML: {error}")
            continue
        for element in root.iter():
            url = element.attrib.get("xmlUrl")
            if url:
                identity = canonical_catalog_url(url)
                expected_source_id = compute_source_id(identity)
                actual_source_id = element.attrib.get("feedmineSourceId")
                if actual_source_id != expected_source_id:
                    errors.append(
                        f"{path}: {url!r}: feedmineSourceId does not match canonical identity"
                    )
                if decode_url_entities(url) != url:
                    errors.append(f"{path}: {url!r}: URL contains a residual XML entity")
                sources.add(identity)
    if errors:
        raise ValueError(
            f"catalog validation found {len(errors)} error(s):\n" + "\n".join(errors)
        )
    return len(sources)


def write_json_atomic(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def publish(args: argparse.Namespace) -> dict:
    source_root = args.source_root.resolve()
    destination = args.destination.resolve()
    catalog_metadata = json.loads(args.catalog_manifest.read_text(encoding="utf-8"))
    source_count = catalog_metadata.get("source_count")
    if not isinstance(source_count, int) or source_count < 1:
        raise ValueError("catalog manifest does not contain a positive source_count")

    source_files = sorted(path for path in source_root.rglob("*.opml") if path.is_file())
    if not source_files:
        raise ValueError(f"no OPML files found below {source_root}")
    expected_file_count = catalog_metadata.get("file_count")
    if expected_file_count != len(source_files):
        raise ValueError(
            f"catalog manifest file_count is {expected_file_count}; OPML tree has {len(source_files)}"
        )
    # Validate every source before writing a single destination file.
    actual_source_count = validate_sources(source_files)
    if actual_source_count != source_count:
        raise ValueError(
            f"catalog manifest source_count is {source_count}; OPML tree has {actual_source_count}"
        )
    revision = args.revision if args.revision is not None else next_revision(destination)
    if revision < 1:
        raise ValueError("revision must be positive")

    # P1-04: enforce strict monotonicity against the destination and against
    # any staging/backup directory left behind by an interrupted run.
    last_revision = last_known_revision(destination)
    if last_revision is not None and revision <= last_revision:
        raise ValueError(
            f"revision {revision} is not greater than the last known revision {last_revision}"
        )

    # P1-09: Stage the complete snapshot in a temporary directory and
    # atomically activate it. If any step fails, the destination is left
    # untouched — readers see either the old revision or the new one,
    # never a mixture of new Feeds/ with old manifest.json.
    staging = destination.with_name(destination.name + f".staging-r{revision}")
    if staging.exists():
        shutil.rmtree(staging)

    published_files = sync_opml_tree(source_root, staging / "Feeds", source_files)

    entries = []
    for path in published_files:
        relative = path.relative_to(staging).as_posix()
        entries.append({"bytes": path.stat().st_size, "path": relative, "sha256": sha256(path)})

    manifest = {
        "fileCount": len(entries),
        "files": entries,
        "generatedAt": args.generated_at
        or datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "revision": revision,
        "schemaVersion": SCHEMA_VERSION,
        "sourceCount": source_count,
        # P0-02: the Swift manifest decoder expects this field. It stays empty
        # only until the signing step below fills it; an unsigned snapshot is
        # reported (and can be refused with --require-signature).
        "signature": "",
    }
    write_json_atomic(staging / "manifest.json", manifest)

    # The snapshot is signed (and the signature self-checked) while it is still
    # staging: an unsigned or unsignable snapshot is never activated.
    signing_key = getattr(args, "signing_key", None)
    if signing_key:
        sign_manifest(staging / "manifest.json", read_signing_key(signing_key))
        manifest = json.loads((staging / "manifest.json").read_text(encoding="utf-8"))
    if not manifest.get("signature"):
        if getattr(args, "require_signature", False):
            raise ValueError("refusing to activate an unsigned manifest: pass --signing-key")
        print(
            "warning: activating an UNSIGNED snapshot (no --signing-key); "
            "pass --require-signature to make this fatal",
            file=sys.stderr,
        )

    # P1-09: Atomically activate the complete snapshot.
    # Strategy: move old destination aside → rename staging in → remove old.
    # A crash between the two renames leaves <destination>.backup-rN, which the
    # next run restores before publishing anything else.
    recover_destination(destination)
    backup = destination.with_name(destination.name + f".backup-r{revision}")
    if backup.exists():
        shutil.rmtree(backup)
    if destination.exists():
        destination.rename(backup)
    try:
        staging.rename(destination)
    except Exception:
        # Rollback: restore the backup on failure
        if backup.exists():
            backup.rename(destination)
        raise
    # Clean up backup on success
    if backup.exists():
        shutil.rmtree(backup)

    if args.bundle_manifest is not None:
        write_json_atomic(args.bundle_manifest.resolve(), manifest)
    return manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-root",
        type=Path,
        default=Path("feedmine/Resources/Feeds"),
        help="curated OPML root",
    )
    parser.add_argument(
        "--catalog-manifest",
        type=Path,
        default=Path("feedmine/Resources/FeedEngine/catalog-manifest.json"),
        help="compiled catalog metadata used to assert source count",
    )
    parser.add_argument("--destination", type=Path, required=True, help="feed-repository checkout")
    parser.add_argument("--revision", type=int, help="explicit monotonically increasing revision")
    parser.add_argument("--generated-at", help="fixed ISO-8601 timestamp (primarily for tests)")
    parser.add_argument(
        "--signing-key",
        help="Ed25519 private key (hex, or path to a file holding it) used to sign the "
        "manifest before the snapshot is activated",
    )
    parser.add_argument(
        "--require-signature",
        action="store_true",
        help="fail instead of activating a snapshot whose manifest carries no signature",
    )
    parser.add_argument(
        "--bundle-manifest",
        type=Path,
        default=Path("feedmine/Resources/FeedEngine/catalog-update-manifest.json"),
        help="manifest embedded as the app's bootstrap revision",
    )
    return parser.parse_args()


if __name__ == "__main__":
    result = publish(parse_args())
    print(
        f"published revision {result['revision']}: "
        f"{result['fileCount']} OPML files, {result['sourceCount']} unique sources"
    )
