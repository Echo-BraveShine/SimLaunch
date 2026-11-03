#!/usr/bin/env python3
"""Check both translation tables, format arguments and literal localization keys."""
import collections
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
STRING = r'"((?:\\.|[^"\\])*)"'
errors = []
tables = {}
for language in ('en', 'zh-Hans'):
    path = ROOT / 'Sources/SimLaunchCore/Resources' / (language + '.lproj/Localizable.strings')
    pairs = re.findall(STRING + r'\s*=\s*' + STRING + r'\s*;', path.read_text())
    keys = [json.loads('"' + key + '"') for key, _ in pairs]
    for key, count in collections.Counter(keys).items():
        if count > 1:
            errors.append(f'{language}: duplicate key {key!r}')
    tables[language] = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
for language, other in (('en', 'zh-Hans'), ('zh-Hans', 'en')):
    for key in tables[language].keys() - tables[other].keys():
        errors.append(f'{other}: missing key {key!r}')

def placeholders(value):
    # Compare argument positions as well as conversion types; allow positional reordering.
    result, index = [], 0
    pattern = r'%(?:(\d+)\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?(?:hh|ll|[hljztL])?([@diuoxXfFeEgGaAcCsSp%])'
    for match in re.finditer(pattern, value):
        if match[2] == '%':
            continue
        index += 1
        result.append((int(match[1] or index), match[2]))
    return sorted(result)

for key in tables['en'].keys() & tables['zh-Hans'].keys():
    if placeholders(tables['en'][key]) != placeholders(tables['zh-Hans'][key]):
        errors.append(f'Format arguments differ: {key!r}')

count = 0
for path in (ROOT / 'Sources').rglob('*.swift'):
    source = path.read_text()
    for match in re.finditer(r'(?:L10n\.(?:text|format)|addNote)\(\s*' + STRING, source):
        # A prefix concatenated with a runtime value is not a complete key.
        if source[match.end():].lstrip().startswith('+') or '\\(' in match[1]:
            continue
        key = json.loads('"' + match[1] + '"')
        count += 1
        if key not in tables['en']:
            errors.append(f'{path.relative_to(ROOT)}: missing literal key {key!r}')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print(f'Localization passed: {len(tables["en"])} keys per language, {count} literal references; keys, duplicates and format arguments checked.')
