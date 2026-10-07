#!/usr/bin/env python3
"""
Second-pass decontamination using parquet data for better decisions.

Fixes from v1:
  - GLOBAL_BRANDS now uses word-boundary matching
  - Language checks run BEFORE world_news shortcut
  - Uses parquet feed_description/status/http_status as primary signal
  - Sequential per-country writes (no race condition)
  - Content-about-country detection via parquet description

Usage:
  python3 scripts/decontaminate_v2.py [--apply]
"""

import json
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

# ── Paths ──────────────────────────────────────────────────────────────

FEEDS_DIR = Path(__file__).resolve().parent.parent / "feedmine" / "Resources" / "Feeds" / "90_countries"
# Corpus artifacts are written at the repository root by the fetch pipeline;
# the path must not depend on a personal checkout.
PARQUET_PATH = Path(__file__).resolve().parent.parent / "feeds_corpus_sources.parquet"
CASES_PATH = Path(__file__).resolve().parent / "decontamination_cases.json"

# ── Country language profiles ──────────────────────────────────────────

COUNTRY_LANGS = {
    'algeria': {'ar','fr'}, 'angola': {'pt'}, 'argentina': {'es'},
    'armenia': {'hy'}, 'australia': {'en'}, 'austria': {'de'},
    'azerbaijan': {'az','ru'}, 'bangladesh': {'bn','en'}, 'belarus': {'be','ru'},
    'belgium': {'nl','fr','de'}, 'bolivia': {'es'}, 'brazil': {'pt'},
    'bulgaria': {'bg'}, 'cambodia': {'km'}, 'canada': {'en','fr'},
    'chile': {'es'}, 'china': {'zh'}, 'colombia': {'es'},
    'costa_rica': {'es'}, 'croatia': {'hr'}, 'cuba': {'es'},
    'cyprus': {'el','tr'}, 'czech_republic': {'cs'}, 'denmark': {'da'},
    'dominican_republic': {'es'}, 'ecuador': {'es'}, 'egypt': {'ar'},
    'el_salvador': {'es'}, 'estonia': {'et'}, 'ethiopia': {'am'},
    'finland': {'fi','sv'}, 'france': {'fr'}, 'georgia': {'ka'},
    'germany': {'de'}, 'ghana': {'en'}, 'greece': {'el'},
    'guatemala': {'es'}, 'haiti': {'fr','ht'}, 'honduras': {'es'},
    'hungary': {'hu'}, 'iceland': {'is'}, 'india': {'hi','en'},
    'indonesia': {'id'}, 'iran': {'fa'}, 'iraq': {'ar','ku'},
    'ireland': {'en','ga'}, 'israel': {'he','ar'}, 'italy': {'it'},
    'ivory_coast': {'fr'}, 'jamaica': {'en'}, 'japan': {'ja'},
    'kazakhstan': {'kk','ru'}, 'kenya': {'en','sw'}, 'latvia': {'lv'},
    'lithuania': {'lt'}, 'luxembourg': {'fr','de','lb'}, 'malaysia': {'ms','en','zh'},
    'malta': {'mt','en'}, 'mexico': {'es'}, 'morocco': {'ar','fr'},
    'myanmar': {'my'}, 'nepal': {'ne'}, 'netherlands': {'nl'},
    'new_zealand': {'en','mi'}, 'nicaragua': {'es'}, 'nigeria': {'en'},
    'norway': {'no'}, 'pakistan': {'ur','en'}, 'panama': {'es'},
    'paraguay': {'es','gn'}, 'peru': {'es'}, 'philippines': {'tl','en'},
    'poland': {'pl'}, 'portugal': {'pt'}, 'puerto_rico': {'es','en'},
    'qatar': {'ar'}, 'romania': {'ro'}, 'russia': {'ru'},
    'saudi_arabia': {'ar'}, 'serbia': {'sr'}, 'singapore': {'en','zh','ms','ta'},
    'slovakia': {'sk'}, 'slovenia': {'sl'}, 'south_africa': {'en','af','zu','xh'},
    'south_korea': {'ko'}, 'spain': {'es'}, 'sri_lanka': {'si','ta','en'},
    'sudan': {'ar','en'}, 'sweden': {'sv'}, 'switzerland': {'de','fr','it','rm'},
    'taiwan': {'zh'}, 'thailand': {'th'}, 'tunisia': {'ar','fr'},
    'turkey': {'tr'}, 'uae': {'ar','en'}, 'ukraine': {'uk','ru'},
    'united_kingdom': {'en'}, 'uruguay': {'es'}, 'usa': {'en'},
    'venezuela': {'es'}, 'vietnam': {'vi'},
}

