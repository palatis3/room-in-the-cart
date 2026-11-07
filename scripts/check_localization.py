#!/usr/bin/env python3
"""Check launch-language coverage and printf argument parity; not linguistic review.

US Spanish uses the `es` catalog localization, which serves es-US. Translations
remain a draft requiring human Spanish review before release. User-entered food
and package names are runtime values and must never become translation keys.
"""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
TABLES = {'tr': 'Localizable', 'message': 'Localizable',
          'entry': 'Localizable', 'unitPicker': 'Localizable', 'offerSection': 'Localizable',
          'ledgerText': 'Ledger', 'ledgerFormat': 'Ledger', 'mtr': 'Membership',
          'ht': 'Household', 'recordsText': 'Records', 'pTr': 'Pickup', 'pCook': 'Pickup',
          'captureText': 'Capture', 'dinnerText': 'Dinners', 'dinnerFormat': 'Dinners',
          'SurfaceCopy.text': 'DeviceSurfaces', 'HistoryCopy.text': 'History', 'fd': 'History', 'PlacementCopy.text': 'Placement',
          'helpText': 'Help', 'StoreQuoteCopy.text': 'StoreQuotes', 'GuardianCopy.text': 'Guardian',
          'DeviceManagementCopy.text': 'DeviceManagement', 'requestDuplicateText': 'RequestDuplicates',
          'sharedRecoveryText': 'Recovery', 'cookLabel': 'DeliveryCook'}
UI_CALLS = {'Text', 'Label', 'Button', 'Toggle', 'Section', 'Picker',
            'NavigationLink', 'ContentUnavailableView'}
STRING = re.compile(r'"(?:\\.|[^"\\])*"')
CALL = re.compile(r'\b(' + '|'.join(re.escape(name) for name in TABLES.keys() | UI_CALLS) + r')\s*\(')
FORMAT = re.compile(r'%(?:(\d+)\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?(hh|ll|h|l|q|z|t|j)?([@diuoxXfFeEgGaAcCsSp])')


def string_end(text, start):
    """Consume a Swift ordinary string, including nested interpolation strings."""
    i = start + 1
    while i < len(text):
        if text[i] == '\\':
            if text[i:i + 2] == '\\(':
                i = balanced_end(text, i + 2)
            else:
                i += 2
        elif text[i] == '"':
            return i + 1
        else:
            i += 1
    raise ValueError('Unterminated Swift string')


def balanced_end(text, start):
    depth = 1
    i = start
    while i < len(text):
        if text[i] == '"':
            i = string_end(text, i)
            continue
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
            if not depth:
                return i + 1
        i += 1
    raise ValueError('Unterminated Swift interpolation')


def first_argument(text, start):
    """Read the first argument without confusing nested strings with commas."""
    index, depth = start, 0
    while index < len(text):
        if text[index] == '"':
            index = string_end(text, index)
            continue
        char = text[index]
        if char in '([{':
            depth += 1
        elif char in ')]}':
            if depth == 0:
                return text[start:index].strip()
            depth -= 1
        elif char == ',' and depth == 0:
            return text[start:index].strip()
        index += 1
    raise ValueError('Unterminated localization call')


def string_tokens(expression):
    i = 0
    while i < len(expression):
        if expression[i] == '"':
            end = string_end(expression, i)
            yield expression[i:end]
            i = end
        else:
            i += 1


def literal(token):
    if '\\(' in token:
        raise ValueError('Interpolated explicit localization keys must use format placeholders')
    return json.loads(token)


