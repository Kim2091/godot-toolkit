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

1. The welcome screen offers your recent projects with previews from their last successful Save. Choose **New from capture**, select a Remix capture, and create the project in a new directory. Or choose **Open** for an existing Toolkit workfile.
2. Remix starts automatically when you open or create a project with the **Remix** toggle enabled. Turning it off pauses rendering and shows the Layout view; turning it on starts or resumes Remix. Toggle it off and on to retry after a renderer failure. Initial shader compilation can take tens of seconds. The camera defaults to **Drone**: press **Z** over the viewport to capture the mouse, look around with the mouse, and fly with **WASD**. **Q/E** moves down/up, **Shift** moves faster, and the wheel adjusts flight speed. Press **Z** or **Escape** to release the cursor. While released, middle/right drag looks around and the wheel zooms. Choose **Orbit** for orbit controls; **F** frames the selection in either mode. Controls work in both Layout and Remix views.
3. **Add light** creates a light at the nearest surface in the centre of the view, with space for the emitter outside the surface. Area and spot lights face the surface. To place a mesh, ingest it, select it in the asset library, and choose **Add mesh**. Both start unattached. Use **Parent → Choose parent…** in Properties to search for an attachment prim, or choose **World (unattached)** to detach. Changing parent preserves the object's world pose; duplicates inherit the same parent and local transform. **Replace mesh** and **Replace material** still use the selected captured asset.
4. Select a scene object to use its grouped authoring controls: transforms and bound materials for meshes; radiance, color, temperature, shape, and cone controls for lights; texture channels and surface settings for materials. Commit numeric edits with Enter, focus loss, or release of a drag; use ↺ to reset an active-layer property override. Choose **Move** or **Rotate** above the viewport and drag the colored world axes or rotation rings. The center square moves in the view plane. **Snap** uses whole scene units and 15° increments; **Escape** or right-click cancels a drag. Light guides show the physical sphere, rectangle, disk, or cylinder, with emission arrows and spotlight cones including their soft edge. Distant and environment lights use orientation symbols. Guides and transform handles remain visible during Drone flight; release the cursor to manipulate them. Gizmos work in Layout and Remix views, preview live, and commit one undo step on release. Edits and attachments to captured assets affect every instance of the same hash.
5. Save the project, or choose **Package mod** to create a new, self-contained replacement mod directory containing `mod.usda` and its dependencies.

Use **Add capture** above the scene tree to attach another Remix capture to the open project. The **Capture** picker switches the active scene; hover an entry to see its full path. Only one capture composes at a time. Replacements and ingested assets stay shared, pending inspector edits are committed before switching, and each capture remembers its own camera. Adding and switching captures support Undo/Redo. **Save** persists the capture list and active capture in the workfile; capture files remain external, unchanged references. Missing captures stay listed but cannot be selected. Packaged mods exclude both capture geometry and the editor capture list.

**Ctrl+T** places the selected object on the surface under the mouse, preserving rotation, scale, and parent attachment. With the mouse captured for Drone mode, it uses the centre crosshair. The moved object's own mesh is excluded from the depth test; meshes rest on their bounds and lights clear their emitter dimensions. Placement is one undo step. If no mesh is hit, placement tries the stage's ground plane; if that also misses, Ctrl+T leaves the object unchanged and Add light falls back to the camera focus distance.

With the cursor released over the viewport, **G** moves the selection in the view plane, **R** rotates around the view axis, and **S** scales uniformly. Move the mouse to preview; **X**, **Y**, or **Z** constrains the operation to that world axis (press the same axis again to release the constraint). **Shift+T** aims a selected light's local −Z direction at the surface under the cursor, keeping its position and scale. Aiming uses captured geometry depth, with the ground plane as a fallback; missing a surface keeps the last valid aim. **Left click** or **Enter** confirms one undo step; **Escape**, **right click**, or losing window focus cancels. Snap applies whole-unit movement, 15° rotation, and 0.1 scale increments. These shortcuts work for lights and meshes in Layout and Remix; typing in properties and captured Drone flight retain their normal controls.

For precise rotation, press **R → X/Y/Z**, then type an angle in degrees, such as **45** or **−22.5**. The typed angle rotates from the pose at the start of the operation and overrides mouse movement and snapping. Negative values, decimals, and the numpad are supported. **Backspace** edits the number; erasing it returns to mouse control. **Enter** or **left click** confirms, and **Escape** or **right click** cancels.

