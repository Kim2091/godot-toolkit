#include "document.h"
#include <chrono>
#include <fstream>
#include <iostream>
#include <pxr/base/tf/errorMark.h>
#include <pxr/usd/usdGeom/xformable.h>
#include <pxr/usd/usdShade/materialBindingAPI.h>

PXR_NAMESPACE_USING_DIRECTIVE
namespace fs = std::filesystem;
using editor::Json;
namespace {
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
std::string text(const fs::path& path) { std::ifstream input(path); return {std::istreambuf_iterator<char>(input), {}}; }
}
int main() {
  const auto directory = fs::temp_directory_path() / ("remix-inheritance-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  fs::create_directories(directory / "game/rtx-remix/mods");
  try {
    TfErrorMark errors;
    const auto mods = directory / "game/rtx-remix/mods";
    const auto base = mods / "base_mod/mod.usda";
    fs::create_directories(base.parent_path() / "maps");
    const auto map = base.parent_path() / "maps/map.usda";
    std::ofstream(base) << "#usda 1.0\n(subLayers = [@maps/map.usda@])\n";
    std::ofstream(map) << R"USD(#usda 1.0
def "RootNode" {
    def "Looks" {
        def Material "mat_2222222222222222" {
            token outputs:mdl:surface.connect = </RootNode/Looks/mat_2222222222222222/Shader.outputs:out>
            def Shader "Shader" {
                color3f inputs:diffuse_color_constant = (0.2, 0.3, 0.4)
                asset inputs:diffuse_texture = @../texture.dds@
                token outputs:out
            }
        }
    }
    def "meshes" {
        def "mesh_0123456789ABCDEF" {
            custom int preserveOriginalDrawCall = 0
            def Mesh "BaseMesh" (prepend apiSchemas = ["MaterialBindingAPI"]) {
                rel material:binding = </RootNode/Looks/mat_2222222222222222>
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0, 1, 2]
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            }
            def RectLight "BaseLight" {
                float inputs:intensity = 123
                double3 xformOp:translate = (11, 12, 13)
                uniform token[] xformOpOrder = ["xformOp:translate"]
            }
        }
        def "mesh_9999999999999999" {
            def RectLight "UnrelatedLight" {
                float inputs:intensity = 25
            }
        }
    }
}
)USD";
    std::ofstream(base.parent_path() / "texture.dds") << "texture data";
    // A second mod with the same hash must not leak its attachments into the
    // base winner. An earlier mod owning only materials must keep its priority.
    fs::create_directories(mods / "c_later");
    std::ofstream(mods / "c_later/mod.usda") << R"USD(#usda 1.0
def "RootNode" { def "meshes" { def "mesh_0123456789ABCDEF" { def SphereLight "LosingLight" {} } } }
)USD";
    fs::create_directories(mods / "a_materials");
    std::ofstream(mods / "a_materials/mod.usda") << R"USD(#usda 1.0
