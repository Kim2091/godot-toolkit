#!/usr/bin/env python3
"""Package existing Linux builds without including user projects or build paths."""
import argparse
import filecmp
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DEPS = ROOT / ".work/deps"
SYSTEM_LIBRARIES = {"libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0",
                    "librt.so.1", "libresolv.so.2", "libvulkan.so.1"}


def run(*args):
    return subprocess.check_output(list(map(str, args)), text=True)


def copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def is_elf(path):
    if not path.is_file():
        return False
    with path.open("rb") as stream:
        return stream.read(4) == b"\x7fELF"


def dependencies(binary):
    output = run("ldd", binary)
    if "not found" in output:
        raise RuntimeError(f"Unresolved dependencies for {binary}:\n{output}")
    return {name: Path(path) for name, path in
            re.findall(r"^\s*(\S+) => (/.+?) \(0x", output, re.MULTILINE)}


def notices(bundle):
    # Preserve component notices, including notices from bundled/static SDKs.
    sources = {
        "godot": DEPS / "godot", "godot-cpp": DEPS / "godot-cpp",
        "OpenUSD": DEPS / "OpenUSD-25.11", "oneTBB": DEPS / "oneTBB-2021.13.0",
        "assimp": DEPS / "assimp-6.0.2", "json": ROOT / "build/_deps/json-src",
        "remix": DEPS / "remix", "remix-sdk": DEPS / "remix-sdk/sources",
    }
    for name, source in sources.items():
        count = 0
        for directory, dirs, files in os.walk(source):
            dirs[:] = [d for d in dirs if not d.startswith(".") and d not in {"build", "_build", "node_modules"}]
            for filename in files:
                if any(word in filename.lower() for word in ("license", "copying", "copyright", "notice")):
                    path = Path(directory) / filename
                    if path.is_file():
                        copy(path, bundle / "licenses" / name / path.relative_to(source))
                        count += 1
        if not count:
            raise RuntimeError(f"No license notices found for {name}: {source}")
    for name in ("libstdc++", "libgcc"):
        candidates = [Path(f"/usr/share/licenses/{name}/RUNTIME.LIBRARY.EXCEPTION"),
                      Path("/usr/share/doc/gcc-14-base/copyright")]
        notice = next((p for p in candidates if p.exists()), None)
        if notice is None:
            raise RuntimeError(f"Install the GCC runtime license notice for {name}")
        copy(notice, bundle / "licenses/gcc" / (name + "-exception.txt"))
    gpl = next((p for p in (Path("/usr/share/licenses/spdx/GPL-3.0-only.txt"),
                           Path("/usr/share/common-licenses/GPL-3")) if p.exists()), None)
    if gpl is None:
        raise RuntimeError("Install the GPL-3 license text for the GCC runtime libraries")
    copy(gpl, bundle / "licenses/gcc/GPL-3.0.txt")
    copy(ROOT / "THIRD_PARTY.md", bundle / "licenses/THIRD_PARTY.md")
    shutil.copytree(ROOT / "patches", bundle / "licenses/source-patches")


