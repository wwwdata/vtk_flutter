#include "windows_frame_target.h"

#include <algorithm>
#include <cstddef>
#include <exception>
#include <limits>
#include <new>
#include <stdexcept>
#include <string_view>

#if defined(_WIN32)
#include <windows.h>
#endif

namespace vtk_flutter::windows {
namespace {

void SetStatus(VtkFlutterStatus *status, std::int32_t code,
               std::string_view message) noexcept {
  if (status == nullptr) {
    return;
  }
  *status = {};
  status->code = code;
  const auto count = std::min(message.size(), sizeof(status->message) - 1U);
  std::copy_n(message.data(), count, status->message);
  status->message[count] = '\0';
}

constexpr std::size_t kRequiredCoreApiSize =
    offsetof(VtkFlutterCoreApiV2, texture_target_destroy) +
    sizeof(decltype(VtkFlutterCoreApiV2::texture_target_destroy));

bool IsReadableCoreApiAddress(std::uintptr_t address) noexcept {
  if (address % alignof(VtkFlutterCoreApiV2) != 0 ||
      address >
          std::numeric_limits<std::uintptr_t>::max() - kRequiredCoreApiSize) {
    return false;
  }
#if defined(_WIN32)
  MEMORY_BASIC_INFORMATION region{};
  if (VirtualQuery(reinterpret_cast<const void *>(address), &region,
                   sizeof(region)) == 0 ||
      region.State != MEM_COMMIT || (region.Protect & PAGE_GUARD) != 0 ||
      (region.Protect & PAGE_NOACCESS) != 0) {
    return false;
  }
  const auto region_end =
      reinterpret_cast<std::uintptr_t>(region.BaseAddress) + region.RegionSize;
  return address <= region_end && region_end - address >= kRequiredCoreApiSize;
#else
  return true;
#endif
}

} // namespace

VtkFlutterFrameCallbacksV2 WindowsFrameTarget::Callbacks() noexcept {
  return {
      sizeof(VtkFlutterFrameCallbacksV2),
      VTK_FLUTTER_FRAME_CALLBACKS_VERSION_2,
      this,
      BeginFrameCallback,
      EndFrameCallback,
      CancelFrameCallback,
  };
}

std::shared_ptr<const PublishedFrame> WindowsFrameTarget::LatestFrame() const {
  std::lock_guard lock(mutex_);
  return latest_;
}

std::int64_t WindowsFrameTarget::SubmittedFrameId() const {
  std::lock_guard lock(mutex_);
  return submitted_frame_id_;
}

std::int64_t WindowsFrameTarget::PresentedFrameCount() const noexcept {
  return presented_count_.load();
}

std::int64_t WindowsFrameTarget::PresentedFrameId() const noexcept {
  return presented_frame_id_.load();
}

void WindowsFrameTarget::RecordPresented(std::int64_t frame_id) noexcept {
  presented_count_.fetch_add(1);
  presented_frame_id_.store(frame_id);
}

void WindowsFrameTarget::Clear() noexcept {
  {
    std::lock_guard lock(mutex_);
    pending_.reset();
    latest_.reset();
    submitted_frame_id_ = 0;
  }
  presented_count_.store(0);
  presented_frame_id_.store(0);
}

std::int32_t VTK_FLUTTER_CALL WindowsFrameTarget::BeginFrameCallback(
    void *user_data, const VtkFlutterViewport *viewport,
    VtkFlutterCpuFrameV2 *frame, VtkFlutterStatus *status) noexcept {
  if (user_data == nullptr || viewport == nullptr || frame == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "Windows begin_frame requires target, viewport, and frame");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  try {
    return static_cast<WindowsFrameTarget *>(user_data)->BeginFrame(
        *viewport, *frame, status);
  } catch (const std::bad_alloc &) {
    SetStatus(status, VTK_FLUTTER_STATUS_INTERNAL_ERROR,
              "Windows could not allocate frame storage");
  } catch (const std::exception &exception) {
    SetStatus(status, VTK_FLUTTER_STATUS_INTERNAL_ERROR, exception.what());
  } catch (...) {
    SetStatus(status, VTK_FLUTTER_STATUS_INTERNAL_ERROR,
              "Windows begin_frame failed");
  }
  return VTK_FLUTTER_STATUS_INTERNAL_ERROR;
}

std::int32_t VTK_FLUTTER_CALL WindowsFrameTarget::EndFrameCallback(
    void *user_data, const VtkFlutterMetrics *metrics,
    VtkFlutterStatus *status) noexcept {
  if (user_data == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "Windows end_frame requires a target");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  return static_cast<WindowsFrameTarget *>(user_data)->EndFrame(metrics,
                                                                status);
}

void VTK_FLUTTER_CALL
WindowsFrameTarget::CancelFrameCallback(void *user_data) noexcept {
  if (user_data != nullptr) {
    static_cast<WindowsFrameTarget *>(user_data)->CancelFrame();
  }
}

std::int32_t WindowsFrameTarget::BeginFrame(const VtkFlutterViewport &viewport,
                                            VtkFlutterCpuFrameV2 &frame,
                                            VtkFlutterStatus *status) {
  if (viewport.width <= 0 || viewport.height <= 0) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "Windows frame dimensions must be positive");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  const auto row_bytes = static_cast<std::uint64_t>(viewport.width) * 4ULL;
  const auto height = static_cast<std::uint64_t>(viewport.height);
  if (row_bytes > std::numeric_limits<std::size_t>::max() ||
      height > std::numeric_limits<std::size_t>::max() / row_bytes) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "Windows frame dimensions overflow");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }

  auto pending = std::make_shared<PublishedFrame>();
  pending->width = viewport.width;
  pending->height = viewport.height;
  pending->row_bytes = row_bytes;
  pending->pixels.resize(static_cast<std::size_t>(row_bytes * height));
  {
    std::lock_guard lock(mutex_);
    if (pending_ != nullptr) {
      SetStatus(status, VTK_FLUTTER_STATUS_INVALID_STATE,
                "A Windows frame is already in progress");
      return VTK_FLUTTER_STATUS_INVALID_STATE;
    }
    pending_ = pending;
  }

  frame = {};
  frame.struct_size = sizeof(VtkFlutterCpuFrameV2);
  frame.version = VTK_FLUTTER_CPU_FRAME_VERSION_2;
  frame.pixels = pending->pixels.data();
  frame.capacity_bytes = pending->pixels.size();
  frame.row_bytes = pending->row_bytes;
  frame.pixel_format = pending->pixel_format;
  SetStatus(status, VTK_FLUTTER_STATUS_OK, {});
  return VTK_FLUTTER_STATUS_OK;
}

