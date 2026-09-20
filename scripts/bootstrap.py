#!/usr/bin/env python3
"""Build pinned dependencies without changing the reference repositories."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import venv

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".work"
DEPS = WORK / "deps"
LOCK = json.loads((ROOT / "dependencies.lock.json").read_text())
WINDOWS = sys.platform == "win32"
TOOLS = WORK / "tools" / "venv"
BIN = TOOLS / ("Scripts" if WINDOWS else "bin")
ENV = dict(os.environ)
ENV["PATH"] = str(BIN) + os.pathsep + ENV["PATH"]


def run(args, cwd=ROOT, **kwargs):
    print("+", " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, env=ENV, check=True, **kwargs)


def tools():
    WORK.mkdir(exist_ok=True)
    if not TOOLS.exists():
        venv.create(TOOLS, with_pip=True)
    if not all((BIN / (name + (".exe" if WINDOWS else ""))).exists() for name in ["cmake", "ninja", "scons", "meson"]):
        run([BIN / ("python.exe" if WINDOWS else "python"), "-m", "pip", "install",
             "cmake==4.4.3", "ninja==1.13.2", "scons==4.11.1", "meson==1.12.0"])
    DEPS.mkdir(exist_ok=True)


def checkout(name):
    item = LOCK[name]
    target = DEPS / name
    if not target.exists():
        local = ROOT / "ref" / item.get("reference", name)
        run(["git", "clone", "--no-checkout", local if (local / ".git").exists() else item["url"], target])
        run(["git", "checkout", "--detach", item["commit"]], cwd=target)
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=target, text=True).strip()
    if actual != item["commit"]:
        raise RuntimeError(f"{target} must be at {item['commit']}; existing checkout was left untouched")
    if (target / ".gitmodules").exists():
        run(["git", "submodule", "update", "--init", "--recursive"], cwd=target)
    return target


def archive(name):
    item = LOCK[name]
    target = DEPS / item["source"]
    if target.exists():
        return target
    downloaded = DEPS / item["archive"]
    if not downloaded.exists():
        print("Downloading", item["url"], flush=True)
        with urllib.request.urlopen(item["url"]) as response, downloaded.open("wb") as output:
            shutil.copyfileobj(response, output)
    if hashlib.sha256(downloaded.read_bytes()).hexdigest() != item["sha256"]:
        raise RuntimeError(f"Checksum mismatch: {downloaded}")
    with tarfile.open(downloaded) as package:
        package.extractall(DEPS, filter="data")
    return target


def cmake(source, build, flags, jobs, install=True):
    run(["cmake", "-S", source, "-B", build, "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release", *flags])
    run(["cmake", "--build", build, "--parallel", jobs])
    if install:
        run(["cmake", "--install", build])


def dependencies(jobs):
    cmake(archive("tbb2021"), WORK / "build/tbb2021", [
        f"-DCMAKE_INSTALL_PREFIX={DEPS / 'tbb2021'}", "-DTBB_TEST=OFF", "-DTBB_STRICT=OFF"], jobs)
    cmake(archive("usd"), WORK / "build/usd", [
        f"-DCMAKE_INSTALL_PREFIX={DEPS / 'usd'}", f"-DCMAKE_PREFIX_PATH={DEPS / 'tbb2021'}",
        "-DPXR_ENABLE_PYTHON_SUPPORT=OFF", "-DPXR_BUILD_IMAGING=OFF", "-DPXR_BUILD_USD_IMAGING=OFF",
        "-DPXR_BUILD_TESTS=OFF", "-DPXR_BUILD_EXAMPLES=OFF", "-DPXR_BUILD_TUTORIALS=OFF",
        "-DPXR_BUILD_USD_TOOLS=OFF", "-DPXR_BUILD_USD_VALIDATION=OFF", "-DPXR_BUILD_MONOLITHIC=OFF",
        "-DPXR_BUILD_EXEC=OFF"], jobs)
    cmake(archive("assimp"), WORK / "build/assimp", [
        f"-DCMAKE_INSTALL_PREFIX={DEPS / 'assimp'}", "-DASSIMP_BUILD_TESTS=OFF", "-DASSIMP_BUILD_ASSIMP_TOOLS=OFF",
        "-DASSIMP_WARNINGS_AS_ERRORS=OFF", "-DASSIMP_BUILD_ALL_IMPORTERS_BY_DEFAULT=OFF",
        "-DASSIMP_BUILD_FBX_IMPORTER=ON", "-DASSIMP_BUILD_OBJ_IMPORTER=ON", "-DASSIMP_BUILD_GLTF_IMPORTER=ON",
        "-DASSIMP_BUILD_ALL_EXPORTERS_BY_DEFAULT=OFF", "-DASSIMP_BUILD_ZLIB=ON", "-DASSIMP_BUILD_MINIZIP=ON",
        "-DUNZIP_FOUND=OFF", "-DZLIB_FOUND=OFF"], jobs)
    checkout("godot-cpp")


def patch(checkout_path, name):
    path = ROOT / "patches" / name
    if subprocess.run(["git", "apply", "--reverse", "--check", str(path)], cwd=checkout_path,
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        return
    run(["git", "apply", "--check", path], cwd=checkout_path)
    run(["git", "apply", path], cwd=checkout_path)


def godot(jobs):
    source = checkout("godot")
    patch(source, "godot-external-frame.patch")
    run(["scons", "platform=" + ("windows" if WINDOWS else "linuxbsd"), "target=editor", "arch=x86_64",
         "dev_build=no", "debug_symbols=no", "optimize=speed", "vulkan=yes", "opengl3=yes",
         *([] if WINDOWS else ["use_llvm=yes"]), f"-j{jobs}"], cwd=source)


def materials(source):
    destination = ROOT / "app/materials"
    for part in ["Base", "mdl"]:
        shutil.copytree(source / "src/mdl" / part, destination, dirs_exist_ok=True)
    shutil.copytree(source / "src/mdl/PACKAGE-LICENSES", destination / "PACKAGE-LICENSES", dirs_exist_ok=True)


def remix(jobs):
    source = checkout("remix")
    materials(source)
    if WINDOWS:
        raise RuntimeError("Build the Windows Remix runtime with its upstream build instructions; the shared-frame runtime patch currently targets Linux")
    patch(source, "remix-editor-frame.patch")
    shutil.copyfile(ROOT / "native/shared_frame.h", source / "src/linux/editor_shared_frame.h")
    sdk = DEPS / "remix-sdk"
    run(["bash", source / "scripts-linux/build-dependencies.sh", sdk])
    nrd = source / "src/dxvk/external/nrd"
    if not nrd.exists():
        nrd.parent.mkdir(parents=True, exist_ok=True)
        nrd.symlink_to(sdk / "sources/nrd", target_is_directory=True)
    build = WORK / "build/remix"
    args = ["meson", "setup"]
    if (build / "meson-private/coredata.dat").exists():
        args += ["--reconfigure"]
    saved = ENV.copy()
    ENV.update(CC="clang", CXX="clang++")
    try:
        run([*args, build, source, "-Dbuildtype=release", "-Denable_d3d9=false", "-Dwerror=true",
             "-Dlinux_native_bootstrap=false", f"-Dlinux_deps_root={sdk / 'prefix'}"])
        run(["meson", "compile", "-C", build, "-j", jobs])
    finally:
        ENV.clear()
        ENV.update(saved)


def editor(jobs):
    source = DEPS / "remix"
    if not source.exists():
        source = ROOT / "ref/dxvk-remix-gmod"
    materials(source)
    flags = [f"-DCMAKE_PREFIX_PATH={DEPS / 'usd'};{DEPS / 'tbb2021'};{DEPS / 'assimp'}",
             f"-DGODOT_CPP_DIR={DEPS / 'godot-cpp'}", f"-DREMIX_SOURCE_DIR={source}"]
    if (DEPS / "godot/thirdparty/vulkan/include").exists():
        flags += [f"-DVulkan_INCLUDE_DIR={DEPS / 'godot/thirdparty/vulkan/include'}"]
    cmake(ROOT, ROOT / "build", flags, jobs, install=False)


def godot_binary():
    candidates = sorted((DEPS / "godot/bin").glob("godot.*editor*x86_64*"))
    candidates = [p for p in candidates if p.is_file() and (p.suffix == ".exe" if WINDOWS else os.access(p, os.X_OK))]
    if not candidates:
        raise RuntimeError("Build Godot first: python scripts/bootstrap.py godot")
    return candidates[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=["all", "deps", "godot", "remix", "editor", "test", "gpu-test", "run"], nargs="?", default="all")
    parser.add_argument("--jobs", type=int, default=min(os.cpu_count() or 4, 8))
    args = parser.parse_args()
    if platform.machine().lower() not in ["x86_64", "amd64"]:
        parser.error("The Remix editor currently requires x86_64")
    tools()
    if args.target in ["all", "deps"]: dependencies(args.jobs)
    if args.target in ["all", "godot"]: godot(args.jobs)
    if args.target in ["all", "remix"]: remix(args.jobs)
    if args.target in ["all", "editor"]: editor(args.jobs)
    if args.target in ["all", "test"]:
        run(["ctest", "--test-dir", ROOT / "build", "--output-on-failure"])
        run([godot_binary(), "--headless", "--path", ROOT / "app", "--script", "res://tests/ingestion_smoke.gd"])
        run([godot_binary(), "--headless", "--path", ROOT / "app", "--script", "res://tests/layout_geometry_test.gd"])
        run([godot_binary(), "--headless", "--path", ROOT / "app", "--script", "res://tests/camera_controls_test.gd"])
        run([godot_binary(), "--headless", "--path", ROOT / "app", "--script", "res://tests/asset_catalog_test.gd"])
    if args.target == "gpu-test":
        run([godot_binary(), "--path", ROOT / "app", "--script", "res://tests/authoring_ui_smoke.gd"])
        run([godot_binary(), "--path", ROOT / "app", "--script", "res://tests/layout_view_smoke.gd"])
        run([godot_binary(), "--path", ROOT / "app", "--script", "res://tests/gpu_smoke.gd"])
        run([godot_binary(), "--path", ROOT / "app", "--script", "res://tests/capture_textures_smoke.gd"])
    if args.target == "run":
        run([godot_binary(), "--path", ROOT / "app"])


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
