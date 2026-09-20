#include "document.h"
#include <chrono>
#include <iostream>
#include <pxr/usd/usdGeom/mesh.h>
#include <pxr/usd/usdLux/lightAPI.h>

using editor::Json;
namespace fs = std::filesystem;
PXR_NAMESPACE_USING_DIRECTIVE
namespace {
void check(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
}
int main() {
  const auto root = fs::temp_directory_path() / ("remix-light-updates-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  try {
    editor::Document doc; doc.create(fs::path(FIXTURE_DIR) / "capture.usda", root / "project.usda");
    // Emissive meshes are still geometry even if they carry the USD light API.
    UsdLuxLightAPI::Apply(doc.stage()->GetPrimAtPath(SdfPath("/RootNode/meshes/mesh_0123456789ABCDEF/mesh")));
    auto edit = [&](const Json& request, const std::string& kind = "lights") {
      auto result = doc.dispatch(request);
      check(result.at("scene_update") == kind, ("Wrong update classification for " + request.at("op").get<std::string>() + ": " + result.at("scene_update").dump()).c_str());
      auto lights = doc.dispatch({{"op", "lights"}});
      check(lights.at("lights") == doc.scene().at("lights"), "Light snapshots must match full scene composition");
      check(lights.at("revision") == doc.revision() && !lights.contains("meshes") && !lights.contains("materials"), "Light snapshots must omit geometry and carry the current revision");
      return result;
    };
    auto light = edit({{"op", "add_light"}, {"type", "SphereLight"}, {"translation", {0, 3, 0}}}).at("selection").get<std::string>();
    edit({{"op", "transform"}, {"path", light}, {"translation", {2, 3, 0}}});
    edit({{"op", "set_authoring_property"}, {"path", light}, {"property", "inputs:intensity"}, {"value", 200}});
    edit({{"op", "set_authoring_property"}, {"path", light}, {"property", "inputs:intensity"}, {"value", 200}}, "none");
    edit({{"op", "reset_authoring_property"}, {"path", light}, {"property", "inputs:intensity"}});
    edit({{"op", "set_light_type"}, {"path", light}, {"type", "RectLight"}});
    edit({{"op", "visibility"}, {"path", light}, {"visible", false}});
    check(doc.scene().at("lights").empty(), "Hiding a light must remove it from light snapshots");
    edit({{"op", "undo"}}); edit({{"op", "redo"}}); edit({{"op", "undo"}});
    const std::string instance = "/RootNode/instances/inst_0123456789ABCDEF_0";
    light = edit({{"op", "set_parent"}, {"path", light}, {"parent", instance}}).at("selection").get<std::string>();
    check(doc.scene().at("lights").size() == 2, "Light snapshots must include all shared capture attachments");
    edit({{"op", "set_authoring_property"}, {"path", light}, {"property", "inputs:intensity"}, {"value", 123}});
    const auto shared = doc.scene();
    for (const auto& entry : shared.at("lights")) check(entry.at("intensity") == 123, "Shared light edits must update every instance");
    auto copy = edit({{"op", "duplicate"}, {"path", light}}).at("selection").get<std::string>();
    check(doc.scene().at("lights").size() == 4, "Duplicated attachments must appear in light snapshots");
    check(edit({{"op", "delete"}, {"path", copy}}).at("selection") == "", "Deleting a light must clear selection");
    bool rejected = false;
    try { doc.inspect(copy); } catch (const std::exception&) { rejected = true; }
    check(rejected, "Inactive USD prims must not expose a selected gizmo or inspector");
    edit({{"op", "undo"}}); check(doc.inspect(copy).at("path") == copy, "Undo must restore deleted light inspection");
    edit({{"op", "redo"}});
    edit({{"op", "batch"}, {"commands", {
      {{"op", "set_authoring_property"}, {"path", light}, {"property", "inputs:intensity"}, {"value", 50}},
      {{"op", "transform"}, {"path", light}, {"translation", {0, 4, 0}}}
    }}});
    edit({{"op", "transform"}, {"path", instance + "/mesh"}, {"translation", {1, 0, 0}}}, "full");
    edit({{"op", "undo"}}, "full"); edit({{"op", "redo"}}, "full");
    light = edit({{"op", "set_parent"}, {"path", light}, {"parent", ""}}).at("selection").get<std::string>();
    // A light can itself parent geometry: moving or removing it needs a full scene.
    UsdGeomMesh::Define(doc.stage(), SdfPath(light + "/ChildMesh"));
    edit({{"op", "transform"}, {"path", light}, {"translation", {1, 4, 0}}}, "full");
    edit({{"op", "delete"}, {"path", light}}, "full");
    edit({{"op", "undo"}}, "full");
    fs::remove_all(root);
    std::cout << "Light update tests passed\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << "\nFixtures: " << root << '\n'; return 1; }
}
