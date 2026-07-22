#include "vtk_flutter_plugin.h"

#include "vtk_flutter_codec.h"
#include "windows_frame_target.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <windows.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <stdexcept>
#include <string>
#include <unordered_map>
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
using SessionKey = std::uintptr_t;

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

class RegistrarViewHost final : public WindowsVtkViewHost {
public:
  explicit RegistrarViewHost(flutter::PluginRegistrarWindows *registrar)
      : registrar_(registrar),
        texture_registrar_(
            registrar == nullptr ? nullptr : registrar->texture_registrar()),
        platform_thread_id_(GetCurrentThreadId()) {
    if (registrar_ == nullptr) {
      return;
    }
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

  ~RegistrarViewHost() override {
    if (window_proc_delegate_ >= 0 && registrar_ != nullptr) {
      registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_delegate_);
    }
    std::lock_guard lock(platform_mutex_);
    platform_operations_.clear();
  }

  bool IsAvailable() const noexcept override {
    return texture_registrar_ != nullptr && flutter_view_window_ != nullptr &&
           window_proc_delegate_ >= 0;
  }

  bool IsOnPlatformThread() const noexcept override {
    return platform_thread_id_ == 0 ||
           GetCurrentThreadId() == platform_thread_id_;
  }

  std::int64_t RegisterTexture(flutter::TextureVariant *texture) override {
    return texture_registrar_ == nullptr
               ? -1
               : texture_registrar_->RegisterTexture(texture);
  }

  bool MarkTextureFrameAvailable(std::int64_t texture_id) override {
    return texture_registrar_ != nullptr &&
           texture_registrar_->MarkTextureFrameAvailable(texture_id);
  }

  void UnregisterTexture(std::int64_t texture_id,
                         std::function<void()> callback) override {
    texture_registrar_->UnregisterTexture(texture_id, std::move(callback));
  }

  bool PostToPlatform(std::function<void()> operation) override {
    const auto operation_id = ++last_platform_operation_id_;
    {
      std::lock_guard lock(platform_mutex_);
      platform_operations_.push_back({operation_id, std::move(operation)});
    }
    const auto root_window = flutter_view_window_ == nullptr
                                 ? nullptr
                                 : CurrentTopLevelWindow(flutter_view_window_);
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

  void DrainPlatformOperations() override {
    std::deque<PlatformOperation> operations;
    {
      std::lock_guard lock(platform_mutex_);
      operations.swap(platform_operations_);
    }
    for (auto &operation : operations) {
      operation.callback();
    }
  }

private:
  struct PlatformOperation {
    std::uint64_t id;
    std::function<void()> callback;
  };

  flutter::PluginRegistrarWindows *registrar_;
  flutter::TextureRegistrar *texture_registrar_;
  HWND flutter_view_window_ = nullptr;
  DWORD platform_thread_id_ = 0;
  int window_proc_delegate_ = -1;
  std::atomic<std::uint64_t> last_platform_operation_id_ = 0;
  std::mutex platform_mutex_;
  std::deque<PlatformOperation> platform_operations_;
};

} // namespace

