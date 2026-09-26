#include "document.h"
#include "render_categories.h"
#include <chrono>
#include <fstream>
#include <iostream>
#include <pxr/base/tf/errorMark.h>
#include <pxr/usd/usdShade/materialBindingAPI.h>
#include <pxr/usd/usdShade/shader.h>
#include <pxr/usd/usdGeom/subset.h>

PXR_NAMESPACE_USING_DIRECTIVE
namespace fs = std::filesystem;
using editor::Json;
namespace {
void check(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
std::string read(const fs::path& path) { std::ifstream file(path); return {std::istreambuf_iterator<char>(file), {}}; }
constexpr auto decal = REMIXAPI_INSTANCE_CATEGORY_BIT_DECAL_STATIC;
constexpr auto terrain = REMIXAPI_INSTANCE_CATEGORY_BIT_TERRAIN;
constexpr auto particle = REMIXAPI_INSTANCE_CATEGORY_BIT_PARTICLE;
constexpr auto sky = REMIXAPI_INSTANCE_CATEGORY_BIT_SKY;
constexpr auto ignore_alpha = REMIXAPI_INSTANCE_CATEGORY_BIT_IGNORE_ALPHA_CHANNEL;
const char* shader_path = "/RootNode/Looks/mat_0123456789ABCDEF/Shader";
const char* mesh_path = "/RootNode/meshes/mesh_0123456789ABCDEF/mesh";
uint32_t flags(const Json& scene, size_t surface = 0) {
  return scene.at("meshes").at(0).at("surfaces").at(surface).at("category_flags").get<uint32_t>();
}
void category(const UsdPrim& prim, const char* name, bool value) {
  prim.CreateAttribute(TfToken(std::string("remix_category:") + name), SdfValueTypeNames->Bool).Set(value);
}
fs::path capture(const fs::path& root, const std::string& config) {
  const auto path = root / "rtx-remix/captures/capture.usda";
  fs::create_directories(path.parent_path());
  fs::copy_file(fs::path(FIXTURE_DIR) / "capture.usda", path);
  auto stage = UsdStage::Open(path.string());
  auto shader = stage->GetPrimAtPath(SdfPath(shader_path));
  shader.CreateAttribute(TfToken("inputs:diffuse_texture"), SdfValueTypeNames->Asset).Set(SdfAssetPath("textures\\FEDCBA9876543210.dds"));
  category(stage->GetPrimAtPath(SdfPath(mesh_path)), "terrain", false);
  category(stage->GetPrimAtPath(SdfPath(mesh_path)), "decal_Static", true);
  auto data = stage->GetRootLayer()->GetCustomLayerData();
  data["lightspeed_exe_name"] = VtValue(std::string("game.exe"));
  stage->GetRootLayer()->SetCustomLayerData(data);
  auto settings = stage->DefinePrim(SdfPath("/remix_settings"), TfToken("RenderSettings"));
  settings.CreateAttribute(TfToken("remix_config"), SdfValueTypeNames->StringArray).Set(VtStringArray{
    "rtx.particleTextures = 0xfedcba9876543210", "rtx.terrainTextures = 0xfedcba9876543210", "rtx.graphicsPreset = 0"});
  stage->GetRootLayer()->Save();
  if (!config.empty()) std::ofstream(root / "rtx.conf") << config;
  return path;
}
void synthetic(const fs::path& root) {
  const auto game = root / "game";
  const auto path = capture(game,
    "\xef\xbb\xbf# category-only import\r\nrtx.terrainTextures = \"0Xfedcba9876543210, 0xAA\" ; comment\r\n"
    "rtx.particleTextures = -0xfedcba9876543210\r\nrtx.decalTextures = 0x0123456789ABCDEF, -0xfedcba9876543210\n"
    "rtx.skyBoxGeometries = 0x0123456789abcdef\nrtx.ignoreTextures = BADHASH\n"
    "rtx.graphicsPreset = 1\nrtx.sceneScale = 999\n"
    "[other.exe]\nrtx.terrainTextures =\n[game.exe]\nrtx.ignoreAlphaOnTextures = 0xFEDCBA9876543210\n");
  const auto before = read(path), config_before = read(game / "rtx.conf");
  editor::Document doc; doc.create(path, root / "project/work.usda");
  const auto mod_before = read(root / "project/mod.usda");
  auto scene = doc.scene();
  check(flags(scene) == (terrain | sky | ignore_alpha), "External category lists must override captured lists/flags, matching texture and geometry hashes independently");
  check(scene.at("meshes").size() == 2, "Both capture instances must be present");
  check(scene.at("meshes").at(1).at("surfaces").at(0).at("category_flags") == flags(scene), "Hash categories must apply to every instance");
  check(scene.at("category_sources").size() == 2, "Report embedded and game category sources");
  check(scene.at("meters_per_unit") == 1, "Game renderer settings must not override USD units");
  bool warned = false;
  for (const auto& warning : scene.at("warnings")) if (warning.get<std::string>().find("Invalid category hash list") != std::string::npos) warned = true;
  check(warned, "Malformed hash assignment must produce a warning");
  check(!doc.describe().at("dirty").get<bool>(), "Reading categories must not dirty a project");
  doc.save();
  check(read(root / "project/mod.usda") == mod_before && read(game / "rtx.conf") == config_before,
    "Saving imported categories must leave the mod and game configuration untouched");

  auto mesh = doc.stage()->GetPrimAtPath(SdfPath(mesh_path));
  category(mesh, "terrain", false);
  category(mesh.GetParent(), "decal_Static", true);
  check(flags(doc.scene()) == (decal | sky | ignore_alpha), "Explicit project true/false categories must override game and captured categories");
  mesh.RemoveProperty(TfToken("remix_category:terrain"));
  mesh.GetParent().RemoveProperty(TfToken("remix_category:decal_Static"));
  auto shader = doc.stage()->GetPrimAtPath(SdfPath(shader_path));
  shader.GetAttribute(TfToken("inputs:diffuse_texture")).Set(SdfAssetPath("replacement.png"));
  check(flags(doc.scene()) == (terrain | sky | ignore_alpha), "Material replacement must retain original texture categorization");
  shader.RemoveProperty(TfToken("inputs:diffuse_texture"));

  // Subsets with unrelated materials must not inherit a neighbouring decal.
  auto material = UsdShadeMaterial::Define(doc.stage(), SdfPath("/RootNode/Looks/other"));
  auto other_shader = UsdShadeShader::Define(doc.stage(), SdfPath("/RootNode/Looks/other/Shader"));
  other_shader.GetPrim().CreateAttribute(TfToken("inputs:diffuse_texture"), SdfValueTypeNames->Asset).Set(SdfAssetPath("0123456789ABCDEF.dds"));
  auto subset = UsdGeomSubset::Define(doc.stage(), SdfPath(std::string(mesh_path) + "/other"));
  subset.CreateElementTypeAttr().Set(UsdGeomTokens->face);
  subset.CreateFamilyNameAttr().Set(TfToken("materialBind"));
  subset.CreateIndicesAttr().Set(VtIntArray{0});
  UsdShadeMaterialBindingAPI::Apply(subset.GetPrim()).Bind(material);
  auto mixed = doc.scene();
  check(flags(mixed) == (decal | sky), "Per-face material binding must use its own texture hash");
  Json grouped_mesh = scene.at("meshes").at(0);
  grouped_mesh["surfaces"].push_back(mixed.at("meshes").at(0).at("surfaces").at(0));
  const auto groups = editor::category_surface_groups(grouped_mesh);
  check(groups.size() == 2 && groups.at(terrain | sky | ignore_alpha) == std::vector<size_t>{0} &&
    groups.at(decal | sky) == std::vector<size_t>{1}, "Renderer must isolate surface categories into distinct draw calls");
  grouped_mesh["surfaces"].push_back(grouped_mesh["surfaces"][0]);
  check(editor::category_surface_groups(grouped_mesh).at(terrain | sky | ignore_alpha).size() == 2, "Equal category surfaces should batch");
  doc.stage()->RemovePrim(subset.GetPath());
  doc.stage()->RemovePrim(material.GetPath());

  // Hash sets are layered opinions: empty lists preserve inherited settings;
  // negative hashes remove entries. External settings are read each snapshot.
  std::ofstream(game / "rtx.conf") << "rtx.terrainTextures =\nrtx.decalTextures =\nrtx.particleTextures =\n";
  check(flags(doc.scene()) == (decal | terrain | particle), "Empty lists preserve capture defaults and old external entries cannot leak between snapshots");
  std::ofstream(game / "rtx.conf") << "rtx.terrainTextures = -0xfedcba9876543210\nrtx.decalTextures = -0xfedcba9876543210, +0xfedcba9876543210\nrtx.particleTextures = -0xfedcba9876543210\n";
  check(flags(doc.scene()) == 0, "Negative hashes must clear capture categories, including when both signs occur in one list");
  fs::remove(game / "rtx.conf");
  check(flags(doc.scene()) == (decal | terrain | particle), "Detached captures fall back to embedded config and captured flags");
  auto settings = doc.stage()->GetPrimAtPath(SdfPath("/remix_settings"));
  settings.CreateAttribute(TfToken("remix:remix_config"), SdfValueTypeNames->StringArray).Set(VtStringArray{"rtx.terrainTextures ="});
  check(flags(doc.scene()) == decal, "Namespaced config takes precedence over legacy embedded config");
  settings.GetAttribute(TfToken("remix:remix_config")).Block();
  check(flags(doc.scene()) == decal, "Blocked namespaced config must suppress legacy fallback");
  settings.RemoveProperty(TfToken("remix:remix_config"));

  // Switching and undo must discover the active capture's game, not the project directory.
  const auto second = capture(root / "second-game", "rtx.terrainTextures = -0xfedcba9876543210\nrtx.particleTextures = -0xfedcba9876543210\nrtx.decalTextures = -0xfedcba9876543210\nrtx.beamTextures = 0xfedcba9876543210\n");
  doc.dispatch({{"op", "add_capture"}, {"path", second.string()}});
  check(flags(doc.scene()) == REMIXAPI_INSTANCE_CATEGORY_BIT_BEAM, "Capture switch must use the new game's config");
  doc.undo(); check(flags(doc.scene()) == (decal | terrain | particle), "Undoing capture switch must restore categories");
  doc.redo(); doc.save();
  editor::Document reopened; reopened.open(root / "project/work.usda");
  check(flags(reopened.scene()) == REMIXAPI_INSTANCE_CATEGORY_BIT_BEAM, "Categories must restore when reopening a project");
  check(read(path) == before, "Importing categories must never modify the capture");
  check(read(root / "project/mod.usda").find("remix_category:") == std::string::npos,
    "Automatic categories must not be published as replacement opinions");
  std::ofstream(game / "rtx.conf") << config_before;
}
void real_capture(const fs::path& path, const fs::path& root) {
  const auto before = read(path);
  editor::Document doc; doc.create(path, root / "real/work.usda");
  auto scene = doc.scene();
  std::map<uint32_t, size_t> counts;
  for (const auto& warning : scene.at("warnings"))
    check(warning.get<std::string>().find("Invalid category hash list") == std::string::npos,
      "The game's category lists must parse without losing hash exclusions");
  for (const auto& mesh : scene.at("meshes")) for (const auto& surface : mesh.at("surfaces"))
    for (uint32_t bit = 1; bit <= (1u << 28); bit <<= 1) if (surface.at("category_flags").get<uint32_t>() & bit) ++counts[bit];
  check(counts[decal] > 0, "Real capture should contain configured decals");
  check(read(path) == before, "Real capture must remain unchanged");
  std::cout << "Real capture categories: " << scene.at("category_sources") << "\n";
  for (const auto& [bit, count] : counts) std::cout << "  flag " << bit << ": " << count << " surfaces\n";
}
}
int main(int argc, char** argv) {
  const auto root = fs::temp_directory_path() / ("remix-categories-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  try {
    TfErrorMark errors;
    synthetic(root);
    if (argc > 1) real_capture(argv[1], root);
    check(errors.IsClean(), "Category import emitted USD errors");
    fs::remove_all(root);
    std::cout << "Capture categories passed\n"; return 0;
  } catch (const std::exception& e) { std::cerr << e.what() << "\nFixtures: " << root << '\n'; return 1; }
}
