#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 MacHorus contributors
"""Fails when a localization key used in the Swift sources is missing in a
Localizable.strings file, or when the language files disagree."""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LANGUAGES = ["en", "de"]
PREFIXES = (
    "menu.", "panel.", "settings.", "permission.", "about.", "statusItem.",
    "overview.", "features.", "privacy.", "category.", "monitor.",
)
DYNAMIC_PREFIXES = ("feature.",)

STRINGS_ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"(?:[^"\\]|\\.)*";\s*$', re.MULTILINE)
SWIFT_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
INTERPOLATION = re.compile(r"\\\((?:[^()]|\([^()]*\))*\)")


def strings_keys(language):
    path = ROOT / "Resources" / f"{language}.lproj" / "Localizable.strings"
    return set(STRINGS_ENTRY.findall(path.read_text(encoding="utf-8")))


def code_keys():
    keys = set()
    # UI strings live in the app target; Core holds no user-visible text.
    for path in (ROOT / "Sources" / "MacHorus").rglob("*.swift"):
        for literal in SWIFT_LITERAL.findall(path.read_text(encoding="utf-8")):
            if not literal.startswith(PREFIXES):
                continue
            # SwiftUI turns each interpolation into a %@ placeholder in the key.
            key = INTERPOLATION.sub("%@", literal)
            if "\\(" not in key:
                keys.add(key)
    return keys


FEATURE_ID = re.compile(r'FeatureDescriptor\(\s*id:\s*"([^"]+)"')


def feature_ids():
    ids = set()
    for path in (ROOT / "Sources").rglob("*.swift"):
        ids.update(FEATURE_ID.findall(path.read_text(encoding="utf-8")))
    return ids


def main():
    errors = []
    per_language = {language: strings_keys(language) for language in LANGUAGES}
    reference = per_language[LANGUAGES[0]]
    for language, keys in per_language.items():
        for key in sorted(reference - keys):
            errors.append(f"{language}: missing key {key!r} (present in {LANGUAGES[0]})")
        for key in sorted(keys - reference):
            errors.append(f"{language}: extra key {key!r} (not in {LANGUAGES[0]})")
    # String(localized:) with an interpolated key looks up a format key such as
    # "feature.%@.title" and silently shows the raw key; use
    # Bundle.main.localizedString(forKey:) for keys built at runtime.
    for path in (ROOT / "Sources").rglob("*.swift"):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if "LocalizationValue(\"" in line and "\\(" in line:
                errors.append(f"{path.relative_to(ROOT)}:{number}: interpolated localization key")
    # Feature identifiers look like keys but are not shown as text.
    used = code_keys() - feature_ids()
    for key in sorted(used - reference):
        errors.append(f"code uses key {key!r} that no strings file defines")
    # Keys built at runtime (e.g. feature.<id>.title) cannot be found in code.
    for key in sorted(reference - used):
        if key.startswith(PREFIXES) and not key.startswith(DYNAMIC_PREFIXES):
            errors.append(f"unused key {key!r}")
    # Every registered feature needs a title and a summary in every language.
    for feature in sorted(feature_ids()):
        for suffix in ("title", "summary"):
            key = f"feature.{feature}.{suffix}"
            for language, keys in per_language.items():
                if key not in keys:
                    errors.append(f"{language}: missing {key!r} for registered feature {feature!r}")
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print(f"localization ok: {len(reference)} keys in {', '.join(LANGUAGES)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
