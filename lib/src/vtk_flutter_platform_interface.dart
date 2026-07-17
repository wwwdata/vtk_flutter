import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'api/vtk_api.dart';
import 'vtk_flutter_method_channel.dart';

abstract class VtkFlutterPlatform extends PlatformInterface {
  VtkFlutterPlatform() : super(token: _token);

  static final Object _token = Object();
  static VtkFlutterPlatform _instance = MethodChannelVtkFlutter();

  static VtkFlutterPlatform get instance => _instance;

  static set instance(VtkFlutterPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<int> createView({
    required VtkViewport viewport,
    required int presentationApiAddress,
    required int nativeSessionAddress,
  }) => throw UnimplementedError();

  Future<void> presentFrame() => throw UnimplementedError();

  Future<void> resize(VtkViewport viewport) => throw UnimplementedError();

  Future<void> disposeView() => throw UnimplementedError();
}
