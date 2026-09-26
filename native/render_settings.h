#pragma once
#include <nlohmann/json.hpp>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include <string>
#include "openremix_settings_schema.h"

namespace studio {
using Json = nlohmann::json;

struct RenderSettings {
  std::string upscaler = "auto", quality = "auto", backend = "pathtrace";
  bool ray_reconstruction = true;
  uint32_t width = 960, height = 540;
  Json pathtrace = pathtrace_defaults();

  static Json pathtrace_defaults() {
    Json result = Json::object();
    for (const auto& option : openremix_settings_schema()) result[option.at("key").get<std::string>()] = option.at("default");
    return result;
  }

  static Json parse_pathtrace(const Json& data) {
    if (!data.is_object()) throw std::runtime_error("OpenRemix path tracing settings must be an object");
    auto result = pathtrace_defaults();
    for (auto it = data.begin(); it != data.end(); ++it)
      if (!result.contains(it.key())) throw std::runtime_error("Unknown OpenRemix setting: " + it.key());
    for (const auto& option : openremix_settings_schema()) {
      const auto key = option.at("key").get<std::string>();
      if (!data.contains(key)) continue;
      const auto& value = data.at(key);
      const auto& initial = option.at("default");
      bool valid = false;
      if (option.contains("choices")) {
        if (initial.is_string()) valid = value.is_string() && option.at("choices").contains(value.get<std::string>());
        else if (value.is_number()) {
          const auto number = value.get<double>();
          valid = std::isfinite(number) && number >= 0 && number <= 3 && number == std::floor(number) &&
            option.at("choices").contains(std::to_string(int(number)));
        }
      } else if (initial.is_boolean()) valid = value.is_boolean();
      else if (value.is_number()) {
        const auto number = value.get<double>();
        valid = std::isfinite(number) && number >= option.at("min").get<double>() && number <= option.at("max").get<double>() &&
          (option.at("step").get<double>() != 1 || number == std::floor(number));
      }
      if (!valid) throw std::runtime_error("Invalid OpenRemix setting: " + key);
      result[key] = value;
    }
    return result;
  }

  static RenderSettings parse(const Json& data, bool openremix = false) {
    RenderSettings result;
    if (openremix && data.contains("pathtrace")) result.pathtrace = parse_pathtrace(data.at("pathtrace"));
    result.upscaler = data.value("upscaler", result.upscaler);
    result.quality = data.value("quality", result.quality);
    result.ray_reconstruction = data.value("ray_reconstruction", result.ray_reconstruction);
    result.backend = data.value("backend", result.backend);
    if (result.backend != "pathtrace" && result.backend != "raster") throw std::runtime_error("Unknown OpenRemix backend");
    if (openremix && result.upscaler != "auto" && result.upscaler != "none" && result.upscaler != "dlss" && result.upscaler != "fsr31") throw std::runtime_error("Unknown OpenRemix upscaler");
    if (!openremix && result.upscaler != "auto" && result.upscaler != "none" && result.upscaler != "dlss" && result.upscaler != "nis" && result.upscaler != "taau")
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

  RenderSettings effective_openremix(bool pathtrace, bool dlss, bool rr, bool fsr) const {
    auto result = *this;
    if (backend == "pathtrace" && !pathtrace) result.backend = "raster";
    if (upscaler == "auto" || (upscaler == "dlss" && !dlss)) result.upscaler = dlss ? "dlss" : fsr ? "fsr31" : "none";
    if (result.upscaler == "fsr31" && !fsr) result.upscaler = "none";
    if (result.backend == "raster") result.upscaler = "none";
    result.ray_reconstruction = ray_reconstruction && rr && result.upscaler == "dlss";
    if (result.upscaler == "none") result.quality = "native";
    else if (quality == "auto") result.quality = "balanced";
    return result;
  }

  Json openremix_variables() const {
    const auto preset = quality == "native" ? "native-aa" : quality == "ultra_performance" ? "ultra-performance" : quality.c_str();
    Json result = {{"rtx.native.backend", backend}, {"rtx.native.pathtrace.upscaler", upscaler == "none" ? "off" : upscaler},
      {"rtx.native.pathtrace.dlssQuality", preset}, {"rtx.native.pathtrace.fsrQuality", preset},
      {"rtx.native.pathtrace.dlssRayReconstruction", ray_reconstruction ? "1" : "0"},
      {"rtx.native.pathtrace.overrideLight", "0"}, {"rtx.native.pathtrace.localRange", "0"}};
    for (auto it = pathtrace.begin(); it != pathtrace.end(); ++it) {
      const auto& value = it.value();
      std::string text = value.is_string() ? value.get<std::string>() : value.is_boolean() ? (value.get<bool>() ? "1" : "0") : value.dump();
      // JSON from Godot represents integral values as doubles. Native integer
      // configuration fields require integer text, rather than e.g. "2.0".
      if (value.is_number() && value.get<double>() == std::floor(value.get<double>())) text = std::to_string(value.get<int64_t>());
      result["rtx.native.pathtrace." + it.key()] = text;
    }
    return result;
  }

  Json json(bool openremix = false) const {
    Json result = {{"upscaler", upscaler}, {"quality", quality}, {"ray_reconstruction", ray_reconstruction}, {"width", width}, {"height", height}};
    if (openremix) { result["backend"] = backend; result["pathtrace"] = pathtrace; }
    return result;
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