std::int32_t WindowsFrameTarget::EndFrame(const VtkFlutterMetrics *metrics,
                                          VtkFlutterStatus *status) noexcept {
  if (metrics == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "Windows end_frame requires metrics");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  std::lock_guard lock(mutex_);
  if (pending_ == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_STATE,
              "No Windows frame is in progress");
    return VTK_FLUTTER_STATUS_INVALID_STATE;
  }
  pending_->id = ++submitted_frame_id_;
  latest_ = std::move(pending_);
  SetStatus(status, VTK_FLUTTER_STATUS_OK, {});
  return VTK_FLUTTER_STATUS_OK;
}

void WindowsFrameTarget::CancelFrame() noexcept {
  std::lock_guard lock(mutex_);
  pending_.reset();
}

const VtkFlutterCoreApiV2 &ValidateCoreApiAddress(std::uintptr_t address) {
  if (address == 0 || !IsReadableCoreApiAddress(address)) {
    throw std::invalid_argument(
        "coreApiAddress must identify a readable ABI v2 table");
  }
  const auto *api = reinterpret_cast<const VtkFlutterCoreApiV2 *>(address);
  if (api->struct_size < kRequiredCoreApiSize) {
    throw std::invalid_argument("Native VTK ABI v2 table is too small");
  }
  if (api->version != VTK_FLUTTER_CORE_API_VERSION_2) {
    throw std::invalid_argument(
        "Native VTK ABI v2 table has an unsupported version");
  }
  if (api->status_clear == nullptr || api->session_create == nullptr ||
      api->session_destroy == nullptr || api->validate_volume == nullptr ||
      api->session_set_volume == nullptr ||
      api->validate_render_request == nullptr ||
      api->session_render == nullptr ||
      api->session_attach_texture_target == nullptr ||
      api->session_detach_texture_target == nullptr ||
      api->texture_target_create == nullptr ||
      api->texture_target_destroy == nullptr) {
    throw std::invalid_argument("Native VTK ABI v2 table is incomplete");
  }
  return *api;
}

} // namespace vtk_flutter::windows
