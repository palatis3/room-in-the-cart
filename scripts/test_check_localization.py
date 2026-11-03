import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
spec=importlib.util.spec_from_file_location('checker',Path(__file__).with_name('check_localization.py'))
c=importlib.util.module_from_spec(spec); spec.loader.exec_module(c)

class LocalizationTests(unittest.TestCase):
    def test_nested_interpolation_first_argument(self):
        value=r'"\(pTr("Received")): \(count)", systemImage: "checkmark")'
        self.assertEqual(c.first_argument(value,0),r'"\(pTr("Received")): \(count)"')
    def test_nested_calls_and_commas(self):
        self.assertEqual(c.first_argument('a ? f("x,y") : g(1,2), other)',0),'a ? f("x,y") : g(1,2)')
    def test_unterminated_string_rejected(self):
        with self.assertRaises(ValueError):c.first_argument('"bad',0)
    def test_explicit_interpolated_key_rejected(self):
        with self.assertRaises(ValueError):c.literal(r'"Hello \(name)"')
    def test_placeholder_reordering(self):
        self.assertEqual(c.signature('%@ %lld'),c.signature('%2$lld %1$@'))
    def test_placeholder_type_mismatch(self):
        self.assertNotEqual(c.signature('%lld'),c.signature('%@'))
    def test_placeholder_conflict(self):
        with self.assertRaises(ValueError):c.signature('%1$@ %1$lld')
    def test_symbolic_catalog_keys(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'InfoPlist.xcstrings'
            path.write_text(json.dumps({'sourceLanguage':'en','strings':{'NSFaceIDUsageDescription':{'localizations':{lang:{'stringUnit':{'state':'translated','value':value}} for lang,value in [('en','Unlock your workspace'),('es','Desbloquea tu espacio')]}}}}))
            self.assertIn('NSFaceIDUsageDescription',c.check_catalog(path))
    def test_missing_translation_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'Ledger.xcstrings'
            path.write_text(json.dumps({'sourceLanguage':'en','strings':{'Need':{'localizations':{'en':{'stringUnit':{'state':'translated','value':'Need'}}}}}}))
            with self.assertRaises(AssertionError):c.check_catalog(path)
    def test_feature_tables_and_runtime_text(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); (root/'ios/Features').mkdir(parents=True)
            (root/'ios/Features/View.swift').write_text(r'''func ledgerText(_ key: String) -> String { key }
Text("\(pTr("Received")): \(count)")
Text(ledgerText("Add item"))
Button("Done") {}
ht((try? status(at: time)) == .ready ? "Ready" : "Waiting")
recordsText(record.title)
Text("\(food.originalText)")''')
            keys,dynamic,runtime=c.source_keys(root)
            self.assertEqual(keys['Pickup'],{'Received'})
            self.assertEqual(keys['Ledger'],{'Add item'})
            self.assertEqual(keys['Localizable'],{'Done'})
            self.assertEqual(keys['Household'],{'Ready','Waiting'})
            self.assertEqual(len(dynamic),1)
            self.assertEqual(runtime,2)

if __name__=='__main__':unittest.main()
