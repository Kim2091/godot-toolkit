#include "render_settings.h"
#include <iostream>

void check(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
int main() {
  try {
    using studio::RenderSettings;
    using studio::Json;
    auto preferences = RenderSettings::parse({{"upscaler", "dlss"}, {"quality", "quality"}, {"ray_reconstruction", true}, {"width", 1536.0}, {"height", 864.0}});
    auto fallback = preferences.effective(false, false, false);
    check(fallback.upscaler == "taau" && !fallback.ray_reconstruction, "Unavailable DLSS must fall back to TAAU without RR");
    check(preferences.upscaler == "dlss" && preferences.ray_reconstruction, "Fallback must preserve the requested preference");
    check(preferences.effective(true, false, false).upscaler == "dlss" && !preferences.effective(true, false, false).ray_reconstruction, "DLSS SR support alone must not enable RR");
    check(preferences.effective(true, true, false).ray_reconstruction, "Capable NVIDIA runtime must allow RR");
    for (const auto* upscaler : {"auto", "taau", "nis", "none"}) {
      preferences.upscaler = upscaler;
      auto effective = preferences.effective(false, false, false);
      check(effective.upscaler != "auto" && effective.upscaler != "nis" && !effective.ray_reconstruction, "Disabled vendor paths must not be selected");
    }
    preferences.upscaler = "none";
    check(preferences.effective(true, true, true).quality == "native", "Native rendering must use full resolution");
    for (auto invalid : {Json{{"width", -1}}, Json{{"width", 8193}}, Json{{"width", 16.5}}, Json{{"width", -4294966336.0}}, Json{{"height", "720"}}, Json{{"ray_reconstruction", "false"}}, Json{{"upscaler", "invalid"}}, Json{{"quality", "invalid"}}}) {
      bool rejected = false;
      try { RenderSettings::parse(invalid); } catch (const std::exception&) { rejected = true; }
      check(rejected, "Malformed render settings must be rejected before altering the runtime");
    }
    const auto open = RenderSettings::parse({{"upscaler", "dlss"}}, true);
    const auto openFallback = open.effective_openremix(true, false, false, true);
    check(openFallback.backend == "pathtrace" && openFallback.upscaler == "fsr31", "OpenRemix defaults and FSR fallback");
    check(open.effective_openremix(false, true, true, true).backend == "raster", "Unsupported tracing falls back to raster");
    const auto variables = openFallback.openremix_variables();
    for (auto it = variables.begin(); it != variables.end(); ++it) check(it.key().rfind("rtx.native.", 0) == 0, "No dxvk variables sent to OpenRemix");
    check(open.upscaler == "dlss", "Runtime fallback preserves saved preference");
    check(open.pathtrace.at("denoiser") == "reblur-sh" && open.pathtrace.at("sharc") == true && open.pathtrace.at("localFireflyFilter") == false,
      "Existing OpenRemix preferences inherit native NRD, SHARC and opt-in firefly defaults");
    const auto configured = RenderSettings::parse({{"pathtrace", {{"localFireflyFilter", true}, {"samples", 4.0}, {"localDirectClamp", 2.5}, {"sharc", false}}}}, true);
    const auto native = configured.openremix_variables();
    check(native.at("rtx.native.pathtrace.localFireflyFilter") == "1" && native.at("rtx.native.pathtrace.sharc") == "0" &&
      native.at("rtx.native.pathtrace.samples") == "4" && native.at("rtx.native.pathtrace.localDirectClamp") == "2.5",
      "Godot numeric JSON and boolean preferences map to valid native configuration text");
    check(configured.effective_openremix(false, false, false, false).pathtrace == configured.pathtrace,
      "Raster or reconstruction fallbacks must not overwrite saved tracing options");
    check(!configured.variables().contains("rtx.native.pathtrace.sharc") && !configured.json().contains("pathtrace"),
      "Remix settings do not contain OpenRemix options");
    for (const auto& invalid : {Json{{"samples", 1.5}}, Json{{"bounces", -1}}, Json{{"samples", true}}, Json{{"sharcCapacityLog2", 23}},
        Json{{"localFireflyFilter", "true"}}, Json{{"sharc", 1}}, Json{{"localDirectClamp", -1}}, Json{{"indirectClamp", 1000001}},
        Json{{"denoiser", "nrd"}}, Json{{"separateLocalLighting", 1.5}}, Json{{"sharcReset", true}}, Json::array()}) {
      bool rejected = false;
      try { RenderSettings::parse({{"pathtrace", invalid}}, true); } catch (const std::exception&) { rejected = true; }
      check(rejected, "Reject invalid native settings before altering the runtime");
    }
    std::cout << "Render settings validation and GPU fallback passed\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