def source_keys(root=ROOT):
    keys = {table: set() for table in set(TABLES.values())}
    dynamic = set()
    runtime_strings = 0
    for folder in ('ios/App', 'ios/Features', 'ios/Extensions'):
        for path in (root / folder).rglob('*.swift'):
            text = path.read_text()
            for call in CALL.finditer(text):
                if re.search(r"\bfunc\s*$", text[:call.start()]):
                    continue
                name = call.group(1)
                argument = first_argument(text, call.end())
                tokens = list(string_tokens(argument))
                direct = len(tokens) == 1 and tokens[0] == argument
                conditional = re.search(r'\?\s*(' + STRING.pattern + r')\s*:\s*(' + STRING.pattern + r')$', argument)
                if name in TABLES:
                    # Nested calls are checked by their own matcher, not assigned
                    # to the enclosing helper's table. Conditional literal keys work.
                    if direct:
                        keys[TABLES[name]].add(literal(argument))
                    elif conditional:
                        keys[TABLES[name]].update(literal(t) for t in conditional.groups())
                    elif name not in ('entry', 'unitPicker', 'offerSection'):
                        dynamic.add((str(path.relative_to(root)), name, argument))
                elif direct:
                    if '\\(' in argument:
                        # User values and already-localized fragments are runtime
                        # compositions. Nested localization calls are checked above.
                        runtime_strings += 1
                    else:
                        value = literal(argument)
                        if any(c.isalpha() for c in value):
                            keys['Localizable'].add(value)
    return keys, dynamic, runtime_strings


def signature(value):
    """Map printf argument positions to types, allowing deliberate reordering."""
    args = {}
    next_position = 1
    index = 0
    while index < len(value):
        if value[index] != '%':
            index += 1
            continue
        if value[index:index + 2] == '%%':
            index += 2
            continue
        token = FORMAT.match(value, index)
        if not token:
            raise ValueError(f'Unsupported or malformed printf placeholder in {value!r}')
        position = int(token.group(1)) if token.group(1) else next_position
        if not token.group(1):
            next_position += 1
        kind = (token.group(2) or '') + token.group(3)
        if position < 1 or (position in args and args[position] != kind):
            raise ValueError(f'Conflicting printf argument in {value!r}')
        args[position] = kind
        index = token.end()
    return args


def check_catalog(path):
    catalog = json.loads(path.read_text())
    assert catalog['sourceLanguage'] == 'en', f'{path}: source must be English'
    entries = catalog['strings']
    for key, entry in entries.items():
        localizations = entry.get('localizations', {})
        assert set(localizations) == {'en', 'es'}, f'{path.name}: English/Spanish parity failure: {key}'
        values = {}
        for language in ('en', 'es'):
            unit = localizations[language]['stringUnit']
            assert unit['state'] == 'translated' and unit['value'].strip(), f'{path.name}: incomplete {language}: {key}'
            values[language] = unit['value']
        # Symbolic catalog keys (InfoPlist keys and enum values) need not equal
        # English copy. Translation arguments must match the English value.
        assert set(re.findall(r'\$\{[^}]+\}', values['en'])) == set(re.findall(r'\$\{[^}]+\}', values['es'])), f'{path.name}: template variable mismatch: {key}'
        assert signature(values['en']) == signature(values['es']), f'{path.name}: placeholder mismatch: {key}'
        if '%' in key:
            assert signature(key) == signature(values['en']), f'{path.name}: source placeholder mismatch: {key}'
    return entries


def main():
    catalogs = {}
    errors = []
    for path in sorted((ROOT / 'ios').rglob('*.xcstrings')):
        if '.build' in path.relative_to(ROOT).parts:
            continue
        try:
            assert path.stem not in catalogs, f'Duplicate catalog table: {path.stem}'
            catalogs[path.stem] = check_catalog(path)
        except (AssertionError, ValueError, KeyError) as error:
            errors.append(str(error))
    keys, dynamic, runtime_strings = source_keys(ROOT)
    for table, required in sorted(keys.items()):
        for key in sorted(required - catalogs.get(table, {}).keys()):
            errors.append(f'{table}.xcstrings missing source key: {key!r}')
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        raise ValueError(f'{len(errors)} localization issue(s)')
    print(f'Localization checks passed: {len(catalogs)} catalogs, '
          f'{sum(len(x) for x in catalogs.values())} en/es entries, '
          f'{sum(len(x) for x in keys.values())} literal source keys, matching format arguments.')
    print(f'Static coverage excludes {len(dynamic)} dynamic helper expressions and '
          f'{runtime_strings} runtime SwiftUI compositions; these require runtime review.')
    if '--show-dynamic' in sys.argv:
        for path, name, argument in sorted(dynamic):
            print(f'{path}: {name}({argument})')
    print('US Spanish copy still requires human language review; this check verifies structure only.')


if __name__ == '__main__':
    try:
        main()
    except (AssertionError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f'Localization check failed: {error}', file=sys.stderr)
        raise SystemExit(1)