def package(output, name, patchelf):
    output.mkdir(parents=True, exist_ok=True)
    engine = next(iter(sorted((DEPS / "godot/bin").glob("godot.*editor*x86_64*"))), None)
    if engine is None:
        raise RuntimeError("Build Godot first: python scripts/bootstrap.py godot")
    with tempfile.TemporaryDirectory(prefix="portable-", dir=ROOT / ".work") as temporary:
        bundle = Path(temporary) / name
        bundle.mkdir()
        # Allowlist application code. app/ also contains private user projects,
        # captures, previews and caches, which must never enter a release.
        for filename in ("project.godot", "main.tscn", "remix_editor.gdextension"):
            copy(ROOT / "app" / filename, bundle / "app" / filename)
        for directory, suffixes in (("scripts", {".gd", ".uid"}), ("shaders", {".gdshader", ".uid"})):
            for path in (ROOT / "app" / directory).rglob("*"):
                if path.is_file() and path.suffix in suffixes:
                    copy(path, bundle / "app" / path.relative_to(ROOT / "app"))
        copy(ROOT / "app/bin/libremix_editor.so", bundle / "app/bin/libremix_editor.so")
        # Godot's game runner loads extensions from this generated list. No
        # editor import scan or workspace .godot cache is needed on first run.
        (bundle / "app/.godot").mkdir()
        (bundle / "app/.godot/extension_list.cfg").write_text("res://remix_editor.gdextension\n")
        shutil.copytree(ROOT / "app/materials", bundle / "app/materials")
        copy(engine, bundle / "bin/godot")
        for binary in ("remix-renderer", "remix-editor-cli"):
            destination = binary + ".bin" if binary == "remix-renderer" else binary
            copy(ROOT / "build" / binary, bundle / "bin" / destination)
        copy(ROOT / "scripts/portable/renderer.sh", bundle / "bin/remix-renderer")
        (bundle / "bin/remix-renderer").chmod(0o755)
        runtime = ROOT / ".work/build/remix/src/linux/libremix.so"
        copy(runtime, bundle / "runtime/libremix.so")
        sdk = DEPS / "remix-sdk/prefix/lib"
        for feature in ("dlss", "dlssd", "dlssg"):
            libraries = list(sdk.glob(f"libnvidia-ngx-{feature}.so.*"))
            if not libraries:
                raise RuntimeError(f"Missing NGX {feature} runtime in {sdk}")
            for library in libraries:
                copy(library, bundle / "runtime" / library.name)
        # Keep USD's relative LibraryPath/ResourcePath layout intact, including
        # schemas and dynamically loaded shader discovery plugins.
        shutil.copytree(DEPS / "usd/lib", bundle / "lib", ignore=shutil.ignore_patterns("cmake", "pkgconfig", "*.a"))
        shutil.copytree(DEPS / "usd/plugin", bundle / "plugin")
        pending = [path for path in bundle.rglob("*") if is_elf(path)]
        copied = {}
        for binary in pending:
            for soname, source in dependencies(binary).items():
                if soname in SYSTEM_LIBRARIES or Path(soname).name.startswith("ld-linux-"):
                    continue
                if soname in copied and not filecmp.cmp(copied[soname], source, shallow=False):
                    raise RuntimeError(f"Conflicting versions of {soname}")
                copied[soname] = source.resolve()
                destination = bundle / "lib" / soname
                if not destination.exists():
                    copy(source, destination)
                    pending.append(destination)
        minimum = (2, 0)
        for binary in (p for p in bundle.rglob("*") if is_elf(p)):
            relative_lib = os.path.relpath(bundle / "lib", binary.parent)
            rpath = "$ORIGIN" if relative_lib == "." else "$ORIGIN/" + relative_lib
            # NGX feature binaries are signed. Rewriting even just their ELF
            # RPATH invalidates the signature and silently disables DLSS/RR.
            if not binary.name.startswith("libnvidia-ngx-"):
                run(patchelf, "--set-rpath", rpath, binary)
            versions = re.findall(r"\bGLIBC_(\d+)\.(\d+)\b", run("readelf", "--version-info", binary))
            minimum = max(minimum, *(tuple(map(int, v)) for v in versions)) if versions else minimum
        glibc = ".".join(map(str, minimum))
        launcher = (ROOT / "scripts/portable/launch.sh").read_text().replace("@GLIBC_MIN@", glibc)
        (bundle / "remix-studio").write_text(launcher)
        (bundle / "remix-studio").chmod(0o755)
        copy(ROOT / "scripts/portable/README.txt", bundle / "README.txt")
        with (bundle / "README.txt").open("a") as stream:
            stream.write(f"\nThis build requires glibc {glibc} or newer.\n")
        notices(bundle)
        info = {"platform": "linux-x86_64", "glibc_minimum": glibc,
                "godot": run(engine, "--version").strip(),
                "source_revision": run("git", "-C", ROOT, "rev-parse", "HEAD").strip(),
                "source_modified": bool(run("git", "-C", ROOT, "status", "--porcelain")),
                "dependencies": json.loads((ROOT / "dependencies.lock.json").read_text()),
                "system_libraries": sorted(SYSTEM_LIBRARIES)}
        (bundle / "build-info.json").write_text(json.dumps(info, indent=2) + "\n")
        # Check patched resolution before publishing; no dependency may resolve
        # into the original checkout, even if it happens to exist on this host.
        for binary in (p for p in bundle.rglob("*") if is_elf(p)):
            for soname, path in dependencies(binary).items():
                if soname not in SYSTEM_LIBRARIES and not Path(soname).name.startswith("ld-linux-") and not path.is_relative_to(bundle):
                    raise RuntimeError(f"External dependency in bundle: {binary}: {path}")
        manifest = []
        for path in sorted(p for p in bundle.rglob("*") if p.is_file()):
            with path.open("rb") as stream:
                manifest.append(f"{hashlib.file_digest(stream, 'sha256').hexdigest()}  {path.relative_to(bundle)}")
        (bundle / "SHA256SUMS").write_text("\n".join(manifest) + "\n")
        archive = output / (name + ".tar.gz")
        staged_archive = archive.with_suffix(".gz.staging")
        with tarfile.open(staged_archive, "w:gz", compresslevel=6) as stream:
            stream.add(bundle, arcname=name)
        os.replace(staged_archive, archive)
        with archive.open("rb") as stream:
            checksum = hashlib.file_digest(stream, "sha256").hexdigest()
        archive.with_name(archive.name + ".sha256").write_text(f"{checksum}  {archive.name}\n")
        print(f"Created {archive} ({archive.stat().st_size / 1024**2:.1f} MiB; glibc >= {glibc})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    parser.add_argument("--name", default="RemixStudio-linux-x86_64")
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        parser.error("Portable packaging currently supports Linux x86_64")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", args.name):
        parser.error("--name must be a simple directory name")
    patchelf = shutil.which("patchelf") or str(ROOT / ".work/tools/venv/bin/patchelf")
    if not Path(patchelf).is_file():
        parser.error("Install patchelf or run python scripts/bootstrap.py portable")
    package(args.output.resolve(), args.name, patchelf)


if __name__ == "__main__":
    main()
