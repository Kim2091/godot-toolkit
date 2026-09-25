#include "document.h"
#include "game_inheritance.h"

#include <chrono>
#include <fstream>
#include <stdexcept>
#ifdef _WIN32
#include <windows.h>
#endif

namespace editor {
namespace {
bool present(const fs::path& path) {
  return fs::exists(fs::symlink_status(path)); // Also detects dangling links.
}

Json read_json(const fs::path& path) {
  std::ifstream input(path);
  if (!input) throw std::runtime_error("Could not read " + path.string());
  return Json::parse(input);
}

void replace_file(const fs::path& source, const fs::path& target) {
#ifdef _WIN32
  if (!MoveFileExW(source.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
    throw std::runtime_error("Could not replace " + target.string());
#else
  fs::rename(source, target);
#endif
}

void write_json(const fs::path& path, const Json& data) {
  const auto temp = fs::path(path.string() + ".saving");
  try {
    std::ofstream output(temp);
    output << data.dump(2) << '\n'; output.close();
    if (!output) throw std::runtime_error("Could not write " + path.string());
    replace_file(temp, path);
  } catch (...) { std::error_code ignored; fs::remove(temp, ignored); throw; }
}

bool owns_link(const fs::path& target, const fs::path& directory) {
  if (!fs::is_symlink(fs::symlink_status(target))) return false;
  auto linked = fs::read_symlink(target);
  if (linked.is_relative()) linked = target.parent_path() / linked;
  return fs::weakly_canonical(linked) == fs::weakly_canonical(directory);
}

// Never traverse a replaced directory symlink while publishing generated files.
void plain_directory(const fs::path& path) {
  if (present(path)) {
    if (fs::is_symlink(path) || !fs::is_directory(path))
      throw std::runtime_error("Live mod folder is occupied: " + path.string());
  } else fs::create_directory(path);
}

fs::path mods_directory(const std::string& folder) {
  if (folder.empty()) throw std::runtime_error("Select the game folder or its rtx-remix/mods folder");
  auto path = fs::absolute(folder).lexically_normal();
  // A trailing separator must not change folder recognition.
  if (path.filename().empty()) path = path.parent_path();
  if (!fs::is_directory(path)) throw std::runtime_error("Game folder does not exist: " + path.string());
  if (path.filename() == "mods" && path.parent_path().filename() == "rtx-remix") return path;
  if (path.filename() == "rtx-remix") return path / "mods";
  return path / "rtx-remix" / "mods";
}

void validate_name(const std::string& name) {
  if (name.empty() || name == "." || name == ".." || name.back() == '.' || name.back() == ' ' ||
      name.find_first_of("<>:\"/\\|?*") != std::string::npos)
    throw std::runtime_error("Enter a mod folder name without path separators or reserved filename characters");
  for (unsigned char c : name) if (c < 32) throw std::runtime_error("Invalid mod folder name");
}
}

Json Document::game_link(const Json& request) {
  require_stage();
  const auto op = request.at("op").get<std::string>();
  const auto settings = fs::path(project_path_.string() + ".studio-link.json");
  const auto directory = fs::path(project_path_.string() + ".studio-live");
  const auto owner = fs::weakly_canonical(project_path_).string();
  Json config;
  if (present(settings)) {
    config = read_json(settings);
    if (!config.is_object() || config.value("version", 0) != 1 || !config.contains("target") ||
        !config["target"].is_string() || !fs::path(config["target"].get<std::string>()).is_absolute())
      throw std::runtime_error("Invalid game link settings: " + settings.string());
  }
  auto status = [&]() -> Json {
    const auto target = config.is_null() ? std::string() : config.at("target").get<std::string>();
    return {{"linked", !target.empty()}, {"connected", !target.empty() && owns_link(target, directory)},
            {"target", target}, {"directory", directory.string()},
            {"retained_mods", config.is_null() ? Json::array() : config.value("retained_mods", Json::array())},
            {"priority_changed", !config.is_null() && config.value("priority_changed", false)}};
  };
  if (op == "game_link_status") return status();
  if (op == "game_unlink") {
    std::string message = "Game unlinked. Project files and the live mod cache were retained.";
    if (!config.is_null()) {
      const fs::path target = config.at("target").get<std::string>();
      if (owns_link(target, directory)) fs::remove(target);
      else if (present(target)) message = "Link settings cleared. The destination was replaced and has been left untouched.";
      // Only remove old priority aliases which still point at our live directory.
      for (const auto& alias : config.value("aliases", Json::array()))
        if (alias.is_string() && owns_link(alias.get<std::string>(), directory)) fs::remove(alias.get<std::string>());
      fs::remove(settings);
    }
    config = nullptr;
    auto result = status(); result["message"] = message; return result;
  }

  fs::path target;
  bool create_link = false;
  if (op == "game_link") {
    const auto name = request.at("name").get<std::string>(); validate_name(name);
    target = mods_directory(request.at("folder").get<std::string>()) / name;
    if (!config.is_null() && fs::path(config.at("target").get<std::string>()) != target)
      throw std::runtime_error("Unlink the current game before choosing another destination");
    if (present(target) && !owns_link(target, directory))
      throw std::runtime_error("The mod destination already exists; choose another name: " + target.string());
    create_link = !present(target);
  } else if (op == "game_sync") {
    if (config.is_null()) throw std::runtime_error("This project is not linked to a game");
    target = config.at("target").get<std::string>();
    if (!owns_link(target, directory))
      throw std::runtime_error("The game link is missing or was replaced. Unlink it and link the project again.");
  } else throw std::runtime_error("Unknown game link command");

  const auto inherited = find_game_inheritance(stage_, target.parent_path(), directory);
  fs::path previous_target;
  bool priority_changed = false;
  if (!inherited.empty() && target >= inherited.front().path.parent_path()) {
    previous_target = config.is_null() ? fs::path() : target;
    auto stem = "000_" + target.filename().string();
    const auto first = inherited.front().path.parent_path().filename().string();
    for (size_t i = 0; stem >= first && i <= first.size(); ++i) stem = "!" + stem;
    if (stem >= first) throw std::runtime_error("Choose a project link name sorting before " + first);
    for (unsigned i = 0;; ++i) {
      auto candidate = target.parent_path() / (stem + (i ? "_" + std::to_string(i + 1) : ""));
      if (candidate < inherited.front().path.parent_path() && (!present(candidate) || owns_link(candidate, directory))) {
        target = candidate; break;
      }
      if (i == 1000) throw std::runtime_error("Could not find a free game link name before the existing mod");
    }
    create_link = !present(target);
    priority_changed = true;
  }

  const auto marker = directory / "project.json";
  if (present(directory)) {
    plain_directory(directory);
    if (!present(marker) || read_json(marker).value("project", std::string()) != owner)
      throw std::runtime_error("Live mod folder belongs to another project: " + directory.string());
  } else {
    plain_directory(directory);
    try { write_json(marker, {{"project", owner}}); }
    catch (...) { std::error_code ignored; fs::remove(directory, ignored); throw; }
  }
  const auto staging = directory / (".publish-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  try {
    export_mod(staging, true);
    publish_game_inheritance(inherited, stage_, staging);
    // Publish dependencies first and mod.usda last. The runtime watches the root's
    // timestamp; it must never see a half-written root or a missing dependency.
    for (const auto& entry : fs::recursive_directory_iterator(staging / "assets")) {
      auto output = directory / entry.path().lexically_relative(staging);
      auto parent = directory;
      for (const auto& part : output.parent_path().lexically_relative(directory)) {
        parent /= part; plain_directory(parent);
      }
      if (fs::is_directory(entry.symlink_status())) plain_directory(output);
      else replace_file(entry.path(), output);
    }
    auto root = directory / "mod.usda";
    if (fs::exists(root)) {
      const auto old_time = fs::last_write_time(root);
      if (fs::last_write_time(staging / "mod.usda") <= old_time)
        fs::last_write_time(staging / "mod.usda", old_time + std::chrono::milliseconds(1));
    }
    replace_file(staging / "mod.usda", root);
    fs::remove_all(staging);
    if (create_link) {
      fs::create_directories(target.parent_path());
      try { fs::create_directory_symlink(directory, target); }
      catch (const fs::filesystem_error& error) {
        throw std::runtime_error(std::string("Could not create the game symlink: ") + error.what() +
          "\nOn Windows, enable Developer Mode or run with permission to create symbolic links.");
      }
    }
    {
      auto aliases = config.is_null() ? Json::array() : config.value("aliases", Json::array());
      if (!previous_target.empty() && std::find(aliases.begin(), aliases.end(), previous_target.string()) == aliases.end())
        aliases.push_back(previous_target.string());
      Json retained = Json::array();
      for (const auto& mod : inherited) retained.push_back({{"name", mod.path.parent_path().filename().string()},
        {"path", mod.path.string()}, {"roots", mod.roots.size()}});
      // Keep the old owned alias until Unlink. A running game may still have a
      // file watcher on it, so deleting it here can crash older Remix builds.
      const Json next{{"version", 1}, {"target", target.string()}, {"aliases", aliases}, {"retained_mods", retained},
        {"priority_changed", priority_changed || (!config.is_null() && config.value("priority_changed", false))}};
      const bool changed = next != config;
      config = next;
      try { if (changed) write_json(settings, config); }
      catch (...) { if (create_link && owns_link(target, directory)) fs::remove(target); throw; }
    }
  } catch (...) { std::error_code ignored; fs::remove_all(staging, ignored); throw; }
  auto result = status(); result["message"] = "Live mod updated: " + target.string(); return result;
}
}