# ── Global brands (word-boundary matching) ─────────────────────────────

GLOBAL_BRANDS = [
    # News (word boundary — won't match "science" or "who")
    r'\bbbc\b', r'\bcnn\b', r'\breuters\b', r'\bbloomberg\b',
    r'\bthe guardian\b', r'\bthe economist\b', r'\bnew york times\b',
    r'\bwashington post\b', r'\bnpr\b', r'\bal jazeera\b',
    r'\bfrance 24\b', r'\bdeutsche welle\b', r'\bdw news\b',
    r'\bassociated press\b', r'\bfinancial times\b', r'\bforbes\b',
    # Entertainment / Tech
    r'\bnetflix\b', r'\bspotify\b', r'\bapple podcasts?\b',
    r'\bgoogle\b', r'\bmicrosoft\b',
    # Science / Nature
    r'\bnational geographic\b', r'\bnasa\b', r'\bspacex\b',
    r'\bdiscovery\b',  # Discovery Channel
    # Education
    r'\bted talks?\b', r'\btedx\b',
    # International orgs
    r'\bunited nations\b', r'\bworld health organization\b',
    r'\bunicef\b', r'\bworld bank\b',
]

# Compile brand patterns
BRAND_PATTERNS = [re.compile(p, re.IGNORECASE) for p in GLOBAL_BRANDS]

# ── Language → valid countries mapping ─────────────────────────────────

LANG_COUNTRIES = {
    "pt": {"brazil", "portugal", "angola"},
    "pt-br": {"brazil"},
    "pt-pt": {"portugal"},
    "es": {"spain", "argentina", "mexico", "colombia", "chile", "peru", "venezuela",
           "ecuador", "guatemala", "cuba", "dominican_republic", "honduras",
           "paraguay", "el_salvador", "nicaragua", "costa_rica", "uruguay",
           "panama", "bolivia", "puerto_rico"},
    "es-mx": {"mexico"}, "es-ar": {"argentina"}, "es-es": {"spain"},
    "de": {"germany", "austria", "switzerland", "luxembourg"},
    "de-de": {"germany"}, "de-at": {"austria"}, "de-ch": {"switzerland"},
    "fr": {"france", "belgium", "switzerland", "canada", "ivory_coast", "haiti"},
    "fr-fr": {"france"}, "fr-ca": {"canada"},
    "it": {"italy", "switzerland"}, "it-it": {"italy"},
    "ja": {"japan"}, "ja-jp": {"japan"},
    "ko": {"south_korea"}, "ko-kr": {"south_korea"},
    "zh": {"china", "taiwan", "singapore", "malaysia"},
    "zh-tw": {"taiwan"}, "zh-cn": {"china"},
    "ru": {"russia", "belarus", "kazakhstan"},
    "ru-ru": {"russia"},
    "ar": {"saudi_arabia", "egypt", "uae", "algeria", "morocco", "tunisia",
           "iraq", "qatar", "sudan", "israel"},
    "nl": {"netherlands", "belgium"},
    "nl-nl": {"netherlands"}, "nl-be": {"belgium"},
    "sv": {"sweden"}, "sv-se": {"sweden"},
    "no": {"norway"}, "nb": {"norway"}, "nb-no": {"norway"},
    "da": {"denmark"}, "da-dk": {"denmark"},
    "fi": {"finland"}, "pl": {"poland"},
    "cs": {"czech_republic"}, "hu": {"hungary"},
    "ro": {"romania"}, "bg": {"bulgaria"},
    "el": {"greece", "cyprus"}, "tr": {"turkey", "cyprus"},
    "uk": {"ukraine"}, "vi": {"vietnam"},
    "th": {"thailand"}, "id": {"indonesia"}, "in": {"indonesia"},  # "in" = deprecated Indonesian code
    "ms": {"malaysia"}, "tl": {"philippines"},
    "hi": {"india"}, "ur": {"pakistan"}, "bn": {"bangladesh"},
    "he": {"israel"}, "fa": {"iran"},
    "kk": {"kazakhstan"}, "et": {"estonia"},
    "lv": {"latvia"}, "lt": {"lithuania"},
    "sr": {"serbia"}, "hr": {"croatia"},
    "sk": {"slovakia"}, "sl": {"slovenia"},
    "hy": {"armenia"}, "ka": {"georgia"}, "az": {"azerbaijan"},
    "am": {"ethiopia"}, "km": {"cambodia"}, "my": {"myanmar"},
    "ne": {"nepal"}, "is": {"iceland"}, "mt": {"malta"},
    "si": {"sri_lanka"}, "sw": {"kenya", "tanzania"},
    "af": {"south_africa"}, "zu": {"south_africa"}, "xh": {"south_africa"},
    "ht": {"haiti"}, "mi": {"new_zealand"}, "ga": {"ireland"},
    "lb": {"luxembourg"}, "gn": {"paraguay"},
    "qu": {"peru", "bolivia"}, "rm": {"switzerland"},
}


