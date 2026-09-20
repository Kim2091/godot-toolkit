#include "document.h"
#include <fstream>
#include <iostream>
#include <chrono>
#include <pxr/base/tf/errorMark.h>
#include <pxr/usd/usdGeom/xformable.h>
#include <pxr/usd/usdShade/material.h>
#include <pxr/usd/usdShade/shader.h>

using editor::Json;
namespace fs = std::filesystem;
PXR_NAMESPACE_USING_DIRECTIVE
namespace {
void check(bool condition, const std::string& message) { if (!condition) throw std::runtime_error(message); }
template<class Function> void rejects(Function function, const std::string& label) {
  bool rejected = false;
  try { function(); } catch (const std::exception&) { rejected = true; }
  check(rejected, label);
}
std::string text(const fs::path& path) {
  std::ifstream input(path); return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}
void material_sampling(const fs::path& root) {
  editor::Document document;
  document.create(fs::path(FIXTURE_DIR) / "capture.usda", root / "sampling/project.usda");
  auto check_modes = [&](int filter, int u, int v) {
    const auto material = document.scene()["materials"][0];
    check(material["filter_mode"] == filter && material["wrap_mode_u"] == u && material["wrap_mode_v"] == v,
      "Material sampling must preserve authored modes or use Remix's linear/repeat defaults");
  };
  check_modes(1, 1, 1);
  auto shader = UsdShadeShader(document.stage()->GetPrimAtPath(SdfPath("/RootNode/Looks/mat_0123456789ABCDEF/Shader")));
  auto filter = shader.CreateInput(TfToken("filter_mode"), SdfValueTypeNames->UInt).GetAttr();
  auto u = shader.CreateInput(TfToken("wrap_mode_u"), SdfValueTypeNames->UInt).GetAttr();
  auto v = shader.CreateInput(TfToken("wrap_mode_v"), SdfValueTypeNames->Int).GetAttr();
  filter.Set(0u); u.Set(2u); v.Set(0); // Nearest, mirrored U, clamped V.
  check_modes(0, 2, 0);
  filter.Set(1u); u.Set(0u); v.Set(3); // Linear, clamped U, clipped V.
  check_modes(1, 0, 3);
  filter.Set(2u); u.Set(4u); v.Set(-1);
  check_modes(1, 1, 1);
  filter.Block(); u.Block(); v.Block();
  check_modes(1, 1, 1);
}
void texture_resolution(const fs::path& root) {
  const auto directory = root / "texture_paths";
  fs::create_directories(directory / "reference/materials");
  fs::create_directories(directory / "reference/textures");
  fs::create_directories(directory / "project/maps");
  for (const auto& path : {directory / "reference/textures/diffuse map.dds", directory / "reference/textures/normal.dds", directory / "project/maps/override.dds"})
    std::ofstream(path) << "Texture resolution fixture";

  const auto material_file = directory / "reference/materials/material.usda";
  auto source = UsdStage::CreateNew(material_file.string());
  auto material = UsdShadeMaterial::Define(source, SdfPath("/Material"));
  source->SetDefaultPrim(material.GetPrim());
  auto shader = UsdShadeShader::Define(source, SdfPath("/Material/Shader"));
  shader.CreateInput(TfToken("diffuse_texture"), SdfValueTypeNames->Asset).Set(SdfAssetPath("..\\textures\\diffuse map.dds"));
  shader.CreateInput(TfToken("normalmap_texture"), SdfValueTypeNames->Asset).Set(SdfAssetPath("../textures/normal.dds"));
  source->GetRootLayer()->Save();
  const auto original_material = text(material_file);

  fs::copy_file(fs::path(FIXTURE_DIR) / "capture.usda", directory / "capture.usda");
  auto capture = UsdStage::Open((directory / "capture.usda").string());
  const auto material_path = SdfPath("/RootNode/Looks/mat_0123456789ABCDEF");
  capture->GetPrimAtPath(material_path).GetReferences().AddReference("reference/materials/material.usda");
  capture->GetRootLayer()->Save();
  const auto original_capture = text(directory / "capture.usda");

  editor::Document document;
  document.create(directory / "capture.usda", directory / "project/project.usda");
  auto attr = document.stage()->GetPrimAtPath(material_path.AppendChild(TfToken("Shader"))).GetAttribute(TfToken("inputs:diffuse_texture"));
  // A stronger metadata-only spec must not steal the weaker value's anchor.
  attr.SetDisplayName("Captured diffuse texture");
  auto scene = document.scene();
  check(scene["warnings"].empty(), "Existing capture textures must resolve without warnings");
  check(fs::equivalent(scene["materials"][0]["albedo_texture"].get<std::string>(), directory / "reference/textures/diffuse map.dds"), "Windows paths must resolve against their referenced material layer");
  check(fs::equivalent(scene["materials"][0]["normal_texture"].get<std::string>(), directory / "reference/textures/normal.dds"), "Standard USD-resolved texture paths must remain valid");
  attr.Set(SdfAssetPath(".\\maps\\override.dds"));
  scene = document.scene();
  check(fs::equivalent(scene["materials"][0]["albedo_texture"].get<std::string>(), directory / "project/maps/override.dds"), "Authored overrides must resolve against the edit layer");
  attr.Set(SdfAssetPath(".\\maps\\missing.dds"));
  scene = document.scene();
  check(scene["materials"][0]["albedo_texture"] == "", "A missing strong texture must not fall back to the capture's weaker texture");
  check(scene["warnings"].size() == 1 && scene["warnings"][0].get<std::string>().find("missing.dds") != std::string::npos, "Missing textures must produce a useful scene warning");
  attr.Block();
  scene = document.scene();
  check(scene["materials"][0]["albedo_texture"] == "" && scene["warnings"].empty(), "An explicitly cleared texture is not a missing asset");
  document.save();
  check(text(material_file) == original_material && text(directory / "capture.usda") == original_capture, "Preview path resolution must not rewrite capture assets");
}
}
int main() {
  auto root = fs::temp_directory_path() / ("godot-remix-tests-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  fs::create_directories(root);
  try {
    TfErrorMark usd_errors;
    material_sampling(root);
    texture_resolution(root);
    fs::copy_file(fs::path(FIXTURE_DIR) / "capture.usda", root / "capture.usda");
    fs::copy_file(fs::path(FIXTURE_DIR) / "replacement.usda", root / "replacement.usda");
    const auto original = text(root / "capture.usda");
    editor::Document doc;
    rejects([&] { doc.open(root / "capture.usda"); }, "Opening a capture as an editable project must fail");
    doc.create(root / "capture.usda", root / "project" / "project.usda");
    check(doc.describe()["open"], "Project did not open");
    check(!doc.describe()["dirty"].get<bool>(), "New project should start clean");
    auto scene = doc.scene();
    check(scene["meshes"].size() == 2, "Capture must render two instances, not its hidden prototype");
    check(scene["meshes"][0]["surfaces"][0]["indices"].size() == 6, "Quad must triangulate to two faces");
    const std::string instance = "/RootNode/instances/inst_0123456789ABCDEF_0";
    const std::string anchor = "/RootNode/meshes/mesh_0123456789ABCDEF";
    check(doc.inspect(instance)["anchor"] == anchor, "Instance must resolve to its captured hash anchor");
    auto added = doc.dispatch({{"op", "add_light"}, {"path", instance}, {"type", "SphereLight"}});
    auto light = added["selection"].get<std::string>();
    check(light.rfind(anchor + "/", 0) == 0, "New light must live under replacement hash");
    check(doc.scene()["lights"].size() == 2, "Light must appear on both captured instances");
    check(doc.describe()["dirty"], "Editing must mark project dirty");
    doc.undo(); check(doc.scene()["lights"].empty(), "Undo must remove the authored light");
    check(!doc.describe()["dirty"].get<bool>(), "Undo to saved content must clear dirty state");
    doc.redo(); check(doc.scene()["lights"].size() == 2, "Redo must restore attached lights");
    doc.dispatch({{"op", "transform"}, {"path", instance + "/SphereLight"}, {"translation", {2, 3, 4}}});
    check(doc.inspect(light)["translation"] == Json::array({2.0, 3.0, 4.0}), "Instance selection must edit the shared attachment");
    check(!doc.stage()->GetEditTarget().GetLayer()->GetPrimAtPath(SdfPath(instance)), "Edits must not leak into capture instance paths");
    auto before = editor::layer_text(doc.stage()->GetEditTarget().GetLayer());
    rejects([&] { doc.dispatch({{"op", "batch"}, {"commands", Json::array({
      {{"op", "transform"}, {"path", light}, {"translation", {1, 2, 3}}},
      {{"op", "set_property"}, {"path", light}, {"property", "missing"}, {"value", 0}}
    })}}); }, "Invalid batch must fail");
    check(editor::layer_text(doc.stage()->GetEditTarget().GetLayer()) == before, "Failed edit must roll back all authored opinions");
    doc.dispatch({{"op", "transform"}, {"path", light}, {"translation", {1, 2, 3}}});
    check(doc.inspect(light)["translation"] == Json::array({1.0, 2.0, 3.0}), "Transform was not applied");
    doc.save();
    check(text(root / "capture.usda") == original, "Saving modified the capture");
    check(!doc.describe()["dirty"].get<bool>(), "Save must clear dirty state");
    editor::Document reopened;
    reopened.open(root / "project" / "project.usda");
    check(reopened.scene()["lights"].size() == 2, "Attached lights must survive save/reopen");
    auto imported = doc.ingest({{"source", (root / "replacement.usda").string()}});
    check(fs::exists(imported["asset"].get<std::string>()), "Ingestion must publish a USD asset");
    doc.dispatch({{"op", "add_mesh"}, {"path", instance}, {"asset", imported["asset"]}});
    check(doc.scene()["meshes"].size() == 4, "Added mesh must preserve original and appear in both instances");
    doc.dispatch({{"op", "replace_mesh"}, {"path", instance}, {"asset", imported["asset"]}});
    check(doc.scene()["meshes"].size() == 4, "Replacing an inline capture must suppress its mesh but retain authored additions");
    doc.undo();
    doc.dispatch({{"op", "replace_material"}, {"path", instance + "/mesh"}, {"asset", (fs::path(FIXTURE_DIR) / "material.usda").string()}});
    auto materials = doc.scene()["materials"];
    check(std::abs(materials[0]["albedo"][1].get<double>() - 0.8) < 0.001, "Replacement shader must override local capture material inputs");
    check(materials[0]["emissive_intensity"] == 0, "Disabled emission must ignore the material's intensity value");
    doc.package(root / "package");
    check(fs::exists(root / "package/mod.usda"), "Package must contain mod.usda");
    auto packaged = UsdStage::Open((root / "package/mod.usda").string());
    check(bool(packaged), "Package must open in OpenUSD");
    check(!packaged->GetPrimAtPath(SdfPath("/RootNode/instances")), "Package must not include capture instances");
    check(packaged->GetPrimAtPath(SdfPath(light)).IsValid(), "Package must preserve new light");
    check(text(root / "capture.usda") == original, "Packaging modified capture");
    auto nested = SdfLayer::CreateNew((root / "project/nested.usda").string());
    nested->SetSubLayerPaths({"mod.usda"}); nested->Save();
    doc.stage()->GetRootLayer()->SetSubLayerPaths({"nested.usda", "../capture.usda"});
    doc.stage()->GetRootLayer()->SetCustomLayerData({{"unknown_project_metadata", VtValue(std::string("keep"))}});
    doc.package(root / "nested_package");
    auto nested_package = UsdStage::Open((root / "nested_package/mod.usda").string());
    check(nested_package->GetRootLayer()->GetSubLayerPaths().size() == 1, "Nested replacement layers must not be duplicated at the root");
    check(nested_package->GetRootLayer()->GetCustomLayerData().count("unknown_project_metadata"), "Packaging must preserve authored root metadata");
    check(nested_package->GetPrimAtPath(SdfPath(light)).IsValid(), "Nested package lost attachments");
    rejects([&] { doc.package(root / "package"); }, "Packaging must not overwrite an existing mod");
    rejects([&] { doc.dispatch({{"op", "select_layer"}, {"layer", (root / "capture.usda").string()}}); }, "Capture edit target must be rejected");
    rejects([&] { doc.ingest({{"source", (root / "replacement.usda").string()}}); }, "Duplicate ingestion must not overwrite assets");
    check(usd_errors.IsClean(), "Document workflow emitted USD errors");
    fs::remove_all(root);
    std::cout << "All document workflow tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << "\nFixtures retained at " << root << '\n'; return 1;
  }
}
