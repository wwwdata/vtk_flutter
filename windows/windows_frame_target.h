#ifndef FLUTTER_PLUGIN_WINDOWS_FRAME_TARGET_H_
#define FLUTTER_PLUGIN_WINDOWS_FRAME_TARGET_H_

#include <vtk_flutter.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

namespace vtk_flutter::windows {

struct PublishedFrame {
  std::int64_t id = 0;
  std::int32_t width = 0;
  std::int32_t height = 0;
  std::uint64_t row_bytes = 0;
  std::int32_t pixel_format = VTK_FLUTTER_PIXEL_FORMAT_RGBA8888;
  std::vector<std::uint8_t> pixels;
};

class WindowsFrameTarget final {
public:
  VtkFlutterFrameCallbacks Callbacks() noexcept;

  std::shared_ptr<const PublishedFrame> LatestFrame() const;
  std::int64_t SubmittedFrameId() const;
  std::int64_t PresentedFrameCount() const noexcept;
  std::int64_t PresentedFrameId() const noexcept;
  void RecordPresented(std::int64_t frame_id) noexcept;
  void Clear() noexcept;

private:
  static std::int32_t VTK_FLUTTER_CALL BeginFrameCallback(
      void *user_data, const VtkFlutterViewport *viewport,
      VtkFlutterCpuFrame *frame, VtkFlutterStatus *status) noexcept;
  static std::int32_t VTK_FLUTTER_CALL
  EndFrameCallback(void *user_data, const VtkFlutterFrameMetrics *metrics,
                   VtkFlutterStatus *status) noexcept;
  static void VTK_FLUTTER_CALL CancelFrameCallback(void *user_data) noexcept;

  std::int32_t BeginFrame(const VtkFlutterViewport &viewport,
                          VtkFlutterCpuFrame &frame, VtkFlutterStatus *status);
  std::int32_t EndFrame(const VtkFlutterFrameMetrics *metrics,
                        VtkFlutterStatus *status) noexcept;
  void CancelFrame() noexcept;

  mutable std::mutex mutex_;
  std::shared_ptr<PublishedFrame> pending_;
  std::shared_ptr<const PublishedFrame> latest_;
  std::int64_t submitted_frame_id_ = 0;
  std::atomic<std::int64_t> presented_count_ = 0;
  std::atomic<std::int64_t> presented_frame_id_ = 0;
};

const VtkFlutterPresentationApi &
ValidatePresentationApiAddress(std::uintptr_t address);

} // namespace vtk_flutter::windows

#endif // FLUTTER_PLUGIN_WINDOWS_FRAME_TARGET_H_