def is_global_brand(text):
    """Check if text matches a global brand (word boundaries)."""
    for pat in BRAND_PATTERNS:
        if pat.search(text):
            return True, pat.pattern
    return False, ""


def is_content_about_country(parquet_desc, country, title):
    """Check if parquet feed_description suggests content is ABOUT the assigned country."""
    combined = f"{parquet_desc} {title}".lower()
    country_variants = [
        country.replace("_", " "),
        country.replace("_", "-"),
    ]
    # Also check capital cities and common country references
    country_indicators = {
        "armenia": ["armenia", "armenian", "yerevan"],
        "azerbaijan": ["azerbaijan", "baku", "azeri"],
        "paraguay": ["paraguay", "asunción", "asuncion"],
        "slovenia": ["slovenia", "slovenian", "ljubljana"],
        "qatar": ["qatar", "qatari", "doha"],
        "cambodia": ["cambodia", "cambodian", "phnom penh"],
        "china": ["china", "chinese", "beijing", "shanghai"],
        "brazil": ["brazil", "brazilian", "brasil", "brasília", "são paulo", "rio de janeiro"],
        "georgia": ["tbilisi", "sakartvelo", "kutaisi", "batumi"],
        "singapore": ["singapore", "singaporean"],
        "malta": ["malta", "maltese", "valletta"],
        "sri_lanka": ["sri lanka", "sri lankan", "colombo"],
    }

    indicators = country_indicators.get(country, country_variants)
    for indicator in indicators:
        if indicator in combined:
            return True

    return False


def load_parquet_index():
    """Load parquet data indexed by source_id."""
    try:
        import pyarrow.parquet as pq
    except ImportError:
        print("WARNING: pyarrow not available, proceeding without parquet data")
        return {}

    if not PARQUET_PATH.exists():
        print(f"WARNING: parquet not found at {PARQUET_PATH}")
        return {}

    sources = pq.read_table(str(PARQUET_PATH))
    index = {}
    for i in range(len(sources)):
        sid = sources['source_id'][i].as_py()
        if sid:
            index[sid] = {
                'status': sources['status'][i].as_py(),
                'http_status': sources['http_status'][i].as_py(),
                'feed_description': (sources['feed_description'][i].as_py() or '').strip(),
                'feed_title': (sources['feed_title'][i].as_py() or '').strip(),
                'content_type': (sources['content_type'][i].as_py() or '').strip(),
                'articles_fetched': sources['articles_fetched'][i].as_py(),
                'latest_item_at': str(sources['latest_item_at'][i].as_py()) if sources['latest_item_at'][i].as_py() else '',
            }
    print(f"Loaded {len(index)} parquet sources")
    return index


