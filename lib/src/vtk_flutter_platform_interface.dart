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

  /// Whether presentation operations are independently keyed by native
  /// session address and can safely keep more than one view alive.
  bool get supportsIndependentSessionViews => false;

  Future<int> createView({
    required VtkViewport viewport,
    required int presentationApiAddress,
    required int nativeSessionAddress,
  }) => throw UnimplementedError();

  Future<void> presentFrame({required int nativeSessionAddress}) =>
      throw UnimplementedError();

  Future<void> resize({
    required int nativeSessionAddress,
    required VtkViewport viewport,
  }) => throw UnimplementedError();

  Future<void> disposeView({required int nativeSessionAddress}) =>
      throw UnimplementedError();
}
