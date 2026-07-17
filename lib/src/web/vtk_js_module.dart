import 'dart:js_interop';

import 'vtk_web_module.dart';

final class VtkJsModule implements VtkWebModule {
  Future<_VtkJsExports>? _module;

  @override
  Future<VtkWebModuleCapabilities> capabilities() async {
    final module = await _loadModule();
    final result = module.getCapabilities();
    return VtkWebModuleCapabilities(
      supportedObjectTypes: [
        for (final value in result.supportedObjectTypes.toDart) value.toDart,
      ],
      supportedScalarTypes: [
        for (final value in result.supportedScalarTypes.toDart) value.toDart,
      ],
      maxImageBytes: result.maxImageBytes.toDartInt,
      supportsRendering: result.supportsRendering.toDart,
      limitations: {
        for (final limitation in result.limitations.toDart)
          limitation.capability.toDart: limitation.reason.toDart,
      },
    );
  }

  @override
  Future<int> openSession() async {
    final module = await _loadModule();
    return (await module.openSession().toDart).toDartInt;
  }

  @override
  Future<int> createObject({
    required int sessionId,
    required String type,
  }) async {
    final module = await _loadModule();
    return (await module.createObject(sessionId.toJS, type.toJS).toDart)
        .toDartInt;
  }

  @override
  Future<int> createImageData({
    required int sessionId,
    required VtkWebImageInput input,
  }) async {
    final module = await _loadModule();
    final result = await module
        .createImageData(
          sessionId.toJS,
          _VtkJsImageInput(
            bytes: input.bytes.toJS,
            scalarType: input.scalarType.toJS,
            dimensions: [for (final value in input.dimensions) value.toJS].toJS,
            componentCount: input.componentCount.toJS,
            origin: [for (final value in input.origin) value.toJS].toJS,
            spacing: [for (final value in input.spacing) value.toJS].toJS,
            direction: [for (final value in input.direction) value.toJS].toJS,
          ),
        )
        .toDart;
    return result.toDartInt;
  }

  @override
  Future<int?> invoke({
    required int sessionId,
    required int target,
    required String operation,
    required List<Object?> arguments,
  }) async {
    final module = await _loadModule();
    final result = await module
        .invoke(
          sessionId.toJS,
          target.toJS,
          operation.toJS,
          [for (final argument in arguments) _toJs(argument)].toJS,
        )
        .toDart;
    return result?.toDartInt;
  }

  @override
  Future<void> destroyObject({
    required int sessionId,
    required int object,
  }) async {
    final module = await _loadModule();
    await module.destroyObject(sessionId.toJS, object.toJS).toDart;
  }

  @override
  Future<VtkWebRenderFrame> render({
    required int sessionId,
    required int renderer,
    required int width,
    required int height,
  }) async {
    final module = await _loadModule();
    final result = await module
        .render(
          sessionId.toJS,
          renderer.toJS,
          _VtkJsViewport(width: width.toJS, height: height.toJS),
        )
        .toDart;
    return VtkWebRenderFrame(
      pngDataUrl: result.pngDataUrl.toDart,
      width: result.width.toDartInt,
      height: result.height.toDartInt,
      renderMicroseconds: result.renderMicroseconds.toDartInt,
      captureMicroseconds: result.captureMicroseconds.toDartInt,
      worldToClip: [
        for (final value in result.worldToClip.toDart) value.toDartDouble,
      ],
    );
  }

  @override
  Future<void> closeSession(int sessionId) async {
    final module = await _loadModule();
    await module.closeSession(sessionId.toJS).toDart;
  }

  Future<_VtkJsExports> _loadModule() =>
      _module ??= _importModule().then(_VtkJsExports.new);

  Future<JSObject> _importModule() {
    final uri = Uri.base.resolve(
      'assets/packages/vtk_flutter/assets/vtk_runtime.js',
    );
    return importModule(uri.toString().toJS).toDart;
  }
}

JSAny? _toJs(Object? value) => switch (value) {
  null => null,
  bool() => value.toJS,
  int() => value.toJS,
  double() => value.toJS,
  String() => value.toJS,
  List<Object?>() => [for (final entry in value) _toJs(entry)].toJS,
  _ => throw ArgumentError.value(value, 'value', 'Unsupported JS argument'),
};

extension type _VtkJsExports(JSObject _) implements JSObject {
  external _VtkJsCapabilities getCapabilities();

  external JSPromise<JSNumber> openSession();

  external JSPromise<JSNumber> createObject(JSNumber sessionId, JSString type);

  external JSPromise<JSNumber> createImageData(
    JSNumber sessionId,
    _VtkJsImageInput input,
  );

  external JSPromise<JSNumber?> invoke(
    JSNumber sessionId,
    JSNumber target,
    JSString operation,
    JSArray<JSAny?> arguments,
  );

  external JSPromise<JSAny?> destroyObject(JSNumber sessionId, JSNumber object);

  external JSPromise<_VtkJsRenderFrame> render(
    JSNumber sessionId,
    JSNumber renderer,
    _VtkJsViewport viewport,
  );

  external JSPromise<JSAny?> closeSession(JSNumber sessionId);
}

extension type _VtkJsCapabilities._(JSObject _) implements JSObject {
  external JSArray<JSString> get supportedObjectTypes;
  external JSArray<JSString> get supportedScalarTypes;
  external JSNumber get maxImageBytes;
  external JSBoolean get supportsRendering;
  external JSArray<_VtkJsLimitation> get limitations;
}

extension type _VtkJsLimitation._(JSObject _) implements JSObject {
  external JSString get capability;
  external JSString get reason;
}

extension type _VtkJsImageInput._(JSObject _) implements JSObject {
  external factory _VtkJsImageInput({
    required JSUint8Array bytes,
    required JSString scalarType,
    required JSArray<JSNumber> dimensions,
    required JSNumber componentCount,
    required JSArray<JSNumber> origin,
    required JSArray<JSNumber> spacing,
    required JSArray<JSNumber> direction,
  });
}

extension type _VtkJsViewport._(JSObject _) implements JSObject {
  external factory _VtkJsViewport({
    required JSNumber width,
    required JSNumber height,
  });
}

extension type _VtkJsRenderFrame._(JSObject _) implements JSObject {
  external JSString get pngDataUrl;
  external JSNumber get width;
  external JSNumber get height;
  external JSNumber get renderMicroseconds;
  external JSNumber get captureMicroseconds;
  external JSArray<JSNumber> get worldToClip;
}