def analyze_case_v2(case, parquet_data):
    """
    Decide REMOVE or KEEP using OPML metadata + parquet feed_description.

    Key improvements over v1:
    - Word-boundary brand matching (no more "science"/"who"/"mit " false positives)
    - Language checks before world_news shortcut
    - Parquet description as primary signal for content-about-country detection
    """
    title = case.get("title", "")
    desc = case.get("description", "")
    category = case.get("category", "")
    feed_lang = (case.get("feed_lang", "") or "").strip().lower()
    country = case.get("country", "")
    tld_country = case.get("tld_country", "")
    topic = case.get("topic", "")
    subcategory = case.get("subcategory", "")
    source_id = case.get("sourceId", "")

    pq = parquet_data.get(source_id, {})
    pq_desc = pq.get("feed_description", "")
    pq_status = pq.get("status", "")
    pq_http = pq.get("http_status", "")

    combined_opml = f"{title} {desc} {category}".lower()
    combined_pq = f"{pq_desc} {title}".lower()

    # ── Step 1: Content is ABOUT the country? Keep it ──
    if is_content_about_country(pq_desc, country, title):
        return "KEEP", "content_about_country"

    # Also check OPML description
    if is_content_about_country(desc, country, title):
        return "KEEP", "content_about_country_opml"

    # ── Step 2: Global brand? (word boundary matching) ──
    is_brand, brand_pattern = is_global_brand(combined_pq)
    if not is_brand:
        is_brand, brand_pattern = is_global_brand(combined_opml)
    if is_brand:
        return "KEEP", f"global_brand:{brand_pattern}"

    # ── Step 3: Language mismatch? ──
    lang_base = feed_lang.split("-")[0] if feed_lang else ""
    country_langs = COUNTRY_LANGS.get(country, set())
    country_lang_bases = {l.split("-")[0].lower() for l in country_langs}
    valid_countries = LANG_COUNTRIES.get(feed_lang, LANG_COUNTRIES.get(lang_base, []))

    lang_mismatch = bool(feed_lang and lang_base and lang_base not in country_lang_bases)

    if not lang_mismatch:
        return "KEEP", "language_matches"

    # ── Step 4: Language clearly belongs to another country ──
    if valid_countries and country not in valid_countries:
        if tld_country and tld_country in valid_countries:
            return "REMOVE", f"lang:{feed_lang}_for_{tld_country}"

    # ── Step 5: TLD confirms different country ──
    if tld_country and tld_country != country:
        # Non-English feed + foreign TLD = strong signal
        if lang_base not in ("en",):
            return "REMOVE", f"non_en_lang:{feed_lang}_tld:{tld_country}"

    # ── Step 6: Parquet signals ──
    # Dead feed in wrong country?
    if pq_status == "failed" and lang_mismatch:
        if tld_country:
            return "REMOVE", f"dead_feed_wrong_country"

    # ── Step 7: English content — check if it's national vs global ──
    if lang_base == "en":
        # English feed in non-English country: check if it's clearly national content
        # from another country (not global)
        national_signals = {
            "united_kingdom": ["uk politics", "british politics", "the times", "daily mail",
                              "house of commons", "downing street", "hugo rifkind"],
            "india": ["indian express", "times of india", "india today", "indian politics"],
            "ireland": ["irish politics", "irish culture", "irish history"],
            "canada": ["canadian politics", "cbc news", "canada's"],
            "australia": ["australian politics", "abc australia", "australia's"],
            "usa": ["connecticut", "us politics", "american politics", "capitol hill",
                   "us state", "u.s. politics"],
        }
        if tld_country and tld_country in national_signals:
            for signal in national_signals[tld_country]:
                if signal in combined_pq or signal in combined_opml:
                    return "REMOVE", f"national_content:{tld_country}"

    # ── Step 8: Default — insufficient evidence, keep ──
    return "KEEP", "insufficient_evidence"


