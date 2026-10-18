"""Regression checks for source coverage inside Swift string interpolation."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from localization_sources import strings


class LocalizationSourceTests(unittest.TestCase):
    def test_accessibility_ternaries_inside_interpolation_are_discovered(self):
        source = r'.accessibilityValue("\(asset.isCompleted ? "已打包" : "待打包")，\(image == nil ? "预览未加载" : "预览已加载")")'
        found = {key for _, _, key, _ in strings(source)}
        self.assertTrue({'已打包', '待打包', '预览未加载', '预览已加载'}.issubset(found))
        self.assertIn('%@，%@', found)

    def test_localized_call_in_interpolation_keeps_its_key_and_source_offset(self):
        source = r'Text("\(L10n.tr("相册"))")'
        entries = list(strings(source))
        entry = next(entry for entry in entries if entry[2] == '相册')
        self.assertEqual(source[entry[0]:entry[1]], '"相册"')
        self.assertIn('%@', {entry[2] for entry in entries})

    def test_comments_are_ignored_and_literal_escapes_preserved(self):
        source = '// "不应提取"\n' + r'Text("第一行\n第二行") /* "也不应提取" */'
        self.assertEqual([entry[2] for entry in strings(source)], [r'第一行\n第二行'])


if __name__ == '__main__':
    unittest.main()
