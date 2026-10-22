#!/usr/bin/env python3
# Tesserae: a disk-space visualizer.
# Copyright (C) 2026 Stephen de la Vega
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

"""Enforce the production UI catalog boundary without third-party parsers."""
import json
from pathlib import Path
import re
import tempfile

ROOT = Path(__file__).resolve().parents[2]
# Exact exceptions only; symbols and shortcut arguments are not title arguments.
ALLOWLIST = {"%@": "Format-only string; contains no words to translate."}
CALL = re.compile(r'\b(?:Text|TextField|SecureField|navigationTitle|Button|Label|Toggle|Picker|Menu|Window|ProgressView|CommandMenu|alert|confirmationDialog|help|accessibilityLabel|accessibilityValue|LocalizedStringKey)\s*\(\s*(?:(?:title|verbatim):\s*)?(#*"|""")|\bNSMenuItem\s*\(\s*title:\s*(#*"|""")')


def production(source):
    # Debug-only menu labels are developer diagnostics, not shipped UI.
    out, branches = [], []
    for line in source.splitlines(keepends=True):
        directive = line.strip()
        if directive.startswith('#if '):
            branches.append((directive == '#if DEBUG', directive == '#if DEBUG'))
        elif (directive == '#else' or directive.startswith('#elseif ')) and branches:
            is_debug, skipped = branches[-1]
            if is_debug:
                branches[-1] = (is_debug, False)
        elif directive == '#endif' and branches:
            branches.pop()
            out.append('\n')
            continue
        out.append('\n' if any(skipped for _, skipped in branches) else line)
    # Preserve quoted URLs and comment-looking text inside literals.
    pattern = r'(?P<string>\"\"\"[\s\S]*?\"\"\"|\"(?:\\.|[^\"\\])*\")|(?P<comment>/\*.*?\*/|//[^\n]*)'
    return re.sub(pattern, lambda m: m[0] if m.group('string') else
                  '\n' * m[0].count('\n'), ''.join(out), flags=re.S)


def check(root=ROOT):
    errors, catalogs = [], {}
    for bundle in ('Tesserae', 'TesseraeKit'):
        path = root / 'apple' / bundle / 'Localizable.xcstrings'
        if not path.exists():
            errors.append(f'{path}: missing catalog')
            catalogs[bundle] = {}
            continue
        data = json.loads(path.read_text())
        assert data['sourceLanguage'] == 'en'
        entries = data['strings']
        assert entries, 'Catalog must inspect production strings'
        catalogs[bundle] = entries
        for key, entry in entries.items():
            if not re.fullmatch(r'[a-zA-Z][a-zA-Z0-9]*(?:\.[a-zA-Z0-9]+)+', key):
                errors.append(f'{path}: unstable key {key}')
            if not entry.get('comment', '').strip():
                errors.append(f'{path}: {key} lacks translator comment')
            if set(entry.get('localizations', {})) != {'en'}:
                errors.append(f'{path}: {key} must ship English only')
            english = entry.get('localizations', {}).get('en', {})
            value = english.get('stringUnit', {}).get('value', '')
            if 'substitutions' in english and re.search(r'%(?:ll|l|h)?[@diuf]', value):
                errors.append(f'{path}: {key} must number every argument when using plural substitutions')
    files = [*(root / "apple/Tesserae").glob("*.swift"),
             *(root / "apple/TesseraeKit").rglob("*.swift")]
    files = [p for p in files if not p.stem.endswith("Tests") and "Tests" not in p.parts]
    assert files, 'Must inspect production sources'
    for path in files:
        source = production(path.read_text())
        bundle = 'TesseraeKit' if 'TesseraeKit' in path.parts else 'Tesserae'
        for match in CALL.finditer(source):
            literal = source[match.end():].split('"', 1)[0]
            is_catalog_key = match[0].startswith('LocalizedStringKey') and literal in catalogs[bundle]
            if literal not in ALLOWLIST and not is_catalog_key:
                errors.append(f'{path.relative_to(root)}:{source[:match.start()].count(chr(10))+1}: literal UI text {literal}')
        for match in re.finditer(r'String\s*\(\s*localized:\s*"([^"]+)"', source):
            key = match[1]
            bundle = 'TesseraeKit' if 'TesseraeKit' in path.parts else 'Tesserae'
            if key not in catalogs[bundle]:
                errors.append(f'{path.relative_to(root)}: missing catalog key {key}')
            # Walk the call while skipping quoted values, including defaultValue.
            token = re.compile(r'"(?:\\.|[^"\\])*"|[()]')
            depth, end = 1, match.end()
            for item in token.finditer(source, match.end()):
                if item[0] == '(':
                    depth += 1
                elif item[0] == ')':
                    depth -= 1
                if depth == 0:
                    end = item.end()
                    break
            arguments = source[match.end():end]
            if not re.search(r'comment:\s*"[^"\s]', arguments):
                errors.append(f'{path.relative_to(root)}: {key} lacks call-site translator comment')
            if bundle == 'TesseraeKit' and not re.search(r'bundle:\s*L10n.bundle', arguments):
                errors.append(f'{path.relative_to(root)}: {key} must use the framework bundle')
    return errors


