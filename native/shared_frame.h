#pragma once
#include <cstdint>

// Private, versioned editor ABI. Separate from the upstream Remix API table.
// File descriptors returned here belong to the caller and are sent with SCM_RIGHTS.
struct EditorSharedFrame {
  uint32_t version = 1;
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t memory_type = 0;
  uint64_t allocation_size = 0;
  uint8_t device_uuid[16]{};
  int memory_fd = -1;
  int ready_fd = -1;
  int released_fd = -1;
};
using ConfigureSharedFrame = int (*)(EditorSharedFrame*);
