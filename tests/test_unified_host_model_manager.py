"""Register models without losing V2 settings or misrepresenting reasoning support."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
SPEC=importlib.util.spec_from_file_location("hostmodels",ROOT/"deploy/configure-host-models.py")
mod=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)

CONFIG='''{
  // keep this outside the provider
  "mcp": {"servers": {"episteme": {"url": "http://localhost:28080/mcp"}}},
  "providers": {
    "other": {"models": {}},
    "host-local": {
      "name": "Host local models",
      "package": "aisdk:@ai-sdk/openai-compatible",
      "settings": {"baseURL": "http://host:8002/v1"},
      "models": {
        "existing": {
          "name": "My existing model",
          "settings": {"temperature": 0.1, "reasoningEffort": "xhigh"},
          "variants": [
            {"id":"xhigh","settings":{"reasoningEffort":"xhigh"}}
          ],
          "limit": {"context": 32768, "output": 4096}
        }
      }
    }
  }
}'''

class ModelManagerTests(unittest.TestCase):
    def test_merge_adds_without_replacing_existing_variants(self):
        updated, before=mod.merge_registry(CONFIG, ["existing","new"],"http://host:8002/v1")
        result=json.loads(mod.strip_trailing_commas(updated))
        models=result["providers"]["host-local"]["models"]
        self.assertEqual(before,"http://host:8002/v1")
        self.assertEqual(models["existing"]["variants"][0]["id"],"xhigh")
        self.assertEqual(models["existing"]["settings"]["temperature"],0.1)
        self.assertEqual(models["existing"]["limit"]["context"],32768)
        self.assertEqual(models["new"]["name"],"new")
        self.assertNotIn("variants",models["new"])
        self.assertIn("// keep this outside the provider",updated)
        self.assertIn('"mcp": {"servers":',updated)
        self.assertIn('"other": {"models": {}}',updated)
    def test_preserves_models_not_currently_advertised(self):
        updated,_=mod.merge_registry(CONFIG, ["new"],"http://host:8002/v1")
        models=json.loads(mod.strip_trailing_commas(updated))["providers"]["host-local"]["models"]
        self.assertIn("existing",models)
    def test_create_fresh_registry_and_backup_on_write(self):
        updated,old=mod.merge_registry('{}\n',["demo"],"http://host:8002/v1")
        self.assertIsNone(old)
        data=json.loads(mod.strip_trailing_commas(updated))
        self.assertEqual(data["providers"]["host-local"]["models"]["demo"],{"name":"demo"})
        with tempfile.TemporaryDirectory() as d:
            file=Path(d)/"opencode.jsonc"
            self.assertTrue(mod.save_config(file,"",updated))
            self.assertFalse(mod.save_config(file,updated,updated))
            self.assertTrue(mod.save_config(file,updated,updated+"\n"))
            self.assertEqual(file.with_name(file.name+".before-host-models").read_text(),updated)
    def test_invalid_negative_control_rejected(self):
        with self.assertRaises(RuntimeError):
            mod.probe("url","demo","",3,64,request=lambda *a: ("accepted","HTTP 200"))
    def test_xhigh_without_high(self):
        def requester(url,model,effort,key,timeout,tokens):
            if effort in ("xhigh","low","medium","none"):
                return "accepted","HTTP 200"
            return "rejected","HTTP 400 reasoning_effort"
        accepted,_=mod.probe("url","demo","",3,64,request=requester)
        self.assertIn("xhigh",accepted)
        self.assertNotIn("high",accepted)

if __name__=="__main__":
    unittest.main()
