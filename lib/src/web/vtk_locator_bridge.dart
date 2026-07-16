import 'dart:js_interop';
import 'dart:typed_data';

final class VtkLocatorResult {
  const VtkLocatorResult({
    required this.pngDataUrl,
    required this.width,
    required this.height,
    required this.patientToClip,
    required this.renderMicroseconds,
    required this.extractionMicroseconds,
    required this.captureMicroseconds,
  });

  final String pngDataUrl;
  final int width;
  final int height;
  final List<double> patientToClip;
  final int renderMicroseconds;
  final int extractionMicroseconds;
  final int captureMicroseconds;
}

final class VtkLocatorBridge {
  Future<_VtkLocatorModule>? _module;
  bool _initialized = false;

  Future<VtkLocatorResult> initialize({
    required Uint8List bytes,
    required int width,
    required int height,
    required int depth,
    required List<double> indexToPatient,
    required int outputWidth,
    required int outputHeight,
    required double azimuth,
    required double elevation,
    required double zoom,
  }) async {
    final module = await (_module ??= _loadModule());
    final result = await module
        .initializeLocator(
          _VtkLocatorOptions(
            bytes: bytes.toJS,
            width: width,
            height: height,
            depth: depth,
            indexToPatient: Float64List.fromList(indexToPatient).toJS,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            cameraAzimuthDegrees: azimuth,
            cameraElevationDegrees: elevation,
            cameraZoom: zoom,
          ),
        )
        .toDart;
    _initialized = true;
    return _toResult(result);
  }

  Future<VtkLocatorResult> renderCamera({
    required int outputWidth,
    required int outputHeight,
    required double azimuth,
    required double elevation,
    required double zoom,
  }) async {
    if (!_initialized) throw StateError('Initialize vtk.js before rendering');
    final module = await (_module ??= _loadModule());
    final result = await module
        .renderLocatorCamera(
          _VtkLocatorCameraOptions(
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            cameraAzimuthDegrees: azimuth,
            cameraElevationDegrees: elevation,
            cameraZoom: zoom,
          ),
        )
        .toDart;
    return _toResult(result);
  }

  Future<void> dispose() async {
    if (!_initialized) return;
    final module = await (_module ??= _loadModule());
    module.disposeLocator();
    _initialized = false;
  }

  Future<_VtkLocatorModule> _loadModule() async {
    final uri = Uri.base.resolve(
      'assets/packages/vtk_flutter/assets/vtk_locator.js',
    );
    final module = await importModule(uri.toString().toJS).toDart;
    return _VtkLocatorModule(module);
  }

  VtkLocatorResult _toResult(_VtkLocatorJsResult result) => VtkLocatorResult(
    pngDataUrl: result.pngDataUrl.toDart,
    width: result.width.toDartInt,
    height: result.height.toDartInt,
    patientToClip: [
      for (final value in result.patientToClip.toDart) value.toDartDouble,
    ],
    renderMicroseconds: result.renderMicroseconds.toDartInt,
    extractionMicroseconds: result.extractionMicroseconds.toDartInt,
    captureMicroseconds: result.captureMicroseconds.toDartInt,
  );
}

extension type _VtkLocatorModule(JSObject _) implements JSObject {
  external JSPromise<_VtkLocatorJsResult> initializeLocator(
    _VtkLocatorOptions options,
  );

  external JSPromise<_VtkLocatorJsResult> renderLocatorCamera(
    _VtkLocatorCameraOptions options,
  );

  external void disposeLocator();
}

extension type _VtkLocatorOptions._(JSObject _) implements JSObject {
  external factory _VtkLocatorOptions({
    required JSUint8Array bytes,
    required int width,
    required int height,
    required int depth,
    required JSFloat64Array indexToPatient,
    required int outputWidth,
    required int outputHeight,
    required double cameraAzimuthDegrees,
    required double cameraElevationDegrees,
    required double cameraZoom,
  });
}

extension type _VtkLocatorCameraOptions._(JSObject _) implements JSObject {
  external factory _VtkLocatorCameraOptions({
    required int outputWidth,
    required int outputHeight,
    required double cameraAzimuthDegrees,
    required double cameraElevationDegrees,
    required double cameraZoom,
  });
}

extension type _VtkLocatorJsResult._(JSObject _) implements JSObject {
  external JSString get pngDataUrl;
  external JSNumber get width;
  external JSNumber get height;
  external JSArray<JSNumber> get patientToClip;
  external JSNumber get renderMicroseconds;
  external JSNumber get extractionMicroseconds;
  external JSNumber get captureMicroseconds;
}
