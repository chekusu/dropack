#!/usr/bin/env python3
"""Validate all 16 translations and materialize app/widget and iOS permission resources.

Translation source files are keyed by stable Chinese source strings. Dynamic
arguments are %@ in source order; no printf interpretation is used at runtime.
"""
import argparse
import json
import re
from localization_sources import strings
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CODES = ['en', 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'es', 'fr', 'de', 'it', 'pt-BR', 'nl', 'pl', 'tr', 'ar', 'hi', 'id']
PERMISSIONS = {
    'NSPhotoLibraryAddUsageDescription': '将照片包中的照片、实况照片和视频逐项保存到系统相册。',
    'NSPhotoLibraryUsageDescription': '选择你想发送的照片和视频，读取原始资源并在本机打成照片包。仅处理你选择的内容。',
}

def quoted(value):
    return json.dumps(value, ensure_ascii=False)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    english = json.loads((ROOT / 'localization/en.json').read_text())
    catalogs = {}
    issues = []
    for directory in ['PhotoRelay', 'Shared', 'DropackLiveActivity']:
        for source in (ROOT / directory).rglob('*.swift'):
            if source.name == 'L10n.swift':
                continue  # Language names are intentionally written natively.
            for _, _, key, _ in strings(source.read_text()):
                if re.search('[\u4e00-\u9fff]', key) and key not in english:
                    issues.append(f'{source.relative_to(ROOT)}: unregistered source key: {key}')
    for code in CODES:
        path = ROOT / 'localization' / f'{code}.json'
        if not path.exists():
            issues.append(f'{code}: missing catalog')
            continue
        values = json.loads(path.read_text())
        missing, extra = set(english) - set(values), set(values) - set(english)
        if missing: issues.append(f'{code}: {len(missing)} missing keys: {sorted(missing)}')
        if extra: issues.append(f'{code}: {len(extra)} unknown keys: {sorted(extra)}')
        for key, value in values.items():
            if not isinstance(value, str) or not value.strip():
                issues.append(f'{code}: empty value: {key}')
                continue
            if key.count('%@') != value.count('%@'):
                issues.append(f'{code}: placeholder mismatch: {key}')
        if code not in ['en', 'zh-Hans']:
            identical = [k for k,v in values.items() if english.get(k) == v]
            # Product names and OK may reasonably be shared. A copied English
            # catalog may never silently satisfy the locale count.
            if len(identical) > max(12, len(english) // 10):
                issues.append(f'{code}: {len(identical)} English copies need review')
        catalogs[code] = {k.replace('\\n', '\n'):v for k,v in values.items()}
    if issues:
        raise SystemExit('\n'.join(issues))
    if args.write:
        resource = ROOT / 'PhotoRelay/Core/Resources/Translations.json'
        resource.parent.mkdir(parents=True, exist_ok=True)
        resource.write_text(json.dumps(catalogs, ensure_ascii=False, indent=2, sort_keys=True) + '\n')
        for code, values in catalogs.items():
            directory = ROOT / 'PhotoRelay/Resources' / f'{code}.lproj'
            directory.mkdir(parents=True, exist_ok=True)
            entries = {'CFBundleDisplayName':'Dropack', 'Dropack Package': 'Dropack · ' + values['照片包'], 'ZIP Package': 'ZIP · ' + values['照片包'], **{key:values[source] for key,source in PERMISSIONS.items()}}
            (directory / 'InfoPlist.strings').write_text('\n'.join(f'{quoted(key)} = {quoted(value)};' for key,value in entries.items()) + '\n')
    print(f'{len(CODES)} languages × {len(english)} keys validated; placeholders and English-copy checks passed.')

if __name__ == '__main__': main()