def process_all():
    """Process all 525 cases using parquet data, grouped by country to avoid races."""
    with open(CASES_PATH) as f:
        cases = json.load(f)

    parquet_data = load_parquet_index()

    # Group cases by country for sequential per-country processing
    by_country = defaultdict(list)
    for c in cases:
        by_country[c["country"]].append(c)

    results = {"removed": [], "kept": [], "errors": []}

    # Process country by country (no race condition)
    for country, country_cases in sorted(by_country.items()):
        opml_path = FEEDS_DIR / country / f"{country}.opml"
        if not opml_path.exists():
            for c in country_cases:
                results["errors"].append({**c, "error": f"OPML not found"})
            continue

        tree = ET.parse(opml_path)
        root = tree.getroot()
        modified = False

        for case in country_cases:
            decision, reason = analyze_case_v2(case, parquet_data)

            if decision == "REMOVE":
                source_id = case["sourceId"]
                removed = find_and_remove_feed(root, source_id)
                if removed:
                    results["removed"].append({**case, "reason": reason})
                    modified = True
                else:
                    # Already removed by v1 pass — skip
                    results["kept"].append({**case, "reason": "already_removed_v1"})
            else:
                results["kept"].append({**case, "reason": reason})

        if modified:
            ET.indent(root, space="  ")
            tree.write(opml_path, encoding="utf-8", xml_declaration=True)
            print(f"  Written: {country}")

    return results


def find_and_remove_feed(root, source_id):
    body = root.find("body")
    if body is None:
        return False

    def walk(parent):
        for child in list(parent):
            if child.tag == "outline" and child.get("type") == "rss":
                if child.get("feedmineSourceId") == source_id:
                    parent.remove(child)
                    return True
            else:
                if walk(child):
                    return True
        return False

    return walk(body)


def main():
    apply_flag = "--apply" in sys.argv

    print("=" * 60)
    print("Decontamination v2 — Parquet-enhanced, sequential per country")
    print("=" * 60)

    if not apply_flag:
        # Dry-run: analyze without modifying
        with open(CASES_PATH) as f:
            cases = json.load(f)
        parquet_data = load_parquet_index()

        would_remove = []
        would_keep = []
        for c in cases:
            decision, reason = analyze_case_v2(c, parquet_data)
            if decision == "REMOVE":
                would_remove.append((c, reason))
            else:
                would_keep.append((c, reason))

        print(f"\nWould REMOVE: {len(would_remove)}")
        print(f"Would KEEP:   {len(would_keep)}")

        print("\n── Would REMOVE ──")
        for c, reason in sorted(would_remove, key=lambda x: x[0]['country'])[:30]:
            print(f"  [{c['country']:20s}] {c['title'][:65]}  — {reason}")
        if len(would_remove) > 30:
            print(f"  ... and {len(would_remove) - 30} more")

        print("\n── v1 removed but v2 would KEEP (restore candidates) ──")
        # Check cases that v1 removed but v2 says keep
        # We need to check the actual OPML state
        for c, reason in would_keep:
            country = c['country']
            opml_path = FEEDS_DIR / country / f"{country}.opml"
            if opml_path.exists():
                tree = ET.parse(opml_path)
                root = tree.getroot()
                body = root.find('body')
                found = False

                def walk_check(elem):
                    nonlocal found
                    for child in elem:
                        if child.tag == "outline" and child.get("type") == "rss":
                            if child.get("feedmineSourceId") == c["sourceId"]:
                                found = True
                        else:
                            walk_check(child)

                if body:
                    walk_check(body)
                if not found:
                    print(f"  RESTORE: [{c['country']}] {c['title'][:65]} — {reason}")

        print(f"\nRun with --apply to execute.")
    else:
        results = process_all()
        print(f"\nDone: {len(results['removed'])} removed, {len(results['kept'])} kept")
        with open("scripts/decontamination_v2_results.json", "w") as f:
            json.dump(results, f, indent=2, ensure_ascii=False)


if __name__ == "__main__":
    main()
