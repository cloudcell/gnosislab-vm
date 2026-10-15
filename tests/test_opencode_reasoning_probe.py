"""Model-specific OpenCode V2 reasoning-effort validation (no network)."""
import importlib.util
import json
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("effort_probe",ROOT/"deploy/probe-opencode-reasoning.py")
mod=importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

CONFIG='''{
  // Preserve unrelated human configuration
  "providers": {"host-local": {
    "settings": {"baseURL": "http://192.168.122.1:8002/v1"},
    "models": {"qwen38": {"name":"Custom",
      "settings": {"reasoningEffort":"high", "temperature":0.2},
      "variants":[{"id":"high","settings":{"reasoningEffort":"high"}},
                  {"id":"creative","settings":{"temperature":0.8}}]
    }}
  }},
  "instructions":["unchanged"],
  "mcp":{"servers":{"episteme":{"url":"http://localhost:28080/mcp"}}}
}'''
class ReasoningTests(unittest.TestCase):
    def test_xhigh_only_without_high_and_preserve_settings(self):
        def request(url, model, effort, key, timeout, max_tokens):
            return ("accepted", "HTTP 200") if effort in ("none","low","medium","xhigh") else ("rejected","HTTP 400 reasoning_effort")
        supported, _=mod.probe("url","qwen38","",5,64,request=request)
        self.assertEqual(supported,["none","low","medium","xhigh"])
        revised=mod.updated_model(CONFIG,"host-local","qwen38",supported,"xhigh")
        parsed=json.loads(mod.strip_trailing_commas(revised))
        model=parsed["providers"]["host-local"]["models"]["qwen38"]
        self.assertEqual(model["settings"]["reasoningEffort"],"xhigh")
        self.assertEqual([v["id"] for v in model["variants"]],["creative","none","low","medium","xhigh"])
        self.assertIn("// Preserve unrelated human configuration",revised)
        self.assertIn('"instructions":["unchanged"]',revised)
        self.assertEqual(parsed["mcp"]["servers"]["episteme"]["url"],"http://localhost:28080/mcp")
    def test_invalid_negative_control_blocks_config(self):
        with self.assertRaises(RuntimeError):
            mod.probe("url","qwen38","",5,64,request=lambda *args: ("accepted","HTTP 200"))
    def test_uncertain_effort_blocks_config(self):
        def request(url, model, effort, key, timeout, max_tokens):
            if effort == mod.INVALID: return "rejected","HTTP 400"
            return ("uncertain","timeout") if effort=="high" else ("accepted","HTTP 200")
        with self.assertRaises(RuntimeError):
            mod.probe("url","qwen38","",5,64,request=request)
    def test_comment_inside_model_blocks_rewrite(self):
        with self.assertRaises(ValueError):
            mod.updated_model(CONFIG.replace('"name":"Custom",','"name":"Custom", /* keep */'),"host-local","qwen38",["xhigh"],"xhigh")
    def test_unverified_default_cannot_be_assigned(self):
        with self.assertRaises(ValueError):
            mod.updated_model(CONFIG,"host-local","qwen38",["low","xhigh"],"high")

if __name__=="__main__":
    unittest.main()
