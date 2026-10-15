"""OpenCode V2 user-managed installation and config regression tests."""
import json
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
BUILD=(ROOT/"create-lab-template").read_text()
ENSURE=(ROOT/"30-ensure-lab-tools.sh").read_text()
MAIN=json.loads((ROOT/"deploy/opencode.json").read_text())
LOCAL=json.loads((ROOT/"deploy/opencode.jsonc").read_text())
class V2Tests(unittest.TestCase):
    def test_v2_schema(self):
        self.assertIn("mcp",MAIN)
        self.assertIn("servers",MAIN["mcp"])
        self.assertFalse(MAIN["autoupdate"])
        self.assertIn("providers",LOCAL)
        provider=LOCAL["providers"]["host-local"]
        self.assertEqual(provider["package"],"aisdk:@ai-sdk/openai-compatible")
        self.assertIn("baseURL",provider["settings"])
    def test_native_user_updater_and_tui_command(self):
        self.assertIn('/home/lab/.opencode/bin/opencode',BUILD)
        self.assertIn('/home/lab/.opencode/bin/opencode',ENSURE)
        self.assertIn('opencode-update-command.md',BUILD)
        self.assertIn('opencode-update-command.md',ENSURE)
        cmd=(ROOT/"deploy/opencode-update-command.md").read_text()
        self.assertIn('explicit confirmation',cmd)
        self.assertIn('opencode upgrade',cmd)
        self.assertNotIn('sudo opencode upgrade',cmd)
    def test_non_destructive_migration(self):
        self.assertIn('opencode-v2-migrate.py',ENSURE)
        migrate=(ROOT/"deploy/opencode-v2-migrate.py").read_text()
        self.assertIn('.v1-backup',migrate)
        self.assertIn('providers',migrate)
    def test_no_root_npm_upgrade(self):
        self.assertNotIn('npm install -g', (ROOT/"deploy/labloop-update-opencode").read_text())
if __name__=="__main__":
    unittest.main()
