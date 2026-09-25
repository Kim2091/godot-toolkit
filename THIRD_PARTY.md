# Third-party components

The application builds against the following components; their source and notices are retained in `.work/deps`:

| Component | License / notice location |
| --- | --- |
| Godot Engine | MIT, `godot/LICENSE.txt` and `godot/COPYRIGHT.txt` |
| godot-cpp | MIT, `godot-cpp/LICENSE.md` |
| OpenUSD | Apache-2.0 with modification, `OpenUSD-25.11/LICENSE.txt` |
| oneTBB | Apache-2.0, `oneTBB-2021.13.0/LICENSE.txt` |
| Assimp | BSD-3-Clause and bundled dependency notices, `assimp-6.0.2/LICENSE` |
| nlohmann/json | MIT, downloaded by CMake into `build/_deps/json-src` |
| dxvk-remix and its SDK dependencies | Runtime repository license and per-dependency notices in `remix` and `remix-sdk` |
| AperturePBR and NVIDIA MDL modules | Module headers and `remix/src/mdl/PACKAGE-LICENSES/LICENSE.md`, copied alongside local material bundles |

Godot supplies the image codecs and BC compressors. Its full copyright file records their respective licenses. The project patches modify the corresponding upstream sources and retain the surrounding upstream notices.

Portable Linux packages retain component notices under `licenses/`, including Godot's
bundled dependencies, OpenUSD, the Remix SDKs, and the GCC runtime libraries and
runtime-library exception. Applied source patches are included there as well.
AperturePBR/MDL and NVIDIA SDK components remain subject to their included terms;
they are not relicensed by this project. This software contains source code provided
by NVIDIA Corporation.
