"""Tests for host model discovery and explicit OpenCode provider generation."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("host_models", ROOT / "deploy/configure-host-models.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class HostModelsTests(unittest.TestCase):
    def test_discovery_preserves_actual_served_ids(self):
        ids = module.model_ids({"data": [{"id": "Qwen3.8-Flash-Next"}, {"id": "local/Qwen3.6"},
                                        {"id": "Qwen3.8-Flash-Next"}]})
        self.assertEqual(ids, ["Qwen3.8-Flash-Next", "local/Qwen3.6"])

    def test_no_discoverable_models_fails(self):
        with self.assertRaises(ValueError):
            module.model_ids({"data": []})

    def test_config_preserves_full_context(self):
        result = module.build_provider(["served-id"], "http://192.168.122.1:8002/v1",
                                       262144, 8192)
        provider = result["provider"]["host-local"]
        self.assertEqual(provider["models"]["served-id"]["limit"]["context"], 262144)
        self.assertEqual(provider["options"]["baseURL"], "http://192.168.122.1:8002/v1")

    def test_unconfigured_context_is_not_guessed(self):
        result = module.build_provider(["model-x"], "http://192.168.122.1:8002/v1", 0, 8192)
        self.assertNotIn("limit", result["provider"]["host-local"]["models"]["model-x"])


if __name__ == "__main__":
    unittest.main()
