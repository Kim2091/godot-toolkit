#pragma once
#include <nlohmann/json.hpp>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include <string>

namespace studio {
using Json = nlohmann::json;

struct RenderSettings {
  std::string upscaler = "auto", quality = "auto";
  bool ray_reconstruction = true;
  uint32_t width = 960, height = 540;

  static RenderSettings parse(const Json& data) {
    RenderSettings result;
    result.upscaler = data.value("upscaler", result.upscaler);
    result.quality = data.value("quality", result.quality);
    result.ray_reconstruction = data.value("ray_reconstruction", result.ray_reconstruction);
    if (result.upscaler != "auto" && result.upscaler != "none" && result.upscaler != "dlss" && result.upscaler != "nis" && result.upscaler != "taau")
      throw std::runtime_error("Unknown upscaler");
    if (result.quality != "auto" && result.quality != "ultra_performance" && result.quality != "performance" && result.quality != "balanced" && result.quality != "quality" && result.quality != "native")
      throw std::runtime_error("Unknown upscaler quality");
    auto dimension = [&](const char* key, uint32_t fallback) {
      const auto value = data.value(key, double(fallback));
      if (!std::isfinite(value) || value < 16 || value > 8192 || value != std::floor(value))
        throw std::runtime_error("Viewport dimensions must be whole pixels between 16 and 8192");
      return uint32_t(value);
    };
    result.width = dimension("width", result.width);
    result.height = dimension("height", result.height);
    return result;
  }

  RenderSettings effective(bool dlss, bool rr, bool nis) const {
    auto result = *this;
    if (upscaler == "auto" || (upscaler == "dlss" && !dlss)) result.upscaler = dlss ? "dlss" : "taau";
    if (upscaler == "nis" && !nis) result.upscaler = "taau";
    result.ray_reconstruction = ray_reconstruction && rr && result.upscaler == "dlss";
    if (result.upscaler == "none") result.quality = "native";
    else if ((quality == "auto" && result.upscaler != "dlss") || (quality == "ultra_performance" && result.upscaler == "nis")) result.quality = "balanced";
    return result;
  }

  Json json() const {
    return {{"upscaler", upscaler}, {"quality", quality}, {"ray_reconstruction", ray_reconstruction}, {"width", width}, {"height", height}};
  }

  // Values match the pinned Remix UpscalerType / DLSSProfile enums. NIS and
  // TAAU presets in its menu also set resolutionScale; setting only the preset
  // via the API does not run that menu code.
  Json variables() const {
    const int type = upscaler == "dlss" ? 1 : upscaler == "nis" ? 2 : upscaler == "taau" ? 3 : 0;
    const int profile = quality == "ultra_performance" ? 0 : quality == "performance" ? 1 : quality == "balanced" ? 2 : quality == "quality" ? 3 : quality == "native" ? 5 : 4;
    const std::string scale = quality == "ultra_performance" ? "0.33" : quality == "performance" ? "0.5" : quality == "balanced" ? "0.66" : quality == "quality" ? "0.75" : "1.0";
    return {{"rtx.dlssPreset", "2"}, {"rtx.upscalerType", std::to_string(type)},
      {"rtx.qualityDLSS", std::to_string(profile)}, {"rtx.resolutionScale", scale},
      {"rtx.enableRayReconstruction", ray_reconstruction ? "True" : "False"}};
  }
};
}