New lights match the defaults in Toolkit's `omni.flux.light_creator.widget`: sphere radius 5 m / radiance 100, rectangle 10 × 10 m / 400, disk radius 5 m / 500, cylinder radius 5 m and length 10 m / 140, and distant angular size 1° / 25. Sizes are converted to the stage's units. Spotlights use the sphere defaults with a 35° cone; domes use USD's intensity default. Existing lights retain their settings. Radius describes the physical emitter, rather than its illumination range; an emitter intersecting the surrounding geometry can lose illumination. Cone and arrow lengths are display guides for direction and angle, not illumination cutoffs.

The editor remembers each project's camera on Save, when switching projects, and on a confirmed close—even when unsaved scene edits are discarded. It restores the camera position, orientation, Drone/Orbit mode, orbit pivot, and flight speed when you reopen the project, with the mouse unlocked. Missing or invalid view data falls back to Frame all.

Camera metadata and previews live beside the workfile as `<project>.studio.json` and `<project>.studio.png`. Copy these with the project to keep its view. Only a successful Save updates the preview; closing preserves the last-save image. Previews use the current Remix frame when available, or a separate Layout view without starting Remix. The sidecars are excluded from mod packages. Recent-project history is local to the application user directory and retains up to 20 projects; **Remove** only forgets an entry. **Recent projects** returns to the welcome screen, and `--project=/path/to/project.usda` opens directly into a project.

The compact interface uses system DPI scaling. Resizing the window changes workspace space without enlarging text and controls; display-scale changes update automatically. Toolbars wrap when needed, and dock splits remain resizable.

The capture stays unchanged. Undo/redo covers authoring-layer edits and capture changes in the workfile, including rollback of failed compound edits. Packaging includes unsaved authored changes, preserves nested replacement layers, excludes the capture sublayer, and refuses to overwrite an existing destination.

Capture texture paths are resolved relative to the USD layer that authored them, including referenced material layers. Windows-style separators are supported when previewing captures on Linux. Missing textures are reported in the editor log; resolving preview paths does not rewrite the capture.

The Remix viewport preserves material filtering and U/V wrap modes. Materials without these settings use Remix's linear filtering and repeat defaults, so terrain and other tiled textures sample correctly outside the 0–1 UV range.

**Render settings** above the viewport controls upscaling, quality, Ray Reconstruction, and output resolution. **Automatic** chooses DLSS when supported and TAAU otherwise; **Off** renders at native resolution. Quality presets control the internal render resolution. Ray Reconstruction is shown only when the active runtime reports support, and requires DLSS. Unavailable upscalers are disabled (the pinned Linux build does not include NIS). A saved unsupported selection falls back to TAAU while retaining the preference. Output resolution offers presets from 960×540 through 4K and custom dimensions; it is independent of UI DPI scaling. Apply saves preferences across all projects and app restarts in `render_settings.json` beside the recent-project history. Upscaler changes apply live; resolution changes reconnect the viewport while retaining the document and camera. Cancel discards unapplied changes.

The build/run helper places NVIDIA's downloaded NGX feature libraries beside `libremix.so` so DLSS and Ray Reconstruction can be discovered. An externally supplied runtime must include its corresponding feature libraries; capability detection also checks hardware and driver support.

The resizable bottom asset library shows mesh previews and material spheres. Use **New folder**, **Rename**, **Move to…**, or drag assets/folders onto a folder to organize the library. Search finds assets across all folders; the type filter separates meshes and materials. Removing a folder moves its contents to its parent. Imports go into the folder selected when ingestion starts.

Folders and display names are virtual: asset files and USD references stay in place. Organization autosaves to `assets/.library.json`, independently of scene Save and Undo. Existing ingested assets are discovered automatically, missing assets remain marked, and a damaged catalog is preserved with organization made read-only. Selecting a library asset shows read-only details; Replace uses the last selected scene object and bound material slot, while Add mesh spawns a standalone object.

