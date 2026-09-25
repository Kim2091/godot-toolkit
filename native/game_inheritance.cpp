#include "game_inheritance.h"

#include <set>
#include <cctype>
#include <pxr/base/tf/errorMark.h>
#include <pxr/base/tf/stringUtils.h>
#include <pxr/usd/sdf/copyUtils.h>
#include <pxr/usd/sdf/layerUtils.h>
#include <pxr/usd/sdf/namespaceEdit.h>
#include <pxr/usd/usd/primFlags.h>
#include <pxr/usd/usdGeom/mesh.h>
#include <pxr/usd/usdLux/lightAPI.h>
#include <pxr/usd/usdUtils/dependencies.h>
#include <pxr/usd/usdUtils/flattenLayerStack.h>

PXR_NAMESPACE_USING_DIRECTIVE
namespace editor {
namespace {
bool preserve_original(const UsdPrim& prim) {
  // Match Remix's preserveGameObject: a light-only attachment normally retains
  // the original draw call, but must not resurrect a base's replaced mesh.
  auto flag = prim.GetAttribute(TfToken("preserveOriginalDrawCall"));
  if (flag) { int value = 0; flag.Get(&value); return value != 0; }
  for (auto spec : prim.GetPrimStack()) if (spec->HasReferences()) {
    auto refs = spec->GetReferenceList();
    if (refs.IsExplicit()) return false;
    for (const SdfReference& ref : refs.GetDeletedItems()) {
      auto asset = TfStringToLower(ref.GetAssetPath());
      if (asset.find("/captures/meshes/" + TfStringToLower(prim.GetName().GetString())) != std::string::npos) return false;
    }
  }
  auto mesh = prim.GetChild(TfToken("mesh"));
  return !mesh || mesh.IsActive();
}

bool replacement_content(const UsdPrim& prim) {
  const auto type = prim.GetTypeName();
  const bool analytical_light = type == TfToken("SphereLight") || type == TfToken("RectLight") ||
    type == TfToken("DiskLight") || type == TfToken("CylinderLight") || type == TfToken("DistantLight");
  // Captured light overrides may deliberately omit their concrete USD type.
  const auto name = prim.GetName().GetString();
  const bool light_override = prim.GetParent().GetPath() == SdfPath("/RootNode/lights") && name.size() == 22 &&
    name.rfind("light_", 0) == 0 && std::all_of(name.begin() + 6, name.end(), [](unsigned char c) { return std::isxdigit(c); });
  if (prim.IsA<UsdGeomMesh>() || analytical_light || light_override || prim.GetTypeName() == TfToken("OmniGraph") ||
      prim.GetTypeName() == TfToken("PointInstancer")) return true;
  for (auto attr : prim.GetAuthoredAttributes())
    if (attr.GetName().GetString().rfind("remix_category:", 0) == 0) return true;
  for (auto child : prim.GetFilteredChildren(UsdPrimIsActive)) if (replacement_content(child)) return true;
  return false;
}

bool self_contained_lights(const UsdPrim& prim) {
  if (prim.HasAuthoredReferences() || prim.HasAuthoredPayloads()) return false;
  const auto type = prim.GetTypeName();
  if (!type.IsEmpty() && type != TfToken("Xform") && type != TfToken("Scope") && !UsdLuxLightAPI(prim)) return false;
  SdfPathVector targets;
  for (auto attr : prim.GetAuthoredAttributes()) { attr.GetConnections(&targets); if (!targets.empty()) return false; }
  for (auto rel : prim.GetAuthoredRelationships()) { rel.GetTargets(&targets); if (!targets.empty()) return false; }
  for (auto child : prim.GetFilteredChildren(UsdPrimIsActive)) if (!self_contained_lights(child)) return false;
  return true;
}

std::string identifier(const fs::path& path) {
  uint64_t hash = 14695981039346656037ull;
  for (unsigned char c : fs::weakly_canonical(path).generic_string()) { hash ^= c; hash *= 1099511628211ull; }
  return "mod_" + std::to_string(hash);
}
}

std::vector<InheritedMod> find_game_inheritance(const UsdStageRefPtr& project,
                                               const fs::path& mods, const fs::path& own_directory) {
  std::set<SdfPath> remaining;
  for (auto layer : project->GetLayerStack(false)) {
    auto data = layer->GetCustomLayerData();
    if (data["lightspeed_layer_type"] == VtValue(std::string("capture"))) continue;
    for (const auto* scope : {"/RootNode/meshes", "/RootNode/lights"}) {
      auto parent = layer->GetPrimAtPath(SdfPath(scope));
      if (parent) for (auto child : parent->GetNameChildren()) remaining.insert(child->GetPath());
    }
  }
  std::vector<InheritedMod> result;
  if (remaining.empty() || !fs::is_directory(mods)) return result;
  std::vector<fs::path> candidates;
  for (const auto& entry : fs::directory_iterator(mods)) {
    if (!entry.is_directory() || fs::weakly_canonical(entry.path()) == fs::weakly_canonical(own_directory)) continue;
    for (const auto& file : fs::directory_iterator(entry.path())) {
      const auto ext = file.path().extension().string();
      if (file.is_regular_file() && file.path().stem() == "mod" && (ext == ".usd" || ext == ".usda" || ext == ".usdc")) {
        candidates.push_back(file.path()); break;
      }
    }
  }
  // Installed Remix returns the first matching hash, ordered by mod path.
  std::sort(candidates.begin(), candidates.end());
  for (const auto& path : candidates) {
    TfErrorMark errors;
    auto source = UsdStage::Open(path.string());
    // An unrelated malformed mod must not prevent publishing this project.
    if (!source) { errors.Clear(); continue; }
    InheritedMod inherited{path, source, {}};
    for (auto it = remaining.begin(); it != remaining.end();) {
      auto prim = source->GetPrimAtPath(*it);
      if (prim && prim.IsActive() && (!preserve_original(prim) || replacement_content(prim))) {
        inherited.roots.push_back(*it); it = remaining.erase(it);
      } else ++it;
    }
    if (!inherited.roots.empty()) result.push_back(std::move(inherited));
    if (remaining.empty()) break;
  }
  return result;
}

void publish_game_inheritance(const std::vector<InheritedMod>& mods,
                             const UsdStageRefPtr& project, const fs::path& staging) {
  if (mods.empty()) return;
  auto inherited = SdfLayer::CreateAnonymous("inherited.usda");
  auto root = SdfLayer::FindOrOpen((staging / "mod.usda").string());
  auto stage = UsdStage::Open(root);
  for (const auto& mod : mods) {
    // Flatten sublayers only: references and assets retain their original data.
    // Hide the source resources beneath a namespace the runtime doesn't scan.
    // Copy just the winning hash to /meshes or /lights. This keeps its material
    // relationships intact without registering unrelated replacement hashes.
    auto flattened = UsdUtilsFlattenLayerStack(mod.stage, [](const SdfLayerHandle& layer, const std::string& asset) {
      if (asset.empty()) return asset;
      auto resolved = SdfComputeAssetPathRelativeToLayer(layer, asset);
      return fs::path(resolved).is_absolute() ? resolved :
        (fs::path(layer->GetRealPath()).parent_path() / resolved).lexically_normal().generic_string();
    });
    const auto hidden = SdfPath("/RootNode/__StudioInherited").AppendChild(TfToken(identifier(mod.path)));
    SdfCreatePrimInLayer(inherited, hidden.GetParentPath());
    if (!SdfCopySpec(flattened, SdfPath("/RootNode"), inherited, hidden))
      throw std::runtime_error("Could not retain replacements from " + mod.path.string());
    for (const auto& path : mod.roots) {
      const auto source_path = path.ReplacePrefix(SdfPath("/RootNode"), hidden);
      SdfCreatePrimInLayer(inherited, path.GetParentPath());
      if (!SdfCopySpec(inherited, source_path, inherited, path)) throw std::runtime_error("Could not retain " + path.GetString());
      auto authored = project->GetPrimAtPath(path).GetAttribute(TfToken("preserveOriginalDrawCall"));
      int preserve = -1;
      if (authored && authored.Get(&preserve) && preserve == 1)
        stage->OverridePrim(path).CreateAttribute(TfToken("preserveOriginalDrawCall"), SdfValueTypeNames->Int, true)
          .Set(preserve_original(mod.stage->GetPrimAtPath(path)) ? 1 : 0);
    }
    // A plain light attachment has no cross-prim dependencies. Avoid pulling
    // the rest of a large base's resources into that common case.
    if (std::all_of(mod.roots.begin(), mod.roots.end(), [&](const SdfPath& path) {
      return self_contained_lights(mod.stage->GetPrimAtPath(path));
    })) {
      SdfBatchNamespaceEdit removal; removal.Add(SdfNamespaceEdit::Remove(hidden));
      if (!inherited->Apply(removal)) throw std::runtime_error("Could not trim unused inherited resources");
    }
  }
  // Preserve the installed mods' sibling dependency layout under owned links.
  // Keep these outside project dependency collection: optional broken authoring
  // references in installed mods are tolerated by Remix itself.
  fs::create_directories(staging / "assets/studio_sources");
  UsdUtilsModifyAssetPaths(inherited, [&](const std::string& asset) -> std::string {
    if (asset.empty()) return asset;
    fs::path path(asset);
    if (!path.is_absolute()) throw std::runtime_error("Unresolved inherited asset: " + asset);
    path = fs::weakly_canonical(path);
    auto directory = path.parent_path();
    for (const auto& mod : mods) {
      const auto game = fs::weakly_canonical(mod.path.parent_path().parent_path().parent_path());
      const auto relative = path.lexically_relative(game);
      if (!relative.empty() && *relative.begin() != "..") { directory = game; break; }
    }
    const auto link = fs::path("studio_sources") / identifier(directory);
    if (!fs::exists(fs::symlink_status(staging / "assets" / link)))
      fs::create_directory_symlink(directory, staging / "assets" / link);
    return (link / path.lexically_relative(directory)).generic_string();
  });
  if (!inherited->Export((staging / "assets/studio_inherited.usda").string())) throw std::runtime_error("Could not publish retained attachments");
  std::vector<std::string> layers = root->GetSubLayerPaths();
  const auto offsets = root->GetSubLayerOffsets();
  layers.push_back("assets/studio_inherited.usda"); root->SetSubLayerPaths(layers);
  for (size_t i = 0; i < offsets.size(); ++i) root->SetSubLayerOffset(offsets[i], i);
  if (!root->Save()) throw std::runtime_error("Could not publish combined mod root");
}
}
