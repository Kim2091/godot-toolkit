#include "document.h"
#include <chrono>
#include <fstream>
#include <iostream>
#include <pxr/base/tf/errorMark.h>
#include <pxr/usd/usdGeom/xformCache.h>

PXR_NAMESPACE_USING_DIRECTIVE
namespace fs = std::filesystem;
using editor::Json;
namespace {
const std::string anchor = "/RootNode/meshes/mesh_0123456789ABCDEF";
const std::string instance = "/RootNode/instances/inst_0123456789ABCDEF_1";
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
std::string text(const fs::path& path) { std::ifstream file(path); return {std::istreambuf_iterator<char>(file), {}}; }
std::string command(editor::Document& doc, const Json& request) { return doc.dispatch(request).value("selection", ""); }
GfMatrix4d world(editor::Document& doc, const std::string& path) {
  return UsdGeomXformCache().GetLocalToWorldTransform(doc.stage()->GetPrimAtPath(SdfPath(path)));
}
void run(const fs::path& directory, bool referenced, bool legacy, bool upgrade = false) {
  fs::create_directories(directory);
  const auto capture = directory / "capture.usda", asset = directory / "asset.usda", project = directory / "project/work.usda";
  fs::copy_file(fs::path(FIXTURE_DIR) / "capture.usda", capture);
  fs::copy_file(fs::path(FIXTURE_DIR) / "replacement.usda", asset);
  const auto geometry = referenced ? "/triangle" : "/mesh";
  if (referenced) {
    auto source = UsdStage::Open(capture.string());
    source->RemovePrim(SdfPath(anchor + "/mesh"));
    source->GetPrimAtPath(SdfPath(anchor)).GetReferences().AddReference("asset.usda");
    source->GetRootLayer()->Save();
  }
  const auto original_capture = text(capture), original_asset = text(asset);
  editor::Document doc; doc.create(capture, project);
  auto layer = doc.stage()->GetEditTarget().GetLayer();
  check(!doc.inspect(instance + geometry).contains("mesh_replacement"), "Original capture must not offer revert");
  doc.dispatch({{"op", "transform"}, {"path", instance + geometry}, {"translation", {0, 2, 0}}});
  // Strong pre-existing active opinions and hidden siblings must survive revert.
  doc.stage()->GetPrimAtPath(SdfPath(anchor + geometry)).SetActive(true);
  doc.stage()->OverridePrim(SdfPath(anchor + "/unused")).SetActive(false);
  const auto original_world = world(doc, instance + geometry);
  const auto added = command(doc, {{"op", "add_mesh"}, {"path", instance + geometry}, {"asset", asset.string()}});
  const auto light = command(doc, {{"op", "add_light"}, {"path", instance + geometry}, {"translation", {2, 3, 4}}});
  const auto light_world = world(doc, light);
  const auto replaced = command(doc, {{"op", "replace_mesh"}, {"path", instance + geometry}, {"asset", asset.string()}});
  check(doc.scene()["meshes"].size() == 4, "Original should be suppressed, with added and replacement geometry retained");
  check(doc.inspect(replaced + "/triangle").contains("mesh_replacement"), "Picking imported geometry must expose revert");
  check(!doc.inspect(added).contains("mesh_replacement") && !doc.inspect(light).contains("mesh_replacement"), "Independent attachments must not offer revert");
  // A light parented inside the replacement must also survive at the same pose.
  const auto nested = command(doc, {{"op", "set_parent"}, {"path", command(doc, {{"op", "add_light"}, {"name", "NestedLight"}, {"translation", {7, 8, 9}}})}, {"parent", replaced + "/triangle"}});
  const auto nested_world = world(doc, nested);
  check(!doc.inspect(nested).contains("mesh_replacement"), "Nested lights must not offer to revert their parent mesh");
  if (legacy) {
    doc.stage()->GetPrimAtPath(SdfPath(anchor)).ClearCustomDataByKey(TfToken("remixStudioMeshRestore"));
    for (const auto& path : {added, replaced}) {
      const auto authored = doc.inspect(path)["authoring"]["edit_path"].get<std::string>();
      doc.stage()->GetPrimAtPath(SdfPath(authored)).ClearCustomDataByKey(TfToken("remixStudioMeshReplacement"));
    }
  } else {
    command(doc, {{"op", "replace_mesh"}, {"path", replaced}, {"asset", asset.string()}});
    check(doc.inspect(instance)["mesh_replacement"]["references"].size() == 2, "Repeated replacements must retain a single restore record");
  }
  if (upgrade) command(doc, {{"op", "replace_mesh"}, {"path", replaced + "/triangle"}, {"asset", asset.string()}});
  doc.save();
  editor::Document reopened; reopened.open(project);
  check(reopened.inspect(replaced + "/triangle").contains("mesh_replacement"), "Revert must work after reopening, including legacy projects");
  auto active_layer = reopened.stage()->GetEditTarget().GetLayer();
  const auto before = editor::layer_text(active_layer);
  const auto revision = reopened.revision();
  const auto result = reopened.dispatch({{"op", "revert_mesh"}, {"path", replaced + "/triangle"}});
  check(reopened.revision() == revision + 1 && result["scene_update"] == "full", "Revert must be one undoable scene update");
  check(result["selection"] == instance + geometry, "Restored selection must stay in the visible capture instance");
  check(reopened.scene()["meshes"].size() == 4, "Revert must restore both captured instances and retain added meshes");
  check(GfIsClose(world(reopened, instance + geometry), original_world, 1e-6), "Capture mesh edits must survive reverting");
  check(GfIsClose(world(reopened, light), light_world, 1e-6), "Sibling light must keep its pose");
  check(GfIsClose(world(reopened, instance + "/" + SdfPath(nested).GetName()), nested_world, 1e-6), "Nested light must keep its pose after reparenting");
  check(!active_layer->GetPrimAtPath(SdfPath(anchor + "/" + SdfPath(replaced).GetName())), "Replacement spec must be removed");
  int preserve = 0; reopened.stage()->GetPrimAtPath(SdfPath(anchor)).GetAttribute(TfToken("preserveOriginalDrawCall")).Get(&preserve);
  check(preserve == 1, "Game publication must restore the original draw call");
  if (!legacy) {
    check(active_layer->GetPrimAtPath(SdfPath(anchor + geometry))->HasActive(), "Pre-existing active opinion must be restored");
    check(!reopened.stage()->GetPrimAtPath(SdfPath(anchor + "/unused")).IsActive(), "Unrelated hidden sibling must stay hidden");
    check(!reopened.inspect(instance + geometry).contains("mesh_replacement"), "Button must disappear after reverting");
  }
  const auto after = editor::layer_text(active_layer);
  reopened.undo(); check(editor::layer_text(active_layer) == before, "Undo must restore the exact replacement and nested attachments");
  reopened.redo(); check(editor::layer_text(active_layer) == after, "Redo must exactly restore the reverted layer");
  reopened.save(); reopened.open(project);
  check(reopened.scene()["meshes"].size() == 4, "Reverted geometry must survive save/reopen");
  reopened.package(directory / "package");
  auto packaged = UsdStage::Open((directory / "package/mod.usda").string());
  preserve = 0; packaged->GetPrimAtPath(SdfPath(anchor)).GetAttribute(TfToken("preserveOriginalDrawCall")).Get(&preserve);
  check(preserve == 1 && !packaged->GetPrimAtPath(SdfPath(anchor + "/" + SdfPath(replaced).GetName())), "Published mod must restore the game mesh and remove the replacement");
  check(text(capture) == original_capture && text(asset) == original_asset, "Reverting must never modify capture or ingested asset files");
}

void deleted_replacement(const fs::path& directory) {
  editor::Document doc;
  doc.create(fs::path(FIXTURE_DIR) / "capture.usda", directory / "work.usda");
  const auto replacement = command(doc, {{"op", "replace_mesh"}, {"path", instance + "/mesh"},
    {"asset", (fs::path(FIXTURE_DIR) / "replacement.usda").string()}});
  const auto layer = doc.stage()->GetEditTarget().GetLayer();
  doc.dispatch({{"op", "select_layer"}, {"layer", doc.stage()->GetRootLayer()->GetIdentifier()}});
  check(!doc.inspect(replacement).contains("mesh_replacement"), "A different active layer must not offer to erase this replacement");
  const auto before = editor::layer_text(layer);
  bool rejected = false;
  try { doc.dispatch({{"op", "revert_mesh"}, {"path", replacement}}); } catch (const std::exception&) { rejected = true; }
  check(rejected && editor::layer_text(layer) == before, "Wrong-layer revert must reject without modifying the replacement");
  doc.dispatch({{"op", "select_layer"}, {"layer", layer->GetIdentifier()}});
  command(doc, {{"op", "delete"}, {"path", replacement}});
  check(doc.inspect(instance).contains("mesh_replacement"), "Hash root must offer restore even after deleting the replacement");
  check(command(doc, {{"op", "revert_mesh"}, {"path", instance}}) == instance + "/mesh", "Deleted replacement must still restore original geometry");
  check(doc.scene()["meshes"].size() == 2, "Restoration must update all instances");
  check(!layer->GetPrimAtPath(SdfPath(anchor + "/mesh"))->HasActive(), "Restore must remove the suppression rather than force an active override");
  const auto next = command(doc, {{"op", "replace_mesh"}, {"path", instance + "/mesh"},
    {"asset", (fs::path(FIXTURE_DIR) / "replacement.usda").string()}});
  const auto moved = command(doc, {{"op", "set_parent"}, {"path", next}, {"parent", ""}});
  const auto moved_world = world(doc, moved);
  command(doc, {{"op", "revert_mesh"}, {"path", instance}});
  check(GfIsClose(world(doc, moved), moved_world, 1e-6), "Detached replacement must survive restoring its original capture");
  check(doc.scene()["meshes"].size() == 3, "Detached mesh must remain as a standalone asset");
}
}
int main() {
  const auto directory = fs::temp_directory_path() / ("remix-mesh-revert-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  try {
    TfErrorMark errors;
    run(directory / "inline", false, false);
    run(directory / "referenced", true, false);
    run(directory / "legacy-inline", false, true);
    run(directory / "legacy-referenced", true, true);
    run(directory / "upgraded-legacy", true, true, true);
    deleted_replacement(directory / "deleted");
    check(errors.IsClean(), "Mesh reversion emitted USD errors");
    fs::remove_all(directory);
    std::cout << "Mesh replacement reversion passed\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << "\nFixtures: " << directory << '\n'; return 1; }
}
