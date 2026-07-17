#include "session.h"

#include <vtkDataArray.h>
#include <vtkImageData.h>
#include <vtkInvoker.h>
#include <vtkObjectManager.h>
#include <vtkPointData.h>
#include <vtkRenderer.h>
#include <vtkSession.h>
#include <vtkSmartPointer.h>
#include <vtkType.h>

// clang-format off
#include <vtk_nlohmannjson.h>
#include VTK_NLOHMANN_JSON(json.hpp)
// clang-format on

#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>

extern "C" int RegisterLibraries_vtkFlutter(
    void *serializer, void *deserializer, void *invoker, const char **error);

struct vtkSessionJsonImpl {
  nlohmann::json json;
};

namespace {
constexpr std::size_t kFrameCallbacksSize =
    sizeof(VtkFlutterFrameCallbacks);
constexpr std::uint64_t kMaximumUploadBytes = 256ULL * 1024ULL * 1024ULL;

vtkSessionJson ParseJson(const char *text) {
  auto result = std::make_unique<vtkSessionJsonImpl>();
  result->json = nlohmann::json::parse(text == nullptr ? "null" : text);
  return result.release();
}

char *StringifyJson(vtkSessionJson value) {
  const auto *implementation = static_cast<vtkSessionJsonImpl *>(value);
  const auto text = implementation->json.dump();
  auto *result = static_cast<char *>(std::malloc(text.size() + 1U));
  if (result == nullptr) {
    return nullptr;
  }
  std::memcpy(result, text.c_str(), text.size() + 1U);
  return result;
}

int VtkScalarType(int32_t scalar_type) {
  switch (scalar_type) {
  case VTK_FLUTTER_SCALAR_UINT8:
    return VTK_UNSIGNED_CHAR;
  case VTK_FLUTTER_SCALAR_INT8:
    return VTK_SIGNED_CHAR;
  case VTK_FLUTTER_SCALAR_UINT16:
    return VTK_UNSIGNED_SHORT;
  case VTK_FLUTTER_SCALAR_INT16:
    return VTK_SHORT;
  case VTK_FLUTTER_SCALAR_UINT32:
    return VTK_UNSIGNED_INT;
  case VTK_FLUTTER_SCALAR_INT32:
    return VTK_INT;
  case VTK_FLUTTER_SCALAR_FLOAT32:
    return VTK_FLOAT;
  case VTK_FLUTTER_SCALAR_FLOAT64:
    return VTK_DOUBLE;
  default:
    throw std::invalid_argument("unsupported scalar type");
  }
}

std::uint64_t CheckedProduct(std::uint64_t left, std::uint64_t right,
                             const char *message) {
  if (right != 0 &&
      left > std::numeric_limits<std::uint64_t>::max() / right) {
    throw std::invalid_argument(message);
  }
  return left * right;
}

void ValidateImage(const VtkFlutterImageData &image) {
  if (image.values == nullptr) {
    throw std::invalid_argument("image values are required");
  }
  if (image.component_count <= 0) {
    throw std::invalid_argument("component_count must be positive");
  }

  std::uint64_t tuple_count = 1;
  for (int axis = 0; axis < 3; ++axis) {
    if (image.dimensions[axis] <= 0) {
      throw std::invalid_argument("image dimensions must be positive");
    }
    tuple_count =
        CheckedProduct(tuple_count,
                       static_cast<std::uint64_t>(image.dimensions[axis]),
                       "image dimensions overflow");
    if (!std::isfinite(image.origin[axis])) {
      throw std::invalid_argument("image origin must be finite");
    }
    if (!std::isfinite(image.spacing[axis]) || image.spacing[axis] <= 0.0) {
      throw std::invalid_argument("image spacing must be finite and positive");
    }
  }
  for (const double value : image.direction) {
    if (!std::isfinite(value)) {
      throw std::invalid_argument("image direction must be finite");
    }
  }

  const auto value_count =
      CheckedProduct(tuple_count,
                     static_cast<std::uint64_t>(image.component_count),
                     "image value count overflows");
  if (image.value_count != value_count) {
    throw std::invalid_argument(
        "image value_count does not match dimensions and components");
  }
  const auto value_size =
      static_cast<std::uint64_t>(vtkDataArray::GetDataTypeSize(
          VtkScalarType(image.scalar_type)));
  const auto byte_count =
      CheckedProduct(value_count, value_size, "image byte count overflows");
  if (image.byte_count != byte_count) {
    throw std::invalid_argument(
        "image byte_count does not match its scalar type and value count");
  }
  if (byte_count > kMaximumUploadBytes) {
    throw std::invalid_argument("image data exceeds the 256 MiB limit");
  }
}
} // namespace