def "RootNode" { def "Looks" { def Material "mat_2222222222222222" {} } }
)USD";
    const auto base_before = text(base), map_before = text(map);
    const auto project = directory / "project/work.usda";
    editor::Document doc; doc.create(fs::path(FIXTURE_DIR) / "capture.usda", project);
    const std::string hash = "/RootNode/meshes/mesh_0123456789ABCDEF";
    auto light = doc.dispatch({{"op", "add_light"}, {"path", "/RootNode/instances/inst_0123456789ABCDEF_0"},
      {"type", "SphereLight"}, {"translation", {1, 2, 3}}})["selection"].get<std::string>();
    const auto authored = editor::layer_text(doc.stage()->GetEditTarget().GetLayer());
    const auto revision = doc.revision();
    // Start with the old link settings, as in the user's existing light-test.
    // Initially the base mod is absent so the requested name is used as-is.
    fs::rename(base, base.parent_path() / "disabled.usda");
    fs::rename(mods / "c_later/mod.usda", mods / "c_later/disabled.usda");
    auto linked = doc.dispatch({{"op", "game_link"}, {"folder", mods.string()}, {"name", "light-test"}});
    check(linked["target"] == (mods / "light-test").string(), "A conflict-free link must keep its requested name");
    fs::rename(base.parent_path() / "disabled.usda", base);
    fs::rename(mods / "c_later/disabled.usda", mods / "c_later/mod.usda");
    linked = doc.dispatch({{"op", "game_sync"}});
    const fs::path target = linked["target"].get<std::string>();
    check(target < base.parent_path() && linked["priority_changed"] && linked["retained_mods"].size() == 1,
      "A shared hash must publish before its base and report retained attachments");
    check(fs::is_symlink(mods / "light-test") && fs::equivalent(mods / "light-test", target),
      "The previous watched link must remain valid during a running game");
    auto stage = UsdStage::Open((target / "mod.usda").string());
    auto published = stage->GetPrimAtPath(SdfPath(hash));
    check(published.GetChild(TfToken("BaseLight")) && stage->GetPrimAtPath(SdfPath(light)),
      "The first runtime replacement must contain both base and project lights");
    check(!published.GetChild(TfToken("LosingLight")), "Later conflicting mods must retain their original losing precedence");
    check(!stage->GetPrimAtPath(SdfPath("/RootNode/meshes/mesh_9999999999999999")) &&
      !stage->GetPrimAtPath(SdfPath("/RootNode/Looks/mat_2222222222222222")),
      "Inherited resources must not register unrelated mesh or material replacements");
    int preserve = 1;
    published.GetAttribute(TfToken("preserveOriginalDrawCall")).Get(&preserve);
    check(preserve == 0, "Attaching a light must not resurrect a mesh suppressed by the base");
    auto material = UsdShadeMaterialBindingAPI(published.GetChild(TfToken("BaseMesh"))).ComputeBoundMaterial();
    check(material && material.GetPath().HasPrefix(SdfPath("/RootNode/__StudioInherited")),
      "Retained meshes must keep their material bindings in the private resource namespace");
    auto shader = material.GetPrim().GetChild(TfToken("Shader"));
    SdfAssetPath texture;
    check(shader.GetAttribute(TfToken("inputs:diffuse_texture")).Get(&texture) &&
      fs::equivalent(texture.GetResolvedPath(), base.parent_path() / "texture.dds"), "Inherited relative textures must resolve through live links");
    SdfPathVector connections;
    material.GetPrim().GetAttribute(TfToken("outputs:mdl:surface")).GetConnections(&connections);
    check(connections.size() == 1 && connections[0].GetPrimPath() == shader.GetPath(), "Inherited shader connections must remain valid");
    GfMatrix4d pose; bool reset;
    UsdGeomXformable(stage->GetPrimAtPath(SdfPath(light))).GetLocalTransformation(&pose, &reset);
    check(pose.ExtractTranslation() == GfVec3d(1, 2, 3), "Inheritance must not move the project light");
    check(text(base) == base_before && text(map) == map_before && doc.revision() == revision &&
      editor::layer_text(doc.stage()->GetEditTarget().GetLayer()) == authored, "Inheritance must leave installed mods and project edits untouched");
    auto again = doc.dispatch({{"op", "game_sync"}});
    check(again["target"] == target.string(), "Repeated sync must not keep changing link priority");
    doc.dispatch({{"op", "delete"}, {"path", light}}); doc.dispatch({{"op", "game_sync"}}); stage->Reload();
    check(!stage->GetPrimAtPath(SdfPath(light)).IsActive() && stage->GetPrimAtPath(SdfPath(hash + "/BaseLight")),
      "Deleting a project light must retain the inherited light");
    doc.undo(); doc.dispatch({{"op", "game_sync"}}); stage->Reload();
    check(stage->GetPrimAtPath(SdfPath(light)).IsActive(), "Undo must restore the project light without changing the base");
    doc.save(); editor::Document reopened; reopened.open(project);
    check(reopened.dispatch({{"op", "game_link_status"}})["retained_mods"].size() == 1, "Retention status must persist across sessions");
    reopened.dispatch({{"op", "game_unlink"}});
    check(!fs::exists(target) && !fs::exists(mods / "light-test") && text(base) == base_before && text(map) == map_before,
      "Unlink must remove owned aliases and leave installed base mods intact");
    check(errors.IsClean(), "Inheritance emitted USD errors");
    fs::remove_all(directory); std::cout << "Game inheritance passed\n"; return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << "\nFixtures: " << directory << '\n'; return 1; }
}
