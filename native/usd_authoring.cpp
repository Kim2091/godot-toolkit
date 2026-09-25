#include "usd_authoring.h"

#include <algorithm>
#include <cmath>
#include <pxr/base/gf/rotation.h>
#include <pxr/usd/sdf/attributeSpec.h>
#include <pxr/usd/sdf/changeBlock.h>
#include <pxr/usd/sdf/namespaceEdit.h>
#include <pxr/usd/usdGeom/boundable.h>
#include <pxr/usd/usdGeom/metrics.h>
#include <pxr/usd/usdLux/lightAPI.h>

PXR_NAMESPACE_USING_DIRECTIVE
namespace editor {
namespace {
void attribute(const SdfPrimSpecHandle& prim, const char* name, const SdfValueTypeName& type,
               const VtValue& value, SdfVariability variability = SdfVariabilityVarying) {
  auto attr = prim->GetAttributes().get(TfToken(name));
  if (!attr) attr = SdfAttributeSpec::New(prim, name, type, variability, false);
  // Keep a previously authored double3 op's precision.
  if (attr->GetTypeName() == SdfValueTypeNames->Double3 && value.IsHolding<GfVec3f>())
    attr->SetDefaultValue(VtValue(GfVec3d(value.Get<GfVec3f>())));
  else if (attr->GetTypeName() == SdfValueTypeNames->Float3 && value.IsHolding<GfVec3d>())
    attr->SetDefaultValue(VtValue(GfVec3f(value.Get<GfVec3d>())));
  else attr->SetDefaultValue(value);
}

bool trs(const GfMatrix4d& matrix, GfVec3f& rotation, GfVec3f& scale) {
  GfMatrix4d basis(1);
  GfVec3d lengths;
  for (int r = 0; r < 3; ++r) {
    auto row = GfVec3d(matrix[r][0], matrix[r][1], matrix[r][2]);
    lengths[r] = row.GetLength();
    if (!std::isfinite(lengths[r]) || lengths[r] < 1e-12) return false;
    for (int c = 0; c < 3; ++c) basis[r][c] = matrix[r][c] / lengths[r];
  }
  if (basis.GetDeterminant() < 0) {
    lengths[0] = -lengths[0];
    for (int c = 0; c < 3; ++c) basis[0][c] = -basis[0][c];
  }
  if (!basis.Orthonormalize(false)) return false;
  // USD row-vector matrices compose S * Rx * Ry * Rz * T.
  const auto angles = basis.ExtractRotation().Decompose(GfVec3d::ZAxis(), GfVec3d::YAxis(), GfVec3d::XAxis());
  rotation = GfVec3f(angles[2], angles[1], angles[0]);
  scale = GfVec3f(lengths);
  auto rebuilt = GfMatrix4d(1).SetScale(GfVec3d(scale)) *
    UsdGeomXformOp::GetOpTransform(UsdGeomXformOp::TypeRotateXYZ, VtValue(rotation), false);
  rebuilt.SetTranslateOnly(matrix.ExtractTranslation());
  // Accept float precision/capture roundoff, but never silently discard shear.
  const double tolerance = 2e-7 * std::max({1.0, std::abs(lengths[0]), lengths[1], lengths[2]});
  return GfIsClose(matrix, rebuilt, tolerance);
}

void write_transform(const SdfPrimSpecHandle& prim, const GfMatrix4d& matrix, bool reset) {
  SdfChangeBlock changes;
  GfVec3f rotation, scale;
  const bool decomposed = trs(matrix, rotation, scale);
  VtTokenArray order;
  if (reset) order.push_back(TfToken("!resetXformStack!"));
  if (decomposed) {
    attribute(prim, "xformOp:translate", SdfValueTypeNames->Double3, VtValue(matrix.ExtractTranslation()));
    attribute(prim, "xformOp:rotateXYZ", SdfValueTypeNames->Float3, VtValue(rotation));
    attribute(prim, "xformOp:scale", SdfValueTypeNames->Float3, VtValue(scale));
    for (const auto* name : {"xformOp:translate", "xformOp:rotateXYZ", "xformOp:scale"}) order.push_back(TfToken(name));
  } else {
    attribute(prim, "xformOp:transform", SdfValueTypeNames->Matrix4d, VtValue(matrix));
    order.push_back(TfToken("xformOp:transform"));
  }
  attribute(prim, "xformOpOrder", SdfValueTypeNames->TokenArray, VtValue(order), SdfVariabilityUniform);
  std::vector<SdfAttributeSpecHandle> obsolete;
  for (auto attr : prim->GetAttributes())
    if (attr->GetName().rfind("xformOp:", 0) == 0 && attr->GetTimeSampleMap().empty() &&
        std::find(order.begin(), order.end(), attr->GetNameToken()) == order.end()) obsolete.push_back(attr);
  for (auto attr : obsolete) prim->RemoveProperty(attr);
}
}

void author_transform(const UsdGeomXformable& xform, const GfMatrix4d& matrix, bool reset) {
  const auto target = xform.GetPrim().GetStage()->GetEditTarget();
  auto prim = SdfCreatePrimInLayer(target.GetLayer(), target.MapToSpecPath(xform.GetPath()));
  write_transform(prim, matrix, reset);
}

void update_light_extent(UsdPrim prim) {
  if (!UsdLuxLightAPI(prim)) return;
  UsdGeomBoundable boundable(prim);
  VtVec3fArray extent;
  if (boundable && UsdGeomBoundable::ComputeExtentFromPlugins(boundable, UsdTimeCode::Default(), &extent))
    boundable.CreateExtentAttr().Set(extent);
  else prim.RemoveProperty(TfToken("extent")); // e.g. a sphere changed to a distant light
}

void replacement_metadata(const SdfLayerHandle& layer, const UsdStageRefPtr& stage) {
  auto data = layer->GetCustomLayerData();
  data["lightspeed_layer_type"] = VtValue(std::string("replacement"));
  if (!data.count("lightspeed_game_name")) {
    std::string game = "Unknown Game";
    for (const auto& source : stage->GetLayerStack(false)) {
      const auto metadata = source->GetCustomLayerData();
      auto found = metadata.find("lightspeed_game_name");
      if (found != metadata.end() && found->second.IsHolding<std::string>()) { game = found->second.Get<std::string>(); break; }
    }
    data["lightspeed_game_name"] = VtValue(game);
  }
  layer->SetCustomLayerData(data);
  // Coordinate systems are stage metadata, so each replacement can also be
  // opened on its own. Never copy a different mod's units or light scale.
  if (!layer->HasField(SdfPath::AbsoluteRootPath(), TfToken("upAxis")))
    layer->SetField(SdfPath::AbsoluteRootPath(), TfToken("upAxis"), VtValue(UsdGeomGetStageUpAxis(stage)));
  if (!layer->HasField(SdfPath::AbsoluteRootPath(), TfToken("metersPerUnit")))
    layer->SetField(SdfPath::AbsoluteRootPath(), TfToken("metersPerUnit"), VtValue(UsdGeomGetStageMetersPerUnit(stage)));
  if (!layer->HasStartTimeCode()) layer->SetStartTimeCode(stage->HasAuthoredTimeCodeRange() ? stage->GetStartTimeCode() : 0);
  if (!layer->HasEndTimeCode()) layer->SetEndTimeCode(stage->HasAuthoredTimeCodeRange() ? stage->GetEndTimeCode() : 100);
  if (!layer->HasTimeCodesPerSecond()) layer->SetTimeCodesPerSecond(stage->GetTimeCodesPerSecond());
}

void normalize_replacement(const SdfLayerHandle& layer, const UsdStageRefPtr& stage) {
  std::vector<SdfPath> paths;
  layer->Traverse(SdfPath::AbsoluteRootPath(), [&](const SdfPath& path) { if (path.IsPrimPath()) paths.push_back(path); });
  for (const auto& path : paths) {
    auto spec = layer->GetPrimAtPath(path);
    bool animated_transform = false;
    for (auto attr : spec->GetAttributes())
      if (attr->GetName().rfind("xformOp", 0) == 0 && !attr->GetTimeSampleMap().empty()) animated_transform = true;
    auto transform = layer->GetAttributeAtPath(path.AppendProperty(TfToken("xformOp:transform")));
    auto order = layer->GetAttributeAtPath(path.AppendProperty(TfToken("xformOpOrder")));
    if (transform && order && !animated_transform &&
        transform->GetDefaultValue().IsHolding<GfMatrix4d>() && order->GetDefaultValue().IsHolding<VtTokenArray>()) {
      const auto ops = order->GetDefaultValue().Get<VtTokenArray>();
      const bool reset = ops.size() == 2 && ops.front() == TfToken("!resetXformStack!");
      if ((ops.size() == 1 || reset) && ops.back() == TfToken("xformOp:transform"))
        write_transform(spec, transform->GetDefaultValue().Get<GfMatrix4d>(), reset);
    }
    // Derive bounds from the composed authored light, including overridden
    // dimensions. Animated dimensions keep their existing extent opinions.
    auto prim = stage->GetPrimAtPath(path);
    if (spec->GetSpecifier() != SdfSpecifierDef || !UsdLuxLightAPI(prim) || !UsdGeomBoundable(prim)) continue;
    bool animated = false;
    for (const auto* name : {"inputs:radius", "inputs:width", "inputs:height", "inputs:length"}) {
      auto attr = prim.GetAttribute(TfToken(name));
      if (attr && attr.ValueMightBeTimeVarying()) animated = true;
    }
    VtVec3fArray extent;
    if (!animated && UsdGeomBoundable::ComputeExtentFromPlugins(UsdGeomBoundable(prim), UsdTimeCode::Default(), &extent))
      attribute(spec, "extent", SdfValueTypeNames->Float3Array, VtValue(extent));
  }
  const auto standalone = layer->GetPrimAtPath(SdfPath("/RootNode/StudioAssets"));
  if (standalone && standalone->GetNameChildren().empty() && standalone->GetProperties().empty()) {
    bool empty = true;
    for (const auto& key : standalone->ListInfoKeys())
      if (key != TfToken("specifier") && key != TfToken("typeName")) empty = false;
    if (empty) {
      SdfBatchNamespaceEdit removal; removal.Add(SdfNamespaceEdit::Remove(standalone->GetPath()));
      layer->Apply(removal);
    }
  }
}
}
