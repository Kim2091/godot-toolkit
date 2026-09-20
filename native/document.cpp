#include "document.h"

#include <chrono>
#include <cmath>
#include <fstream>
#include <set>
#include <stdexcept>
#include <pxr/base/gf/rotation.h>
#include <pxr/base/gf/transform.h>
#include <pxr/base/tf/stringUtils.h>
#include <pxr/usd/ar/resolver.h>
#include <pxr/usd/sdf/copyUtils.h>
#include <pxr/usd/sdf/layerUtils.h>
#include <pxr/usd/usd/primRange.h>
#include <pxr/usd/usdGeom/imageable.h>
#include <pxr/usd/usdGeom/metrics.h>
#include <pxr/usd/usdGeom/xform.h>
#include <pxr/usd/usdGeom/xformable.h>
#include <pxr/usd/usdGeom/xformCache.h>
#include <pxr/usd/usdLux/sphereLight.h>
#include <pxr/usd/usdLux/rectLight.h>
#include <pxr/usd/usdLux/diskLight.h>
#include <pxr/usd/usdLux/cylinderLight.h>
#include <pxr/usd/usdLux/distantLight.h>
#include <pxr/usd/usdLux/domeLight.h>
#include <pxr/usd/usdLux/shapingAPI.h>
#include <pxr/usd/usdShade/material.h>
#include <pxr/usd/usdShade/materialBindingAPI.h>
#include <pxr/usd/usdShade/shader.h>
#include <pxr/usd/usdUtils/dependencies.h>
#ifdef _WIN32
#include <windows.h>
#endif

