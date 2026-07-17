#include "vtk_flutter_plugin.h"

#include "vtk_flutter_codec.h"
#include "windows_frame_target.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <windows.h>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace vtk_flutter {
namespace {

constexpr char kChannelName[] = "vtk_flutter/session";
constexpr char kGraphicsSupport[] =
    "VTK code asset CPU RGBA readback (Windows)";
constexpr char kHandoffMode[] = "windows_pixel_buffer_rgba_readback";
constexpr UINT kDispatchMessage = WM_APP + 0x5654;

using EncodableResult = flutter::MethodResult<flutter::EncodableValue>;
using SharedResult = std::shared_ptr<EncodableResult>;

flutter::EncodableValue Key(const char *value) {
  return flutter::EncodableValue(value);
}

std::string StatusCode(std::int32_t code) {
  switch (code) {
  case VTK_FLUTTER_STATUS_INVALID_ARGUMENT:
    return "invalid_argument";
  case VTK_FLUTTER_STATUS_INVALID_STATE:
    return "invalid_state";
  case VTK_FLUTTER_STATUS_NOT_SUPPORTED:
    return "not_supported";
  case VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE:
    return "render_target_unavailable";
  default:
    return "vtk_internal_error";
  }
}

std::string StatusMessage(const char *operation,
                          const VtkFlutterStatus &status) {
  return status.message[0] == '\0' ? std::string(operation) + " failed"
                                   : std::string(status.message);
}

class CoreFailure final : public std::runtime_error {
public:
  CoreFailure(std::int32_t code, std::string message)
      : std::runtime_error(std::move(message)), code_(code) {}

  std::int32_t code() const noexcept { return code_; }

private:
  std::int32_t code_;
};

void RequireCoreSuccess(std::int32_t code, const VtkFlutterStatus &status,
                        const char *operation) {
  if (code != VTK_FLUTTER_STATUS_OK) {
    throw CoreFailure(code, StatusMessage(operation, status));
  }
}

struct PixelBufferLease {
  explicit PixelBufferLease(
      std::shared_ptr<const windows::PublishedFrame> published)
      : frame(std::move(published)) {
    buffer.buffer = frame->pixels.data();
    buffer.width = static_cast<std::size_t>(frame->width);
    buffer.height = static_cast<std::size_t>(frame->height);
    buffer.release_context = this;
    buffer.release_callback = [](void *context) {
      delete static_cast<PixelBufferLease *>(context);
    };
  }

  std::shared_ptr<const windows::PublishedFrame> frame;
  FlutterDesktopPixelBuffer buffer{};
};

flutter::EncodableMap ViewMap(std::int64_t texture_id) {
  return {
      {Key("textureId"), flutter::EncodableValue(texture_id)},
  };
}

HWND CurrentTopLevelWindow(HWND flutter_view_window) noexcept {
  return IsWindow(flutter_view_window) == 0
             ? nullptr
             : GetAncestor(flutter_view_window, GA_ROOT);
}

} // namespace

class VtkFlutterPlugin::Implementation final {
public:
  explicit Implementation(flutter::PluginRegistrarWindows *registrar)
      : registrar_(registrar),
        texture_registrar_(
            registrar == nullptr ? nullptr : registrar->texture_registrar()) {
    if (registrar_ == nullptr) {
      return;
    }
    channel_ =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar_->messenger(), kChannelName,
            &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto &call, auto result) {
      HandleMethodCall(call, std::move(result));
    });
    platform_thread_id_ = GetCurrentThreadId();
    if (auto *view = registrar_->GetView()) {
      flutter_view_window_ = view->GetNativeWindow();
    }
    if (flutter_view_window_ != nullptr) {
      window_proc_delegate_ = registrar_->RegisterTopLevelWindowProcDelegate(
          [this](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
            if (message != kDispatchMessage) {
              return std::nullopt;
            }
            DrainPlatformOperations();
            return 0;
          });
    }
  }

  ~Implementation() {
    closed_ = true;
    if (channel_ != nullptr) {
      channel_->SetMethodCallHandler(nullptr);
    }
    DisposeView(nullptr);
    WaitForPendingUnregistration();
    if (window_proc_delegate_ >= 0) {
      registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_delegate_);
    }
    std::lock_guard lock(platform_mutex_);
    platform_operations_.clear();
  }

  void
  HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue> &call,
                   std::unique_ptr<EncodableResult> result) {
    auto shared_result = SharedResult(std::move(result));
    if (call.method_name() == "capabilities") {
      shared_result->Success(
          flutter::EncodableValue(windows::CapabilitiesMap()));
      return;
    }
    if (call.method_name() == "createView") {
      CreateView(call.arguments(), std::move(shared_result));
      return;
    }
    if (call.method_name() == "presentFrame") {
      PresentFrame(std::move(shared_result));
      return;
    }
    if (call.method_name() == "status") {
      shared_result->Success(flutter::EncodableValue(Status()));
      return;
    }
    if (call.method_name() == "resize") {
      Resize(call.arguments(), std::move(shared_result));
      return;
    }
    if (call.method_name() == "recreateGraphicsContext") {
      RecreateGraphicsContext(std::move(shared_result));
      return;
    }
    if (call.method_name() == "disposeView") {
      DisposeView(std::move(shared_result));
      return;
    }
    shared_result->NotImplemented();
  }

