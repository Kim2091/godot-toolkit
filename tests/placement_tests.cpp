#include "document.h"
#include <chrono>
#include <fstream>
#include <iostream>
#include <pxr/base/gf/rotation.h>
#include <pxr/base/tf/errorMark.h>
#include <pxr/usd/usdGeom/xform.h>
#include <pxr/usd/usdGeom/xformCache.h>

using editor::Json;
namespace fs = std::filesystem;
PXR_NAMESPACE_USING_DIRECTIVE
namespace {
void check(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
std::string text(const fs::path& path) { std::ifstream file(path); return {std::istreambuf_iterator<char>(file), {}}; }
GfMatrix4d world(editor::Document& doc, const std::string& path) {
  return UsdGeomXformCache().GetLocalToWorldTransform(doc.stage()->GetPrimAtPath(SdfPath(path)));
}
Json matrix(const GfMatrix4d& value) {
  Json result = Json::array();
  for (int r = 0; r < 4; ++r) for (int c = 0; c < 4; ++c) result.push_back(value[r][c]);
  return result;
}
void same(const GfMatrix4d& actual, const GfMatrix4d& expected, const char* message) {
  check(GfIsClose(actual, expected, 1e-7), message);
}
}
int main() {
  const auto root = fs::temp_directory_path() / ("remix-placement-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  fs::create_directories(root);
  try {
    TfErrorMark errors;
    const auto capture = fs::path(FIXTURE_DIR) / "capture.usda";
    const auto original = text(capture);
    editor::Document doc; doc.create(capture, root / "project.usda");
    const std::string instance = "/RootNode/instances/inst_0123456789ABCDEF_1";
    const std::string mesh = instance + "/mesh";
    auto selected = [&](const Json& request) { return doc.dispatch(request)["selection"].get<std::string>(); };
    auto parent = [&](const std::string& path, const std::string& target) {
      return selected({{"op", "set_parent"}, {"path", path}, {"parent", target}});
    };
    // Exercise rotated, nonuniformly scaled captured parents and a transformed scene root.
    auto scale = GfMatrix4d(1); scale.SetScale(GfVec3d(2, 3, 4));
    auto transformed_parent = scale * GfMatrix4d(GfRotation(GfVec3d(0, 1, 0), 40), GfVec3d(4, 2, 1));
    UsdGeomXformable(doc.stage()->GetPrimAtPath(SdfPath(instance))).MakeMatrixXform().Set(transformed_parent);
    UsdGeomXformable(doc.stage()->GetPrimAtPath(SdfPath("/RootNode"))).MakeMatrixXform().Set(GfMatrix4d(1).SetTranslate(GfVec3d(10, 0, 0)));
    auto light = selected({{"op", "add_light"}, {"type", "SpotLight"}, {"translation", {1, 2, 3}}});
    check(doc.inspect(light)["attachment"]["parent"] == "", "New lights must be unattached");
    check(world(doc, light).ExtractTranslation() == GfVec3d(1, 2, 3), "Standalone spawn coordinates must be world coordinates");
    check(doc.scene()["lights"].size() == 1, "Standalone light must appear only once");
    const auto pose = world(doc, light);
    const auto standalone = light;
    light = parent(light, instance);
    same(world(doc, light), pose, "Attaching to a transformed capture instance must preserve world pose");
    check(doc.inspect(light)["attachment"]["parent"] == instance, "Inspector must identify the selected instance as parent");
    check(doc.scene()["lights"].size() == 2, "Capture attachment must compose into matching instances");
    check(!doc.stage()->GetPrimAtPath(SdfPath(standalone)), "Reparent must remove the original standalone object");
    doc.undo(); same(world(doc, standalone), pose, "Attachment undo must restore the standalone pose");
    doc.redo(); same(world(doc, light), pose, "Attachment redo must restore world pose");
    auto duplicate = selected({{"op", "duplicate"}, {"path", light}});
    check(doc.inspect(duplicate)["attachment"]["parent"] == instance, "Duplicate must inherit the selected light's parent");
    same(world(doc, duplicate), pose, "Duplicate must inherit its full local transform");
    check(doc.scene()["lights"].size() == 4, "Duplicated attachment must be shared across capture instances");
    auto moved = pose * GfMatrix4d(GfRotation(GfVec3d(1, 0, 0), 25), GfVec3d(2, 3, 4));
    doc.dispatch({{"op", "transform"}, {"path", light}, {"world_matrix", matrix(moved)}});
    same(world(doc, light), moved, "World gizmo transform must account for the selected instance parent");
    doc.undo(); same(world(doc, light), pose, "A gizmo transform must undo in one step");
    UsdGeomXformable(doc.stage()->GetPrimAtPath(SdfPath("/RootNode/meshes/mesh_0123456789ABCDEF/mesh"))).MakeMatrixXform().Set(
      GfMatrix4d(GfRotation(GfVec3d(0, 1, 0), 15), GfVec3d(7, 8, 9)));
    light = parent(light, mesh);
    same(world(doc, light), pose, "Attaching to a captured mesh child must keep the world pose");
    check(SdfPath(light).GetParentPath() == SdfPath(instance), "Picking capture geometry must attach to its draw-call root, not its mesh child");
    light = parent(light, "");
    same(world(doc, light), pose, "Detaching must keep world pose under a transformed scene root");
    check(doc.scene()["lights"].size() == 3, "Detach removes all shared copies of only that attachment");
    auto reference = selected({{"op", "add_mesh"}, {"asset", (fs::path(FIXTURE_DIR) / "replacement.usda").string()}, {"translation", {5, 6, 7}}});
    check(doc.inspect(reference)["attachment"]["parent"] == "", "Meshes must spawn without a selected captured prim");
    check(world(doc, reference).ExtractTranslation() == GfVec3d(5, 6, 7), "Standalone mesh must spawn at the world position");
    check(doc.inspect(reference + "/triangle")["attachment"]["path"] == reference, "Selecting referenced geometry must expose its authored owner's parent");
    const auto mesh_pose = world(doc, reference);
    reference = parent(reference + "/triangle", instance);
    same(world(doc, reference), mesh_pose, "Parenting referenced geometry must move the whole asset without changing its pose");
    auto mesh_copy = selected({{"op", "duplicate"}, {"path", reference + "/triangle"}});
    check(doc.inspect(mesh_copy)["attachment"]["parent"] == instance, "Duplicating referenced geometry must preserve its attachment");
    auto child = parent(light, reference + "/triangle");
    same(world(doc, child), pose, "An authored mesh may serve as a parent");
    const auto before = editor::layer_text(doc.stage()->GetEditTarget().GetLayer());
    const auto revision = doc.revision();
    for (const auto& invalid : {reference, reference + "/triangle", child}) {
      bool rejected = false;
      try { parent(reference, invalid); } catch (const std::exception&) { rejected = true; }
      check(rejected && editor::layer_text(doc.stage()->GetEditTarget().GetLayer()) == before && doc.revision() == revision,
        "Self and descendant attachments must fail without editing the document");
    }
    for (auto candidate : doc.dispatch({{"op", "parent_candidates"}, {"path", reference}})["parents"]) {
      const auto path = candidate["path"].get<std::string>();
      const auto name = SdfPath(reference).GetName();
      check(path.find("/" + name + "/") == std::string::npos && SdfPath(path).GetName() != name,
        "Parent picker must exclude self and descendants across all instances");
    }
    auto singular = UsdGeomXform::Define(doc.stage(), SdfPath("/RootNode/Singular"));
    singular.MakeMatrixXform().Set(GfMatrix4d(1).SetScale(GfVec3d(0, 1, 1)));
    bool rejected = false;
    try { parent(child, "/RootNode/Singular"); } catch (const std::exception&) { rejected = true; }
    check(rejected, "Singular parents must not corrupt an object's transform");
    doc.save();
    editor::Document reopened; reopened.open(root / "project.usda");
    same(world(reopened, child), pose, "Parent attachments must survive save and reopen");
    check(reopened.inspect(duplicate)["attachment"]["parent"] == instance, "Duplicate parent must persist");
    doc.package(root / "package");
    auto packaged = UsdStage::Open((root / "package/mod.usda").string());
    const auto published = SdfPath(child).ReplacePrefix(SdfPath(instance), SdfPath("/RootNode/meshes/mesh_0123456789ABCDEF"));
    check(packaged->GetPrimAtPath(published).IsDefined(), "Attachments must remain defined when capture layers are absent");
    const auto root_prim = packaged->GetPrimAtPath(SdfPath("/RootNode/meshes/mesh_0123456789ABCDEF"));
    bool reset = false;
    auto local = UsdGeomXformCache().ComputeRelativeTransform(packaged->GetPrimAtPath(published), root_prim, &reset);
    same(local * world(doc, instance), pose, "Runtime draw-call transform must reconstruct the visible attachment pose");
    check(text(capture) == original, "Placement must leave the capture untouched");
    check(errors.IsClean(), "Placement emitted USD errors");
    fs::remove_all(root);
    std::cout << "Placement tests passed\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << "\nFixtures: " << root << '\n'; return 1; }
}