namespace vtk_flutter {
RenderTargetUnavailable::RenderTargetUnavailable()
    : std::runtime_error(
          "no platform render target is attached to this session") {}

InvalidState::InvalidState(const char *message) : std::runtime_error(message) {}

Session::Session() {
  vtkSessionDescriptor descriptor{};
  descriptor.ParseJson = ParseJson;
  descriptor.StringifyJson = StringifyJson;
  descriptor.InteractorManagesTheEventLoop = 1;
  session_ = vtkCreateSession(&descriptor);
  if (session_ == nullptr) {
    throw std::runtime_error("VTK could not create a session");
  }
  try {
    if (vtkSessionInitializeObjectManager(session_) ==
        vtkSessionResultFailure) {
      throw std::runtime_error(
          "VTK could not initialize its object manager");
    }
    const vtkSessionObjectManagerRegistrarFunc registrars[] = {
        RegisterLibraries_vtkFlutter,
    };
    if (vtkSessionInitializeObjectManagerExtensionHandlers(
            session_, registrars, std::size(registrars)) ==
        vtkSessionResultFailure) {
      throw std::runtime_error(
          "VTK could not initialize package object handlers");
    }
    manager_ = vtkObjectManager::SafeDownCast(
        reinterpret_cast<vtkObjectBase *>(vtkSessionGetManager(session_)));
    if (manager_ == nullptr) {
      throw std::runtime_error("VTK returned no object manager");
    }
  } catch (...) {
    vtkFreeSession(session_);
    session_ = nullptr;
    throw;
  }
}

Session::~Session() {
  if (attached_target_ != nullptr) {
    try {
      attached_target_->Detach(this);
    } catch (...) {
    }
  }
  if (session_ != nullptr) {
    vtkFreeSession(session_);
  }
}

Session::Operation::Operation(Session &session)
    : session_(session), lock_(session.operation_mutex_) {
  if (session_.operation_active_) {
    throw InvalidState("reentrant access to a session is not allowed");
  }
  session_.operation_active_ = true;
}

Session::Operation::~Operation() { session_.operation_active_ = false; }

VtkFlutterObjectHandle Session::CreateObject(const char *class_name) {
  Operation operation(*this);
  if (class_name == nullptr || class_name[0] == '\0') {
    throw std::invalid_argument("class_name is required");
  }
  const auto object = vtkSessionCreateObject(session_, class_name);
  if (object == 0) {
    throw std::invalid_argument(std::string("unsupported VTK class: ") +
                                class_name);
  }
  return object;
}

void Session::DestroyObject(VtkFlutterObjectHandle object) {
  Operation operation(*this);
  if (object == 0) {
    throw std::invalid_argument("object handle must be non-zero");
  }
  if (manager_->GetObjectAtId(object) == nullptr) {
    return;
  }
  if (!manager_->UnRegisterObject(object)) {
    throw std::runtime_error("VTK could not destroy the object");
  }
  manager_->UnRegisterState(object);
}

std::string Session::Invoke(VtkFlutterObjectHandle object,
                            const char *method_name,
                            const char *arguments_json) {
  Operation operation(*this);
  if (object == 0 || manager_->GetObjectAtId(object) == nullptr) {
    throw std::invalid_argument("VTK object does not exist");
  }
  if (method_name == nullptr || method_name[0] == '\0') {
    throw std::invalid_argument("method_name is required");
  }
  if (arguments_json == nullptr) {
    throw std::invalid_argument("arguments_json is required");
  }

  auto arguments = std::unique_ptr<vtkSessionJsonImpl>(
      static_cast<vtkSessionJsonImpl *>(ParseJson(arguments_json)));
  if (!arguments->json.is_array()) {
    throw std::invalid_argument("VTK method arguments must be a JSON array");
  }
  auto result =
      manager_->GetInvoker()->Invoke(object, method_name, arguments->json);
  if (!result.value("Success", false)) {
    const auto message =
        result.value("Message", std::string("no matching VTK overload"));
    throw std::invalid_argument(std::string("VTK cannot invoke ") +
                                method_name + ": " + message);
  }
  if (const auto value = result.find("Value"); value != result.end()) {
    return value->dump();
  }
  if (const auto identifier = result.find("Id");
      identifier != result.end()) {
    const auto result_object =
        identifier->get<VtkFlutterObjectHandle>();
    return nlohmann::json{{"Id", result_object}}.dump();
  }
  return "null";
}

VtkFlutterObjectHandle
Session::CreateImageData(const VtkFlutterImageData &input) {
  Operation operation(*this);
  ValidateImage(input);

  auto image = vtkSmartPointer<vtkImageData>::New();
  image->SetDimensions(input.dimensions);
  image->SetOrigin(input.origin);
  image->SetSpacing(input.spacing);
  image->SetDirectionMatrix(input.direction);
  image->AllocateScalars(VtkScalarType(input.scalar_type),
                         input.component_count);
  auto *scalars = image->GetPointData()->GetScalars();
  if (scalars == nullptr || scalars->GetVoidPointer(0) == nullptr) {
    throw std::runtime_error("VTK could not allocate image scalars");
  }
  std::memcpy(scalars->GetVoidPointer(0), input.values,
              static_cast<std::size_t>(input.byte_count));
  const auto object = manager_->RegisterObject(image);
  if (object == 0) {
    throw std::runtime_error("VTK could not register image data");
  }
  return object;
}

void Session::Render(VtkFlutterObjectHandle renderer,
                     const VtkFlutterViewport &viewport,
                     VtkFlutterFrameMetrics &metrics) {
  Operation operation(*this);
  if (viewport.width <= 0 || viewport.height <= 0) {
    throw std::invalid_argument("viewport dimensions must be positive");
  }
  if (attached_target_ == nullptr) {
    throw RenderTargetUnavailable();
  }
  auto renderer_object =
      vtkRenderer::SafeDownCast(manager_->GetObjectAtId(renderer));
  if (renderer_object == nullptr) {
    throw std::invalid_argument(
        "renderer must identify a vtkRenderer in this session");
  }

  metrics = {};
  metrics.frame_bytes = static_cast<std::uint64_t>(viewport.width) *
                        static_cast<std::uint64_t>(viewport.height) * 4ULL;
  metrics.frame_width = viewport.width;
  metrics.frame_height = viewport.height;
  attached_target_->Render(renderer_object, viewport, metrics);
}

void Session::AttachTextureTarget(VtkFlutterTextureTarget &target) {
  Operation operation(*this);
  if (attached_target_ == &target) {
    return;
  }
  if (attached_target_ != nullptr) {
    throw InvalidState("a texture target is already attached to the session");
  }
  target.Attach(this);
  attached_target_ = &target;
}

void Session::DetachTextureTarget(VtkFlutterTextureTarget &target) {
  Operation operation(*this);
  if (attached_target_ == nullptr) {
    return;
  }
  if (attached_target_ != &target) {
    throw InvalidState("the requested texture target is not attached");
  }
  target.Detach(this);
  attached_target_ = nullptr;
}
} // namespace vtk_flutter