def test_scanner():
    """Mutation probes: exercise every required entry point and both catalogs."""
    with tempfile.TemporaryDirectory(prefix="tesserae-strings-") as directory:
        root = Path(directory)
        for bundle in ('Tesserae', 'TesseraeKit'):
            folder = root / 'apple' / bundle
            folder.mkdir(parents=True)
            (folder / 'Localizable.xcstrings').write_text(json.dumps({
                'sourceLanguage': 'en', 'strings': {'test.title': {
                    'comment': 'Fixture title.', 'localizations': {'en': {
                        'stringUnit': {'state': 'translated', 'value': 'Title'}}}}}}))
            bundle_argument = ', bundle: L10n.bundle' if bundle == 'TesseraeKit' else ''
            (folder / 'Fixture.swift').write_text('Text(String(localized: "test.title", defaultValue: "Title"' +
                                                 bundle_argument + ', comment: "Fixture"))')
        assert not check(root), 'Valid fixture must pass before mutation'
        app = root / 'apple/Tesserae/Fixture.swift'
        for call in ('Text', 'Button', 'Label', 'Toggle', 'Picker', 'Menu', 'alert',
                     'TextField', 'SecureField', '.navigationTitle', 'confirmationDialog',
                     '.help', '.accessibilityLabel', '.accessibilityValue'):
            app.write_text(call + '("Uncatalogued")')
            assert check(root), f'Missed direct literal in {call}'
        for source in ('Text(verbatim: "Uncatalogued")',
                       '#if DEBUG\nText("Debug")\n#elseif RELEASE\nText("Release")\n#endif',
                       '#if DEBUG\nText("Debug")\n#elseif RELEASE\n// no UI\n#else\nText("Fallback")\n#endif',
                       'NSMenuItem(title: "Uncatalogued")', 'Text(#"Uncatalogued"#)',
                       'Text(\n"Uncatalogued")', 'LocalizedStringKey("unknown.key")',
                       '#if DEBUG\nText("Debug")\n#else\nText("Release")\n#endif'):
            app.write_text(source)
            assert check(root), f'Missed mutation: {source}'
        app.write_text('LocalizedStringKey("test.title")\n// Text("Comment")\n#if DEBUG\nText("Debug")\n#endif')
        assert not check(root), 'Catalog keys, comments and Debug-only code must pass'
        app.write_text('Text(String(localized: "missing.key", comment: "Missing"))')
        assert check(root), 'Missing catalog keys must fail'
        app.write_text('Text(String(localized: "test.title"))')
        assert check(root), 'Missing call-site comments must fail'
        app.write_text('Text(String(localized: "test.title", comment: "Title"))')
        for bundle in ('Tesserae', 'TesseraeKit'):
            catalog = root / 'apple' / bundle / 'Localizable.xcstrings'
            original = catalog.read_text()
            data = json.loads(original)
            del data['strings']['test.title']['comment']
            catalog.write_text(json.dumps(data))
            assert check(root), f'Missing translator comment in {bundle} must fail'
            catalog.write_text(original)
        catalog = root / 'apple/Tesserae/Localizable.xcstrings'
        original = catalog.read_text()
        data = json.loads(original)
        english = data['strings']['test.title']['localizations']['en']
        english['stringUnit']['value'] = '%#@count@ (%@)'
        english['substitutions'] = {'count': {'argNum': 1, 'formatSpecifier': 'lld'}}
        catalog.write_text(json.dumps(data))
        assert check(root), 'Mixed positional plural formats must fail'
        catalog.write_text(original)
        framework = root / 'apple/TesseraeKit/Fixture.swift'
        original = framework.read_text()
        framework.write_text(original.replace(', bundle: L10n.bundle', ''))
        assert check(root), 'Framework lookups must not fall back to the main bundle'
        framework.write_text(original)
        assert not check(root), 'Restoring mutations must restore a passing fixture'


if __name__ == '__main__':
    test_scanner()
    problems = check()
    print('\n'.join(problems) if problems else 'Production UI strings and English catalog comments passed')
    raise SystemExit(bool(problems))
