from __future__ import annotations

import os
import xml.etree.ElementTree as ET
from pathlib import Path

from .constants import PERMANENT_DEAD_STATUSES
from .models import CheckResult


def clean_dead_feeds(results: list[CheckResult], root_dir: Path) -> int:
    """Remove feeds whose final status is ``dead`` from their OPML files.

    Only feeds the server confirmed are *permanently* gone (404/410) are
    removed.  Unresolved DNS/TLS failures, rate limits and 5xx responses are
    transient, so those outlines are left in place for manual review.

    Only touches files that actually contain removable feeds.  Returns the
    number of files modified.
    """
    # Build: file → set of dead URLs
    dead_by_file: dict[str, set[str]] = {}
    for r in results:
        if r.status == "dead" and r.status_code in PERMANENT_DEAD_STATUSES:
            for sf in r.source_files:
                dead_by_file.setdefault(sf, set()).add(r.url)

    modified = 0
    for rel_path, dead_urls in sorted(dead_by_file.items()):
        abs_path = root_dir / rel_path
        if not abs_path.exists():
            continue
        try:
            if _strip_feeds(abs_path, dead_urls):
                modified += 1
        except (ET.ParseError, OSError):
            continue

    return modified


def _strip_feeds(path: Path, dead_urls: set[str]) -> bool:
    """Remove dead <outline> elements from an OPML file.  Returns True if
    the file was actually changed."""
    tree = ET.parse(str(path))
    root = tree.getroot()
    body = root.find("body")
    if body is None:
        return False

    changed = False

    def _prune(element: ET.Element) -> None:
        nonlocal changed
        to_remove: list[ET.Element] = []
        for child in element.findall("outline"):
            url = child.get("xmlUrl") or child.get("xmlurl") or ""
            url = url.strip()
            if url in dead_urls:
                to_remove.append(child)
                changed = True
            else:
                _prune(child)
        for child in to_remove:
            element.remove(child)

    _prune(body)

    if changed:
        _write_opml(tree, path)

    return changed


def _write_opml(tree: ET.ElementTree, path: Path) -> None:
    """Write *tree* back to *path* with decent formatting.

    Written through a sibling temporary file and ``os.replace`` so an
    interrupted run can never leave a half-written catalog file behind.
    """
    root = tree.getroot()

    # Indent for readability
    _indent(root, level=0)

    text = ET.tostring(root, encoding="unicode")

    # Add XML declaration if missing (ElementTree strips it during parse)
    if not text.startswith("<?xml"):
        text = '<?xml version="1.0" encoding="UTF-8"?>\n' + text

    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    os.replace(temporary, path)


def _indent(elem: ET.Element, level: int = 0) -> None:
    """Recursively add whitespace for pretty-printing."""
    indent = "\n" + "  " * level
    if len(elem):
        if not elem.text or not elem.text.strip():
            elem.text = indent + "  "
        if not elem.tail or not elem.tail.strip():
            elem.tail = indent
        for child in elem:
            _indent(child, level + 1)
        if not child.tail or not child.tail.strip():
            child.tail = indent
    else:
        if level and (not elem.tail or not elem.tail.strip()):
            elem.tail = indent
