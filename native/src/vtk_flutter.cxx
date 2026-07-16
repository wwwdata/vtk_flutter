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
  delete session;
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
  return TranslateErrors(status,
                         [&] { session->value.Render(*request, *metrics); });
}
