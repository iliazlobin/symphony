"""The packaged editor is reproducible and independent of runtime npm or a CDN."""
import hashlib
import json
import fnmatch
import shutil
import subprocess
import tempfile
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "elixir/assets"
BUNDLE = ROOT / "elixir/priv/static/design-editor"


class DesignAssetTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("node") and (SOURCE / "node_modules/esbuild").is_dir(),
                         "Node and installed locked editor dependencies are required")
    def test_generated_build_is_independent_of_dependency_symlink_location(self):
        manifest = json.loads((BUNDLE / "manifest.json").read_text())
        with tempfile.TemporaryDirectory(prefix="symphony-editor-repro-") as directory:
            isolated = Path(directory) / "elixir/assets"
            for name in manifest["sources"]:
                target = isolated / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(SOURCE / name, target)
            (isolated / "node_modules").symlink_to((SOURCE / "node_modules").resolve(), target_is_directory=True)
            shutil.copytree(BUNDLE, Path(directory) / "elixir/priv/static/design-editor")
            result = subprocess.run([shutil.which("node"), "build.mjs", "--check"], cwd=isolated,
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Verified", result.stdout)

    def test_generated_manifest_covers_current_sources_and_every_embedded_asset(self):
        manifest = json.loads((BUNDLE / "manifest.json").read_text())
        self.assertEqual(manifest["version"], 1)
        for name, expected in manifest["sources"].items():
            self.assertNotIn("..", Path(name).parts)
            self.assertEqual(hashlib.sha256((SOURCE / name).read_bytes()).hexdigest(), expected, name)
        source_files = {
            path.relative_to(SOURCE).as_posix()
            for path in SOURCE.rglob("*")
            if path.is_file() and "node_modules" not in path.relative_to(SOURCE).parts
        }
        self.assertEqual(source_files, set(manifest["sources"]))
        self.assertEqual(
            {path.relative_to(BUNDLE).as_posix() for path in BUNDLE.rglob("*") if path.is_file()},
            set(manifest["assets"]) | {"manifest.json"},
        )
        for name, item in manifest["assets"].items():
            self.assertNotIn("..", Path(name).parts)
            data = (BUNDLE / name).read_bytes()
            self.assertEqual(len(data), item["bytes"], name)
            self.assertEqual(hashlib.sha256(data).hexdigest(), item["sha256"], name)
        self.assertEqual(manifest["assets"][manifest["entry"]["js"]]["type"], "application/javascript")
        self.assertEqual(manifest["assets"][manifest["entry"]["css"]]["type"], "text/css")

    def test_chunks_fonts_and_runtime_fallback_stay_inside_the_same_origin_bundle(self):
        manifest = json.loads((BUNDLE / "manifest.json").read_text())
        assets = set(manifest["assets"])
        fonts = {name for name in assets if name.startswith("fonts/")}
        self.assertGreater(len(fonts), 230)
        self.assertTrue(any(name.startswith("fonts/Xiaolai/") for name in fonts))
        self.assertFalse(any(name.startswith("fonts/Liberation/") for name in fonts))
        for name in assets:
            if not name.endswith((".js", ".css")):
                continue
            contents = (BUNDLE / name).read_text()
            self.assertNotIn("https://esm.sh/", contents, name)
            for target in manifest["assets"][name]["imports"]:
                self.assertNotIn("..", Path(target).parts)
                self.assertIn(target, assets, (name, target))
        self.assertTrue(manifest["assets"][manifest["entry"]["js"]]["imports"])
        notices = (BUNDLE / "THIRD_PARTY_NOTICES.txt").read_text()
        self.assertIn("Copyright (c) 2020 Excalidraw", notices)
        self.assertIn("SIL OPEN FONT LICENSE Version 1.1", notices)
        self.assertIn("same-origin", notices)

    def test_frontend_dependencies_are_exactly_pinned_in_the_lockfile(self):
        package = json.loads((SOURCE / "package.json").read_text())
        lock = json.loads((SOURCE / "package-lock.json").read_text())
        for name, version in {**package["dependencies"], **package["devDependencies"]}.items():
            self.assertRegex(version, r"^\d+\.\d+\.\d+$")
            self.assertEqual(lock["packages"]["node_modules/" + name]["version"], version)
            self.assertTrue(lock["packages"]["node_modules/" + name]["integrity"].startswith("sha512-"))

    def test_application_context_includes_verified_editor_inputs_and_excludes_runtime_npm(self):
        patterns = (ROOT / "deploy/gke/application.Dockerfile.dockerignore").read_text().splitlines()

        def included(name):
            result = True
            for pattern in patterns:
                keep = pattern.startswith("!")
                pattern = pattern.removeprefix("!").rstrip("/")
                if fnmatch.fnmatchcase(name, pattern):
                    result = keep
            return result

        manifest = json.loads((BUNDLE / "manifest.json").read_text())
        for name in manifest["sources"]:
            self.assertTrue(included("elixir/assets/" + name), name)
        for name in manifest["assets"]:
            self.assertTrue(included("elixir/priv/static/design-editor/" + name), name)
        for name in ("elixir/assets/node_modules/react/index.js", "elixir/assets/node_modules/.package-lock.json",
                     "elixir/WORKFLOW.md", "private/operator-config.json"):
            self.assertFalse(included(name), name)
