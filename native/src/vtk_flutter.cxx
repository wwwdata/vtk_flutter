#include "vtk_flutter.h"

#include "session.h"

#include <algorithm>
#include <exception>
#include <memory>
#include <new>
#include <stdexcept>
#include <string_view>

namespace {
void SetStatus(VtkFlutterStatus *status, VtkFlutterStatusCode code,
               std::string_view message = {}) {
  if (status == nullptr) {
    return;
  }
  status->code = static_cast<int32_t>(code);
  const auto length = std::min(message.size(), sizeof(status->message) - 1);
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
    const auto code = static_cast<VtkFlutterStatusCode>(exception.Code());
    SetStatus(status, code, exception.what());
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
} // namespace

uint32_t VTK_FLUTTER_CALL vtk_flutter_abi_version(void) {
  return VTK_FLUTTER_ABI_VERSION;
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
    auto session = std::make_unique<VtkFlutterSession>();
    *out_session = session.release();
  });
}

void VTK_FLUTTER_CALL vtk_flutter_session_destroy(VtkFlutterSession *session) {
  try {
    delete session;
  } catch (...) {
    // Destruction has no status channel in the legacy ABI. Never unwind into C.
  }
}

int32_t VTK_FLUTTER_CALL vtk_flutter_validate_volume(
    const VtkFlutterVolume *volume, VtkFlutterStatus *status) {
  if (volume == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "volume is required");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  return TranslateErrors(
      status, [&] { vtk_flutter::VolumePipeline::ValidateVolume(*volume); });
}

int32_t VTK_FLUTTER_CALL vtk_flutter_session_set_volume(
    VtkFlutterSession *session, const VtkFlutterVolume *volume,
    VtkFlutterStatus *status) {
  if (session == nullptr || volume == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "session and volume are required");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  return TranslateErrors(status, [&] { session->value.SetVolume(*volume); });
}

int32_t VTK_FLUTTER_CALL vtk_flutter_validate_render_request(
    const VtkFlutterRenderRequest *request, VtkFlutterStatus *status) {
  if (request == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "render request is required");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  return TranslateErrors(status, [&] {
    vtk_flutter::VolumePipeline::ValidateRenderRequest(*request);
  });
}

int32_t VTK_FLUTTER_CALL vtk_flutter_session_render(
    VtkFlutterSession *session, const VtkFlutterRenderRequest *request,
    VtkFlutterMetrics *metrics, VtkFlutterStatus *status) {
  if (session == nullptr || request == nullptr || metrics == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "session, request, and metrics are required");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  *metrics = {};
  VtkFlutterMetrics rendered_metrics{};
  const auto code = TranslateErrors(status, [&] {
    session->value.Render(*request, rendered_metrics);
  });
  if (code == VTK_FLUTTER_STATUS_OK) {
    *metrics = rendered_metrics;
  }
  return code;
}

namespace {
int32_t VTK_FLUTTER_CALL SessionAttachTextureTargetV2(
    VtkFlutterSession *session, VtkFlutterTextureTarget *target,
    VtkFlutterStatus *status) {
  if (session == nullptr || target == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "session and target are required");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  return TranslateErrors(
      status, [&] { session->value.AttachTextureTarget(*target); });
}

int32_t VTK_FLUTTER_CALL SessionDetachTextureTargetV2(
    VtkFlutterSession *session, VtkFlutterTextureTarget *target,
    VtkFlutterStatus *status) {
  if (session == nullptr || target == nullptr) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "session and target are required");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  return TranslateErrors(
      status, [&] { session->value.DetachTextureTarget(*target); });
}

int32_t VTK_FLUTTER_CALL TextureTargetCreateV2(
    const VtkFlutterFrameCallbacksV2 *callbacks,
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

int32_t VTK_FLUTTER_CALL TextureTargetDestroyV2(
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

const VtkFlutterCoreApiV2 kCoreApiV2 = {
    sizeof(VtkFlutterCoreApiV2),
    VTK_FLUTTER_CORE_API_VERSION_2,
    vtk_flutter_status_clear,
    vtk_flutter_session_create,
    vtk_flutter_session_destroy,
    vtk_flutter_validate_volume,
    vtk_flutter_session_set_volume,
    vtk_flutter_validate_render_request,
    vtk_flutter_session_render,
    SessionAttachTextureTargetV2,
    SessionDetachTextureTargetV2,
    TextureTargetCreateV2,
    TextureTargetDestroyV2,
};
} // namespace

const VtkFlutterCoreApiV2 *VTK_FLUTTER_CALL
vtk_flutter_get_core_api_v2(void) {
  return &kCoreApiV2;
}
