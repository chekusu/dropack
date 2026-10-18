# Dropack language resources

The app and website use the same 16 languages. iOS names Chinese locales `zh-Hans` and `zh-Hant`; the website uses `zh-CN` and `zh-TW`.

Use `L10n.tr("保存")` for app text and `L10n.tr("已保存 %@ 项", String(count))` for dynamic values. Arguments stay verbatim so filenames and user album names are never translated. Source keys stay stable. Every key must exist in all 16 JSON files; the English catalog is the runtime fallback.

Service stages, enum raw values, filenames and checkpoint messages retain their canonical values. The display boundary calls `L10n.tr(message)`. Known dynamic checkpoint templates are translated without rewriting stored history or changing task comparisons. Explicit arguments containing a stage or app error must themselves use `L10n.tr(stage)`; user content must not.

`AppPreferences` publishes the selected language. Views observe it and use the locale/layout direction environment, retaining view identity and running tasks. Live Activities carry an optional language code; older activity payloads remain decodable. The activity bridge updates its language when preferences change.

After adding or editing translations:

```sh
python3 scripts/localization_audit.py --write
python3 scripts/generate_project.py
```

The audit checks all source keys, locale coverage, nonempty values, parameter counts and copied-English placeholders. It produces `PhotoRelay/Core/Resources/Translations.json` for both executables and all 16 `InfoPlist.strings` permission descriptions. The build generator includes these resources and declares English as the development language.

Automatic validation does not replace native-language editorial review. Device UI testing should include German text lengths, Japanese, Arabic direction, large text, and changing languages during an existing album task.
