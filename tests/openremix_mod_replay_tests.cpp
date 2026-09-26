#include "document.h"
#include "usd/mods.h"
#include "usd/submission.h"
#include <chrono>
#include <iostream>
#include <thread>

namespace fs = std::filesystem;
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
int main() {
  const auto root = fs::temp_directory_path() / ("toolkit-openremix-replay-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  fs::create_directories(root);
  try {
    const auto capture = fs::path(FIXTURE_DIR) / "capture.usda";
    editor::Document document;
    document.create(capture, root / "project.usda");
    const std::string parent = "/RootNode/instances/inst_0123456789ABCDEF_1";
    auto light = document.dispatch({{"op", "add_light"}, {"type", "SphereLight"}, {"translation", {1, 3, 2}}, {"intensity", 5}})["selection"].get<std::string>();
    document.dispatch({{"op", "set_parent"}, {"path", light}, {"parent", parent}});
    auto mesh = document.dispatch({{"op", "add_mesh"}, {"asset", (fs::path(FIXTURE_DIR) / "replacement.usda").string()}, {"translation", {2, 1, 0}}})["selection"].get<std::string>();
    document.dispatch({{"op", "set_parent"}, {"path", mesh}, {"parent", parent}});
    const auto composed = document.scene();
    document.package(root / "mods/toolkit");
    remix::NativeResources resources;
    struct Stop { remix::NativeResources& resources; ~Stop() { remix::usd::stopMods(resources); } } stop{resources};
    remix::usd::Submission scene(resources, remix::usd::load({capture.string()}), 1ull << 32);
    remix::usd::startMods(true);
    require(!remix::usd::configureMods((root / "mods").c_str(), 1, 1, false), "configure exported mods");
    for (int i = 0; i < 100; ++i) {
      remix::usd::modBoundary(resources);
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    require(!*remix::usd::modDiagnostic(), remix::usd::modDiagnostic());
    scene.draw(false, 1);
    require(resources.draws().size() == composed["meshes"].size(), "exported attachments preserve original captured meshes");
    const auto lights = resources.sphereLights();
    require(lights.size() == composed["lights"].size() && lights.size() == 2, "exported light attaches to each captured hash instance");
    std::vector<float> actual, expected;
    for (const auto& light : lights) actual.push_back(light.position[0]);
    for (const auto& light : composed["lights"]) expected.push_back(light["transform"][12]);
    std::sort(actual.begin(), actual.end()); std::sort(expected.begin(), expected.end());
    require(actual == expected, "exported parent-relative transforms match the toolkit viewport");
    resources.finishFrame();
    remix::usd::stopMods(resources);
    fs::remove_all(root);
    std::cout << "Toolkit exported mod capture replay passed\n";
  } catch (const std::exception& e) {
    std::cerr << e.what() << "\nFixtures: " << root << '\n'; return 1;
  } catch (...) {
    std::cerr << "Resource error\nFixtures: " << root << '\n'; return 1;
  }
}
