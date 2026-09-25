#include "document.h"
#include "dxvk/rtx_render/rtx_light_usd_value.h"
#include <chrono>
#include <iostream>
#include <pxr/base/tf/errorMark.h>
#include <pxr/usd/usd/primRange.h>
#include <pxr/usd/usdLux/lightAPI.h>

PXR_NAMESPACE_USING_DIRECTIVE
namespace fs = std::filesystem;
using editor::Json;
namespace {
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }

// Same attribute precedence as LightData::getLightAttribute in the game.
VtValue value(const UsdPrim& prim, const char* name) {
  auto attr = prim.GetAttribute(TfToken(std::string("inputs:") + name));
  if (!attr.IsAuthored()) attr = prim.GetAttribute(TfToken(name));
  VtValue result;
  if (attr) attr.Get(&result);
  return result;
}

void color(const UsdPrim& prim, const GfVec3f& expected) {
  const auto authored = value(prim, "color");
  check(authored.IsHolding<GfVec3f>(), "Published light color must use USD's native float vector");
  // Reproduce the installed 12759b3e runtime's failed type check.
  check(!authored.IsHolding<dxvk::Vector3>(), "USD colors must not hold renderer-private vector types");
  dxvk::Vector3 rgb(1);
  check(dxvk::readUsdLightValue(authored, rgb), "Runtime must accept color3f");
  check(rgb == dxvk::Vector3(expected.data()), "Runtime must retain every color channel");
  float intensity = 1, exposure = 0;
  bool temperature = true;
  check(dxvk::readUsdLightValue(value(prim, "intensity"), intensity) && intensity == 100, "Radiance must survive publication");
  check(dxvk::readUsdLightValue(value(prim, "exposure"), exposure) && exposure == 0, "Exposure must survive publication");
  check(dxvk::readUsdLightValue(value(prim, "enableColorTemperature"), temperature) && !temperature,
        "Disabled temperature must survive publication");
}
}

int main(int argc, char** argv) {
  const auto directory = fs::temp_directory_path() / ("remix-light-color-" +
    std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  try {
    TfErrorMark errors;
    editor::Document doc;
    doc.create(fs::path(FIXTURE_DIR) / "capture.usda", directory / "project.usda");
    const auto game = directory / "game/rtx-remix/mods";
    fs::create_directories(game);
    doc.dispatch({{"op", "game_link"}, {"folder", game.string()}, {"name", "color-test"}});
    std::vector<std::string> paths;
    for (const char* type : {"SphereLight", "RectLight", "DiskLight", "CylinderLight", "DistantLight"}) {
      auto path = doc.dispatch({{"op", "add_light"}, {"type", type}})["selection"].get<std::string>();
      path = doc.dispatch({{"op", "set_parent"}, {"path", path},
        {"parent", "/RootNode/instances/inst_0123456789ABCDEF_0"}})["selection"].get<std::string>();
      const auto authored = doc.inspect(path)["authoring"]["edit_path"].get<std::string>();
      paths.push_back(authored);
      doc.dispatch({{"op", "set_authoring_property"}, {"path", path}, {"property", "inputs:intensity"}, {"value", 100}});
      for (const auto& rgb : {GfVec3f(1, 0, 0), GfVec3f(0, 1, 0), GfVec3f(0, 0, 1), GfVec3f(0.25f, 0.5f, 0.75f)}) {
        doc.dispatch({{"op", "set_authoring_property"}, {"path", path}, {"property", "inputs:color"},
          {"value", {rgb[0], rgb[1], rgb[2]}}});
        color(doc.stage()->GetPrimAtPath(SdfPath(authored)), rgb);
        doc.dispatch({{"op", "game_sync"}});
        auto live = UsdStage::Open((game / "color-test/mod.usda").string());
        color(live->GetPrimAtPath(SdfPath(authored)), rgb);
      }
    }
    doc.save(); doc.package(directory / "package");
    auto package = UsdStage::Open((directory / "package/mod.usda").string());
    for (const auto& path : paths) color(package->GetPrimAtPath(SdfPath(path)), GfVec3f(0.25f, 0.5f, 0.75f));

    // Legacy attributes still deserialize. Bad types must leave defaults intact
    // instead of reintroducing the unsafe reinterpretation this runtime guarded.
    auto legacy = UsdStage::CreateInMemory();
    check(legacy->GetRootLayer()->ImportFromString(R"(#usda 1.0
def SphereLight "Legacy" {
    color3f color = (0, 1, 0)
}
)"), "Legacy light fixture must parse");
    dxvk::Vector3 rgb(1);
    check(dxvk::readUsdLightValue(value(legacy->GetPrimAtPath(SdfPath("/Legacy")), "color"), rgb) &&
      rgb == dxvk::Vector3(0, 1, 0), "Legacy colors must load");
    for (const auto& invalid : {VtValue(), VtValue(std::string("red")), VtValue(1.f), VtValue(GfVec3d(1))}) {
      check(!dxvk::readUsdLightValue(invalid, rgb) && rgb == dxvk::Vector3(0, 1, 0), "Bad colors must leave output unchanged");
    }
    float intensity = 100;
    check(!dxvk::readUsdLightValue(VtValue(std::string("100")), intensity) && intensity == 100, "Scalar type checks must remain intact");
    bool enabled = false;
    check(dxvk::readUsdLightValue(VtValue(true), enabled) && enabled, "Temperature enable must remain supported");
    check(errors.IsClean(), "Color loading must not emit USD diagnostics");

    // Optional read-only verification of an actual published mod.
    if (argc > 1) {
      auto stage = UsdStage::Open(argv[1]);
      check(bool(stage), "Cannot open supplied mod");
      unsigned checked = 0;
      for (const auto& prim : stage->Traverse()) {
        if (!UsdLuxLightAPI(prim)) continue;
        const auto val = value(prim, "color");
        check(dxvk::readUsdLightValue(val, rgb), "Actual mod color must deserialize");
        std::cout << prim.GetPath() << ": " << rgb.x << ", " << rgb.y << ", " << rgb.z << '\n';
        ++checked;
      }
      check(checked > 0, "No lights found in supplied mod");
    }
    fs::remove_all(directory);
    std::cout << "Remix USD light color tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << "\nFixtures: " << directory << '\n'; return 1;
  }
}