PXR_NAMESPACE_USING_DIRECTIVE
namespace editor {
namespace {
std::string required(const Json& data, const char* key) {
  auto value = data.at(key).get<std::string>();
  if (value.empty()) throw std::runtime_error(std::string(key) + " must not be empty");
  return value;
}
std::string relative_asset(const fs::path& path, const SdfLayerHandle& layer) {
  return fs::relative(fs::absolute(path), fs::path(layer->GetRealPath()).parent_path()).generic_string();
}
bool is_capture(const SdfLayerHandle& layer) {
  auto data = layer->GetCustomLayerData();
  auto it = data.find("lightspeed_layer_type");
  return it != data.end() && it->second.IsHolding<std::string>() && it->second.Get<std::string>() == "capture";
}
GfVec3d vector3(const Json& data) {
  if (!data.is_array() || data.size() != 3) throw std::runtime_error("Expected three numeric components");
  GfVec3d v(data[0].get<double>(), data[1].get<double>(), data[2].get<double>());
  for (int i = 0; i < 3; ++i) if (!std::isfinite(v[i])) throw std::runtime_error("Non-finite transform");
  return v;
}
std::string unique_child(const UsdStageRefPtr& stage, const std::string& parent, const std::string& name) {
  auto stem = TfMakeValidIdentifier(name);
  if (stem.empty()) stem = "asset";
  auto result = parent + "/" + stem;
  for (int i = 2; stage->GetPrimAtPath(SdfPath(result)); ++i) result = parent + "/" + stem + "_" + std::to_string(i);
  return result;
}
Json value_json(const VtValue& v) {
  if (v.IsHolding<bool>()) return v.Get<bool>();
  if (v.IsHolding<int>()) return v.Get<int>();
  if (v.IsHolding<float>()) return v.Get<float>();
  if (v.IsHolding<double>()) return v.Get<double>();
  if (v.IsHolding<std::string>()) return v.Get<std::string>();
  if (v.IsHolding<TfToken>()) return v.Get<TfToken>().GetString();
  if (v.IsHolding<SdfAssetPath>()) return v.Get<SdfAssetPath>().GetAssetPath();
  if (v.IsHolding<GfVec3f>()) { auto x = v.Get<GfVec3f>(); return {x[0], x[1], x[2]}; }
  if (v.IsHolding<GfVec3d>()) { auto x = v.Get<GfVec3d>(); return {x[0], x[1], x[2]}; }
  return nullptr;
}
void set_value(const UsdAttribute& attr, const Json& value) {
  const auto type = attr.GetTypeName();
  bool ok = false;
  if (type == SdfValueTypeNames->Bool) ok = attr.Set(value.get<bool>());
  else if (type == SdfValueTypeNames->Int) ok = attr.Set(value.get<int>());
  else if (type == SdfValueTypeNames->Float) ok = attr.Set(value.get<float>());
  else if (type == SdfValueTypeNames->Double) ok = attr.Set(value.get<double>());
  else if (type == SdfValueTypeNames->String) ok = attr.Set(value.get<std::string>());
  else if (type == SdfValueTypeNames->Token) ok = attr.Set(TfToken(value.get<std::string>()));
  else if (type == SdfValueTypeNames->Asset) ok = attr.Set(SdfAssetPath(value.get<std::string>()));
  else if (type.GetType() == TfType::Find<GfVec3f>()) ok = attr.Set(GfVec3f(vector3(value)));
  else if (type.GetType() == TfType::Find<GfVec3d>()) ok = attr.Set(vector3(value));
  else throw std::runtime_error("This attribute type is read-only: " + type.GetAsToken().GetString());
  if (!ok) throw std::runtime_error("USD rejected the property value");
}
}

std::string layer_text(const SdfLayerHandle& layer) {
  std::string text;
  if (!layer->ExportToString(&text)) throw std::runtime_error("Could not serialize USD layer");
  return text;
}

void atomic_save_layer(const SdfLayerHandle& layer) {
  fs::path path(layer->GetRealPath());
  if (path.empty()) throw std::runtime_error("Cannot save an anonymous layer");
  auto temp = path.parent_path() / (path.stem().string() + ".saving" + path.extension().string());
  if (!layer->Export(temp.string())) throw std::runtime_error("Could not write " + temp.string());
#ifdef _WIN32
  // The replacement must work when the destination already exists on Windows.
  if (!MoveFileExW(temp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
    throw std::runtime_error("Could not replace " + path.string());
#else
  fs::rename(temp, path);
#endif
}

void Document::require_stage() const {
  if (!stage_) throw std::runtime_error("Open a project first");
}

void Document::open(const fs::path& path) {
  auto next = UsdStage::Open(fs::absolute(path).string());
  if (!next) throw std::runtime_error("Could not open USD file: " + path.string());
  if (is_capture(next->GetRootLayer())) throw std::runtime_error("This is a capture. Use New from capture to create writable project layers.");
  SdfLayerHandle target;
  auto metadata = next->GetRootLayer()->GetCustomLayerData();
  auto omni = metadata.find("omni_layer");
  if (omni != metadata.end() && omni->second.IsHolding<VtDictionary>()) {
    const auto& dict = omni->second.Get<VtDictionary>();
    auto authoring = dict.find("authoring_layer");
    if (authoring != dict.end() && authoring->second.IsHolding<std::string>())
      target = SdfLayer::FindOrOpenRelativeToLayer(next->GetRootLayer(), authoring->second.Get<std::string>());
  }
  for (auto layer : next->GetLayerStack(false)) {
    if (!target && !is_capture(layer) && layer != next->GetRootLayer()) target = layer;
  }
  if (!target) target = next->GetRootLayer();
  if (is_capture(target) || !target->PermissionToEdit()) throw std::runtime_error("No writable replacement layer");
  stage_ = next;
  edit_layer_ = target;
  stage_->SetEditTarget(edit_layer_);
  project_path_ = fs::absolute(path);
  undo_.clear(); redo_.clear(); saved_layers_.clear();
  for (auto layer : stage_->GetLayerStack(false)) saved_layers_[layer->GetIdentifier()] = layer_text(layer);
  ++revision_;
}

void Document::create(const fs::path& capture, const fs::path& project) {
  if (fs::exists(project)) throw std::runtime_error("Project already exists");
  auto source = UsdStage::Open(fs::absolute(capture).string());
  if (!source || !source->GetPrimAtPath(SdfPath("/RootNode"))) throw std::runtime_error("Expected a Remix capture with /RootNode");
  auto root = fs::absolute(project).parent_path();
  fs::create_directories(root);
  auto mod_path = root / "mod.usda";
  if (fs::exists(mod_path)) throw std::runtime_error("mod.usda already exists; choose a new project directory");
  auto mod = SdfLayer::CreateNew(mod_path.string());
  auto work = SdfLayer::CreateNew(fs::absolute(project).string());
  if (!mod || !work) throw std::runtime_error("Could not create project files");
  mod->SetCustomLayerData({{"lightspeed_layer_type", VtValue(std::string("replacement"))}});
  work->SetCustomLayerData({
    {"lightspeed_layer_type", VtValue(std::string("workfile"))},
    {"omni_layer", VtValue(VtDictionary{{"authoring_layer", VtValue(std::string("./mod.usda"))}})}
  });
  work->SetSubLayerPaths({"./mod.usda", fs::relative(fs::absolute(capture), root).generic_string()});
  auto stage = UsdStage::Open(work);
  UsdGeomSetStageUpAxis(stage, UsdGeomGetStageUpAxis(source));
  UsdGeomSetStageMetersPerUnit(stage, UsdGeomGetStageMetersPerUnit(source));
  if (!work->Save() || !mod->Save()) throw std::runtime_error("Could not save new project");
  open(project);
}

bool Document::dirty() const {
  if (!stage_) return false;
  for (auto layer : stage_->GetLayerStack(false)) {
    auto found = saved_layers_.find(layer->GetIdentifier());
    if (found == saved_layers_.end() || found->second != layer_text(layer)) return true;
  }
  return false;
}

Json Document::describe() const {
  if (!stage_) return {{"open", false}, {"revision", revision_}};
  Json prims = Json::array(), layers = Json::array(), warnings = Json::array();
  for (auto prim : stage_->Traverse()) {
    auto imageable = UsdGeomImageable(prim);
    prims.push_back({{"path", prim.GetPath().GetString()}, {"name", prim.GetName().GetString()},
      {"type", prim.GetTypeName().GetString()}, {"active", prim.IsActive()},
      {"visible", !imageable || imageable.ComputeVisibility() != UsdGeomTokens->invisible}});
    if (prim.GetTypeName() == TfToken("SkelRoot") || prim.GetTypeName() == TfToken("OmniGraph"))
      warnings.push_back("Preserved without editing support: " + prim.GetPath().GetString());
  }
  for (auto layer : stage_->GetLayerStack(false)) {
    layers.push_back({{"id", layer->GetIdentifier()}, {"name", layer->GetDisplayName()},
      {"capture", is_capture(layer)}, {"editable", !is_capture(layer) && layer->PermissionToEdit()},
      {"selected", layer == edit_layer_}});
  }
  for (const auto& error : stage_->GetCompositionErrors()) warnings.push_back(error->ToString());
  return {{"open", true}, {"path", project_path_.generic_string()}, {"dirty", dirty()},
    {"revision", revision_}, {"up_axis", UsdGeomGetStageUpAxis(stage_).GetString()},
    {"meters_per_unit", UsdGeomGetStageMetersPerUnit(stage_)}, {"prims", prims},
    {"layers", layers}, {"warnings", warnings}, {"can_undo", !undo_.empty()}, {"can_redo", !redo_.empty()}};
}

Json Document::inspect(const std::string& path) const {
  require_stage();
  auto prim = stage_->GetPrimAtPath(SdfPath(path));
  if (!prim) throw std::runtime_error("Prim no longer exists");
  Json properties = Json::array();
  for (auto attr : prim.GetAttributes()) {
    VtValue value;
    if (!attr.Get(&value)) continue;
    auto json = value_json(value);
    if (json.is_null()) continue;
    properties.push_back({{"name", attr.GetName().GetString()}, {"type", attr.GetTypeName().GetAsToken().GetString()}, {"value", json}});
  }
  Json result{{"path", path}, {"properties", properties}};
  auto transform = UsdGeomXformable(prim);
  if (transform) {
    GfMatrix4d matrix; bool reset;
    transform.GetLocalTransformation(&matrix, &reset);
    auto translation = matrix.ExtractTranslation();
    result["translation"] = {translation[0], translation[1], translation[2]};
    GfTransform components(matrix);
    auto scale = components.GetScale();
    auto rotation = components.GetRotation().Decompose(GfVec3d(1, 0, 0), GfVec3d(0, 1, 0), GfVec3d(0, 0, 1));
    result["scale"] = {scale[0], scale[1], scale[2]};
    result["rotation"] = {rotation[0], rotation[1], rotation[2]};
  }
  try { result["anchor"] = anchor_for(path); } catch (const std::runtime_error&) { result["anchor"] = nullptr; }
  return result;
}

void Document::edit(const std::string& label, const std::function<void()>& operation) {
  require_stage();
  if (!edit_layer_ || is_capture(edit_layer_)) throw std::runtime_error("Capture layers cannot be edited");
  const auto before = layer_text(edit_layer_);
  try { operation(); }
  catch (...) { edit_layer_->ImportFromString(before); throw; }
  const auto after = layer_text(edit_layer_);
  if (before == after) return;
  undo_.push_back({label, edit_layer_, before, after});
  redo_.clear();
  ++revision_;
}

void Document::undo() {
  if (undo_.empty()) return;
  auto entry = undo_.back();
  if (!entry.layer->ImportFromString(entry.before)) throw std::runtime_error("Could not undo USD edit");
  undo_.pop_back(); redo_.push_back(entry); ++revision_;
}
void Document::redo() {
  if (redo_.empty()) return;
  auto entry = redo_.back();
  if (!entry.layer->ImportFromString(entry.after)) throw std::runtime_error("Could not redo USD edit");
  redo_.pop_back(); undo_.push_back(entry); ++revision_;
}

void Document::select_layer(const std::string& identifier) {
  require_stage();
  for (auto layer : stage_->GetLayerStack(false)) {
    if (layer->GetIdentifier() != identifier) continue;
    if (is_capture(layer) || !layer->PermissionToEdit()) throw std::runtime_error("Layer is read-only");
    edit_layer_ = layer; stage_->SetEditTarget(layer); return;
  }
  throw std::runtime_error("Layer is not in this project");
}

void Document::set_property(const Json& request) {
  auto prim = stage_->GetPrimAtPath(SdfPath(authored_path(required(request, "path"))));
  if (!prim) throw std::runtime_error("Unknown prim");
  auto attr = prim.GetAttribute(TfToken(required(request, "property")));
  if (!attr) throw std::runtime_error("Unknown attribute");
  set_value(attr, request.at("value"));
}

void Document::set_transform(const Json& request) {
  auto selected_path = required(request, "path");
  auto path = authored_path(selected_path);
  auto prim = stage_->GetPrimAtPath(SdfPath(path));
  UsdGeomXformable xform(prim);
  if (!xform) throw std::runtime_error("Selection cannot be transformed");
  GfMatrix4d matrix; bool reset;
  xform.GetLocalTransformation(&matrix, &reset);
  if (request.contains("matrix")) {
    const auto& elements = request.at("matrix");
    if (elements.size() != 16) throw std::runtime_error("Expected a 4x4 matrix");
    for (int r = 0; r < 4; ++r) for (int c = 0; c < 4; ++c) matrix[r][c] = elements[r * 4 + c].get<double>();
  } else {
    if (request.contains("rotation") || request.contains("scale")) {
      GfTransform original(matrix);
      auto old_rotation = original.GetRotation().Decompose(GfVec3d(1, 0, 0), GfVec3d(0, 1, 0), GfVec3d(0, 0, 1));
      auto rotation = request.contains("rotation") ? vector3(request.at("rotation")) : old_rotation;
      auto scale = request.contains("scale") ? vector3(request.at("scale")) : original.GetScale();
      if (scale[0] == 0 || scale[1] == 0 || scale[2] == 0) throw std::runtime_error("Scale cannot be zero");
      auto t = matrix.ExtractTranslation();
      matrix.SetScale(scale);
      matrix *= GfMatrix4d(GfRotation(GfVec3d(1, 0, 0), rotation[0]), GfVec3d(0));
      matrix *= GfMatrix4d(GfRotation(GfVec3d(0, 1, 0), rotation[1]), GfVec3d(0));
      matrix *= GfMatrix4d(GfRotation(GfVec3d(0, 0, 1), rotation[2]), GfVec3d(0));
      matrix.SetTranslateOnly(t);
    }
    if (request.contains("translation")) matrix.SetTranslateOnly(vector3(request.at("translation")));
    if (request.contains("world_delta")) {
      UsdGeomXformCache cache;
      auto selected = stage_->GetPrimAtPath(SdfPath(selected_path));
      auto parent = cache.GetParentToWorldTransform(selected);
      matrix.SetTranslateOnly(matrix.ExtractTranslation() + parent.GetInverse().TransformDir(vector3(request.at("world_delta"))));
    }
  }
  if (!xform.MakeMatrixXform().Set(matrix)) throw std::runtime_error("Could not author transform");
}

std::string Document::authored_path(const std::string& path) const {
  const SdfPath selected(path);
  const SdfPath instances("/RootNode/instances");
  if (!selected.HasPrefix(instances)) return path;
  auto instance = selected;
  while (instance.GetParentPath() != instances && instance != SdfPath::AbsoluteRootPath()) instance = instance.GetParentPath();
  if (instance.GetParentPath() != instances) throw std::runtime_error("Select a captured asset or an authored replacement");
  auto anchor = SdfPath(anchor_for(instance.GetString()));
  if (instance == selected) throw std::runtime_error("Select a mesh or light inside the captured instance to edit it");
  return selected.ReplacePrefix(instance, anchor).GetString();
}

std::string Document::anchor_for(const std::string& path) const {
  auto prim = stage_->GetPrimAtPath(SdfPath(path));
  if (!prim) throw std::runtime_error("Choose a captured asset");
  auto find_hash_root = [](const SdfPath& candidate) -> std::string {
    auto text = candidate.GetString();
    for (const auto& prefix : {std::string("/RootNode/meshes/mesh_"), std::string("/RootNode/lights/light_")}) {
      if (text.rfind(prefix, 0) == 0) return text.substr(0, text.find('/', prefix.size()));
    }
    return {};
  };
  for (auto p = prim; p && !p.IsPseudoRoot(); p = p.GetParent()) {
    auto root = find_hash_root(p.GetPath());
    if (!root.empty()) return root;
    for (auto spec : p.GetPrimStack()) {
      root = find_hash_root(spec->GetPath());
      if (!root.empty()) return root;
    }
  }
  throw std::runtime_error("Select a captured mesh or light to attach this asset");
}

std::string Document::add_reference(const Json& request) {
  auto anchor = anchor_for(required(request, "path"));
  fs::path asset = fs::absolute(required(request, "asset"));
  auto source = UsdStage::Open(asset.string());
  if (!source || !source->GetDefaultPrim()) throw std::runtime_error("Asset requires a valid USD default prim; ingest it first");
  auto root = stage_->OverridePrim(SdfPath(anchor));
  bool replace = request.value("replace", false);
  if (replace) {
    // Inline captured meshes survive clearing reference arcs. Suppress original
    // children while retaining the user's authored attachments.
    for (auto child : root.GetChildren()) {
      auto spec = edit_layer_->GetPrimAtPath(child.GetPath());
      if (!spec || spec->GetSpecifier() != SdfSpecifierDef) child.SetActive(false);
    }
    root.GetReferences().SetReferences({});
  }
  auto preserve = root.CreateAttribute(TfToken("preserveOriginalDrawCall"), SdfValueTypeNames->Int, true);
  int previous = 1; preserve.Get(&previous);
  preserve.Set(replace ? 0 : previous);
  auto path = unique_child(stage_, anchor, "ref_" + asset.stem().string());
  auto prim = UsdGeomXform::Define(stage_, SdfPath(path)).GetPrim();
  prim.GetReferences().AddReference(relative_asset(asset, edit_layer_));
  prim.CreateAttribute(TfToken("IsRemixRef"), SdfValueTypeNames->Bool, true).Set(true);
  GfMatrix4d normalization;
  normalization.SetScale(UsdGeomGetStageMetersPerUnit(source) / UsdGeomGetStageMetersPerUnit(stage_));
  if (UsdGeomGetStageUpAxis(source) != UsdGeomGetStageUpAxis(stage_)) {
    normalization *= GfMatrix4d(GfRotation(GfVec3d(1, 0, 0), UsdGeomGetStageUpAxis(source) == UsdGeomTokens->y ? 90.0 : -90.0), GfVec3d(0));
  }
  UsdGeomXformable(prim).MakeMatrixXform().Set(normalization);
  if (request.contains("translation")) set_transform({{"path", path}, {"translation", request.at("translation")}});
  return path;
}

std::string Document::add_light(const Json& request) {
  auto anchor = anchor_for(required(request, "path"));
  auto type = request.value("type", std::string("SphereLight"));
  auto path = unique_child(stage_, anchor, request.value("name", type));
  auto sdf = SdfPath(path);
  UsdPrim light;
  if (type == "SphereLight" || type == "SpotLight") light = UsdLuxSphereLight::Define(stage_, sdf).GetPrim();
  else if (type == "RectLight") light = UsdLuxRectLight::Define(stage_, sdf).GetPrim();
  else if (type == "DiskLight") light = UsdLuxDiskLight::Define(stage_, sdf).GetPrim();
  else if (type == "CylinderLight") light = UsdLuxCylinderLight::Define(stage_, sdf).GetPrim();
  else if (type == "DistantLight") light = UsdLuxDistantLight::Define(stage_, sdf).GetPrim();
  else if (type == "DomeLight") light = UsdLuxDomeLight::Define(stage_, sdf).GetPrim();
  else throw std::runtime_error("Unsupported light type");
  UsdLuxLightAPI(light).CreateIntensityAttr().Set(request.value("intensity", type == "DistantLight" ? 50000.0f : 1000.0f));
  UsdLuxLightAPI(light).CreateColorAttr().Set(GfVec3f(1.0f));
  if (type == "SpotLight") UsdLuxShapingAPI::Apply(light).CreateShapingConeAngleAttr().Set(35.0f);
  auto preserve = stage_->OverridePrim(SdfPath(anchor)).CreateAttribute(TfToken("preserveOriginalDrawCall"), SdfValueTypeNames->Int, true);
  int previous = 1; preserve.Get(&previous); preserve.Set(previous);
  set_transform({{"path", path}, {"translation", request.value("translation", Json::array({0, 0, 0}))}});
  return path;
}

void Document::replace_material(const Json& request) {
  auto path = SdfPath(required(request, "path"));
  auto selected = stage_->GetPrimAtPath(path);
  if (!selected) throw std::runtime_error("Select a material or mesh");
  auto material = UsdShadeMaterial(selected);
  if (!material) material = UsdShadeMaterialBindingAPI(selected).ComputeBoundMaterial();
  if (!material) throw std::runtime_error("Selection has no bound material");
  auto asset = fs::absolute(required(request, "asset"));
  auto source = UsdStage::Open(asset.string());
  if (!source || !UsdShadeMaterial(source->GetDefaultPrim())) throw std::runtime_error("Choose an ingested material USD");
  auto flattened = source->Flatten();
  UsdUtilsModifyAssetPaths(flattened, [&](const std::string& dependency) {
    if (dependency.empty()) return dependency;
    auto resolved = fs::path(dependency);
    if (!resolved.is_absolute()) resolved = asset.parent_path() / resolved;
    return relative_asset(resolved, edit_layer_);
  });
  // A reference alone is weaker than the capture's local shader inputs.
  if (!SdfCreatePrimInLayer(edit_layer_, material.GetPath().GetParentPath()))
    throw std::runtime_error("Could not author replacement material ancestors");
  if (!SdfCopySpec(flattened, source->GetDefaultPrim().GetPath(), edit_layer_, material.GetPath()))
    throw std::runtime_error("Could not author replacement material");
}

void Document::save() {
  require_stage();
  for (auto layer : stage_->GetLayerStack(false)) {
    auto text = layer_text(layer);
    if (saved_layers_[layer->GetIdentifier()] == text) continue;
    if (is_capture(layer)) throw std::runtime_error("Refusing to write a capture layer");
    atomic_save_layer(layer);
    saved_layers_[layer->GetIdentifier()] = text;
  }
}

void Document::package(const fs::path& directory) {
  require_stage();
  if (fs::exists(directory)) throw std::runtime_error("Package destination must not already exist");
  auto temp = fs::absolute(directory).parent_path() / (directory.filename().string() + ".building");
  if (fs::exists(temp)) throw std::runtime_error("An unfinished package exists: " + temp.string());
  fs::create_directories(temp / "assets");
  try {
    // Keep the workfile's authored opinions and direct replacement sublayers. Expanding
    // GetLayerStack into a new sublayer list would apply nested layers more than once.
    auto root = stage_->GetRootLayer();
    auto snapshot = SdfLayer::CreateAnonymous("package.usda");
    snapshot->TransferContent(root);
    std::vector<std::string> roots;
    for (const auto& path : root->GetSubLayerPaths()) {
      auto layer = SdfLayer::FindOrOpenRelativeToLayer(root, path);
      if (!layer) throw std::runtime_error("Missing project layer: " + std::string(path));
      if (!is_capture(layer)) roots.push_back(layer->GetRealPath());
    }
    snapshot->SetSubLayerPaths(roots);
    auto metadata = snapshot->GetCustomLayerData();
    metadata["lightspeed_layer_type"] = VtValue(std::string("replacement"));
    metadata.erase("omni_layer");
    snapshot->SetCustomLayerData(metadata);
    UsdUtilsModifyAssetPaths(snapshot, [&](const std::string& asset) {
      return asset.empty() ? asset : SdfComputeAssetPathRelativeToLayer(root, asset);
    });
    auto package_root = temp / "mod.usda";
    if (!snapshot->Export(package_root.string())) throw std::runtime_error("Could not create package root");
    std::vector<SdfLayerRefPtr> layers;
    std::vector<std::string> asset_files, missing;
    if (!UsdUtilsComputeAllDependencies(SdfAssetPath(package_root.string()), &layers, &asset_files, &missing) || !missing.empty())
      throw std::runtime_error("Resolve missing package dependencies before exporting" + (missing.empty() ? std::string() : ": " + missing.front()));
    std::map<std::string, fs::path> destinations;
    size_t index = 0;
    for (auto layer : layers) {
      if (is_capture(layer)) throw std::runtime_error("A replacement layer depends on a capture; remove that capture sublayer before packaging");
      auto source = fs::weakly_canonical(layer->GetRealPath()).string();
      destinations[source] = fs::equivalent(source, package_root) ? fs::path("mod.usda") :
        fs::path("assets") / (std::to_string(index++) + "_" + fs::path(source).filename().string());
    }
    // MDL imports are not USD asset dependencies. Keep each material module bundle's
    // names and directory structure so sibling and nvidia module imports still resolve.
    std::map<fs::path, fs::path> bundles;
    std::set<std::string> files;
    for (const auto& asset : asset_files) {
      fs::path source = fs::weakly_canonical(asset);
      if (source.extension() == ".mdl") {
        auto parent = source.parent_path();
        if (!bundles.count(parent)) {
          auto target = fs::path("assets") / ("materials_" + std::to_string(index++));
          bundles[parent] = target;
          for (const auto& entry : fs::recursive_directory_iterator(parent)) {
            if (!entry.is_regular_file()) continue;
            auto relative = fs::relative(entry.path(), parent);
            if (entry.path().extension() != ".mdl" && relative.begin()->string() != "PACKAGE-LICENSES") continue;
            auto key = fs::weakly_canonical(entry.path()).string();
            destinations[key] = target / relative; files.insert(key);
          }
        }
      }
      if (!destinations.count(source.string())) destinations[source.string()] = fs::path("assets") / (std::to_string(index++) + "_" + source.filename().string());
      files.insert(source.string());
    }
    for (const auto& source : files) {
      auto target = temp / destinations.at(source);
      fs::create_directories(target.parent_path());
      fs::copy_file(source, target);
    }
    std::set<std::string> written;
    for (auto layer : layers) {
      const auto source = fs::weakly_canonical(layer->GetRealPath()).string();
      if (!written.insert(source).second) continue;
      const auto destination = destinations.at(source);
      auto copy = SdfLayer::CreateAnonymous(fs::path(source).filename().string());
      copy->TransferContent(layer);
      UsdUtilsModifyAssetPaths(copy, [&](const std::string& asset) {
        if (asset.empty()) return asset;
        auto resolved = SdfComputeAssetPathRelativeToLayer(layer, asset);
        auto found = destinations.find(fs::weakly_canonical(resolved).string());
        if (found == destinations.end()) throw std::runtime_error("Unresolved package asset: " + asset);
        return fs::relative(temp / found->second, (temp / destination).parent_path()).generic_string();
      });
      if (!copy->Export((temp / destination).string())) throw std::runtime_error("Failed to write packaged USD");
    }
    fs::rename(temp, fs::absolute(directory));
  } catch (...) { fs::remove_all(temp); throw; }
}

Json Document::scene() const { require_stage(); return compose_scene(stage_, revision_); }
Json Document::ingest(const Json& request) { require_stage(); return ingest_asset(request, project_path_.parent_path()); }

void Document::mutate(const Json& request, Json& result) {
  const auto op = required(request, "op");
  if (op == "set_property") set_property(request);
  else if (op == "transform") set_transform(request);
  else if (op == "add_mesh" || op == "replace_mesh") {
    auto data = request; data["replace"] = op == "replace_mesh";
    result["selection"] = add_reference(data);
  } else if (op == "add_light") result["selection"] = add_light(request);
  else if (op == "replace_material") replace_material(request);
  else if (op == "visibility") {
    auto prim = stage_->GetPrimAtPath(SdfPath(authored_path(required(request, "path"))));
    auto imageable = UsdGeomImageable(prim);
    if (!imageable) throw std::runtime_error("Selection has no visibility");
    imageable.CreateVisibilityAttr().Set(request.value("visible", true) ? UsdGeomTokens->inherited : UsdGeomTokens->invisible);
  } else if (op == "delete") {
    auto path = SdfPath(authored_path(required(request, "path")));
    auto spec = edit_layer_->GetPrimAtPath(path);
    if (!spec || spec->GetSpecifier() != SdfSpecifierDef) throw std::runtime_error("Delete an authored asset; use visibility to hide a captured mesh");
    stage_->GetPrimAtPath(path).SetActive(false);
  } else if (op == "duplicate") {
    auto path = SdfPath(authored_path(required(request, "path")));
    auto spec = edit_layer_->GetPrimAtPath(path);
    if (!spec || spec->GetSpecifier() != SdfSpecifierDef) throw std::runtime_error("Duplicate an authored asset rather than a capture instance");
    auto next = unique_child(stage_, path.GetParentPath().GetString(), path.GetName() + "_copy");
    if (!SdfCopySpec(edit_layer_, path, edit_layer_, SdfPath(next))) throw std::runtime_error("Could not duplicate asset");
    result["selection"] = next;
  } else if (op == "remap") {
    const auto from = required(request, "from"), to = required(request, "to");
    UsdUtilsModifyAssetPaths(edit_layer_, [&](const std::string& path) {
      return path.rfind(from, 0) == 0 ? to + path.substr(from.size()) : path;
    });
  } else if (op == "batch") {
    for (const auto& command : request.at("commands")) mutate(command, result);
  } else throw std::runtime_error("Unknown edit command: " + op);
}

Json Document::dispatch(const Json& request) {
  const auto op = required(request, "op");
  Json result = Json::object();
  if (op == "open") open(required(request, "path"));
  else if (op == "create") create(required(request, "capture"), required(request, "path"));
  else if (op == "save") save();
  else if (op == "package") package(required(request, "path"));
  else if (op == "undo") undo();
  else if (op == "redo") redo();
  else if (op == "select_layer") select_layer(required(request, "layer"));
  else if (op == "inspect") return inspect(required(request, "path"));
  else if (op == "scene") return scene();
  else if (op == "ingest") return ingest(request);
  else if (op != "describe") edit(request.value("label", op), [&] { mutate(request, result); });
  result["document"] = describe();
  return result;
}
}
