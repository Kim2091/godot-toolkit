#include "document.h"

#include <cmath>
#include <map>
#include <set>
#include <array>
#include <algorithm>
#include <pxr/base/gf/vec2f.h>
#include <pxr/usd/usd/primRange.h>
#include <pxr/usd/usdGeom/camera.h>
#include <pxr/usd/usdGeom/mesh.h>
#include <pxr/usd/usdGeom/metrics.h>
#include <pxr/usd/usdGeom/primvarsAPI.h>
#include <pxr/usd/usdGeom/subset.h>
#include <pxr/usd/usdGeom/xformCache.h>
#include <pxr/usd/usdLux/lightAPI.h>
#include <pxr/usd/usdShade/material.h>
#include <pxr/usd/usdShade/materialBindingAPI.h>
#include <pxr/usd/usdShade/shader.h>

PXR_NAMESPACE_USING_DIRECTIVE
namespace editor {
namespace {
std::string source_path(const UsdPrim& prim) {
  for (const auto& spec : prim.GetPrimStack()) {
    const auto path = spec->GetPath().GetString();
    if (path.rfind("/RootNode/meshes/", 0) == 0 || path.rfind("/RootNode/lights/", 0) == 0) return path;
  }
  return prim.GetPath().GetString();
}
Json matrix_json(const GfMatrix4d& matrix) {
  Json values = Json::array();
  for (int r = 0; r < 4; ++r) for (int c = 0; c < 4; ++c) values.push_back(matrix[r][c]);
  return values;
}
template<typename T> T attribute(const UsdPrim& prim, const char* name, const T& fallback) {
  T result = fallback;
  if (!prim) return result;
  auto attr = prim.GetAttribute(TfToken(name));
  if (attr) attr.Get(&result);
  return result;
}
std::string texture(const UsdPrim& shader, const char* name) {
  auto value = attribute(shader, name, SdfAssetPath());
  return value.GetResolvedPath().empty() ? value.GetAssetPath() : value.GetResolvedPath();
}
Json material_json(const UsdShadeMaterial& material) {
  auto connected = material.ComputeSurfaceSource(TfToken("mdl"));
  UsdPrim shader = connected ? connected.GetPrim() : UsdPrim();
  if (!shader) for (auto child : material.GetPrim().GetChildren()) if (child.IsA<UsdShadeShader>()) { shader = child; break; }
  auto color = attribute(shader, "inputs:diffuse_color_constant", GfVec3f(0.7f));
  auto emission = attribute(shader, "inputs:emissive_color_constant", GfVec3f(0.0f));
  auto transmission = attribute(shader, "inputs:transmittance_color", GfVec3f(1.0f));
  auto source = attribute(shader, "info:mdl:sourceAsset", SdfAssetPath()).GetAssetPath();
  const bool translucent = source.find("Translucent") != std::string::npos;
  VtValue alpha_reference;
  if (shader) {
    const auto attr = shader.GetAttribute(TfToken("inputs:alpha_test_reference_value"));
    if (attr) attr.Get(&alpha_reference);
  }
  const auto alpha = VtValue::Cast<float>(alpha_reference);
  return {
    {"id", material.GetPath().GetString()},
    {"kind", translucent ? "translucent" : "opaque"},
    {"albedo", {color[0], color[1], color[2]}},
    {"roughness", attribute(shader, "inputs:reflection_roughness_constant", 0.5f)},
    {"metallic", attribute(shader, "inputs:metallic_constant", 0.0f)},
    {"opacity", attribute(shader, "inputs:opacity_constant", 1.0f)},
    {"alpha_test", attribute(shader, "inputs:alpha_test_type", 7)},
    {"alpha_reference", alpha.IsHolding<float>() ? int(std::clamp(alpha.Get<float>(), 0.f, 255.f)) : 0},
    {"emissive", {emission[0], emission[1], emission[2]}},
    {"emissive_intensity", attribute(shader, "inputs:enable_emission", false) ? attribute(shader, "inputs:emissive_intensity", 40.0f) : 0.0f},
    {"ior", attribute(shader, "inputs:ior_constant", 1.3f)},
    {"transmittance", {transmission[0], transmission[1], transmission[2]}},
    {"albedo_texture", texture(shader, translucent ? "inputs:transmittance_texture" : "inputs:diffuse_texture")},
    {"normal_texture", texture(shader, "inputs:normalmap_texture")},
    {"roughness_texture", texture(shader, "inputs:reflectionroughness_texture")},
    {"metallic_texture", texture(shader, "inputs:metallic_texture")},
    {"emissive_texture", texture(shader, "inputs:emissive_mask_texture")}
  };
}
int element_index(const TfToken& interpolation, int face, int corner, int vertex) {
  if (interpolation == UsdGeomTokens->constant) return 0;
  if (interpolation == UsdGeomTokens->uniform) return face;
  if (interpolation == UsdGeomTokens->faceVarying) return corner;
  return vertex;
}
// Project onto the dominant plane so concave polygon faces can be ear-clipped.
std::vector<std::array<int, 3>> triangulate(const VtVec3fArray& points, const VtIntArray& indices, int start, int count) {
  std::vector<std::array<int, 3>> triangles;
  if (count < 3) return triangles;
  GfVec3f normal(0);
  for (int i = 0; i < count; ++i) normal += GfCross(points[indices[start + i]], points[indices[start + (i + 1) % count]]);
  int axis = 0;
  if (std::abs(normal[1]) > std::abs(normal[axis])) axis = 1;
  if (std::abs(normal[2]) > std::abs(normal[axis])) axis = 2;
  int x = (axis + 1) % 3, y = (axis + 2) % 3;
  auto cross = [&](int a, int b, int c) {
    const auto& pa = points[indices[start + a]];
    const auto& pb = points[indices[start + b]];
    const auto& pc = points[indices[start + c]];
    return (pb[x] - pa[x]) * (pc[y] - pa[y]) - (pb[y] - pa[y]) * (pc[x] - pa[x]);
  };
  const float sign = normal[axis] >= 0 ? 1.f : -1.f;
  std::vector<int> corners;
  for (int i = 0; i < count; ++i) corners.push_back(i);
  while (corners.size() > 3) {
    bool found = false;
    for (size_t i = 0; i < corners.size(); ++i) {
      int a = corners[(i + corners.size() - 1) % corners.size()], b = corners[i], c = corners[(i + 1) % corners.size()];
      if (cross(a, b, c) * sign <= 1e-12f) continue;
      bool contains = false;
      for (int p : corners) {
        if (p == a || p == b || p == c) continue;
        if (cross(a, b, p) * sign >= 0 && cross(b, c, p) * sign >= 0 && cross(c, a, p) * sign >= 0) { contains = true; break; }
      }
      if (contains) continue;
      triangles.push_back({start + a, start + b, start + c});
      corners.erase(corners.begin() + i); found = true; break;
    }
    if (!found) throw std::runtime_error("Degenerate or self-intersecting polygon");
  }
  triangles.push_back({start + corners[0], start + corners[1], start + corners[2]});
  return triangles;
}
}

Json compose_scene(const UsdStageRefPtr& stage, uint64_t revision) {
  Json result{{"revision", revision}, {"meshes", Json::array()}, {"materials", Json::array()},
    {"lights", Json::array()}, {"cameras", Json::array()}, {"warnings", Json::array()},
    {"up_axis", UsdGeomGetStageUpAxis(stage).GetString()}, {"meters_per_unit", UsdGeomGetStageMetersPerUnit(stage)}};
  UsdGeomXformCache transforms;
  std::set<std::string> materials;
  for (auto prim : UsdPrimRange::Stage(stage, UsdTraverseInstanceProxies())) {
    auto imageable = UsdGeomImageable(prim);
    if (imageable && imageable.ComputeVisibility() == UsdGeomTokens->invisible) continue;
    const auto path = prim.GetPath().GetString();
    const auto world = transforms.GetLocalToWorldTransform(prim);
    if (auto mesh = UsdGeomMesh(prim)) {
      try {
        VtVec3fArray points, normals;
        VtIntArray indices, counts, holes;
        mesh.GetPointsAttr().Get(&points); mesh.GetFaceVertexIndicesAttr().Get(&indices);
        mesh.GetFaceVertexCountsAttr().Get(&counts); mesh.GetNormalsAttr().Get(&normals);
        mesh.GetHoleIndicesAttr().Get(&holes);
        std::string reason;
        if (!UsdGeomMesh::ValidateTopology(indices, counts, points.size(), &reason)) throw std::runtime_error(reason);
        VtVec2fArray uv;
        auto st = UsdGeomPrimvarsAPI(mesh).GetPrimvar(TfToken("st"));
        if (st) st.ComputeFlattened(&uv);
        auto binding = UsdShadeMaterialBindingAPI(prim).ComputeBoundMaterial();
        std::map<int, UsdShadeMaterial> face_materials;
        for (auto subset : UsdGeomSubset::GetGeomSubsets(mesh, UsdGeomTokens->face, TfToken("materialBind"))) {
          VtIntArray faces; subset.GetIndicesAttr().Get(&faces);
          auto bound = UsdShadeMaterialBindingAPI(subset.GetPrim()).ComputeBoundMaterial();
          for (int face : faces) face_materials[face] = bound;
        }
        std::map<std::string, Json> surfaces;
        int corner = 0;
        for (size_t face = 0; face < counts.size(); ++face) {
          const int count = counts[face], first = corner; corner += count;
          if (std::find(holes.begin(), holes.end(), int(face)) != holes.end()) continue;
          auto material = face_materials.count(face) ? face_materials.at(face) : binding;
          std::string material_id = material ? material.GetPath().GetString() : "default";
          if (material && materials.insert(material_id).second) result["materials"].push_back(material_json(material));
          if (!surfaces.count(material_id)) surfaces[material_id] = {{"material", material_id}, {"vertices", Json::array()}, {"indices", Json::array()}};
          auto& surface = surfaces[material_id];
          for (auto triangle : triangulate(points, indices, first, count)) {
            if (attribute(prim, "orientation", UsdGeomTokens->rightHanded) == UsdGeomTokens->leftHanded) std::swap(triangle[1], triangle[2]);
            auto geometric = GfCross(points[indices[triangle[1]]] - points[indices[triangle[0]]], points[indices[triangle[2]]] - points[indices[triangle[0]]]).GetNormalized();
            for (int c : triangle) {
              int vertex = indices[c];
              auto point = points[vertex];
              auto normal = geometric;
              auto n = element_index(mesh.GetNormalsInterpolation(), face, c, vertex);
              if (n >= 0 && size_t(n) < normals.size()) normal = normals[n];
              GfVec2f texcoord(0);
              int u = st ? element_index(st.GetInterpolation(), face, c, vertex) : -1;
              if (u >= 0 && size_t(u) < uv.size()) texcoord = uv[u];
              surface["indices"].push_back(surface["vertices"].size());
              surface["vertices"].push_back({point[0], point[1], point[2], normal[0], normal[1], normal[2], texcoord[0], texcoord[1]});
            }
          }
        }
        Json parts = Json::array();
        for (auto& entry : surfaces) parts.push_back(std::move(entry.second));
        result["meshes"].push_back({{"id", path}, {"source_path", source_path(prim)}, {"transform", matrix_json(world)}, {"surfaces", parts},
          {"double_sided", attribute(prim, "doubleSided", false)}});
      } catch (const std::exception& error) { result["warnings"].push_back(path + ": " + error.what()); }
    } else if (auto light = UsdLuxLightAPI(prim)) {
      auto color = attribute(prim, "inputs:color", GfVec3f(1));
      result["lights"].push_back({{"id", path}, {"source_path", source_path(prim)}, {"type", prim.GetTypeName().GetString()},
        {"transform", matrix_json(world)}, {"color", {color[0], color[1], color[2]}},
        {"intensity", attribute(prim, "inputs:intensity", 1.f) * std::pow(2.f, attribute(prim, "inputs:exposure", 0.f))},
        {"radius", attribute(prim, "inputs:radius", 0.5f)}, {"width", attribute(prim, "inputs:width", 1.f)},
        {"height", attribute(prim, "inputs:height", 1.f)}, {"length", attribute(prim, "inputs:length", 1.f)},
        {"angle", attribute(prim, "inputs:angle", 0.53f)}, {"cone_angle", attribute(prim, "inputs:shaping:cone:angle", 180.f)},
        {"texture", texture(prim, "inputs:texture:file")}});
    } else if (auto camera = UsdGeomCamera(prim)) {
      result["cameras"].push_back({{"id", path}, {"transform", matrix_json(world)},
        {"focal_length", attribute(prim, "focalLength", 50.f)}, {"horizontal_aperture", attribute(prim, "horizontalAperture", 20.955f)}});
    }
  }
  return result;
}
}
