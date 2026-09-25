#pragma once

#include <pxr/base/gf/matrix4d.h>
#include <pxr/usd/usdGeom/xformable.h>

namespace editor {
// Toolkit-compatible static transforms. Matrices with shear retain their full
// matrix representation, since three TRS ops cannot represent them faithfully.
void author_transform(const pxr::UsdGeomXformable& xform, const pxr::GfMatrix4d& matrix, bool reset);
void update_light_extent(pxr::UsdPrim prim);
void replacement_metadata(const pxr::SdfLayerHandle& layer, const pxr::UsdStageRefPtr& stage);
// Normalize publication copies, never the capture or the user's undo history.
void normalize_replacement(const pxr::SdfLayerHandle& layer, const pxr::UsdStageRefPtr& stage);
}