class VtkFlutterPlugin::Implementation final {
public:
  explicit Implementation(flutter::PluginRegistrarWindows *registrar)
      : Implementation(std::make_unique<RegistrarViewHost>(registrar)) {
    if (registrar == nullptr) {
      return;
    }
    channel_ =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), kChannelName,
            &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto &call, auto result) {
      HandleMethodCall(call, std::move(result));
    });
  }

  explicit Implementation(std::unique_ptr<WindowsVtkViewHost> view_host)
      : view_host_(std::move(view_host)) {}

  ~Implementation() {
    closed_ = true;
    if (channel_ != nullptr) {
      channel_->SetMethodCallHandler(nullptr);
    }
    if (view_host_ != nullptr) {
      view_host_->DrainPlatformOperations();
    }
    std::vector<std::pair<SessionKey, std::shared_ptr<ViewState>>> views;
    views.reserve(views_.size());
    for (const auto &[key, view] : views_) {
      views.emplace_back(key, view);
    }
    for (const auto &[key, view] : views) {
      if (view->disposing) {
        continue;
      }
      try {
        DestroyPresentationTargets(*view);
        BeginTextureUnregistration(key, view);
      } catch (const std::exception &exception) {
        const auto message = std::string("[vtk_flutter] Windows dispose during "
                                         "plugin destruction failed: ") +
                             exception.what() + "\n";
        OutputDebugStringA(message.c_str());
      }
    }
    WaitForPendingUnregistrations();
  }

  void
  HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue> &call,
                   std::unique_ptr<EncodableResult> result) {
    if (view_host_ != nullptr && view_host_->IsOnPlatformThread()) {
      view_host_->DrainPlatformOperations();
    }
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
      PresentFrame(call.arguments(), std::move(shared_result));
      return;
    }
    if (call.method_name() == "status") {
      Status(call.arguments(), std::move(shared_result));
      return;
    }
    if (call.method_name() == "resize") {
      Resize(call.arguments(), std::move(shared_result));
      return;
    }
    if (call.method_name() == "recreateGraphicsContext") {
      RecreateGraphicsContext(call.arguments(), std::move(shared_result));
      return;
    }
    if (call.method_name() == "disposeView") {
      DisposeView(call.arguments(), std::move(shared_result));
      return;
    }
    shared_result->NotImplemented();
  }

