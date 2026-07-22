#include "vtk_flutter.h"

#include "session.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>

namespace {
std::mutex g_sessions_mutex;
std::unordered_map<VtkFlutterSession *, std::shared_ptr<VtkFlutterSession>>
    g_sessions;

void SetStatus(VtkFlutterStatus *status, VtkFlutterStatusCode code,
               std::string_view message = {}) {
  if (status == nullptr) {
    return;
  }
  status->code = static_cast<int32_t>(code);
  const auto length = std::min(message.size(), sizeof(status->message) - 1U);
  std::copy_n(message.data(), length, status->message);
  status->message[length] = '\0';
}

template <typename Action>
int32_t TranslateErrors(VtkFlutterStatus *status, Action action) {
  SetStatus(status, VTK_FLUTTER_STATUS_OK);
  try {
    action();
    return VTK_FLUTTER_STATUS_OK;
  } catch (const vtk_flutter::FrameCallbackFailure &exception) {
    SetStatus(status,
              static_cast<VtkFlutterStatusCode>(exception.Code()),
              exception.what());
    return exception.Code();
  } catch (const vtk_flutter::InvalidState &exception) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_STATE, exception.what());
    return VTK_FLUTTER_STATUS_INVALID_STATE;
  } catch (const vtk_flutter::RenderTargetUnavailable &exception) {
    SetStatus(status, VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE,
              exception.what());
    return VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE;
  } catch (const std::invalid_argument &exception) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT, exception.what());
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  } catch (const std::exception &exception) {
    SetStatus(status, VTK_FLUTTER_STATUS_INTERNAL_ERROR, exception.what());
    return VTK_FLUTTER_STATUS_INTERNAL_ERROR;
  } catch (...) {
    SetStatus(status, VTK_FLUTTER_STATUS_INTERNAL_ERROR,
              "unknown native error");
    return VTK_FLUTTER_STATUS_INTERNAL_ERROR;
  }
}

template <typename Action>
int32_t WithLiveSession(VtkFlutterSession *session, VtkFlutterStatus *status,
                        Action action) {
  if (session == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "session is required");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  std::shared_ptr<VtkFlutterSession> live_session;
  {
    std::lock_guard lock(g_sessions_mutex);
    const auto iterator = g_sessions.find(session);
    if (iterator == g_sessions.end()) {
      SetStatus(status, VTK_FLUTTER_STATUS_INVALID_STATE,
                "session is not live");
      return VTK_FLUTTER_STATUS_INVALID_STATE;
    }
    live_session = iterator->second;
  }
  return TranslateErrors(status, [&] { action(live_session->value); });
}

int32_t VTK_FLUTTER_CALL SessionIsValid(VtkFlutterSession *session,
                                        VtkFlutterStatus *status) {
  return WithLiveSession(session, status, [](auto &) {});
}

int32_t VTK_FLUTTER_CALL SessionAttachTextureTarget(
    VtkFlutterSession *session, VtkFlutterTextureTarget *target,
    VtkFlutterStatus *status) {
  if (target == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "target is required");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  return WithLiveSession(
      session, status, [&](auto &value) { value.AttachTextureTarget(*target); });
}

int32_t VTK_FLUTTER_CALL SessionDetachTextureTarget(
    VtkFlutterSession *session, VtkFlutterTextureTarget *target,
    VtkFlutterStatus *status) {
  if (target == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "target is required");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  return WithLiveSession(
      session, status, [&](auto &value) { value.DetachTextureTarget(*target); });
}

int32_t VTK_FLUTTER_CALL TextureTargetCreate(
    const VtkFlutterFrameCallbacks *callbacks,
    VtkFlutterTextureTarget **out_target, VtkFlutterStatus *status) {
  if (callbacks == nullptr || out_target == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "callbacks and out_target are required");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  *out_target = nullptr;
  return TranslateErrors(status, [&] {
    auto target = std::make_unique<VtkFlutterTextureTarget>(*callbacks);
    *out_target = target.release();
  });
}

int32_t VTK_FLUTTER_CALL TextureTargetDestroy(
    VtkFlutterTextureTarget *target, VtkFlutterStatus *status) {
  if (target == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "target is required");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  return TranslateErrors(status, [&] {
    target->MarkDestroying();
    delete target;
  });
}

const VtkFlutterPresentationApi kPresentationApi = {
    sizeof(VtkFlutterPresentationApi),
    VTK_FLUTTER_PRESENTATION_API_VERSION,
    vtk_flutter_status_clear,
    SessionIsValid,
    SessionAttachTextureTarget,
    SessionDetachTextureTarget,
    TextureTargetCreate,
    TextureTargetDestroy,
};
} // namespace

uint32_t VTK_FLUTTER_CALL vtk_flutter_abi_version(void) {
  return VTK_FLUTTER_ABI_VERSION;
}

const VtkFlutterPresentationApi *VTK_FLUTTER_CALL
vtk_flutter_get_presentation_api(void) {
  return &kPresentationApi;
}

void VTK_FLUTTER_CALL vtk_flutter_status_clear(VtkFlutterStatus *status) {
  SetStatus(status, VTK_FLUTTER_STATUS_OK);
}

