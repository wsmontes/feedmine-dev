#!/usr/bin/env python3
"""
Convert string_template.json + per-language translation files → Localizable.xcstrings.

Usage:
  python3 scripts/translate.py [--lang pt-BR,es,...]

``--lang`` defaults to ``all``: every language with a translation file is
emitted.  Keys and localizations already present in the current catalog are
preserved, so regenerating never drops hand-added strings or locales.

Reads:
  - feedmine/Resources/string_template.json  (master list of all strings)
  - feedmine/Resources/translations/{lang}.json  (per-language translations)
  - feedmine/Resources/Localizable.xcstrings  (current catalog, for preservation)

Produces:
  - feedmine/Resources/Localizable.xcstrings

To add a new language, just create feedmine/Resources/translations/{code}.json
with the format: {"string_key": "translated_value", ...}
"""
import json, sys, os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE_PATH = ROOT / "feedmine" / "Resources" / "string_template.json"
TRANSLATIONS_DIR = ROOT / "feedmine" / "Resources" / "translations"
OUTPUT_PATH = ROOT / "feedmine" / "Resources" / "Localizable.xcstrings"

# All language codes we support
ALL_LANGS = [
    "ar", "ca", "zh-Hans", "zh-Hant", "hr", "cs", "da", "nl",
    "en-AU", "en-GB", "en-IN", "fi", "fr", "fr-CA", "de", "el",
    "he", "hi", "hu", "id", "it", "ja", "ko", "ms", "nb", "pl",
    "pt-BR", "pt-PT", "ro", "ru", "sk", "es", "es-419", "sv",
    "th", "tr", "uk", "vi",
]


def load_template() -> dict:
    with open(TEMPLATE_PATH) as f:
        return json.load(f)


def load_existing_catalog() -> dict:
    """Return the ``strings`` map of the catalog currently on disk."""
    if not OUTPUT_PATH.exists():
        return {}
    try:
        with open(OUTPUT_PATH) as f:
            return json.load(f).get("strings", {})
    except (OSError, ValueError):
        return {}


def catalog_units(strings: dict) -> set[tuple[str, str]]:
    """Every (key, language) pair present in a catalog ``strings`` map."""
    return {
        (key, lang)
        for key, entry in strings.items()
        for lang in entry.get("localizations", {})
    }


def load_translations(lang: str) -> dict:
    """Load a translation file, return {key: value} dict."""
    path = TRANSLATIONS_DIR / f"{lang}.json"
    if not path.exists():
        return {}
    with open(path) as f:
        data = json.load(f)
    # Support both flat {key: value} and nested {"strings": {key: value}} formats
    if "strings" in data:
        return data["strings"]
    return data


def build_xcstrings(template: dict, langs: list[str], existing: dict | None = None) -> dict:
    """Build the full .xcstrings structure from template + translation files.

    ``existing`` is the catalog currently on disk.  Keys it holds that the
    template no longer lists are carried over verbatim, and localizations
    without a translation file are kept, so regeneration never shrinks the
    shipped catalog.
    """
    existing = existing or {}
    xcstrings = {
        "sourceLanguage": "en",
        "strings": {},
        "version": "1.0"
    }

    translations = {}
    for lang in langs:
        t = load_translations(lang)
        if t:
            translations[lang] = t
            print(f"  Loaded {lang}: {len(t)} translations")

    strings = template.get("strings", {})
    for key, info in strings.items():
        entry = {
            "localizations": {
                "en": {
                    "stringUnit": {
                        "state": "translated",
                        "value": key
                    }
                }
            }
        }

        # Add comment if present
        if info.get("comment"):
            entry["comment"] = info["comment"]

        # Add translations for each language
        for lang, trans in translations.items():
            if key in trans:
                entry["localizations"][lang] = {
                    "stringUnit": {
                        "state": "translated",
                        "value": trans[key]
                    }
                }

        # Localizations present in the catalog but not covered by a
        # translation file must not disappear.
        for lang, localization in existing.get(key, {}).get("localizations", {}).items():
            entry["localizations"].setdefault(lang, localization)

        xcstrings["strings"][key] = entry

    # Keys that exist only in the current catalog are preserved unchanged.
    for key, entry in existing.items():
        if key not in strings:
            xcstrings["strings"][key] = entry

    return xcstrings


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Generate Localizable.xcstrings")
    parser.add_argument("--lang", type=str, default="all",
                        help="Comma-separated language codes to include (default: all)")
    args = parser.parse_args()

    target_langs = [l.strip() for l in args.lang.split(",")]

    # If "all", include every language that has a translation file
    if args.lang == "all":
        target_langs = []
        for f in sorted(TRANSLATIONS_DIR.glob("*.json")):
            code = f.stem
            target_langs.append(code)

    print(f"Reading template: {TEMPLATE_PATH}")
    template = load_template()
    print(f"  {len(template['strings'])} strings in template")

    existing = load_existing_catalog()
    if existing:
        print(f"  Current catalog: {len(existing)} strings (preserved)")

    print(f"Loading translations for: {', '.join(target_langs)}")
    xcstrings = build_xcstrings(template, target_langs, existing)

    # Never overwrite the shipped catalog with a narrower one.
    lost_keys = set(existing) - set(xcstrings["strings"])
    lost_units = catalog_units(existing) - catalog_units(xcstrings["strings"])
    if lost_keys or lost_units:
        raise SystemExit(
            f"refusing to write {OUTPUT_PATH}: would drop {len(lost_keys)} key(s) "
            f"and {len(lost_units)} key/language pair(s)"
        )

    # Count coverage
    total = len(xcstrings["strings"])
    for lang in target_langs:
        count = sum(1 for e in xcstrings["strings"].values()
                    if "localizations" in e and lang in e["localizations"])
        pct = count * 100 // total if total else 0
        print(f"  {lang}: {count}/{total} ({pct}%)")

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT_PATH, 'w') as f:
        json.dump(xcstrings, f, indent=2, ensure_ascii=False)

    print(f"\nWrote {OUTPUT_PATH}")
    print(f"Total strings in catalog: {total}")


if __name__ == "__main__":
    main()
