#include "document.h"
#include <chrono>
#include <fstream>
#include <iostream>
#include <pxr/base/tf/errorMark.h>
#include <pxr/usd/usdGeom/xformable.h>
#include <pxr/usd/usdUtils/dependencies.h>

using editor::Json;
namespace fs = std::filesystem;
PXR_NAMESPACE_USING_DIRECTIVE
namespace {
void check(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
template<class F> void rejects(F action, const char* message) {
  bool rejected = false;
  try { action(); } catch (const std::exception&) { rejected = true; }
  check(rejected, message);
}
std::string text(const fs::path& path) {
  std::ifstream input(path); return {std::istreambuf_iterator<char>(input), {}};
}
}

int main() {
  const auto directory = fs::temp_directory_path() / ("studio-game-link-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  fs::create_directories(directory / "Game with spaces");
  try {
    TfErrorMark errors;
    const auto capture = directory / "capture.usda";
    fs::copy_file(fs::path(FIXTURE_DIR) / "capture.usda", capture);
    const auto capture_before = text(capture);
    const auto project = directory / "project/work.usda";
    editor::Document doc; doc.create(capture, project);
    check(!doc.dispatch({{"op", "game_link_status"}})["linked"].get<bool>(), "New projects must not be linked");
    const auto root_before = text(project), mod_before = text(project.parent_path() / "mod.usda");
    const std::string instance = "/RootNode/instances/inst_0123456789ABCDEF_0";
    const auto light = doc.dispatch({{"op", "add_light"}, {"path", instance}, {"type", "SphereLight"}})["selection"].get<std::string>();
    doc.dispatch({{"op", "transform"}, {"path", light}, {"translation", {1, 2, 3}}});

    // Referenced geometry, texture and MDL imports must resolve through the game
    // symlink, even when the original assets live outside the project directory.
    fs::create_directories(directory / "external/meshes");
    fs::create_directories(directory / "external/textures");
    fs::create_directories(directory / "external/materials/nvidia");
    fs::copy_file(fs::path(FIXTURE_DIR) / "replacement.usda", directory / "external/meshes/mesh.usda");
    std::ofstream(directory / "external/textures/color.dds") << "texture";
    std::ofstream(directory / "external/materials/Surface.mdl") << "mdl 1.6;";
    std::ofstream(directory / "external/materials/nvidia/common.mdl") << "mdl 1.6;";
    auto asset = UsdStage::Open((directory / "external/meshes/mesh.usda").string());
    auto mesh = asset->GetPrimAtPath(SdfPath("/ReferenceTarget/triangle"));
    mesh.CreateAttribute(TfToken("texture"), SdfValueTypeNames->Asset).Set(SdfAssetPath("../textures/color.dds"));
    mesh.CreateAttribute(TfToken("module"), SdfValueTypeNames->Asset).Set(SdfAssetPath("../materials/Surface.mdl"));
    asset->GetRootLayer()->Save();
    const auto mesh_selection = doc.dispatch({{"op", "add_mesh"}, {"path", instance}, {"asset", (directory / "external/meshes/mesh.usda").string()}})["selection"].get<std::string>();
    const auto mesh_path = doc.inspect(mesh_selection)["authoring"]["edit_path"].get<std::string>();

    // Nested layers, root opinions and offsets must survive without captures.
    auto nested = SdfLayer::CreateNew((project.parent_path() / "nested.usda").string());
    nested->SetSubLayerPaths({"mod.usda"}); nested->Save();
    doc.stage()->GetRootLayer()->SetSubLayerPaths({"nested.usda", "../capture.usda"});
    doc.stage()->GetRootLayer()->SetSubLayerOffset(SdfLayerOffset(3, 2), 0);
    auto metadata = doc.stage()->GetRootLayer()->GetCustomLayerData();
    metadata["custom_opinion"] = VtValue(std::string("keep"));
    doc.stage()->GetRootLayer()->SetCustomLayerData(metadata);
    const auto revision = doc.revision();
    const auto authored = editor::layer_text(doc.stage()->GetEditTarget().GetLayer());

    const auto game = directory / "Game with spaces";
    const auto target = game / "rtx-remix/mods/My live mod";
    auto linked = doc.dispatch({{"op", "game_link"}, {"folder", game.string()}, {"name", "My live mod"}});
    check(linked["linked"].get<bool>() && linked["connected"].get<bool>() && fs::is_symlink(target), "Link must create and remember a directory symlink");
    const fs::path live = linked["directory"].get<std::string>();
    auto stage = UsdStage::Open((target / "mod.usda").string());
    check(bool(stage) && stage->GetPrimAtPath(SdfPath(light)), "Game-facing mod must contain unsaved replacements");
    check(!stage->GetPrimAtPath(SdfPath("/RootNode/instances")), "Game mod must exclude captured geometry");
    check(stage->GetRootLayer()->GetCustomLayerData().count("custom_opinion"), "Workfile opinions must survive publication");
    check(!stage->GetRootLayer()->GetCustomLayerData().count("remix_studio_captures"), "Game mod must exclude the capture catalog");
    check(stage->GetRootLayer()->GetSubLayerOffsets()[0] == SdfLayerOffset(3, 2), "Publication must preserve layer offsets");
    auto published_mesh = stage->GetPrimAtPath(SdfPath(mesh_path + "/triangle"));
    SdfAssetPath texture, module;
    check(published_mesh && published_mesh.GetAttribute(TfToken("texture")).Get(&texture), "Referenced mesh must compose through the link");
    check(fs::equivalent(texture.GetResolvedPath(), directory / "external/textures/color.dds"), "Published texture must point to original data");
    check(fs::is_symlink(texture.GetResolvedPath()), "Live textures must be symlinked rather than copied");
    published_mesh.GetAttribute(TfToken("module")).Get(&module);
    check(fs::is_symlink(fs::path(module.GetResolvedPath()).parent_path() / "nvidia/common.mdl"), "MDL sibling imports must keep their layout");
    check(text(project) == root_before && text(project.parent_path() / "mod.usda") == mod_before && text(capture) == capture_before,
      "Live publication must not save the project or alter captures");
    check(doc.revision() == revision && doc.describe()["dirty"] && editor::layer_text(doc.stage()->GetEditTarget().GetLayer()) == authored,
      "Live publication must preserve revision, dirty state and authoring contents");
    for (const auto& layer : stage->GetUsedLayers()) if (!layer->IsAnonymous()) {
      check(layer->GetRealPath().find(".publish-") == std::string::npos, "Published layers must not depend on staging files");
      auto content = editor::layer_text(layer);
      check(content.find(directory.string()) == std::string::npos, "USD asset paths must stay relative for Windows/Wine games");
    }

    auto time_before = fs::last_write_time(target / "mod.usda");
    doc.dispatch({{"op", "transform"}, {"path", light}, {"translation", {9, 8, 7}}});
    doc.dispatch({{"op", "game_sync"}}); stage->Reload();
    GfMatrix4d transform; bool reset = false;
    UsdGeomXformable(stage->GetPrimAtPath(SdfPath(light))).GetLocalTransformation(&transform, &reset);
    check(transform.ExtractTranslation() == GfVec3d(9, 8, 7), "Committed transforms must publish to the game");
    check(fs::last_write_time(target / "mod.usda") > time_before, "Each publication must notify Remix's root-file watcher");
    doc.undo(); doc.dispatch({{"op", "game_sync"}}); stage->Reload();
    UsdGeomXformable(stage->GetPrimAtPath(SdfPath(light))).GetLocalTransformation(&transform, &reset);
    check(transform.ExtractTranslation() == GfVec3d(1, 2, 3), "Undo history must remain functional after publication");
    doc.redo(); doc.dispatch({{"op", "game_sync"}});
    const auto last_good = text(target / "mod.usda");
    fs::rename(directory / "external/textures/color.dds", directory / "external/textures/hidden.dds");
    rejects([&] { doc.dispatch({{"op", "game_sync"}}); }, "Missing dependencies must fail publication");
    check(text(target / "mod.usda") == last_good, "Failed publication must retain the last complete root");
    fs::rename(directory / "external/textures/hidden.dds", directory / "external/textures/color.dds");

    doc.save();
    editor::Document reopened; reopened.open(project);
    check(reopened.dispatch({{"op", "game_link_status"}})["connected"], "Link settings must persist across sessions");
    reopened.dispatch({{"op", "game_sync"}});
    reopened.dispatch({{"op", "game_unlink"}});
    check(!fs::exists(fs::symlink_status(target)) && fs::exists(live / "mod.usda") && fs::exists(project), "Unlink must remove only the shortcut");
    check(!reopened.dispatch({{"op", "game_link_status"}})["linked"].get<bool>(), "Unlink must clear remembered settings");

    auto link_to = [&](std::string name) { return reopened.dispatch({{"op", "game_link"}, {"folder", target.parent_path().string()}, {"name", name}}); };
    fs::create_directory(target); std::ofstream(target / "keep.txt") << "existing mod";
    rejects([&] { link_to("My live mod"); }, "Existing mod directories must never be replaced");
    check(text(target / "keep.txt") == "existing mod", "Collision must preserve the existing mod");
    fs::create_directory_symlink(directory / "missing", target.parent_path() / "broken");
    rejects([&] { link_to("broken"); }, "Dangling foreign symlinks must never be replaced");
    rejects([&] { link_to("../escape"); }, "Mod names must not escape the mods folder");
    link_to("another");
    auto another = target.parent_path() / "another";
    fs::remove(another); fs::create_directory(another); std::ofstream(another / "keep.txt") << "foreign";
    rejects([&] { reopened.dispatch({{"op", "game_sync"}}); }, "Lost links must not write into a replacement directory");
    reopened.dispatch({{"op", "game_unlink"}});
    check(text(another / "keep.txt") == "foreign", "Unlink must leave a replaced destination untouched");
    link_to("last"); fs::remove(target.parent_path() / "last");
    check(!reopened.dispatch({{"op", "game_link_status"}})["connected"].get<bool>(), "Missing links must be reported");
    reopened.dispatch({{"op", "game_unlink"}});
    // Neighboring mods and a legacy base-mod choice must not affect publication.
    const auto neighbor = target.parent_path() / "base_mod/mod.usda";
    fs::create_directories(neighbor.parent_path());
    std::ofstream(neighbor) << "An unrelated mod; do not load or rewrite it";
    const auto independent = link_to("z_independent");
    const auto independent_target = fs::path(independent["target"].get<std::string>());
    const auto alias = target.parent_path() / "old_owned_alias";
    fs::create_directory_symlink(live, alias);
    const auto settings = fs::path(project.string() + ".studio-link.json");
    std::ofstream(settings) << Json{{"version", 1}, {"target", independent_target.string()},
      {"base_mod", neighbor.string()}, {"aliases", Json::array({alias.string(), neighbor.parent_path().string()})}}.dump();
    auto status = reopened.dispatch({{"op", "game_sync"}});
    check(status["target"] == independent_target.string() && !status.contains("base_mod") && !status.contains("mods"),
      "Publishing must keep the chosen destination and ignore removed base-mod settings");
    reopened.package(directory / "independent-package");
    check(text(neighbor) == "An unrelated mod; do not load or rewrite it", "Other mods must remain untouched");
    reopened.dispatch({{"op", "game_unlink"}});
    check(!fs::exists(alias) && !fs::exists(independent_target) && fs::exists(neighbor),
      "Unlink must safely clean up old owned aliases without removing neighboring mods");
    check(errors.IsClean(), "Game link workflow emitted USD errors");
    fs::remove_all(directory);
    std::cout << "Game link workflows passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << "\nFixtures retained at " << directory << '\n'; return 1;
  }
}