VtkFlutterTextureTarget::VtkFlutterTextureTarget(
    const VtkFlutterFrameCallbacks &callbacks) {
  if (callbacks.version != VTK_FLUTTER_FRAME_CALLBACKS_VERSION ||
      callbacks.struct_size < kFrameCallbacksSize) {
    throw std::invalid_argument("unsupported frame callback table");
  }
  if (callbacks.begin_frame == nullptr || callbacks.end_frame == nullptr ||
      callbacks.cancel_frame == nullptr) {
    throw std::invalid_argument("all frame callbacks are required");
  }
  render_target_ =
      std::make_unique<vtk_flutter::CallbackRenderTarget>(callbacks);
}

VtkFlutterTextureTarget::~VtkFlutterTextureTarget() = default;

void VtkFlutterTextureTarget::Attach(vtk_flutter::Session *session) {
  std::lock_guard lock(attachment_mutex_);
  if (destroying_) {
    throw vtk_flutter::InvalidState("the texture target is being destroyed");
  }
  if (attached_session_ != nullptr && attached_session_ != session) {
    throw vtk_flutter::InvalidState(
        "the texture target is already attached to another session");
  }
  attached_session_ = session;
}

void VtkFlutterTextureTarget::Detach(vtk_flutter::Session *session) {
  std::lock_guard lock(attachment_mutex_);
  if (attached_session_ == nullptr) {
    return;
  }
  if (attached_session_ != session) {
    throw vtk_flutter::InvalidState(
        "the texture target is attached to another session");
  }
  attached_session_ = nullptr;
}

void VtkFlutterTextureTarget::MarkDestroying() {
  std::lock_guard lock(attachment_mutex_);
  if (attached_session_ != nullptr) {
    throw vtk_flutter::InvalidState(
        "the texture target must be detached before destruction");
  }
  if (destroying_) {
    throw vtk_flutter::InvalidState(
        "the texture target is already being destroyed");
  }
  destroying_ = true;
}

void VtkFlutterTextureTarget::Render(
    vtkSmartPointer<vtkRenderer> renderer,
    const VtkFlutterViewport &viewport, VtkFlutterFrameMetrics &metrics) {
  render_target_->Render(std::move(renderer), viewport, metrics);
}
