#ifndef FLUTTER_PLUGIN_VTK_FLUTTER_PLUGIN_H_
#define FLUTTER_PLUGIN_VTK_FLUTTER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace vtk_flutter {

class VtkFlutterPlugin : public flutter::Plugin {
public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  explicit VtkFlutterPlugin(
      flutter::PluginRegistrarWindows *registrar = nullptr);
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
