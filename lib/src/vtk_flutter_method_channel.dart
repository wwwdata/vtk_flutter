import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api/vtk_api.dart';
import 'vtk_flutter_platform_interface.dart';

final class MethodChannelVtkFlutter extends VtkFlutterPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('vtk_flutter/session');

  @override
  bool get supportsIndependentSessionViews =>
      !kIsWeb &&
      switch (defaultTargetPlatform) {
        .android || .iOS || .macOS || .windows => true,
        .fuchsia || .linux => false,
      };

  @override
  Future<int> createView({
    required VtkViewport viewport,
    required int presentationApiAddress,
    required int nativeSessionAddress,
  }) async {
    final values = await _invokeMap(
      method: 'createView',
      arguments: {
        'width': viewport.width,
        'height': viewport.height,
        'presentationApiAddress': presentationApiAddress,
        'nativeSessionAddress': nativeSessionAddress,
      },
    );
    final textureId = values.readInt('textureId');
    if (textureId < 0) {
      throw const VtkApiStateException(
        'The platform returned an invalid texture identifier',
      );
    }
    return textureId;
  }

  @override
  Future<void> presentFrame({required int nativeSessionAddress}) => _invokeMap(
    method: 'presentFrame',
    arguments: {'nativeSessionAddress': nativeSessionAddress},
  );

  @override
  Future<void> resize({
    required int nativeSessionAddress,
    required VtkViewport viewport,
  }) => _invokeVoid(
    method: 'resize',
    arguments: {
      'nativeSessionAddress': nativeSessionAddress,
      'width': viewport.width,
      'height': viewport.height,
    },
  );

  @override
  Future<void> disposeView({required int nativeSessionAddress}) => _invokeVoid(
    method: 'disposeView',
    arguments: {'nativeSessionAddress': nativeSessionAddress},
  );

  Future<Map<Object?, Object?>> _invokeMap({
    required String method,
    Object? arguments,
  }) async {
    try {
      final result = await methodChannel.invokeMapMethod<Object?, Object?>(
        method,
        arguments,
      );
      if (result == null) {
        throw VtkApiStateException(
          'The platform returned no result for $method',
        );
      }
      return result;
    } on PlatformException catch (error) {
      throw VtkApiStateException(
        error.message ?? 'The platform VTK presentation operation failed',
      );
    } on MissingPluginException {
      throw const VtkApiStateException(
        'The platform VTK presentation plugin is unavailable',
      );
    }
  }

  Future<void> _invokeVoid({required String method, Object? arguments}) async {
    try {
      await methodChannel.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      throw VtkApiStateException(
        error.message ?? 'The platform VTK presentation operation failed',
      );
    } on MissingPluginException {
      throw const VtkApiStateException(
        'The platform VTK presentation plugin is unavailable',
      );
    }
  }
}

extension on Map<Object?, Object?> {
  int readInt(String key) {
    final value = this[key];
    if (value is! num || !value.isFinite) {
      throw VtkApiStateException('The platform returned an invalid $key');
    }
    return value.round();
  }
}
