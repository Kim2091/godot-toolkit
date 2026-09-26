#!/usr/bin/env python3
"""Validate an extracted portable build with the source checkout hidden by bwrap."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, nargs="?", default=ROOT / "dist/RemixStudio-linux-x86_64.tar.gz")
    parser.add_argument("--gpu", action="store_true", help="Also test real Vulkan viewport presentation")
    parser.add_argument("--openremix-source", type=Path, default=Path(os.environ.get("OPENREMIX_SOURCE_DIR", ROOT / ".work/deps/openremix")))
    args = parser.parse_args()
    if not shutil.which("bwrap"):
        parser.error("Install bubblewrap to verify that the bundle works without the checkout")
    directory = Path(tempfile.mkdtemp(prefix="remix portable test "))
    print(f"Test artifacts: {directory}", flush=True)
    with tarfile.open(args.archive) as archive:
        archive.extractall(directory, filter="data")
    bundle, = [path for path in directory.iterdir() if path.is_dir()]
    for line in (bundle / "SHA256SUMS").read_text().splitlines():
        expected, relative = line.split("  ", 1)
        with (bundle / relative).open("rb") as stream:
            assert hashlib.file_digest(stream, "sha256").hexdigest() == expected, relative
    allowed = {"project.godot", "main.tscn", "remix_editor.gdextension", ".godot", "bin", "materials", "scripts", "shaders"}
    assert {path.name for path in (bundle / "app").iterdir()} == allowed
    assert not (bundle / "data").exists(), "Package contains user settings/caches"
    for feature in (bundle / "runtime/remix").glob("libnvidia-ngx-*.so.*"):
        original = ROOT / ".work/deps/remix-sdk/prefix/lib" / feature.name
        with original.open("rb") as source, feature.open("rb") as packaged:
            assert hashlib.file_digest(source, "sha256").digest() == hashlib.file_digest(packaged, "sha256").digest(), "NGX signature was modified"
    shutil.copy(ROOT / "scripts/portable/smoke.gd", directory / "smoke.gd")
    environment = dict(os.environ)
    for key in ("REMIX_RUNTIME_PATH", "OPENREMIX_RUNTIME_PATH", "REMIX_RENDERER_WORKER", "REMIX_STUDIO_SETTINGS_DIR",
                "REMIX_STUDIO_DATA_DIR", "PXR_PLUGINPATH_NAME", "LD_LIBRARY_PATH"):
        environment.pop(key, None)
    sandbox = ["bwrap", "--die-with-parent", "--ro-bind", "/", "/", "--dev-bind", "/dev", "/dev",
               "--proc", "/proc", "--tmpfs", "/tmp", "--ro-bind-try", "/tmp/.X11-unix", "/tmp/.X11-unix",
               "--bind", str(directory), str(directory), "--tmpfs", str(ROOT),
               "--chdir", str(directory)]

    if args.openremix_source.exists() and not args.openremix_source.resolve().is_relative_to(ROOT):
        sandbox += ["--tmpfs", str(args.openremix_source.resolve())]

    def execute(name, arguments, expected=None):
        result = subprocess.run(sandbox + list(map(str, arguments)), env=environment,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=660)
        (directory / (name + ".log")).write_text(result.stdout)
        if result.returncode != 0 or (expected and expected not in result.stdout):
            raise RuntimeError(f"{name} failed ({result.returncode}):\n{result.stdout}")
        print(f"{name}: PASS", flush=True)
        return result.stdout

    for name in ("headless", "gpu", "openremix") if args.gpu else ("headless",):
        environment["REMIX_STUDIO_TEST_RENDERER"] = "openremix" if name == "openremix" else "remix"
        project_dir = directory / name
        project_dir.mkdir()
        shutil.copy(ROOT / "tests/fixtures/capture.usda", project_dir / "capture.usda")
        environment["REMIX_STUDIO_PORTABLE_TEST_DIR"] = str(project_dir)
        execute(name, [bundle / "remix-studio", *(["--headless"] if name == "headless" else []),
                       "--script", directory / "smoke.gd"], "PASS")
    # Relative filenames must keep the caller's cwd in CLI mode.
    result = execute("cli", [bundle / "remix-studio", "--cli", "inspect", "headless/project.usda"])
    assert json.loads(result)["open"]
    assert (bundle / "data/settings/recent_projects.json").exists()
    # A second location must use its own relative library/resource paths, while
    # an explicitly selected writable data directory still works.
    moved = directory / "moved application"
    bundle.rename(moved)
    environment["REMIX_STUDIO_DATA_DIR"] = str(directory / "separate data")
    sandbox += ["--ro-bind", str(moved), str(moved)]
    execute("relocated", [moved / "remix-studio", "--headless", "--quit-after", "3"])
    assert (directory / "separate data/settings").is_dir()
    print("Portable build validation passed. The source checkout was inaccessible in every run.")


if __name__ == "__main__":
    main()
