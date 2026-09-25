Remix Studio — portable Linux x86_64 build

Extract the entire archive to a writable directory, then run ./remix-studio.
No installation, Python, compiler, Godot installation, or source checkout is needed.
An X11/Wayland desktop, Vulkan loader, and a driver/GPU supporting Remix ray
tracing are required. GPU drivers and glibc are supplied by your Linux system.

The bundle includes the patched Godot engine, editor extension, OpenUSD schemas
and libraries, Assimp, oneTBB, Remix runtime, DLSS features and MDL materials.
The Godot build retains editor capabilities for authoring image codecs/compressors;
the launcher opens Remix Studio directly. Third-party terms are in licenses/.
This software contains source code provided by NVIDIA Corporation. The NVIDIA
SDK portions remain subject to their included NVIDIA RTX SDK license terms.

Settings, recent-project history, logs and caches stay in data/ beside the launcher.
Set REMIX_STUDIO_DATA_DIR to put that data elsewhere (for a read-only installation).
REMIX_STUDIO_SETTINGS_DIR, REMIX_RUNTIME_PATH and REMIX_RENDERER_WORKER overrides
are also supported. Moving the whole folder retains its settings. Recent-project
paths and game links still refer to the original project locations.

Projects and captures are separate from the application and are not included.
Keep their referenced captures/assets accessible when moving a project to another
machine. Package mod exports game replacements, not the editor or source captures.
This native Linux runtime does not replace a game's Windows d3d9.dll.

For CLI access: ./remix-studio --cli inspect /path/to/project.usda
For a startup check: ./remix-studio --headless --quit-after 3
Verify extracted files: sha256sum -c SHA256SUMS
Build provenance and the system requirements are recorded in build-info.json.
