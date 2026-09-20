#include "channel.h"
#include <array>
#include <cerrno>
#include <stdexcept>
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

namespace editor {
bool Channel::read_exact(void* data, size_t size) {
  auto* bytes = static_cast<char*>(data);
  size_t received = 0;
  while (received < size) {
#ifdef _WIN32
    DWORD count = 0;
    if (!ReadFile(reinterpret_cast<HANDLE>(input_), bytes + received, DWORD(size - received), &count, nullptr)) {
      if (GetLastError() == ERROR_BROKEN_PIPE && received == 0) return false;
      throw std::runtime_error("Renderer channel read failed");
    }
#else
    const auto count = ::read(int(input_), bytes + received, size - received);
    if (count < 0) { if (errno == EINTR) continue; throw std::runtime_error("Renderer channel read failed"); }
#endif
    if (count == 0) {
      if (!received) return false;
      throw std::runtime_error("Truncated renderer message");
    }
    received += size_t(count);
  }
  return true;
}
void Channel::write_exact(const void* data, size_t size) {
  auto* bytes = static_cast<const char*>(data);
  while (size) {
#ifdef _WIN32
    DWORD count = 0;
    if (!WriteFile(reinterpret_cast<HANDLE>(output_), bytes, DWORD(size), &count, nullptr)) throw std::runtime_error("Renderer channel closed");
#else
    auto count = ::write(int(output_), bytes, size);
    if (count < 0) { if (errno == EINTR) continue; throw std::runtime_error("Renderer channel closed"); }
#endif
    if (count == 0) throw std::runtime_error("Renderer channel made no progress");
    bytes += count; size -= size_t(count);
  }
}
bool Channel::receive(nlohmann::json& message) {
  std::array<uint8_t, 4> header{};
  if (!read_exact(header.data(), header.size())) return false;
  const auto length = uint32_t(header[0]) | uint32_t(header[1]) << 8 | uint32_t(header[2]) << 16 | uint32_t(header[3]) << 24;
  if (!length || length > max_message_bytes) throw std::runtime_error("Renderer message exceeds protocol limit");
  std::string payload(length, '\0');
  if (!read_exact(payload.data(), payload.size())) throw std::runtime_error("Missing renderer message body");
  message = nlohmann::json::parse(payload);
  if (message.value("version", 0u) != protocol_version) throw std::runtime_error("Incompatible renderer protocol version");
  return true;
}
void Channel::send(const nlohmann::json& message) {
  std::lock_guard lock(write_mutex_);
  auto envelope = message; envelope["version"] = protocol_version;
  auto payload = envelope.dump();
  if (payload.size() > max_message_bytes) throw std::runtime_error("Renderer message exceeds protocol limit");
  auto size = uint32_t(payload.size());
  std::array<uint8_t, 4> header{uint8_t(size), uint8_t(size >> 8), uint8_t(size >> 16), uint8_t(size >> 24)};
  write_exact(header.data(), header.size()); write_exact(payload.data(), payload.size());
}
}