private:
  class AsyncCompletion final {
  public:
    explicit AsyncCompletion(std::function<void()> completion)
        : completion_(std::move(completion)) {}

    void MarkCallbackComplete() { MarkComplete(true); }
    void MarkPlatformCleanupComplete() { MarkComplete(false); }

  private:
    void MarkComplete(bool callback) {
      std::function<void()> completion;
      {
        std::lock_guard lock(mutex_);
        if (callback) {
          callback_complete_ = true;
        } else {
          platform_cleanup_complete_ = true;
        }
        if (callback_complete_ && platform_cleanup_complete_ &&
            completion_ != nullptr) {
          completion = std::move(completion_);
        }
      }
      if (completion != nullptr) {
        completion();
      }
    }

    std::mutex mutex_;
    bool callback_complete_ = false;
    bool platform_cleanup_complete_ = false;
    std::function<void()> completion_;
  };

  struct PendingViewCreation {
    VtkFlutterViewport viewport;
    const VtkFlutterPresentationApi *presentation_api;
    VtkFlutterSession *session;
    SharedResult result;
  };

  struct ViewState {
    bool IsComplete() const noexcept {
      return ready && !initializing && !disposing &&
             presentation_api != nullptr && session != nullptr &&
             target != nullptr && target_attached && frame_target != nullptr &&
             texture != nullptr && texture_id >= 0;
    }

    const VtkFlutterPresentationApi *presentation_api = nullptr;
    VtkFlutterSession *session = nullptr;
    VtkFlutterTextureTarget *target = nullptr;
    VtkFlutterTextureTarget *pending_destroy_target = nullptr;
    std::shared_ptr<windows::WindowsFrameTarget> frame_target;
    std::shared_ptr<flutter::TextureVariant> texture;
    VtkFlutterViewport viewport{};
    std::int64_t texture_id = -1;
    std::int64_t graphics_context_generation = 0;
    int pending_unregistrations = 0;
    bool target_attached = false;
    bool initializing = false;
    bool disposing = false;
    bool ready = false;
    std::vector<PendingViewCreation> pending_view_creations;
    std::vector<SharedResult> pending_disposals;
  };

  SessionKey DecodeSessionKey(const flutter::EncodableValue *arguments,
                              const SharedResult &result) const {
    try {
      return windows::DecodeNativeSessionAddress(arguments);
    } catch (const std::exception &exception) {
      result->Error("invalid_native_session", exception.what());
      return 0;
    }
  }

  std::shared_ptr<ViewState>
  ViewForArguments(const flutter::EncodableValue *arguments,
                   const SharedResult &result) const {
    const auto key = DecodeSessionKey(arguments, result);
    if (key == 0) {
      return nullptr;
    }
    const auto iterator = views_.find(key);
    if (iterator == views_.end()) {
      result->Error("vtk_not_initialized",
                    "Create a Windows VTK view for this session first");
      return nullptr;
    }
    return iterator->second;
  }

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
    const auto key = reinterpret_cast<SessionKey>(session);
    if (const auto existing = views_.find(key); existing != views_.end()) {
      const auto &view = existing->second;
      if (view->presentation_api != presentation_api) {
        result->Error("invalid_state",
                      "The session view uses a different presentation API");
        return;
      }
      if (view->disposing) {
        view->pending_view_creations.push_back(
            {viewport, presentation_api, session, std::move(result)});
        return;
      }
      if (!view->IsComplete()) {
        result->Error(
            "invalid_state",
            "Dispose the incomplete Windows VTK view before retrying");
        return;
      }
      view->viewport = viewport;
      result->Success(flutter::EncodableValue(ViewMap(view->texture_id)));
      return;
    }
    if (view_host_ == nullptr || !view_host_->IsAvailable()) {
      result->Error("vtk_create_failed",
                    "The Windows Flutter texture or platform dispatcher is "
                    "unavailable");
      return;
    }

    auto view = std::make_shared<ViewState>();
    view->presentation_api = presentation_api;
    view->session = session;
    view->viewport = viewport;
    view->frame_target = std::make_shared<windows::WindowsFrameTarget>();
    view->initializing = true;

    try {
      auto callbacks = view->frame_target->Callbacks();
      VtkFlutterStatus status{};
      const auto create_code = presentation_api->texture_target_create(
          &callbacks, &view->target, &status);
      if (create_code != VTK_FLUTTER_STATUS_OK) {
        if (view->target != nullptr && !TryDestroyTarget(*view, view->target)) {
          view->pending_destroy_target = view->target;
          view->target = nullptr;
          views_.emplace(key, view);
        }
        RequireCoreSuccess(create_code, status, "texture_target_create");
      }
      if (view->target == nullptr) {
        throw std::runtime_error(
            "Native VTK texture_target_create returned no target");
      }

      status = {};
      const auto attach_code = presentation_api->session_attach_texture_target(
          session, view->target, &status);
      if (attach_code != VTK_FLUTTER_STATUS_OK) {
        if (!TryDestroyTarget(*view, view->target)) {
          views_.emplace(key, view);
        } else {
          view->target = nullptr;
        }
        RequireCoreSuccess(attach_code, status,
                           "session_attach_texture_target");
      }
      view->target_attached = true;

      std::int64_t texture_id = -1;
      try {
        const auto frame_target = view->frame_target;
        view->texture = std::make_shared<flutter::TextureVariant>(
            flutter::PixelBufferTexture([frame_target](std::size_t,
                                                       std::size_t) {
              const auto frame = frame_target->LatestFrame();
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
        texture_id = view_host_->RegisterTexture(view->texture.get());
      } catch (...) {
        try {
          RollBackUnregisteredView(*view);
        } catch (...) {
          if (view->target != nullptr ||
              view->pending_destroy_target != nullptr) {
            views_.emplace(key, view);
          }
          throw;
        }
        throw;
      }
      if (texture_id < 0) {
        try {
          RollBackUnregisteredView(*view);
        } catch (...) {
          if (view->target != nullptr ||
              view->pending_destroy_target != nullptr) {
            views_.emplace(key, view);
          }
          throw;
        }
        if (view->target != nullptr ||
            view->pending_destroy_target != nullptr) {
          views_.emplace(key, view);
        }
        throw std::runtime_error(
            "Flutter rejected the Windows VTK external texture");
      }

      view->texture_id = texture_id;
      view->graphics_context_generation = 1;
      view->initializing = false;
      view->ready = true;
      views_.emplace(key, view);
      result->Success(flutter::EncodableValue(ViewMap(texture_id)));
    } catch (const CoreFailure &failure) {
      view->initializing = false;
      result->Error(StatusCode(failure.code()), failure.what());
    } catch (const std::exception &exception) {
      view->initializing = false;
      result->Error("vtk_create_failed", exception.what());
    }
  }

  bool TryDestroyTarget(ViewState &view,
                        VtkFlutterTextureTarget *target) noexcept {
    if (target == nullptr || view.presentation_api == nullptr) {
      return true;
    }
    VtkFlutterStatus status{};
    return view.presentation_api->texture_target_destroy(target, &status) ==
           VTK_FLUTTER_STATUS_OK;
  }

  void RollBackUnregisteredView(ViewState &view) {
    if (view.target_attached) {
      VtkFlutterStatus status{};
      RequireCoreSuccess(view.presentation_api->session_detach_texture_target(
                             view.session, view.target, &status),
                         status, "roll back texture target attachment");
      view.target_attached = false;
    }
    if (view.target != nullptr) {
      VtkFlutterStatus status{};
      RequireCoreSuccess(
          view.presentation_api->texture_target_destroy(view.target, &status),
          status, "destroy unregistered texture target");
      view.target = nullptr;
    }
  }

  void PresentFrame(const flutter::EncodableValue *arguments,
                    SharedResult result) {
    const auto view = ViewForArguments(arguments, result);
    if (view == nullptr || !CanUseView(*view, result)) {
      return;
    }
    if (!view_host_->IsOnPlatformThread()) {
      result->Error("invalid_state",
                    "Windows frames must be presented on the platform thread");
      return;
    }
    const auto frame = view->frame_target->LatestFrame();
    if (frame == nullptr) {
      result->Error("vtk_render_failed",
                    "Native VTK has not published a Windows frame");
      return;
    }
    if (!view_host_->MarkTextureFrameAvailable(view->texture_id)) {
      result->Error("vtk_render_failed",
                    "Flutter rejected the Windows VTK texture frame");
      return;
    }
    result->Success(flutter::EncodableValue(PresentationMap(*view, frame->id)));
  }

  flutter::EncodableMap PresentationMap(const ViewState &view,
                                        std::int64_t frame_id) const {
    return {
        {Key("frameId"), flutter::EncodableValue(frame_id)},
        {Key("presentedFrameCount"),
         flutter::EncodableValue(view.frame_target->PresentedFrameCount())},
        {Key("presentedFrameId"),
         flutter::EncodableValue(view.frame_target->PresentedFrameId())},
        {Key("graphicsContextGeneration"),
         flutter::EncodableValue(view.graphics_context_generation)},
        {Key("handoffMode"), flutter::EncodableValue(kHandoffMode)},
    };
  }

  flutter::EncodableMap StatusMap(const ViewState &view) const {
    const auto frame_target = view.frame_target;
    return {
        {Key("textureId"), flutter::EncodableValue(view.texture_id)},
        {Key("ready"), flutter::EncodableValue(view.IsComplete())},
        {Key("initializing"), flutter::EncodableValue(view.initializing)},
        {Key("disposing"), flutter::EncodableValue(view.disposing)},
        {Key("pendingTextureUnregistrations"),
         flutter::EncodableValue(view.pending_unregistrations)},
        {Key("queuedInitializationCount"),
         flutter::EncodableValue(
             static_cast<std::int64_t>(view.pending_view_creations.size()))},
        {Key("presentedFrameCount"),
         flutter::EncodableValue(frame_target == nullptr
                                     ? std::int64_t{0}
                                     : frame_target->PresentedFrameCount())},
        {Key("presentedFrameId"),
         flutter::EncodableValue(frame_target == nullptr
                                     ? std::int64_t{0}
                                     : frame_target->PresentedFrameId())},
        {Key("graphicsContextGeneration"),
         flutter::EncodableValue(view.graphics_context_generation)},
        {Key("graphicsSupport"), flutter::EncodableValue(kGraphicsSupport)},
    };
  }

  void Status(const flutter::EncodableValue *arguments, SharedResult result) {
    const auto view = ViewForArguments(arguments, result);
    if (view != nullptr) {
      result->Success(flutter::EncodableValue(StatusMap(*view)));
    }
  }

  void Resize(const flutter::EncodableValue *arguments, SharedResult result) {
    const auto view = ViewForArguments(arguments, result);
    if (view == nullptr || !CanUseView(*view, result)) {
      return;
    }
    try {
      view->viewport = windows::DecodeViewport(arguments);
      result->Success(flutter::EncodableValue());
    } catch (const std::exception &exception) {
      result->Error("invalid_viewport", exception.what());
    }
  }

  void RecreateGraphicsContext(const flutter::EncodableValue *arguments,
                               SharedResult result) {
    const auto view = ViewForArguments(arguments, result);
    if (view == nullptr || !CanUseView(*view, result)) {
      return;
    }

    try {
      DestroyPendingTarget(*view);

      VtkFlutterTextureTarget *replacement = nullptr;
      auto callbacks = view->frame_target->Callbacks();
      VtkFlutterStatus status{};
      const auto create_code = view->presentation_api->texture_target_create(
          &callbacks, &replacement, &status);
      if (create_code != VTK_FLUTTER_STATUS_OK) {
        if (replacement != nullptr && !TryDestroyTarget(*view, replacement)) {
          view->pending_destroy_target = replacement;
        }
        RequireCoreSuccess(create_code, status, "texture_target_create");
      }
      if (replacement == nullptr) {
        throw std::runtime_error(
            "Native VTK texture_target_create returned no target");
      }

      status = {};
      const auto detach_code =
          view->presentation_api->session_detach_texture_target(
              view->session, view->target, &status);
      if (detach_code != VTK_FLUTTER_STATUS_OK) {
        if (!TryDestroyTarget(*view, replacement)) {
          view->pending_destroy_target = replacement;
        }
        RequireCoreSuccess(detach_code, status,
                           "session_detach_texture_target");
      }
      view->target_attached = false;

      status = {};
      const auto attach_code =
          view->presentation_api->session_attach_texture_target(
              view->session, replacement, &status);
      if (attach_code != VTK_FLUTTER_STATUS_OK) {
        VtkFlutterStatus restore_status{};
        view->target_attached =
            view->presentation_api->session_attach_texture_target(
                view->session, view->target, &restore_status) ==
            VTK_FLUTTER_STATUS_OK;
        if (!TryDestroyTarget(*view, replacement)) {
          view->pending_destroy_target = replacement;
        }
        RequireCoreSuccess(attach_code, status,
                           "session_attach_texture_target");
      }

      auto *previous = view->target;
      view->target = replacement;
      view->target_attached = true;
      view->graphics_context_generation += 1;
      const auto cleanup_pending = !TryDestroyTarget(*view, previous);
      if (cleanup_pending) {
        view->pending_destroy_target = previous;
      }
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {Key("graphicsContextGeneration"),
           flutter::EncodableValue(view->graphics_context_generation)},
          {Key("cleanupPending"), flutter::EncodableValue(cleanup_pending)},
      }));
    } catch (const CoreFailure &failure) {
      result->Error("vtk_context_failed", failure.what());
    } catch (const std::exception &exception) {
      result->Error("vtk_context_failed", exception.what());
    }
  }

  void DestroyPendingTarget(ViewState &view) {
    if (view.pending_destroy_target == nullptr) {
      return;
    }
    VtkFlutterStatus status{};
    RequireCoreSuccess(view.presentation_api->texture_target_destroy(
                           view.pending_destroy_target, &status),
                       status, "destroy deferred texture target");
    view.pending_destroy_target = nullptr;
  }

  void DestroyPresentationTargets(ViewState &view) {
    DestroyPendingTarget(view);
    if (view.presentation_api != nullptr && view.session != nullptr &&
        view.target != nullptr && view.target_attached) {
      VtkFlutterStatus status{};
      RequireCoreSuccess(view.presentation_api->session_detach_texture_target(
                             view.session, view.target, &status),
                         status, "session_detach_texture_target");
      view.target_attached = false;
    }
    if (view.presentation_api != nullptr && view.target != nullptr) {
      VtkFlutterStatus status{};
      RequireCoreSuccess(
          view.presentation_api->texture_target_destroy(view.target, &status),
          status, "texture_target_destroy");
      view.target = nullptr;
    }
  }

  void DisposeView(const flutter::EncodableValue *arguments,
                   SharedResult result) {
    const auto key = DecodeSessionKey(arguments, result);
    if (key == 0) {
      return;
    }
    const auto iterator = views_.find(key);
    if (iterator == views_.end()) {
      result->Success(flutter::EncodableValue());
      return;
    }
    const auto &view = iterator->second;
    if (view->disposing) {
      view->pending_disposals.push_back(std::move(result));
      return;
    }

    try {
      DestroyPresentationTargets(*view);
    } catch (const CoreFailure &failure) {
      result->Error(StatusCode(failure.code()), failure.what());
      return;
    } catch (const std::exception &exception) {
      result->Error("vtk_internal_error", exception.what());
      return;
    }

    view->ready = false;
    view->graphics_context_generation = 0;
    view->viewport = {};
    if (view->frame_target != nullptr) {
      view->frame_target->Clear();
    }
    view->pending_disposals.push_back(result);
    try {
      BeginTextureUnregistration(key, view);
    } catch (const std::exception &exception) {
      view->pending_disposals.pop_back();
      result->Error("vtk_internal_error", exception.what());
    }
  }

  void BeginTextureUnregistration(SessionKey key,
                                  const std::shared_ptr<ViewState> &view) {
    if (view->disposing) {
      return;
    }
    view->disposing = true;
    const auto texture_id = view->texture_id;
    if (texture_id < 0 || view_host_ == nullptr) {
      view->texture_id = -1;
      view->texture.reset();
      FinishDispose(key, view);
      return;
    }

    const auto completion = std::make_shared<AsyncCompletion>(
        [this] { CompletePendingUnregistration(); });
    view->texture_id = -1;
    view->pending_unregistrations = 1;
    {
      std::lock_guard lock(unregister_mutex_);
      ++pending_unregistrations_;
    }
    auto retained_texture = std::exchange(
        view->texture, std::shared_ptr<flutter::TextureVariant>());
    try {
      view_host_->UnregisterTexture(texture_id, [this, key, view,
                                                 retained_texture,
                                                 completion]() mutable {
        auto finish = [this, key, view, retained_texture,
                       completion](bool resume_pending_creations) mutable {
          retained_texture.reset();
          try {
            FinishDispose(key, view, resume_pending_creations);
          } catch (const std::exception &exception) {
            const auto message =
                std::string("[vtk_flutter] Windows platform texture "
                            "cleanup failed: ") +
                exception.what() + "\n";
            OutputDebugStringA(message.c_str());
          } catch (...) {
            OutputDebugStringA("[vtk_flutter] Windows platform texture cleanup "
                               "failed with an unknown error\n");
          }
          completion->MarkPlatformCleanupComplete();
        };
        if (view_host_->IsOnPlatformThread()) {
          finish(true);
        } else {
          try {
            auto platform_finish = [finish]() mutable { finish(true); };
            if (!view_host_->PostToPlatform(platform_finish)) {
              OutputDebugStringA(
                  "[vtk_flutter] Windows texture cleanup is running on "
                  "the unregister callback after a failed "
                  "platform-window wakeup\n");
              finish(false);
            }
            unregister_condition_.notify_all();
          } catch (const std::exception &exception) {
            const auto message =
                std::string("[vtk_flutter] Windows could not queue "
                            "platform texture cleanup: ") +
                exception.what() + "\n";
            OutputDebugStringA(message.c_str());
            finish(false);
          } catch (...) {
            OutputDebugStringA(
                "[vtk_flutter] Windows could not queue platform texture "
                "cleanup because of an unknown error\n");
            finish(false);
          }
        }
        completion->MarkCallbackComplete();
      });
    } catch (...) {
      view->texture = std::move(retained_texture);
      view->texture_id = texture_id;
      view->pending_unregistrations = 0;
      view->disposing = false;
      completion->MarkPlatformCleanupComplete();
      completion->MarkCallbackComplete();
      throw;
    }
  }

  void FinishDispose(SessionKey key, const std::shared_ptr<ViewState> &view,
                     bool resume_pending_creations = true) {
    view->pending_unregistrations = 0;
    view->disposing = false;
    view->frame_target.reset();
    view->presentation_api = nullptr;
    view->session = nullptr;

    const auto iterator = views_.find(key);
    if (iterator != views_.end() && iterator->second == view) {
      views_.erase(iterator);
    }

    auto disposals = std::move(view->pending_disposals);
    for (const auto &result : disposals) {
      result->Success(flutter::EncodableValue());
    }

    auto creations = std::move(view->pending_view_creations);
    for (auto &creation : creations) {
      if (closed_) {
        creation.result->Error("vtk_disposed",
                               "The Windows VTK plugin is unavailable");
      } else if (!resume_pending_creations) {
        creation.result->Error(
            "vtk_create_failed",
            "Retry the Windows VTK view after the platform dispatcher "
            "becomes available");
      } else {
        CreateView(creation.viewport, creation.presentation_api,
                   creation.session, std::move(creation.result));
      }
    }
  }

  void CompletePendingUnregistration() {
    {
      std::lock_guard lock(unregister_mutex_);
      --pending_unregistrations_;
    }
    unregister_condition_.notify_all();
  }

  bool CanUseView(const ViewState &view, const SharedResult &result) const {
    if (closed_ || !view.IsComplete()) {
      result->Error("vtk_not_initialized",
                    "Complete the Windows VTK view before using it");
      return false;
    }
    return true;
  }

  void WaitForPendingUnregistrations() {
    for (;;) {
      if (view_host_ != nullptr) {
        view_host_->DrainPlatformOperations();
      }
      std::unique_lock lock(unregister_mutex_);
      if (pending_unregistrations_ == 0) {
        return;
      }
      unregister_condition_.wait_for(lock, std::chrono::milliseconds(10));
    }
  }

  std::unique_ptr<WindowsVtkViewHost> view_host_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unordered_map<SessionKey, std::shared_ptr<ViewState>> views_;
  std::atomic_bool closed_ = false;
  std::mutex unregister_mutex_;
  std::condition_variable unregister_condition_;
  int pending_unregistrations_ = 0;
};

void VtkFlutterPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  registrar->AddPlugin(std::make_unique<VtkFlutterPlugin>(registrar));
}

VtkFlutterPlugin::VtkFlutterPlugin(flutter::PluginRegistrarWindows *registrar)
    : implementation_(std::make_unique<Implementation>(registrar)) {}

VtkFlutterPlugin::VtkFlutterPlugin(
    std::unique_ptr<WindowsVtkViewHost> view_host)
    : implementation_(std::make_unique<Implementation>(std::move(view_host))) {}

VtkFlutterPlugin::~VtkFlutterPlugin() = default;

void VtkFlutterPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  implementation_->HandleMethodCall(method_call, std::move(result));
}

} // namespace vtk_flutter
