#include "document.h"
#include "usd_authoring.h"
#include <chrono>
#include <fstream>
#include <iostream>
#include <pxr/base/tf/errorMark.h>
#include <pxr/usd/usdGeom/boundable.h>
#include <pxr/usd/usdGeom/metrics.h>
#include <pxr/usd/usdGeom/xformCache.h>
#include <pxr/usd/usdLux/rectLight.h>
#include <pxr/usd/usdLux/sphereLight.h>

PXR_NAMESPACE_USING_DIRECTIVE
namespace fs = std::filesystem;
using editor::Json;
namespace {
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
std::string text(const fs::path& path) { std::ifstream input(path); return {std::istreambuf_iterator<char>(input), {}}; }
GfMatrix4d local(const UsdPrim& prim) {
  GfMatrix4d matrix; bool reset;
  UsdGeomXformable(prim).GetLocalTransformation(&matrix, &reset); return matrix;
}
void same(const GfMatrix4d& a, const GfMatrix4d& b) {
  check(GfIsClose(a, b, 1e-5), "Transform conversion must retain position, orientation and size");
}
void check_trs(const UsdPrim& prim, bool reset = false) {
  VtTokenArray order;
  check(UsdGeomXformable(prim).GetXformOpOrderAttr().Get(&order), "Missing transform order");
  VtTokenArray expected;
  if (reset) expected.push_back(TfToken("!resetXformStack!"));
  for (const auto* op : {"xformOp:translate", "xformOp:rotateXYZ", "xformOp:scale"}) expected.push_back(TfToken(op));
  check(order == expected, "Static attachments must use Toolkit's translate / rotateXYZ / scale order");
  check(!prim.GetAttribute(TfToken("xformOp:transform")), "Unused legacy matrices must be removed");
}
void bounds(const UsdPrim& prim, const GfVec3f& half_size) {
  VtVec3fArray extent;
  check(UsdGeomBoundable(prim).GetExtentAttr().Get(&extent) && extent == VtVec3fArray{-half_size, half_size},
        "Light extent must match the emitter's local dimensions");
}
Json values(const GfMatrix4d& matrix) {
  Json result = Json::array();
  for (int r = 0; r < 4; ++r) for (int c = 0; c < 4; ++c) result.push_back(matrix[r][c]);
  return result;
}
}

