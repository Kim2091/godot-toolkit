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
    std::cout << "Render settings validation and GPU fallback passed\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
