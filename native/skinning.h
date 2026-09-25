#pragma once

#include "document.h"
#include <set>
#include <pxr/usd/usdGeom/mesh.h>
#include <pxr/usd/usdGeom/xformCache.h>
#include <pxr/usd/usdSkel/cache.h>

namespace editor {
// One cache per scene snapshot: poses are instance-specific, and no evaluated
// points or skeleton opinions are ever written back to the USD document.
class SceneSkinning {
public:
  explicit SceneSkinning(pxr::UsdGeomXformCache& transforms) : transforms_(transforms) {}
  std::string deform(const pxr::UsdGeomMesh& mesh, pxr::VtVec3fArray& points,
              pxr::VtVec3fArray& normals, pxr::TfToken& normal_interpolation,
              const pxr::VtIntArray& indices, const pxr::VtIntArray& counts);
  const Json& skeletons() const { return skeletons_; }
private:
  pxr::UsdGeomXformCache& transforms_;
  pxr::UsdSkelCache cache_;
  std::set<pxr::SdfPath> populated_;
  std::map<pxr::SdfPath, pxr::VtMatrix4dArray> poses_;
  Json skeletons_ = Json::object();
};
}
