#include "shared_frame.h"
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/texture2drd.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <vulkan/vulkan.h>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <cstring>
#include <stdexcept>
#ifndef _WIN32
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <poll.h>
#endif

namespace editor {
using namespace godot;
static void vk_check(VkResult result, const char* action) {
  if (result != VK_SUCCESS) throw std::runtime_error(std::string(action) + " (Vulkan " + std::to_string(result) + ")");
}

class RemixGpuBridge : public RefCounted {
  GDCLASS(RemixGpuBridge, RefCounted)
public:
  String open_channel() {
#ifndef _WIN32
    close_socket();
    static std::atomic<uint64_t> counter{0};
    directory_ = "/tmp/remix-editor-" + std::to_string(getpid()) + "-" + std::to_string(++counter);
    if (mkdir(directory_.c_str(), 0700) != 0) return "";
    endpoint_ = directory_ + "/frames";
    socket_ = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    sockaddr_un address{}; address.sun_family = AF_UNIX;
    std::strncpy(address.sun_path, endpoint_.c_str(), sizeof(address.sun_path) - 1);
    if (socket_ < 0 || bind(socket_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 || listen(socket_, 1) != 0) {
      close_socket(); return "";
    }
    return endpoint_.c_str();
#else
    return "";
#endif
  }
  void import_frame() { RenderingServer::get_singleton()->call_on_render_thread(callable_mp(this, &RemixGpuBridge::import_on_render_thread)); }
  void copy_frame() { RenderingServer::get_singleton()->call_on_render_thread(callable_mp(this, &RemixGpuBridge::copy_on_render_thread)); }
  void close_frame() {
    { std::lock_guard<std::mutex> lock(close_mutex_); closed_ = false; }
    RenderingServer::get_singleton()->call_on_render_thread(callable_mp(this, &RemixGpuBridge::close_and_notify));
    std::unique_lock<std::mutex> lock(close_mutex_);
    close_condition_.wait(lock, [this] { return closed_; });
  }
  ~RemixGpuBridge() { close_socket(); }
protected:
  static void _bind_methods() {
    ClassDB::bind_method(D_METHOD("open_channel"), &RemixGpuBridge::open_channel);
    ClassDB::bind_method(D_METHOD("import_frame"), &RemixGpuBridge::import_frame);
    ClassDB::bind_method(D_METHOD("copy_frame"), &RemixGpuBridge::copy_frame);
    ClassDB::bind_method(D_METHOD("close_frame"), &RemixGpuBridge::close_frame);
    ADD_SIGNAL(MethodInfo("configured", PropertyInfo(Variant::OBJECT, "texture")));
    ADD_SIGNAL(MethodInfo("frame_copied"));
    ADD_SIGNAL(MethodInfo("failed", PropertyInfo(Variant::STRING, "message")));
  }
private:
  void close_and_notify() {
    close_on_render_thread();
    { std::lock_guard<std::mutex> lock(close_mutex_); closed_ = true; }
    close_condition_.notify_one();
  }
  void close_socket() {
#ifndef _WIN32
    if (socket_ >= 0) ::close(socket_);
    socket_ = -1;
    if (!endpoint_.empty()) unlink(endpoint_.c_str());
    if (!directory_.empty()) rmdir(directory_.c_str());
#endif
    endpoint_.clear(); directory_.clear();
  }
  void import_on_render_thread() {
    try {
      close_on_render_thread();
      auto* rd = RenderingServer::get_singleton()->get_rendering_device();
      if (!rd || !rd->has_method("texture_copy_from_external"))
        throw std::runtime_error("The viewport requires the patched Godot Vulkan build. Run scripts/bootstrap.py.");
#ifndef _WIN32
      pollfd available{socket_, POLLIN, 0};
      if (socket_ < 0 || poll(&available, 1, 0) != 1) throw std::runtime_error("Renderer did not supply a GPU frame handle");
      int connection = accept4(socket_, nullptr, nullptr, SOCK_CLOEXEC);
      if (connection < 0) throw std::runtime_error("Could not receive the GPU frame channel");
      EditorSharedFrame descriptor{};
      iovec payload{&descriptor, sizeof(descriptor)};
      alignas(cmsghdr) char control[CMSG_SPACE(3 * sizeof(int))]{};
      msghdr message{}; message.msg_iov = &payload; message.msg_iovlen = 1;
      message.msg_control = control; message.msg_controllen = sizeof(control);
      auto received = recvmsg(connection, &message, MSG_CMSG_CLOEXEC | MSG_WAITALL);
      ::close(connection);
      close_socket();
      auto* header = CMSG_FIRSTHDR(&message);
      if (received != sizeof(descriptor) || (message.msg_flags & MSG_CTRUNC) || !header ||
          header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS || header->cmsg_len != CMSG_LEN(3 * sizeof(int)))
        throw std::runtime_error("Invalid GPU frame descriptor");
      int handles[3]; std::memcpy(handles, CMSG_DATA(header), sizeof(handles));
      struct Handles { int* fds; ~Handles() { for (int i = 0; i < 3; ++i) if (fds[i] >= 0) ::close(fds[i]); } } ownership{handles};
      if (descriptor.version != 1 || descriptor.width < 16 || descriptor.height < 16 || descriptor.width > 8192 || descriptor.height > 8192)
        throw std::runtime_error("Unsupported GPU frame descriptor");
      device_ = reinterpret_cast<VkDevice>(rd->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_LOGICAL_DEVICE, RID(), 0));
      auto physical = reinterpret_cast<VkPhysicalDevice>(rd->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_PHYSICAL_DEVICE, RID(), 0));
      VkPhysicalDeviceIDProperties identity{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};
      VkPhysicalDeviceProperties2 properties{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2}; properties.pNext = &identity;
      vkGetPhysicalDeviceProperties2(physical, &properties);
      if (std::memcmp(identity.deviceUUID, descriptor.device_uuid, 16)) throw std::runtime_error("Godot and Remix must use the same GPU");
      VkExternalMemoryImageCreateInfo external{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO};
      external.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
      VkImageCreateInfo image{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO}; image.pNext = &external;
      image.imageType = VK_IMAGE_TYPE_2D; image.format = VK_FORMAT_R8G8B8A8_UNORM;
      image.extent = {descriptor.width, descriptor.height, 1}; image.mipLevels = 1; image.arrayLayers = 1;
      image.samples = VK_SAMPLE_COUNT_1_BIT; image.tiling = VK_IMAGE_TILING_OPTIMAL;
      image.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
      vk_check(vkCreateImage(device_, &image, nullptr, &image_), "Create imported image");
      VkMemoryRequirements requirements; vkGetImageMemoryRequirements(device_, image_, &requirements);
      if (descriptor.memory_type >= 32 || !(requirements.memoryTypeBits & (1u << descriptor.memory_type)) || descriptor.allocation_size < requirements.size)
        throw std::runtime_error("Renderer GPU allocation is incompatible");
      VkImportMemoryFdInfoKHR import{VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR};
      import.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT; import.fd = handles[0];
      VkMemoryDedicatedAllocateInfo dedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO}; dedicated.image = image_; dedicated.pNext = &import;
      VkMemoryAllocateInfo allocate{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
      allocate.pNext = &dedicated; allocate.allocationSize = descriptor.allocation_size; allocate.memoryTypeIndex = descriptor.memory_type;
      vk_check(vkAllocateMemory(device_, &allocate, nullptr, &memory_), "Import frame memory"); handles[0] = -1;
      vk_check(vkBindImageMemory(device_, image_, memory_, 0), "Bind frame memory");
      auto import_semaphore = reinterpret_cast<PFN_vkImportSemaphoreFdKHR>(vkGetDeviceProcAddr(device_, "vkImportSemaphoreFdKHR"));
      if (!import_semaphore) throw std::runtime_error("Vulkan external semaphore import is unavailable");
      VkSemaphoreCreateInfo semaphore{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
      vk_check(vkCreateSemaphore(device_, &semaphore, nullptr, &ready_), "Create frame semaphore");
      vk_check(vkCreateSemaphore(device_, &semaphore, nullptr, &released_), "Create release semaphore");
      for (int i = 1; i < 3; ++i) {
        VkImportSemaphoreFdInfoKHR info{VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR};
        info.semaphore = i == 1 ? ready_ : released_; info.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT; info.fd = handles[i];
        vk_check(import_semaphore(device_, &info), "Import synchronization semaphore"); handles[i] = -1;
      }
      Ref<RDTextureFormat> format; format.instantiate();
      format->set_format(RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM);
      // Texture2DRD creates both linear and sRGB views of this Godot-owned copy.
      // Declare them up front so Vulkan allocates a mutable-format image.
      format->add_shareable_format(RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM);
      format->add_shareable_format(RenderingDevice::DATA_FORMAT_R8G8B8A8_SRGB);
      format->set_width(descriptor.width); format->set_height(descriptor.height);
      // Viewport presentation stays on the GPU; explicit project saves may read
      // the finished frame once to generate a recent-project thumbnail.
      format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_CAN_COPY_TO_BIT |
        RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT);
      Ref<RDTextureView> view; view.instantiate();
      target_ = rd->texture_create(format, view);
      if (!target_.is_valid()) throw std::runtime_error("Could not create viewport texture");
      texture_.instantiate(); texture_->set_texture_rd_rid(target_);
      call_deferred("emit_signal", "configured", texture_);
#else
      throw std::runtime_error("Shared Vulkan frames are not yet available on Windows");
#endif
    } catch (const std::exception& error) {
      close_on_render_thread(); close_socket();
      call_deferred("emit_signal", "failed", String(error.what()));
    }
  }
  void copy_on_render_thread() {
    auto* rd = RenderingServer::get_singleton()->get_rendering_device();
    if (!rd || !target_.is_valid()) return;
    auto result = int64_t(rd->call("texture_copy_from_external", target_, uint64_t(image_), uint64_t(ready_), uint64_t(released_)));
    if (result != OK) call_deferred("emit_signal", "failed", "Could not copy the Remix GPU frame");
    else call_deferred("emit_signal", "frame_copied");
  }
  void close_on_render_thread() {
    if (!device_) return;
    // Ready waits are submitted only after the producer reports GPU completion.
    auto* rd = RenderingServer::get_singleton()->get_rendering_device();
    rd->call("external_frame_flush");
    if (texture_.is_valid()) { texture_->set_texture_rd_rid(RID()); texture_.unref(); }
    if (target_.is_valid()) rd->free_rid(target_);
    target_ = RID();
    if (ready_) vkDestroySemaphore(device_, ready_, nullptr);
    if (released_) vkDestroySemaphore(device_, released_, nullptr);
    if (image_) vkDestroyImage(device_, image_, nullptr);
    if (memory_) vkFreeMemory(device_, memory_, nullptr);
    ready_ = VK_NULL_HANDLE; released_ = VK_NULL_HANDLE; image_ = VK_NULL_HANDLE; memory_ = VK_NULL_HANDLE; device_ = VK_NULL_HANDLE;
  }
  int socket_ = -1;
  std::string endpoint_, directory_;
  VkDevice device_ = VK_NULL_HANDLE;
  VkImage image_ = VK_NULL_HANDLE;
  VkDeviceMemory memory_ = VK_NULL_HANDLE;
  VkSemaphore ready_ = VK_NULL_HANDLE, released_ = VK_NULL_HANDLE;
  RID target_;
  Ref<Texture2DRD> texture_;
  std::mutex close_mutex_;
  std::condition_variable close_condition_;
  bool closed_ = true;
};
void register_gpu_bridge() { ClassDB::register_class<RemixGpuBridge>(); }
}
