#ifndef FLUTTER_PLUGIN_VTK_FLUTTER_PLUGIN_H_
#define FLUTTER_PLUGIN_VTK_FLUTTER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/texture_registrar.h>

#include <cstdint>
#include <functional>
#include <memory>

namespace vtk_flutter {

class WindowsVtkViewHost {
public:
  virtual ~WindowsVtkViewHost() = default;

  virtual bool IsAvailable() const noexcept = 0;
  virtual bool IsOnPlatformThread() const noexcept = 0;
  virtual std::int64_t RegisterTexture(flutter::TextureVariant *texture) = 0;
  virtual bool MarkTextureFrameAvailable(std::int64_t texture_id) = 0;
  virtual void UnregisterTexture(std::int64_t texture_id,
                                 std::function<void()> callback) = 0;
  virtual bool PostToPlatform(std::function<void()> operation) = 0;
  virtual void DrainPlatformOperations() = 0;
};

class VtkFlutterPlugin : public flutter::Plugin {
public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  explicit VtkFlutterPlugin(
      flutter::PluginRegistrarWindows *registrar = nullptr);
  explicit VtkFlutterPlugin(std::unique_ptr<WindowsVtkViewHost> view_host);
  ~VtkFlutterPlugin() override;

  VtkFlutterPlugin(const VtkFlutterPlugin &) = delete;
  VtkFlutterPlugin &operator=(const VtkFlutterPlugin &) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

private:
  class Implementation;
  std::unique_ptr<Implementation> implementation_;
};

} // namespace vtk_flutter

#endif // FLUTTER_PLUGIN_VTK_FLUTTER_PLUGIN_H_