Thumbnails use a separate Godot preview scene with approximate material shading. USD extraction runs in the background, one preview renders at a time, and visible assets get priority. The 256px previews are cached in `assets/.thumbnails` and invalidated when their dependencies change. **Refresh** discovers new files and checks cached previews; **Retry preview** retries selected assets. The catalog and thumbnail cache are excluded from mod packages.

## Implemented scope

| Area | Support |
| --- | --- |
| USD documents | `.usd`, `.usda`, `.usdc`; workfile sublayers; authoring layer selection; captured hash references; save/reopen; dependency remapping through the native command API |
| Static mesh ingestion | USD assets with a default prim; glTF/GLB, FBX, OBJ through Assimp; transforms, normals, UVs, material assignments; unit/axis normalization |
| Materials | AperturePBR opaque/cutout and translucent parameters; material replacement; PNG/JPEG/TGA/EXR/HDR conversion and existing DDS assets |
| Texture processing | BC7 color, BC6H HDR, BC5 hemispherical-octahedral normals, BC4 scalar maps, mipmaps, glTF packed metallic/roughness extraction |
| Authoring UI | Curated typed mesh/material/light controls; bound material slots; active-layer reset; virtual asset folders, search, and cached thumbnails |
| Placement | Standalone or attached meshes and sphere/spot/rect/disk/cylinder/distant/dome lights; parent picker preserving world pose; move/rotate gizmos, radius guides, snapping; duplicate/delete; visibility via properties |
| Viewport | Composed USD triangles, material subsets, material/light updates, camera orbit, nearest-triangle picking, selection outline, wireframe layout mode |
| Renderer isolation | Framed IPC; GPU memory sharing on Linux; synchronized GPU texture copies; manual worker restart without discarding the document |

Unsupported USD content is retained when opening and saving a project. The preview is a static rendering adapter: skeletal animation, animation playback, graphs, particles, arbitrary MDL networks, terrain authoring, and Toolkit-specific advanced workflows are outside this implementation. Imported non-Remix USD shaders are not automatically converted into complete AperturePBR networks.

## Architecture and limits

`native/document.cpp` owns the OpenUSD stage, layers, edit transactions, and packaging. `native/ingestion.cpp` converts source assets into staged USD assets before publishing them. The GDExtension exposes this to the standalone UI in `app/scripts` and runs ingestion on a background thread. Texture conversion uses Godot's codecs and compressors.

`native/scene.cpp` composes visible geometry and lighting into a renderer snapshot. `native/renderer_main.cpp` creates Remix SDK materials/meshes/lights and submits instances each frame. Repeated geometry within a snapshot shares a Remix mesh. Light edits send a small lighting snapshot and update only changed lights, preserving Remix mesh/material resources and the Layout geometry/picking cache. This includes light creation, deletion, and undo/redo; edits to lights with geometry descendants use the full scene path. Editor lights remain dynamic so repeated edits keep updating their illumination. Invalid captured UV components use zero in the preview without changing the USD assets. Geometry changes send complete JSON snapshots split into bounded IPC frames, so captures can exceed 64 MiB. Protocol v2 uses the high bit of each little-endian length header to mark continuation frames; a message is decoded and applied only after its final frame arrives. The editor and worker must be updated together. Snapshots still need to fit in memory; incremental binary geometry streaming and large-capture performance work remain.

The layout view uploads each unique mesh to Godot once per scene snapshot and draws wireframes on the GPU. It caches the resulting viewport image until the camera, selection, scene, or view size changes. Repeated instances share GPU geometry and a picking BVH, built lazily on first use. Selection first rejects mesh bounding boxes, then queries the native triangle BVH; framing uses cached world bounds. Large snapshots still take time to compose and upload when the scene changes, but orbiting does not walk their triangles in GDScript.

The Linux runtime patch exports an offscreen Vulkan image and two binary semaphores. Handles travel over a private Unix socket using `SCM_RIGHTS`; ordinary control messages use length-prefixed stdio. Godot verifies the GPU UUID, imports the allocation, and copies it into an engine-owned texture with queue ownership transfers and semaphore waits/signals. No CPU image readback is used for viewport presentation. The worker completes its GPU submission before acknowledging a frame so a crashed producer cannot leave Godot waiting for an unsignaled future frame. Frame production is serialized, with a configurable output image (960×540 by default) scaled to fit the viewport.

