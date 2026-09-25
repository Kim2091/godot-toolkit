#pragma once
#include "document.h"

namespace editor {
struct InheritedMod {
  fs::path path;
  pxr::UsdStageRefPtr stage;
  std::vector<pxr::SdfPath> roots;
};
std::vector<InheritedMod> find_game_inheritance(const pxr::UsdStageRefPtr& project,
                                               const fs::path& mods, const fs::path& own_directory);
void publish_game_inheritance(const std::vector<InheritedMod>& mods,
                             const pxr::UsdStageRefPtr& project, const fs::path& staging);
}
