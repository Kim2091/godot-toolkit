# Remix Studio

A standalone Godot application for authoring RTX Remix replacements in OpenUSD. The document stays in USD; a separate `dxvk-remix` process renders the viewport. It does not use Omniverse Kit.

This is an initial implementation, not full Toolkit parity. The embedded Vulkan viewport currently targets Linux x86_64. The editor and worker have Windows code paths, but Windows shared-frame transport and Windows builds have not been validated.

## Build and run

On Linux, install a C++ toolchain with Clang, Python 3.12+, Git, a Vulkan loader/driver, and the normal Godot X11/Wayland development dependencies. Use a Vulkan ray-tracing capable GPU. Development and GPU testing were performed on an RTX 2080.

```sh
python scripts/bootstrap.py all --jobs 8
python scripts/bootstrap.py run
```

The first build downloads and compiles OpenUSD 25.11, oneTBB, Assimp, Godot, godot-cpp, and the Remix SDK/runtime. It requires substantial disk space and build time. Everything goes under `.work`, `build`, and `app/bin`. Existing reference checkouts under `ref` are used as clone sources and are not modified. Revisions and source archive checksums are in `dependencies.lock.json`; engine/runtime changes are reproducible patches in `patches`.

Individual build targets are `deps`, `godot`, `remix`, and `editor`. The editor uses the locally built runtime automatically, or the library named by `REMIX_RUNTIME_PATH`. `REMIX_RENDERER_WORKER` overrides the worker executable.

To launch the already built app directly:

```sh
.work/deps/godot/bin/godot.linuxbsd.editor.x86_64.llvm --path app
```

## Workflow

1. Choose **New from capture**, select a Remix capture, and create the project in a new directory. Or choose **Open** for an existing Toolkit workfile.
2. Start Remix with **Start / restart Remix**. Initial shader compilation can take tens of seconds. Orbit with middle/right drag, zoom with the wheel, and frame the selection with **F**.
3. Ingest an asset, select it in the asset library, then select a captured mesh and choose **Add mesh**, **Replace mesh**, or **Replace material**. Lights also attach to the selected captured asset.
4. Select the authored object to edit its translation, rotation, scale, or USD properties. Shift-drag translates the selection; **Snap** snaps movement to whole scene units. Edits to a captured asset's replacement affect every captured instance of that hash.
5. Save the project, or choose **Package mod** to create a new, self-contained replacement mod directory containing `mod.usda` and its dependencies.

The capture stays unchanged. Undo/redo operates on the authoring layer, including rollback of failed compound edits. Packaging includes unsaved authored changes, preserves nested replacement layers, excludes the capture sublayer, and refuses to overwrite an existing destination.

## Implemented scope

| Area | Support |
| --- | --- |
| USD documents | `.usd`, `.usda`, `.usdc`; workfile sublayers; authoring layer selection; captured hash references; save/reopen; dependency remapping through the native command API |
| Static mesh ingestion | USD assets with a default prim; glTF/GLB, FBX, OBJ through Assimp; transforms, normals, UVs, material assignments; unit/axis normalization |
| Materials | AperturePBR opaque/cutout and translucent parameters; material replacement; PNG/JPEG/TGA/EXR/HDR conversion and existing DDS assets |
| Texture processing | BC7 color, BC6H HDR, BC5 hemispherical-octahedral normals, BC4 scalar maps, mipmaps, glTF packed metallic/roughness extraction |
| Placement | Attached meshes and sphere/spot/rect/disk/cylinder/distant/dome lights; inspector transforms; translation dragging; duplicate/delete; visibility via properties |
| Viewport | Composed USD triangles, material subsets, material/light updates, camera orbit, nearest-triangle picking, selection outline, wireframe layout mode |
| Renderer isolation | Framed IPC; GPU memory sharing on Linux; synchronized GPU texture copies; manual worker restart without discarding the document |

Unsupported USD content is retained when opening and saving a project. The preview is a static rendering adapter: skeletal animation, animation playback, graphs, particles, arbitrary MDL networks, terrain authoring, and Toolkit-specific advanced workflows are outside this implementation. Imported non-Remix USD shaders are not automatically converted into complete AperturePBR networks.

## Architecture and limits

`native/document.cpp` owns the OpenUSD stage, layers, edit transactions, and packaging. `native/ingestion.cpp` converts source assets into staged USD assets before publishing them. The GDExtension exposes this to the standalone UI in `app/scripts` and runs ingestion on a background thread. Texture conversion uses Godot's codecs and compressors.

`native/scene.cpp` composes visible geometry and lighting into a renderer snapshot. `native/renderer_main.cpp` creates Remix SDK materials/meshes/lights and submits instances each frame. Repeated geometry within a snapshot shares a Remix mesh. Scene changes currently send complete JSON snapshots, capped at 64 MiB; incremental binary geometry streaming and large-capture performance work remain.

The Linux runtime patch exports an offscreen Vulkan image and two binary semaphores. Handles travel over a private Unix socket using `SCM_RIGHTS`; ordinary control messages use length-prefixed stdio. Godot verifies the GPU UUID, imports the allocation, and copies it into an engine-owned texture with queue ownership transfers and semaphore waits/signals. No CPU image readback is used for viewport presentation. The worker completes its GPU submission before acknowledging a frame so a crashed producer cannot leave Godot waiting for an unsignaled future frame. The initial implementation serializes frame production and uses a fixed 960×540 image scaled to fit the viewport.

The preview uses Remix's RIS light sampling. The pinned native fork produced black analytical lighting with RTXDI enabled in the embedded viewport; RTXDI is disabled until that integration issue is resolved.

Windows currently has a separate native Remix preview window fallback. Windows external memory/handle transport, embedded viewport validation, and an in-game Windows mod compatibility run are still outstanding. Packaged mods have been tested by reopening their USD composition, not by loading them into a game. A redistributable application bundle is also not produced yet.

## Validation

```sh
python scripts/bootstrap.py test
python scripts/bootstrap.py gpu-test
```

Native tests cover capture immutability, composition, shared instance edits, transaction rollback, undo/redo, material and mesh replacement, and packaging. Protocol tests cover normal sessions, invalid versions, truncation, oversized messages, and recoverable command errors. The Godot ingestion test checks DDS formats, mipmaps, channel values, glTF ingestion, and material dependency packaging. The GPU test checks visible rendered geometry and worker restart while retaining unsaved edits; it needs an active desktop session and supported GPU. Test screenshots and generated projects are retained under `.work/integration` and `.work/ingestion`.

The pinned upstream Remix test suite has independent failures: two referenced Python test files are absent, and its SDL `offscreen` smoke test cannot find a present-capable queue on the tested driver. Its desktop smoke test runs successfully. Our GPU test exercises the patched runtime through the application.

## Third-party files

The bootstrap copies AperturePBR modules and their license notices from the Remix checkout into ignored `app/materials` for local use. These modules are not included in this repository's authored source. Dependencies and material modules retain their own licenses; see `THIRD_PARTY.md`.
