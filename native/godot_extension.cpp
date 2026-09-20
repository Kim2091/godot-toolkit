#include "document.h"
#include <future>
#include <atomic>
#include <cmath>
#include <algorithm>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

namespace editor {
void register_gpu_bridge();
void convert_texture(const fs::path& source, const fs::path& target, const std::string& kind) {
  using godot::Image;
  auto image = Image::load_from_file(source.string().c_str());
  if (image.is_null() || image->is_empty()) throw std::runtime_error("Cannot decode texture: " + source.string());
  if (image->is_compressed() && image->decompress() != godot::OK) throw std::runtime_error("Cannot decompress texture");
  bool normal = kind == "normal_ogl" || kind == "normal_dx";
  bool scalar = kind == "roughness_g" || kind == "metallic_b" || kind == "scalar";
  auto extension = source.extension().string();
  std::transform(extension.begin(), extension.end(), extension.begin(), ::tolower);
  bool hdr = extension == ".exr" || extension == ".hdr";
  image->clear_mipmaps();
  if (scalar) {
    image->convert(Image::FORMAT_RGBA8);
    auto pixels = image->get_data();
    godot::PackedByteArray channel;
    channel.resize(pixels.size() / 4);
    int component = kind == "roughness_g" ? 1 : kind == "metallic_b" ? 2 : 0;
    for (int64_t i = 0; i < channel.size(); ++i) channel.ptrw()[i] = pixels.ptr()[i * 4 + component];
    image = Image::create_from_data(image->get_width(), image->get_height(), false, Image::FORMAT_R8, channel);
    if (image->generate_mipmaps() != godot::OK || image->compress_from_channels(Image::COMPRESS_S3TC, Image::USED_CHANNELS_R) != godot::OK)
      throw std::runtime_error("BC4 scalar compression is unavailable");
    if (int64_t(image->call("save_dds", godot::String(target.string().c_str()))) != godot::OK) throw std::runtime_error("Could not write DDS texture");
    return;
  }
  image->convert(normal ? Image::FORMAT_RGBA8 : Image::FORMAT_RGBAH);
  if (!normal && !hdr && kind == "color") image->srgb_to_linear();
  if (image->generate_mipmaps(normal) != godot::OK) throw std::runtime_error("Cannot generate texture mipmaps");
  if (normal) {
    auto pixels = image->get_data();
    godot::PackedByteArray encoded;
    encoded.resize(pixels.size() / 2);
    auto* output = encoded.ptrw();
    const auto* input = pixels.ptr();
    for (int64_t i = 0; i < pixels.size() / 4; ++i) {
      float x = input[i * 4] / 127.5f - 1.f;
      float y = input[i * 4 + 1] / 127.5f - 1.f;
      float z = std::abs(input[i * 4 + 2] / 127.5f - 1.f);
      if (kind == "normal_ogl") y = -y;
      float denominator = std::max(std::abs(x) + std::abs(y) + z, 0.00001f);
      output[i * 2] = uint8_t(std::clamp(std::round(((x + y) / denominator * 0.5f + 0.5f) * 255.f), 0.f, 255.f));
      output[i * 2 + 1] = uint8_t(std::clamp(std::round(((x - y) / denominator * 0.5f + 0.5f) * 255.f), 0.f, 255.f));
    }
    image = Image::create_from_data(image->get_width(), image->get_height(), image->has_mipmaps(), Image::FORMAT_RG8, encoded);
    if (image->compress_from_channels(Image::COMPRESS_S3TC, Image::USED_CHANNELS_RG) != godot::OK)
      throw std::runtime_error("BC5 normal compression is unavailable");
  } else {
    if (!hdr) {
      if (kind == "color") image->linear_to_srgb();
      image->convert(Image::FORMAT_RGBA8);
    }
    if (image->compress(Image::COMPRESS_BPTC) != godot::OK) throw std::runtime_error("BC7/BC6H texture compression is unavailable");
  }
  // save_dds was added after the minimum GDExtension ABI used for this library.
  if (int64_t(image->call("save_dds", godot::String(target.string().c_str()))) != godot::OK)
    throw std::runtime_error("Could not write DDS texture");
}

class RemixDocument : public godot::RefCounted {
  GDCLASS(RemixDocument, godot::RefCounted)
public:
  ~RemixDocument() { cancel_ingestion(); if (job_.valid()) job_.wait(); }
  godot::String execute(const godot::String& json) {
    try {
      auto result = document_.dispatch(Json::parse(json.utf8().get_data()));
      return Json({{"ok", true}, {"result", result}}).dump().c_str();
    } catch (const std::exception& error) {
      return Json({{"ok", false}, {"error", error.what()}}).dump().c_str();
    }
  }
  godot::String start_ingestion(const godot::String& json) {
    try {
      if (job_.valid()) throw std::runtime_error("An ingestion job is already running");
      auto request = Json::parse(json.utf8().get_data());
      auto description = document_.describe();
      if (!description.value("open", false)) throw std::runtime_error("Open a project first");
      auto directory = fs::path(description.at("path").get<std::string>()).parent_path();
      canceled_ = std::make_shared<std::atomic_bool>(false);
      job_ = std::async(std::launch::async, [request, directory, canceled = canceled_] {
        try { return Json{{"ok", true}, {"result", ingest_asset(request, directory, convert_texture, [canceled] { return canceled->load(); })}}; }
        catch (const std::exception& error) { return Json{{"ok", false}, {"error", error.what()}}; }
      });
      return "{\"ok\":true}";
    } catch (const std::exception& error) { return Json({{"ok", false}, {"error", error.what()}}).dump().c_str(); }
  }
  godot::String poll_ingestion() {
    if (!job_.valid() || job_.wait_for(std::chrono::milliseconds(0)) != std::future_status::ready) return "";
    return job_.get().dump().c_str();
  }
  void cancel_ingestion() { if (canceled_) canceled_->store(true); }
protected:
  static void _bind_methods() {
    godot::ClassDB::bind_method(godot::D_METHOD("execute", "request"), &RemixDocument::execute);
    godot::ClassDB::bind_method(godot::D_METHOD("start_ingestion", "request"), &RemixDocument::start_ingestion);
    godot::ClassDB::bind_method(godot::D_METHOD("poll_ingestion"), &RemixDocument::poll_ingestion);
    godot::ClassDB::bind_method(godot::D_METHOD("cancel_ingestion"), &RemixDocument::cancel_ingestion);
  }
private:
  Document document_;
  std::future<Json> job_;
  std::shared_ptr<std::atomic_bool> canceled_;
};

void initialize(godot::ModuleInitializationLevel level) {
  if (level == godot::MODULE_INITIALIZATION_LEVEL_SCENE) {
    godot::ClassDB::register_class<RemixDocument>();
    register_gpu_bridge();
  }
}
void terminate(godot::ModuleInitializationLevel) {}
}

extern "C" GDExtensionBool GDE_EXPORT remix_editor_init(GDExtensionInterfaceGetProcAddress get_proc_address,
    GDExtensionClassLibraryPtr library, GDExtensionInitialization* initialization) {
  godot::GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
  init.register_initializer(editor::initialize);
  init.register_terminator(editor::terminate);
  init.set_minimum_library_initialization_level(godot::MODULE_INITIALIZATION_LEVEL_SCENE);
  return init.init();
}
