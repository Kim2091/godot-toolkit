#include "document.h"
#include <chrono>
#include <fstream>
#include <iostream>
#include <pxr/base/gf/rotation.h>
#include <pxr/base/tf/errorMark.h>
#include <pxr/usd/usdGeom/metrics.h>
#include <pxr/usd/usdGeom/xform.h>
#include <pxr/usd/usdGeom/xformCache.h>

PXR_NAMESPACE_USING_DIRECTIVE
namespace fs = std::filesystem;
using editor::Json;
namespace {
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
std::string text(const fs::path& path) { std::ifstream file(path); return {std::istreambuf_iterator<char>(file), {}}; }
Json elements(const GfMatrix4d& matrix) {
  Json result = Json::array();
  for (int r = 0; r < 4; ++r) for (int c = 0; c < 4; ++c) result.push_back(matrix[r][c]);
  return result;
}
GfMatrix4d matrix(const Json& values) {
  GfMatrix4d result(1);
  for (int r = 0; r < 4; ++r) for (int c = 0; c < 4; ++c) result[r][c] = values[r * 4 + c];
  return result;
}
GfMatrix4d world(editor::Document& doc, const std::string& path) {
  return UsdGeomXformCache().GetLocalToWorldTransform(doc.stage()->GetPrimAtPath(SdfPath(path)));
}
void same(const GfMatrix4d& actual, const GfMatrix4d& expected, const char* message) {
  check(GfIsClose(actual, expected, 1e-5), message);
}
void texture_paths(const fs::path& root) {
  const auto model = root / "source/model.fbx";
  fs::create_directories(model.parent_path() / "Textures");
  fs::create_directories(root / "mdl");
  std::ofstream(root / "mdl/AperturePBR_Opacity.mdl") << "mdl 1.6;";
  std::ofstream(model.parent_path() / "Textures/color map.png") << "expected albedo";
  const auto fixture = text(fs::path(FIXTURE_DIR) / "textured_model.fbx");
  int converted = 0;
  auto convert = [&](const fs::path& source, const fs::path& destination, const std::string& kind) {
    check(text(source) == "expected albedo" && kind == "color", "FBX must resolve the intended texture before converting it");
    fs::copy_file(source, destination); ++converted;
  };
  int index = 0;
  for (const auto& texture : {std::string("Textures\\color map.png"), std::string("Textures/color map.png"),
                            (model.parent_path() / "Textures/color map.png").string()}) {
    auto contents = fixture;
    const std::string original = "Textures\\color map.png";
    size_t position = 0;
    while ((position = contents.find(original, position)) != std::string::npos) {
      contents.replace(position, original.size(), texture); position += texture.size();
    }
    std::ofstream(model) << contents;
    const auto before = converted;
    auto imported = editor::ingest_asset({{"source", model.string()}, {"name", "fbx_" + std::to_string(index++)},
      {"mdl_directory", (root / "mdl").string()}}, root / "project", convert);
    check(converted == before + 1, "FBX regression fixture must contain one diffuse texture");
    auto asset = UsdStage::Open(imported["asset"].get<std::string>());
    auto scene = editor::compose_scene(asset, 0);
    check(scene["meshes"].size() == 1 && scene["materials"].size() == 1, "Textured FBX must produce geometry and a material");
    check(fs::is_regular_file(scene["materials"][0]["albedo_texture"].get<std::string>()), "Converted texture must resolve from the ingested USD");
    check(std::abs(matrix(scene["meshes"][0]["transform"]).ExtractTranslation()[0] - 2) < 1e-6,
      "FBX import must convert the 200 cm node translation to two meters");
  }
  fs::remove(model.parent_path() / "Textures/color map.png");
  bool rejected = false;
  try { editor::ingest_asset({{"source", model.string()}, {"name", "missing"}, {"mdl_directory", (root / "mdl").string()}}, root / "project", convert); }
  catch (const std::exception& error) { rejected = std::string(error.what()).find("Missing model texture:") != std::string::npos; }
  check(rejected && !fs::exists(root / "project/assets/.missing.ingesting"), "Missing textures must fail cleanly without leaving a partial asset");
}
void references(const fs::path& root) {
  fs::create_directories(root);
  const auto capture = root / "capture.usda";
  const auto asset = root / "asset.usda";
  fs::copy_file(fs::path(FIXTURE_DIR) / "capture.usda", capture);
  fs::copy_file(fs::path(FIXTURE_DIR) / "replacement.usda", asset);
  const std::string instance = "/RootNode/instances/inst_0123456789ABCDEF_1";
  const std::string anchor = "/RootNode/meshes/mesh_0123456789ABCDEF";
  auto captured = UsdStage::Open(capture.string());
  UsdGeomSetStageMetersPerUnit(captured, 0.01);
  UsdGeomSetStageUpAxis(captured, UsdGeomTokens->z);
  const auto parent = GfMatrix4d(1).SetScale(GfVec3d(2, 3, 4)) *
    GfMatrix4d(GfRotation(GfVec3d::ZAxis(), 35), GfVec3d(700, -500, 120));
  UsdGeomXformable(captured->GetPrimAtPath(SdfPath(instance))).MakeMatrixXform().Set(parent);
  captured->GetRootLayer()->Save();
  auto source = UsdStage::Open(asset.string());
  const auto imported_root = GfMatrix4d(1).SetScale(0.01) *
    GfMatrix4d(GfRotation(GfVec3d::YAxis(), 20), GfVec3d(2, 3, 4));
  UsdGeomXformable(source->GetDefaultPrim()).MakeMatrixXform().Set(imported_root);
  const auto child = GfMatrix4d(1).SetTranslate(GfVec3d(200, 0, 0));
  UsdGeomXformable(source->GetPrimAtPath(SdfPath("/ReferenceTarget/triangle"))).MakeMatrixXform().Set(child);
  source->GetRootLayer()->Save();
  const auto original_capture = text(capture), original_asset = text(asset);
  const auto normalization = GfMatrix4d(1).SetScale(100) * GfMatrix4d(GfRotation(GfVec3d::XAxis(), 90), GfVec3d(0));
  editor::Document doc; doc.create(capture, root / "project/project.usda");
  auto add = [&](const Json& request) { return doc.dispatch(request)["selection"].get<std::string>(); };
  const auto standalone = add({{"op", "add_mesh"}, {"asset", asset.string()}});
  same(world(doc, standalone + "/triangle"), child * imported_root * normalization,
    "Added meshes must retain their imported root transform and project normalization");
  const auto attached = add({{"op", "add_mesh"}, {"path", instance + "/mesh"}, {"asset", asset.string()}});
  check(SdfPath(attached).GetParentPath() == SdfPath(instance), "Added attachment selection must use the visible instance");
  same(world(doc, attached + "/triangle"), child * imported_root * normalization * parent, "Attached mesh transform is incorrect");
  const auto replaced = add({{"op", "replace_mesh"}, {"path", instance + "/mesh"}, {"asset", asset.string()}});
  check(SdfPath(replaced).GetParentPath() == SdfPath(instance), "Replacement must select its visible instance for the gizmo");
  same(world(doc, replaced + "/triangle"), world(doc, attached + "/triangle"), "Replacing and adding must compose the same asset transform");
  check(!doc.stage()->GetPrimAtPath(SdfPath(instance + "/mesh")).IsActive(), "Replacement must suppress original capture geometry");
  const auto pose = world(doc, replaced);
  same(matrix(doc.inspect(replaced)["world_transform"]), pose, "Gizmo must inspect the visible replacement transform");
  auto moved = pose; moved.SetTranslateOnly(GfVec3d(42, 51, 63));
  doc.dispatch({{"op", "transform"}, {"path", replaced}, {"world_matrix", elements(moved)}});
  same(world(doc, replaced), moved, "Replacement gizmo movement must account for the capture instance");
  same(world(doc, replaced + "/triangle"), child * moved, "Visible geometry must follow the replacement gizmo");
  doc.undo(); same(world(doc, replaced), pose, "Mesh movement undo lost its transform");
  doc.redo(); same(world(doc, replaced), moved, "Mesh movement redo lost its transform");
  const auto authored = doc.inspect(replaced)["authoring"]["edit_path"].get<std::string>();
  check(!doc.stage()->GetEditTarget().GetLayer()->GetPrimAtPath(SdfPath(instance)), "Replacement must not author capture instance overrides");
  doc.save();
  editor::Document reopened; reopened.open(root / "project/project.usda");
  same(world(reopened, replaced + "/triangle"), child * moved, "Replacement pose must survive save/reopen");
  doc.package(root / "package");
  auto packaged = UsdStage::Open((root / "package/mod.usda").string());
  bool reset = false;
  const auto relative = UsdGeomXformCache().ComputeRelativeTransform(packaged->GetPrimAtPath(SdfPath(authored + "/triangle")),
    packaged->GetPrimAtPath(SdfPath(anchor)), &reset);
  same(relative * parent, child * moved, "Packaged replacement must reconstruct the visible pose using the game draw call");
  check(text(capture) == original_capture && text(asset) == original_asset, "Referencing must never modify the capture or asset");
}
}
int main() {
  const auto root = fs::temp_directory_path() / ("remix-model-import-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  try {
    TfErrorMark errors;
    texture_paths(root / "textures");
    references(root / "references");
    check(errors.IsClean(), "Model ingestion/replacement emitted USD errors");
    fs::remove_all(root);
    std::cout << "Model texture paths and replacement transforms passed\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << "\nFixtures: " << root << '\n'; return 1; }
}