private:
  struct PendingViewCreation {
    VtkFlutterViewport viewport;
    const VtkFlutterPresentationApi *presentation_api;
    VtkFlutterSession *session;
    SharedResult result;
  };

  void CreateView(const flutter::EncodableValue *arguments,
                  SharedResult result) {
    VtkFlutterViewport viewport{};
    try {
      viewport = windows::DecodeViewport(arguments);
    } catch (const std::exception &exception) {
      result->Error("invalid_viewport", exception.what());
      return;
    }

    const VtkFlutterPresentationApi *presentation_api = nullptr;
    try {
      presentation_api = &windows::ValidatePresentationApiAddress(
          windows::DecodePresentationApiAddress(arguments));
    } catch (const std::exception &exception) {
      result->Error("invalid_presentation_api", exception.what());
      return;
    }
    VtkFlutterSession *session = nullptr;
    try {
      session = reinterpret_cast<VtkFlutterSession *>(
          windows::DecodeNativeSessionAddress(arguments));
    } catch (const std::exception &exception) {
      result->Error("invalid_native_session", exception.what());
      return;
    }
    CreateView(viewport, presentation_api, session, std::move(result));
  }

  void CreateView(const VtkFlutterViewport &viewport,
                  const VtkFlutterPresentationApi *presentation_api,
                  VtkFlutterSession *session, SharedResult result) {
    if (closed_) {
      result->Error("vtk_disposed", "The Windows VTK plugin is unavailable");
      return;
    }
    if (disposing_) {
      pending_view_creations_.push_back(
          {viewport, presentation_api, session, std::move(result)});
      return;
    }
    if (session_ != nullptr) {
      if (presentation_api_ != presentation_api || session_ != session) {
        result->Error("invalid_state",
                      "The active view uses a different native VTK "
                      "presentation API or session");
        return;
      }
      viewport_ = viewport;
      result->Success(flutter::EncodableValue(ViewMap(texture_id_.load())));
      return;
    }
    if (texture_registrar_ == nullptr || flutter_view_window_ == nullptr ||
        window_proc_delegate_ < 0) {
      result->Error("vtk_create_failed",
                    "The Windows Flutter texture or platform dispatcher is "
                    "unavailable");
      return;
    }

    initializing_ = true;
    auto frame_target = std::make_shared<windows::WindowsFrameTarget>();
    auto graphics_support = std::string(kGraphicsSupport);
    VtkFlutterTextureTarget *target = nullptr;
    bool attached = false;
    try {
      VtkFlutterStatus status{};
      auto callbacks = frame_target->Callbacks();
      RequireCoreSuccess(
          presentation_api->texture_target_create(&callbacks, &target, &status),
          status, "texture_target_create");
      if (target == nullptr) {
        throw std::runtime_error(
            "Native VTK texture_target_create returned no target");
      }
      status = {};
      RequireCoreSuccess(presentation_api->session_attach_texture_target(
                             session, target, &status),
                         status, "session_attach_texture_target");
      attached = true;

      auto texture = std::make_unique<flutter::TextureVariant>(
          flutter::PixelBufferTexture([frame_target](std::size_t, std::size_t) {
            auto frame = frame_target->LatestFrame();
            if (frame == nullptr) {
              return static_cast<const FlutterDesktopPixelBuffer *>(nullptr);
            }
            auto *lease = new (std::nothrow) PixelBufferLease(frame);
            if (lease == nullptr) {
              return static_cast<const FlutterDesktopPixelBuffer *>(nullptr);
            }
            frame_target->RecordPresented(frame->id);
            return static_cast<const FlutterDesktopPixelBuffer *>(
                &lease->buffer);
          }));
      const auto texture_id =
          texture_registrar_->RegisterTexture(texture.get());
      if (texture_id < 0) {
        throw std::runtime_error(
            "Flutter rejected the Windows VTK external texture");
      }

      presentation_api_ = presentation_api;
      session_ = session;
      target_ = target;
      frame_target_ = std::move(frame_target);
      texture_ = std::move(texture);
      texture_id_ = texture_id;
      viewport_ = viewport;
      graphics_context_generation_ = 1;
      graphics_support_ = std::move(graphics_support);
      ready_ = true;
      initializing_ = false;
      result->Success(flutter::EncodableValue(ViewMap(texture_id)));
    } catch (const CoreFailure &failure) {
      CleanupCreatedTarget(presentation_api, session, target, attached);
      initializing_ = false;
      result->Error(StatusCode(failure.code()), failure.what());
    } catch (const std::exception &exception) {
      CleanupCreatedTarget(presentation_api, session, target, attached);
      initializing_ = false;
      result->Error("vtk_create_failed", exception.what());
    }
  }

  static void
  CleanupCreatedTarget(const VtkFlutterPresentationApi *presentation_api,
                       VtkFlutterSession *session,
                       VtkFlutterTextureTarget *target,
                       bool attached) noexcept {
    if (presentation_api == nullptr) {
      return;
    }
    if (attached && session != nullptr && target != nullptr) {
      VtkFlutterStatus status{};
      presentation_api->session_detach_texture_target(session, target, &status);
    }
    if (target != nullptr) {
      VtkFlutterStatus status{};
      presentation_api->texture_target_destroy(target, &status);
    }
  }

  void PresentFrame(SharedResult result) {
    if (!CanUseView(result)) {
      return;
    }
    if (platform_thread_id_ != 0 &&
        GetCurrentThreadId() != platform_thread_id_) {
      result->Error("invalid_state",
                    "Windows frames must be presented on the platform thread");
      return;
    }
    const auto frame = frame_target_->LatestFrame();
    if (frame == nullptr) {
      result->Error("vtk_render_failed",
                    "Native VTK has not published a Windows frame");
      return;
    }
    if (!texture_registrar_->MarkTextureFrameAvailable(texture_id_.load())) {
      result->Error("vtk_render_failed",
                    "Flutter rejected the Windows VTK texture frame");
      return;
    }
    result->Success(flutter::EncodableValue(PresentationMap(frame->id)));
  }

  flutter::EncodableMap PresentationMap(std::int64_t frame_id) const {
    return {
        {Key("frameId"), flutter::EncodableValue(frame_id)},
        {Key("presentedFrameCount"),
         flutter::EncodableValue(frame_target_->PresentedFrameCount())},
        {Key("presentedFrameId"),
         flutter::EncodableValue(frame_target_->PresentedFrameId())},
        {Key("graphicsContextGeneration"),
         flutter::EncodableValue(graphics_context_generation_.load())},
        {Key("handoffMode"), flutter::EncodableValue(kHandoffMode)},
    };
  }

  flutter::EncodableMap Status() const {
    const auto frame_target = frame_target_;
    return {
        {Key("textureId"), flutter::EncodableValue(texture_id_.load())},
        {Key("ready"), flutter::EncodableValue(ready_.load())},
        {Key("initializing"), flutter::EncodableValue(initializing_.load())},
        {Key("disposing"), flutter::EncodableValue(disposing_.load())},
        {Key("pendingTextureUnregistrations"),
         flutter::EncodableValue(pending_unregistrations_.load())},
        {Key("queuedInitializationCount"),
         flutter::EncodableValue(
             static_cast<std::int64_t>(pending_view_creations_.size()))},
        {Key("presentedFrameCount"),
         flutter::EncodableValue(frame_target == nullptr
                                     ? std::int64_t{0}
                                     : frame_target->PresentedFrameCount())},
        {Key("presentedFrameId"),
         flutter::EncodableValue(frame_target == nullptr
                                     ? std::int64_t{0}
                                     : frame_target->PresentedFrameId())},
        {Key("graphicsContextGeneration"),
         flutter::EncodableValue(graphics_context_generation_.load())},
        {Key("graphicsSupport"), flutter::EncodableValue(graphics_support_)},
    };
  }

  void Resize(const flutter::EncodableValue *arguments, SharedResult result) {
    if (!CanUseView(result)) {
      return;
    }
    try {
      viewport_ = windows::DecodeViewport(arguments);
      result->Success(flutter::EncodableValue());
    } catch (const std::exception &exception) {
      result->Error("invalid_viewport", exception.what());
    }
  }

  void RecreateGraphicsContext(SharedResult result) {
    if (!CanUseView(result)) {
      return;
    }

    VtkFlutterTextureTarget *replacement = nullptr;
    bool old_detached = false;
    try {
      auto callbacks = frame_target_->Callbacks();
      VtkFlutterStatus status{};
      RequireCoreSuccess(presentation_api_->texture_target_create(
                             &callbacks, &replacement, &status),
                         status, "texture_target_create");
      status = {};
      RequireCoreSuccess(presentation_api_->session_detach_texture_target(
                             session_, target_, &status),
                         status, "session_detach_texture_target");
      old_detached = true;
      status = {};
      RequireCoreSuccess(presentation_api_->session_attach_texture_target(
                             session_, replacement, &status),
                         status, "session_attach_texture_target");

      auto *previous = target_;
      target_ = replacement;
      replacement = nullptr;
      status = {};
      RequireCoreSuccess(
          presentation_api_->texture_target_destroy(previous, &status), status,
          "texture_target_destroy");
      const auto generation = graphics_context_generation_.fetch_add(1) + 1;
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {Key("graphicsContextGeneration"),
           flutter::EncodableValue(generation)},
      }));
    } catch (const CoreFailure &failure) {
      if (old_detached && replacement != nullptr) {
        VtkFlutterStatus rollback_status{};
        presentation_api_->session_attach_texture_target(session_, target_,
                                                         &rollback_status);
      }
      if (replacement != nullptr) {
        VtkFlutterStatus destroy_status{};
        presentation_api_->texture_target_destroy(replacement, &destroy_status);
      }
      result->Error("vtk_context_failed", failure.what());
    } catch (const std::exception &exception) {
      result->Error("vtk_context_failed", exception.what());
    }
  }

  void DestroyPresentationTarget() noexcept {
    const auto *presentation_api = presentation_api_;
    auto *session = session_;
    auto *target = target_;
    presentation_api_ = nullptr;
    session_ = nullptr;
    target_ = nullptr;
    if (presentation_api == nullptr) {
      return;
    }

    if (session != nullptr && target != nullptr) {
      VtkFlutterStatus status{};
      presentation_api->session_detach_texture_target(session, target, &status);
    }
    if (target != nullptr) {
      VtkFlutterStatus status{};
      presentation_api->texture_target_destroy(target, &status);
    }
  }

  void DisposeView(SharedResult result) {
    if (result != nullptr) {
      pending_disposals_.push_back(std::move(result));
    }
    if (disposing_.exchange(true)) {
      return;
    }
    if (session_ == nullptr && texture_id_ < 0 &&
        pending_unregistrations_ == 0) {
      FinishDispose();
      return;
    }

    ready_ = false;
    DestroyPresentationTarget();
    viewport_ = {};
    graphics_context_generation_ = 0;
    if (frame_target_ != nullptr) {
      frame_target_->Clear();
    }

    const auto texture_id = texture_id_.exchange(-1);
    if (texture_id < 0 || texture_registrar_ == nullptr) {
      texture_.reset();
      FinishDispose();
      return;
    }

    {
      std::lock_guard lock(unregister_mutex_);
      pending_unregistrations_ = 1;
    }
    auto retained_texture =
        std::shared_ptr<flutter::TextureVariant>(std::move(texture_));
    texture_registrar_->UnregisterTexture(
        texture_id,
        [this, retained_texture = std::move(retained_texture)]() mutable {
          retained_texture.reset();
          if (!closed_) {
            if (GetCurrentThreadId() == platform_thread_id_) {
              FinishDispose();
            } else if (!PostToPlatform([this] { FinishDispose(); })) {
              disposing_ = false;
            }
          }
          {
            std::lock_guard lock(unregister_mutex_);
            pending_unregistrations_ = 0;
            unregister_condition_.notify_all();
          }
        });
  }

  void FinishDispose() {
    if (frame_target_ != nullptr) {
      frame_target_->Clear();
    }
    frame_target_.reset();
    disposing_ = false;

    auto disposals = std::move(pending_disposals_);
    pending_disposals_.clear();
    for (const auto &result : disposals) {
      result->Success(flutter::EncodableValue());
    }

    auto creations = std::move(pending_view_creations_);
    pending_view_creations_.clear();
    for (auto &creation : creations) {
      if (closed_) {
        creation.result->Error("vtk_disposed",
                               "The Windows VTK plugin is unavailable");
      } else {
        CreateView(creation.viewport, creation.presentation_api,
                   creation.session, std::move(creation.result));
      }
    }
  }

  bool CanUseView(const SharedResult &result) const {
    if (closed_ || disposing_ || initializing_ || !ready_ ||
        presentation_api_ == nullptr || session_ == nullptr ||
        target_ == nullptr || frame_target_ == nullptr || texture_id_ < 0) {
      result->Error("vtk_not_initialized",
                    "Create a Windows VTK view before using it");
      return false;
    }
    return true;
  }

  bool PostToPlatform(std::function<void()> operation) {
    if (closed_ || flutter_view_window_ == nullptr) {
      return false;
    }
    const auto operation_id = ++last_platform_operation_id_;
    {
      std::lock_guard lock(platform_mutex_);
      platform_operations_.push_back({operation_id, std::move(operation)});
    }
    const auto root_window = CurrentTopLevelWindow(flutter_view_window_);
    if (root_window != nullptr &&
        PostMessage(root_window, kDispatchMessage, 0, 0) != 0) {
      return true;
    }
    std::lock_guard lock(platform_mutex_);
    const auto pending =
        std::find_if(platform_operations_.begin(), platform_operations_.end(),
                     [operation_id](const auto &candidate) {
                       return candidate.id == operation_id;
                     });
    if (pending == platform_operations_.end()) {
      return true;
    }
    platform_operations_.erase(pending);
    return false;
  }

  void DrainPlatformOperations() {
    std::deque<PlatformOperation> operations;
    {
      std::lock_guard lock(platform_mutex_);
      operations.swap(platform_operations_);
    }
    for (auto &operation : operations) {
      operation.callback();
    }
  }

  void WaitForPendingUnregistration() {
    std::unique_lock lock(unregister_mutex_);
    unregister_condition_.wait(
        lock, [this] { return pending_unregistrations_.load() == 0; });
  }

  flutter::PluginRegistrarWindows *registrar_;
  flutter::TextureRegistrar *texture_registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::TextureVariant> texture_;
  const VtkFlutterPresentationApi *presentation_api_ = nullptr;
  VtkFlutterSession *session_ = nullptr;
  VtkFlutterTextureTarget *target_ = nullptr;
  std::shared_ptr<windows::WindowsFrameTarget> frame_target_;
  VtkFlutterViewport viewport_{};
  std::atomic<std::int64_t> texture_id_ = -1;
  std::atomic<std::int64_t> graphics_context_generation_ = 0;
  std::atomic<int> pending_unregistrations_ = 0;
  std::atomic_bool initializing_ = false;
  std::atomic_bool disposing_ = false;
  std::atomic_bool ready_ = false;
  std::atomic_bool closed_ = false;
  std::string graphics_support_;
  std::vector<PendingViewCreation> pending_view_creations_;
  std::vector<SharedResult> pending_disposals_;
  std::mutex unregister_mutex_;
  std::condition_variable unregister_condition_;
  struct PlatformOperation {
    std::uint64_t id;
    std::function<void()> callback;
  };
  HWND flutter_view_window_ = nullptr;
  DWORD platform_thread_id_ = 0;
  int window_proc_delegate_ = -1;
  std::atomic<std::uint64_t> last_platform_operation_id_ = 0;
  std::mutex platform_mutex_;
  std::deque<PlatformOperation> platform_operations_;
};

void VtkFlutterPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  registrar->AddPlugin(std::make_unique<VtkFlutterPlugin>(registrar));
}

VtkFlutterPlugin::VtkFlutterPlugin(flutter::PluginRegistrarWindows *registrar)
    : implementation_(std::make_unique<Implementation>(registrar)) {}

VtkFlutterPlugin::~VtkFlutterPlugin() = default;

void VtkFlutterPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  implementation_->HandleMethodCall(method_call, std::move(result));
}

} // namespace vtk_flutter
