#!/usr/bin/env python3
"""验证工程再生成保留 Xcode 的签名、数组和共享容器设置，不依赖第三方 Python 包。"""
import json
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class ProjectGenerationTests(unittest.TestCase):
    def test_regeneration_preserves_signing_and_array_values(self):
        with tempfile.TemporaryDirectory(prefix="FreeReadingProject-") as temporary:
            root = Path(temporary)
            for folder in ["App", "ShareExtension", "Scripts"]:
                shutil.copytree(ROOT / folder, root / folder)
            project = root / "FreeReading.xcodeproj"
            project.mkdir()
            source = plistlib.loads(subprocess.check_output(["plutil", "-convert", "xml1", "-o", "-", str(ROOT / "FreeReading.xcodeproj/project.pbxproj")]))
            for item in source["objects"].values():
                if item.get("isa") == "XCBuildConfiguration":
                    settings = item["buildSettings"]
                    settings["FREEREADING_APP_GROUP"] = "group.example.fixture"
                    if "PRODUCT_BUNDLE_IDENTIFIER" in settings:
                        settings["DEVELOPMENT_TEAM"] = "TESTTEAM"
                        settings["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/Frameworks"]
            (project / "project.pbxproj").write_bytes(plistlib.dumps(source))
            command = ["python3", str(root / "Scripts/generate_project.py")]
            subprocess.run(command, check=True, capture_output=True)
            first = (project / "project.pbxproj").read_bytes()
            subprocess.run(command, check=True, capture_output=True)
            self.assertEqual(first, (project / "project.pbxproj").read_bytes())
            result = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(project / "project.pbxproj")]))
            targets = {i["name"]: i for i in result["objects"].values() if i.get("isa") == "PBXNativeTarget"}
            self.assertEqual(set(targets), {"FreeReading", "FreeReadingShare"})
            for item in result["objects"].values():
                if item.get("isa") == "XCBuildConfiguration":
                    settings = item["buildSettings"]
                    self.assertEqual(settings.get("FREEREADING_APP_GROUP"), "group.example.fixture")
                    if "PRODUCT_BUNDLE_IDENTIFIER" in settings:
                        self.assertEqual(settings["DEVELOPMENT_TEAM"], "TESTTEAM")
                        self.assertEqual(settings["LD_RUNPATH_SEARCH_PATHS"], ["$(inherited)", "@executable_path/Frameworks"])
if __name__ == "__main__":
    unittest.main()
