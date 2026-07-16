import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'src/models.dart';
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

  Future<VtkCapabilities> capabilities() => throw UnimplementedError();

  Future<int> createSession(VtkViewport viewport) => throw UnimplementedError();

  Future<void> setVolume(VtkVolume volume) => throw UnimplementedError();

  Future<VtkFrameMetrics> render(VtkRenderRequest request) =>
      throw UnimplementedError();

  Future<VtkSessionStatus> status() => throw UnimplementedError();

  Future<void> resize(VtkViewport viewport) => throw UnimplementedError();

  Future<int> recreateGraphicsContext() => throw UnimplementedError();

  Future<void> disposeSession() => throw UnimplementedError();
}
