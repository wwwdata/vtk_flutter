#include "include/vtk_flutter/vtk_flutter_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "vtk_flutter_plugin.h"

void VtkFlutterPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  vtk_flutter::VtkFlutterPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
