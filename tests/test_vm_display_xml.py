"""Host-only regression checks for local VM defaults (no KVM required)."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("vm_display_xml", ROOT / "scripts/vm_display_xml.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

EXAMPLE = """<domain><devices><interface><model type='virtio'/></interface>
<video><model type='virtio' heads='1' primary='yes'/></video></devices></domain>"""


class DisplayXmlTests(unittest.TestCase):
    def test_virtio_self_closing_model(self):
        xml = mod.set_resolution(EXAMPLE, 2560, 1440)
        self.assertIn("<resolution x='2560' y='1440'/>", xml)
        self.assertIn("<interface><model type='virtio'/></interface>", xml)

    def test_update_existing_resolution(self):
        xml = mod.set_resolution(
            "<domain><devices><video><model type='qxl'><resolution x='1024' y='768'/>"
            "</model></video></devices></domain>", 2560, 1440,
        )
        self.assertEqual(xml.count("<resolution"), 1)
        self.assertNotIn("x='1024'", xml)
        self.assertIn("x='2560' y='1440'", xml)

    def test_reject_missing_video(self):
        with self.assertRaises(ValueError):
            mod.set_resolution("<domain><devices/></domain>", 2560, 1440)

    def test_reject_invalid_geometry(self):
        with self.assertRaises(ValueError):
            mod.set_resolution(EXAMPLE, 0, 1440)

    def test_idempotent(self):
        first = mod.set_resolution(EXAMPLE, 2560, 1440)
        self.assertEqual(mod.set_resolution(first, 2560, 1440), first)


if __name__ == "__main__":
    unittest.main()