int32_t VTK_FLUTTER_CALL vtk_flutter_session_create(
    VtkFlutterSession **out_session, VtkFlutterStatus *status) {
  if (out_session == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "out_session is required");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  *out_session = nullptr;
  return TranslateErrors(status, [&] {
    auto session = std::make_shared<VtkFlutterSession>();
    {
      std::lock_guard lock(g_sessions_mutex);
      g_sessions.emplace(session.get(), session);
    }
    *out_session = session.get();
  });
}

void VTK_FLUTTER_CALL vtk_flutter_session_destroy(
    VtkFlutterSession *session) {
  try {
    std::shared_ptr<VtkFlutterSession> live_session;
    {
      std::lock_guard lock(g_sessions_mutex);
      const auto iterator = g_sessions.find(session);
      if (iterator == g_sessions.end()) {
        return;
      }
      live_session = std::move(iterator->second);
      g_sessions.erase(iterator);
    }
  } catch (...) {
  }
}

#if defined(VTK_FLUTTER_BUILD_TESTING)
namespace vtk_flutter::testing {
int32_t WithLiveSession(
    VtkFlutterSession *session, VtkFlutterStatus *status,
    const std::function<void(vtk_flutter::Session &)> &action) {
  return ::WithLiveSession(session, status, action);
}
} // namespace vtk_flutter::testing
#endif

int32_t VTK_FLUTTER_CALL vtk_flutter_object_create(
    VtkFlutterSession *session, const char *class_name,
    VtkFlutterObjectHandle *out_object, VtkFlutterStatus *status) {
  if (class_name == nullptr || out_object == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "class_name and out_object are required");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  *out_object = 0;
  return WithLiveSession(session, status, [&](auto &value) {
    *out_object = value.CreateObject(class_name);
  });
}

int32_t VTK_FLUTTER_CALL vtk_flutter_object_destroy(
    VtkFlutterSession *session, VtkFlutterObjectHandle object,
    VtkFlutterStatus *status) {
  return WithLiveSession(
      session, status, [&](auto &value) { value.DestroyObject(object); });
}

int32_t VTK_FLUTTER_CALL vtk_flutter_object_invoke(
    VtkFlutterSession *session, VtkFlutterObjectHandle object,
    const char *method_name, const char *arguments_json, char **result_json,
    VtkFlutterStatus *status) {
  if (method_name == nullptr || arguments_json == nullptr ||
      result_json == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "method_name, arguments_json, and result_json are required");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  *result_json = nullptr;
  return WithLiveSession(session, status, [&](auto &value) {
    const auto result = value.Invoke(object, method_name, arguments_json);
    auto *buffer = static_cast<char *>(std::malloc(result.size() + 1U));
    if (buffer == nullptr) {
      throw std::bad_alloc();
    }
    std::memcpy(buffer, result.c_str(), result.size() + 1U);
    *result_json = buffer;
  });
}

void VTK_FLUTTER_CALL vtk_flutter_string_free(char *value) {
  std::free(value);
}

int32_t VTK_FLUTTER_CALL vtk_flutter_image_data_create(
    VtkFlutterSession *session, const VtkFlutterImageData *image,
    VtkFlutterObjectHandle *out_object, VtkFlutterStatus *status) {
  if (image == nullptr || out_object == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "image and out_object are required");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  *out_object = 0;
  return WithLiveSession(session, status, [&](auto &value) {
    *out_object = value.CreateImageData(*image);
  });
}

int32_t VTK_FLUTTER_CALL vtk_flutter_session_render(
    VtkFlutterSession *session, VtkFlutterObjectHandle renderer,
    const VtkFlutterViewport *viewport, VtkFlutterFrameMetrics *metrics,
    VtkFlutterStatus *status) {
  const VtkFlutterRenderLayer layer{
      sizeof(VtkFlutterRenderLayer),
      VTK_FLUTTER_RENDER_LAYER_VERSION,
      renderer,
      0.0,
      0.0,
      1.0,
      1.0,
  };
  return vtk_flutter_session_render_layout(session, &layer, 1U, viewport, 0U,
                                           metrics, status);
}

int32_t VTK_FLUTTER_CALL vtk_flutter_session_render_layout(
    VtkFlutterSession *session, const VtkFlutterRenderLayer *layers,
    uint32_t layer_count, const VtkFlutterViewport *viewport,
    uint32_t primary_layer, VtkFlutterFrameMetrics *metrics,
    VtkFlutterStatus *status) {
  if (metrics != nullptr) {
    *metrics = {};
  }
  if (layers == nullptr || viewport == nullptr || metrics == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "layers, viewport, and metrics are required");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  VtkFlutterFrameMetrics rendered_metrics{};
  const auto code = WithLiveSession(session, status, [&](auto &value) {
    value.RenderLayout(layers, layer_count, *viewport, primary_layer,
                       rendered_metrics);
  });
  if (code == VTK_FLUTTER_STATUS_OK) {
    *metrics = rendered_metrics;
  }
  return code;
}