int main() {
  const auto directory = fs::temp_directory_path() / ("remix-format-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  fs::create_directories(directory);
  try {
    TfErrorMark errors;
    const auto capture = fs::path(FIXTURE_DIR) / "capture.usda";
    const auto original = text(capture);
    editor::Document doc; doc.create(capture, directory / "work.usda");
    const std::string instance = "/RootNode/instances/inst_0123456789ABCDEF_1";
    const auto path = doc.dispatch({{"op", "add_light"}, {"type", "SphereLight"}})["selection"].get<std::string>();
    auto prim = doc.stage()->GetPrimAtPath(SdfPath(path));
    check_trs(prim); bounds(prim, GfVec3f(5));
    doc.dispatch({{"op", "set_authoring_property"}, {"path", path}, {"property", "inputs:radius"}, {"value", 7}});
    bounds(prim, GfVec3f(7)); doc.undo(); bounds(prim, GfVec3f(5)); doc.redo(); bounds(prim, GfVec3f(7));
    doc.dispatch({{"op", "set_light_type"}, {"path", path}, {"type", "RectLight"}});
    doc.dispatch({{"op", "set_authoring_property"}, {"path", path}, {"property", "inputs:width"}, {"value", 8}});
    doc.dispatch({{"op", "set_authoring_property"}, {"path", path}, {"property", "inputs:height"}, {"value", 6}});
    bounds(prim, GfVec3f(4, 3, 0));
    doc.dispatch({{"op", "set_light_type"}, {"path", path}, {"type", "DistantLight"}});
    check(!prim.GetAttribute(TfToken("extent")), "Changing to an unbounded light must remove old emitter bounds");
    doc.undo(); bounds(prim, GfVec3f(4, 3, 0));

    for (const auto& scale : {GfVec3d(1), GfVec3d(100), GfVec3d(-2, 3, 4), GfVec3d(2, -3, -4)}) {
      for (const auto& rotation : {GfVec3f(23, -47, 136), GfVec3f(12, 90, -25), GfVec3f(-50, -90, 31)}) {
        auto matrix = GfMatrix4d(1).SetScale(scale) * UsdGeomXformOp::GetOpTransform(UsdGeomXformOp::TypeRotateXYZ, VtValue(rotation), false);
        matrix.SetTranslateOnly(GfVec3d(3079.465576171875, 2112.412353515625, -48.98970031738281));
        doc.dispatch({{"op", "transform"}, {"path", path}, {"matrix", values(matrix)}});
        check_trs(prim); same(local(prim), matrix);
      }
    }
    doc.dispatch({{"op", "transform"}, {"path", path}, {"matrix", values(GfMatrix4d(1))}});
    doc.dispatch({{"op", "transform"}, {"path", path}, {"rotation", {23, -47, 136}}});
    const auto angles = doc.inspect(path)["rotation"];
    check(std::abs(angles[0].get<double>() - 23) < 1e-5 && std::abs(angles[1].get<double>() + 47) < 1e-5 &&
      std::abs(angles[2].get<double>() - 136) < 1e-5, "Inspector must report the same XYZ order as the authored transform");
    const auto rotated = local(prim);
    doc.dispatch({{"op", "transform"}, {"path", path}, {"scale", {2, 3, 4}}});
    same(local(prim), GfMatrix4d(1).SetScale(GfVec3d(2, 3, 4)) * rotated);
    // Exact matrix reported by the user, including capture floating-point noise.
    const GfMatrix4d reported(-0.244675759507496, 0.9696050482078551, 0, 0,
      -0.9696051060008268, -0.24467574492368524, 0, 0, 0, 0, 1.0000000596046483, 0,
      -727.7873563347988, 261.9990416438899, 24.975205956411287, 1);
    doc.dispatch({{"op", "transform"}, {"path", path}, {"matrix", values(reported)}});
    check_trs(prim); same(local(prim), reported);
    const auto before_parent = UsdGeomXformCache().GetLocalToWorldTransform(prim);
    const auto attached = doc.dispatch({{"op", "set_parent"}, {"path", path}, {"parent", instance + "/mesh"}})["selection"].get<std::string>();
    same(UsdGeomXformCache().GetLocalToWorldTransform(doc.stage()->GetPrimAtPath(SdfPath(attached))), before_parent);
    const auto authored = doc.inspect(attached)["authoring"]["edit_path"].get<std::string>();
    prim = doc.stage()->GetPrimAtPath(SdfPath(authored)); check_trs(prim);

    // Mimic an existing project. Publication upgrades a copy without changing
    // its revision, undo history, authored matrix or saved project files.
    UsdGeomXformable(prim).MakeMatrixXform().Set(reported);
    auto animated = UsdLuxSphereLight::Define(doc.stage(), SdfPath(authored).GetParentPath().AppendChild(TfToken("Animated")));
    auto op = animated.MakeMatrixXform(); op.Set(reported); op.Set(GfMatrix4d(1), 0); op.Set(reported, 24);
    auto reset_light = UsdLuxSphereLight::Define(doc.stage(), SdfPath(authored).GetParentPath().AppendChild(TfToken("Reset")));
    reset_light.MakeMatrixXform().Set(reported); reset_light.SetResetXformStack(true);
    auto sheared = UsdLuxSphereLight::Define(doc.stage(), SdfPath(authored).GetParentPath().AppendChild(TfToken("Sheared")));
    auto shear = reported; shear[0][2] = 0.25;
    editor::author_transform(sheared, shear, true);
    check(bool(sheared.GetPrim().GetAttribute(TfToken("xformOp:transform"))), "Shear needs its full matrix");
    doc.save();
    const auto layer = doc.stage()->GetEditTarget().GetLayer();
    const auto before = editor::layer_text(layer);
    const auto revision = doc.revision();
    doc.package(directory / "package");
    auto packaged = UsdStage::Open((directory / "package/mod.usda").string());
    auto published = packaged->GetPrimAtPath(SdfPath(authored));
    check(published.IsDefined(), "Light must be defined without the capture");
    check_trs(published); same(local(published), reported); bounds(published, GfVec3f(4, 3, 0));
    same(local(packaged->GetPrimAtPath(sheared.GetPath())), shear);
    check(UsdGeomXformable(packaged->GetPrimAtPath(sheared.GetPath())).GetResetXformStack(), "Reset stack must survive fallback");
    auto samples = packaged->GetPrimAtPath(animated.GetPath()).GetAttribute(TfToken("xformOp:transform"));
    check(samples && samples.GetNumTimeSamples() == 2, "Animated matrices must not be collapsed to static TRS");
    auto published_reset = packaged->GetPrimAtPath(reset_light.GetPath());
    check_trs(published_reset, true); same(local(published_reset), reported);
    check(!packaged->GetPrimAtPath(SdfPath("/RootNode/StudioAssets")), "Empty standalone containers must be omitted from publication");
    check(!packaged->GetPrimAtPath(SdfPath("/RootNode/instances")), "Capture instances must not be exported");
    for (const auto& source : packaged->GetLayerStack(false)) {
      if (source->IsAnonymous()) continue;
      auto metadata = source->GetCustomLayerData();
      check(metadata["lightspeed_layer_type"].Get<std::string>() == "replacement" &&
        metadata["lightspeed_game_name"].Get<std::string>() == "Unknown Game", "Replacement metadata must be present on each project layer");
      check(source->HasStartTimeCode() && source->HasEndTimeCode() && source->HasTimeCodesPerSecond(), "Replacement layers need explicit timing metadata");
      auto standalone = UsdStage::Open(source);
      check(UsdGeomGetStageUpAxis(standalone) == UsdGeomTokens->y && UsdGeomGetStageMetersPerUnit(standalone) == 1,
        "Replacement layers must retain the capture coordinate system when opened alone");
    }
    check(editor::layer_text(layer) == before && text(directory / "mod.usda") == before && doc.revision() == revision,
      "Publishing must not mutate the project or its undo history");
    check(text(capture) == original, "Capture must remain unchanged");
    check(errors.IsClean(), "Replacement formatting emitted USD errors");
    fs::remove_all(directory);
    std::cout << "Replacement formatting passed\n"; return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << "\nFixtures: " << directory << '\n'; return 1; }
}