The preview uses Remix's RIS light sampling. The pinned native fork produced black analytical lighting with RTXDI enabled in the embedded viewport; RTXDI is disabled until that integration issue is resolved.

Windows currently has a separate native Remix preview window fallback. Windows external memory/handle transport, embedded viewport validation, and an in-game Windows mod compatibility run are still outstanding. Packaged mods have been tested by reopening their USD composition, not by loading them into a game. A redistributable application bundle is also not produced yet.

## Validation

```sh
python scripts/bootstrap.py test
python scripts/bootstrap.py gpu-test
```

Native tests cover capture immutability, composition, shared instance edits, transaction rollback, undo/redo, material and mesh replacement, and packaging. Protocol tests cover normal sessions, invalid versions, truncated continuations, oversized frames, UTF-8 across frame boundaries, transfers and replies above 64 MiB, and recoverable command errors. A headless Godot test exercises large transfers through the real client and worker. The Godot ingestion test checks DDS formats, mipmaps, channel values, glTF ingestion, and material dependency packaging. The GPU test checks visible rendered geometry, invalid captured UV handling, and worker restart while retaining unsaved edits; it needs an active desktop session and supported GPU. Test screenshots and generated projects are retained under `.work/integration` and `.work/ingestion`.

Layout tests cover nearest-hit picking with transformed instances, shared geometry, cache invalidation, GPU wireframe visibility, selection, resizing, and alignment of the transparent selection overlay with the Remix view.

Authoring tests cover supported fields, missing shader inputs, active-layer resets, light type conversion, color temperature, exposure and cone parameters, capture immutability, and subset materials. Catalog tests cover persistence, folders, invalid moves, missing assets, and corrupt catalogs. The authoring GPU test exercises inspector edits and focus preservation, DDS material and mesh previews, cache reuse/invalidation, project-switch cancellation, retry, and packaging exclusions. Its artifacts are under `.work/authoring`.

Camera tests cover drone movement and mouse look in Y-up and Z-up scenes, diagonal speed, speed adjustment, cursor release, focus loss, text-entry shortcuts, and switching back to Orbit.

Texture tests cover referenced layers, Windows-style paths, authoring-layer overrides, missing and cleared assets, material sampling settings, and a four-color DDS texture verifying both UV axes across nine tiles (including negative UVs and UVs above one) in the Remix viewport.

Project-session tests cover camera round trips, saved-view sidecars, close/cancel and failed-save behavior, command-line startup, recent history, and write failures. GPU tests check Layout and Remix save previews and compact layout at 100%, 150%, and 200% scale, including resize behavior, dialogs, and picking. Session screenshots are retained under `.work/session_ui`. Test runs use isolated recent-project settings.

The pinned upstream Remix test suite has independent failures: two referenced Python test files are absent, and its SDL `offscreen` smoke test cannot find a present-capable queue on the tested driver. Its desktop smoke test runs successfully. Our GPU test exercises the patched runtime through the application.

## Third-party files

The bootstrap copies AperturePBR modules and their license notices from the Remix checkout into ignored `app/materials` for local use. These modules are not included in this repository's authored source. Dependencies and material modules retain their own licenses; see `THIRD_PARTY.md`.

Multiple-capture tests cover legacy workfiles, exclusive scene composition, shared unsaved replacements, layer ordering and offsets, coordinate systems, duplicate and missing captures, undo/redo, save/reopen, capture immutability, packaging, per-capture cameras, pending inspector edits, and renderer reuse.

Placement tests cover standalone spawning, parent selection, pose preservation under transformed parents, reference roots, duplicate attachments, cycle rejection, undo/redo, save/reopen, and capture immutability. Gizmo tests cover both up axes, letterboxed projections, constrained moves, rotation, snapping, cancellation, and one-step commits. The placement GPU test verifies the parent picker, spawning without a capture selection, live light and mesh previews, restored illumination after cancellation, and rejection of stale preview requests. Artifacts are under `.work/placement`.

Surface placement tests cover nearest-hit depth, mirrored transforms, self-exclusion, ground fallback, emitter clearance, and both up axes. The light placement GPU test creates each analytical light type on a running scene in metre and centimetre units, verifies visible illumination, and exercises Ctrl+T, Drone placement, inspector focus, and undo. Artifacts are under `.work/light_placement`.
