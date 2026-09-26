#pragma once
#include "document.h"
#include <optional>
#include <set>
#include <unordered_map>
#include <pxr/usd/usdShade/material.h>

namespace editor {
// Snapshot-only state: configuration never becomes an opinion in a saved mod.
class CaptureCategories {
public:
  CaptureCategories(const pxr::UsdStageRefPtr& stage, Json& warnings);
  uint32_t flags(const pxr::UsdPrim& mesh, const pxr::UsdShadeMaterial& material);
  const Json& sources() const { return sources_; }
private:
  std::set<std::string> capture_layers_;
  struct Opinion { uint32_t mask = 0, values = 0; };
  std::unordered_map<uint64_t, Opinion> textures_, geometries_;
  std::map<std::string, std::optional<uint64_t>> material_hashes_;
  Json sources_ = Json::array();
  std::optional<uint64_t> texture_hash(const pxr::UsdShadeMaterial& material);
};
}
