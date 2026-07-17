part of 'vtk_api.dart';

abstract base class VtkObject implements _VtkOwnedObject {
  VtkObject._({
    required VtkSession session,
    required VtkBackendObjectHandle handle,
  }) : this._internal(session: session, handle: handle);

  VtkObject._internal({required this._session, required this._handle});

  final VtkSession _session;
  final VtkBackendObjectHandle _handle;
  Future<void>? _disposeOperation;
  bool _disposeStarted = false;
  bool _disposed = false;

  bool get isDisposed => _disposeStarted || _disposed;

  @override
  VtkBackendObjectHandle get _ownedHandle => _handle;

  @override
  bool get _ownedDisposed => _disposed;

  Future<void> dispose() async {
    if (_disposed) return;
    final currentDispose = _disposeOperation;
    if (currentDispose != null) return currentDispose;

    _disposeStarted = true;
    final operation = _session._disposeObject(this);
    _disposeOperation = operation;
    try {
      await operation;
    } on Object {
      _disposeStarted = false;
      _disposeOperation = null;
      rethrow;
    }
  }

  void _ensureUsable() {
    if (_disposeStarted || _disposed) {
      throw VtkApiStateException('$runtimeType is disposed');
    }
  }

  @override
  void _markDisposed() {
    _disposeStarted = true;
    _disposed = true;
  }
}

abstract base class _VtkAlgorithm extends VtkObject {
  _VtkAlgorithm._({required super.session, required super.handle}) : super._();

  Future<void> setInputData(VtkImageData input) => _session._invoke(
    target: this,
    operation: .setInputData,
    arguments: [input],
  );

  Future<void> setInputConnection({
    required VtkAlgorithmOutput input,
    int port = 0,
  }) {
    if (port < 0) {
      throw const VtkApiValidationException(
        field: 'port',
        message: 'Input port cannot be negative',
      );
    }
    return _session._invoke(
      target: this,
      operation: .setInputConnection,
      arguments: [port, input],
    );
  }

  Future<VtkAlgorithmOutput> output({int port = 0}) =>
      _session._output(algorithm: this, port: port);
}

abstract base class _VtkMapper extends VtkObject {
  _VtkMapper._({required super.session, required super.handle}) : super._();

  Future<void> setInputData(VtkImageData input) => _session._invoke(
    target: this,
    operation: .setInputData,
    arguments: [input],
  );

  Future<void> setInputConnection({
    required VtkAlgorithmOutput input,
    int port = 0,
  }) {
    if (port < 0) {
      throw const VtkApiValidationException(
        field: 'port',
        message: 'Input port cannot be negative',
      );
    }
    return _session._invoke(
      target: this,
      operation: .setInputConnection,
      arguments: [port, input],
    );
  }
}

final class VtkImageData extends VtkObject {
  VtkImageData._new({required super.session, required super.handle})
    : super._();
}

final class VtkAlgorithmOutput extends VtkObject {
  VtkAlgorithmOutput._new({required super.session, required super.handle})
    : super._();
}

final class VtkImageReslice extends _VtkAlgorithm {
  VtkImageReslice._new({required super.session, required super.handle})
    : super._();

  Future<void> setResliceAxes(VtkMatrix4 axes) => _session._invoke(
    target: this,
    operation: .setResliceAxes,
    arguments: [axes],
  );

  Future<void> setOutputDimensionality(int dimensions) {
    if (dimensions != 2 && dimensions != 3) {
      throw const VtkApiValidationException(
        field: 'dimensions',
        message: 'Output dimensionality must be 2 or 3',
      );
    }
    return _session._invoke(
      target: this,
      operation: .setOutputDimensionality,
      arguments: [dimensions],
    );
  }

  Future<void> setInterpolation(VtkInterpolation interpolation) =>
      _session._invoke(
        target: this,
        operation: .setResliceInterpolation,
        arguments: [interpolation],
      );

  Future<void> setAutoCropOutput(bool enabled) => _session._invoke(
    target: this,
    operation: .setAutoCropOutput,
    arguments: [enabled],
  );
}

final class VtkImageMapToWindowLevelColors extends _VtkAlgorithm {
  VtkImageMapToWindowLevelColors._new({
    required super.session,
    required super.handle,
  }) : super._();

  Future<void> setWindow(double window) {
    _validatePositiveDouble(value: window, field: 'window');
    return _session._invoke(
      target: this,
      operation: .setWindow,
      arguments: [window],
    );
  }

  Future<void> setLevel(double level) {
    _validateFinite(value: level, field: 'level');
    return _session._invoke(
      target: this,
      operation: .setLevel,
      arguments: [level],
    );
  }
}

final class VtkImageSliceMapper extends _VtkMapper {
  VtkImageSliceMapper._new({required super.session, required super.handle})
    : super._();
}

final class VtkImageActor extends VtkObject {
  VtkImageActor._new({required super.session, required super.handle})
    : super._();

  Future<void> setMapper(VtkImageSliceMapper mapper) => _session._invoke(
    target: this,
    operation: .setMapper,
    arguments: [mapper],
  );

  Future<void> setProperty(VtkImageProperty property) => _session._invoke(
    target: this,
    operation: .setProperty,
    arguments: [property],
  );
}

final class VtkImageProperty extends VtkObject {
  VtkImageProperty._new({required super.session, required super.handle})
    : super._();

  Future<void> setInterpolation(VtkInterpolation interpolation) =>
      _session._invoke(
        target: this,
        operation: .setImageInterpolation,
        arguments: [interpolation],
      );

  Future<void> setColorWindow(double window) {
    _validatePositiveDouble(value: window, field: 'window');
    return _session._invoke(
      target: this,
      operation: .setColorWindow,
      arguments: [window],
    );
  }

  Future<void> setColorLevel(double level) {
    _validateFinite(value: level, field: 'level');
    return _session._invoke(
      target: this,
      operation: .setColorLevel,
      arguments: [level],
    );
  }
}

final class VtkSmartVolumeMapper extends _VtkMapper {
  VtkSmartVolumeMapper._new({required super.session, required super.handle})
    : super._();

  Future<void> setBlendMode(VtkVolumeBlendMode mode) => _session._invoke(
    target: this,
    operation: .setVolumeBlendMode,
    arguments: [mode],
  );

  Future<void> setSampleDistance(double distance) {
    _validatePositiveDouble(value: distance, field: 'distance');
    return _session._invoke(
      target: this,
      operation: .setSampleDistance,
      arguments: [distance],
    );
  }
}

final class VtkColorTransferFunction extends VtkObject {
  VtkColorTransferFunction._new({required super.session, required super.handle})
    : super._();

  Future<void> addPoint({required double value, required VtkColor color}) {
    _validateFinite(value: value, field: 'value');
    return _session._invoke(
      target: this,
      operation: .addRgbPoint,
      arguments: [value, ...color.values],
    );
  }

  Future<void> removeAllPoints() =>
      _session._invoke(target: this, operation: .removeAllPoints);
}

final class VtkPiecewiseFunction extends VtkObject {
  VtkPiecewiseFunction._new({required super.session, required super.handle})
    : super._();

  Future<void> addPoint({required double value, required double opacity}) {
    _validateFinite(value: value, field: 'value');
    _validateUnitInterval(value: opacity, field: 'opacity');
    return _session._invoke(
      target: this,
      operation: .addOpacityPoint,
      arguments: [value, opacity],
    );
  }

  Future<void> removeAllPoints() =>
      _session._invoke(target: this, operation: .removeAllPoints);
}

final class VtkVolumeProperty extends VtkObject {
  VtkVolumeProperty._new({required super.session, required super.handle})
    : super._();

  Future<void> setColor(VtkColorTransferFunction function) => _session._invoke(
    target: this,
    operation: .setColorTransferFunction,
    arguments: [function],
  );

  Future<void> setScalarOpacity(VtkPiecewiseFunction function) =>
      _session._invoke(
        target: this,
        operation: .setScalarOpacity,
        arguments: [function],
      );

  Future<void> setInterpolation(VtkInterpolation interpolation) =>
      _session._invoke(
        target: this,
        operation: .setVolumeInterpolation,
        arguments: [interpolation],
      );

  Future<void> setShade(bool enabled) => _session._invoke(
    target: this,
    operation: .setShade,
    arguments: [enabled],
  );

  Future<void> setAmbient(double value) =>
      _setUnitValue(operation: .setAmbient, value: value, field: 'ambient');

  Future<void> setDiffuse(double value) =>
      _setUnitValue(operation: .setDiffuse, value: value, field: 'diffuse');

  Future<void> setSpecular(double value) =>
      _setUnitValue(operation: .setSpecular, value: value, field: 'specular');

  Future<void> setSpecularPower(double value) {
    _validatePositiveDouble(value: value, field: 'specularPower');
    return _session._invoke(
      target: this,
      operation: .setSpecularPower,
      arguments: [value],
    );
  }

  Future<void> setScalarOpacityUnitDistance(double distance) {
    _validatePositiveDouble(value: distance, field: 'distance');
    return _session._invoke(
      target: this,
      operation: .setScalarOpacityUnitDistance,
      arguments: [distance],
    );
  }

  Future<void> _setUnitValue({
    required VtkBackendOperation operation,
    required double value,
    required String field,
  }) {
    _validateUnitInterval(value: value, field: field);
    return _session._invoke(
      target: this,
      operation: operation,
      arguments: [value],
    );
  }
}

final class VtkVolume extends VtkObject {
  VtkVolume._new({required super.session, required super.handle}) : super._();

  Future<void> setMapper(VtkSmartVolumeMapper mapper) => _session._invoke(
    target: this,
    operation: .setMapper,
    arguments: [mapper],
  );

  Future<void> setProperty(VtkVolumeProperty property) => _session._invoke(
    target: this,
    operation: .setProperty,
    arguments: [property],
  );
}

final class VtkFlyingEdges3D extends _VtkAlgorithm {
  VtkFlyingEdges3D._new({required super.session, required super.handle})
    : super._();

  Future<void> setValue({int index = 0, required double value}) {
    if (index < 0) {
      throw const VtkApiValidationException(
        field: 'index',
        message: 'Contour index cannot be negative',
      );
    }
    _validateFinite(value: value, field: 'value');
    return _session._invoke(
      target: this,
      operation: .setIsoValue,
      arguments: [index, value],
    );
  }

  Future<void> setComputeNormals(bool enabled) => _session._invoke(
    target: this,
    operation: .setComputeNormals,
    arguments: [enabled],
  );
}

final class VtkPolyDataConnectivityFilter extends _VtkAlgorithm {
  VtkPolyDataConnectivityFilter._new({
    required super.session,
    required super.handle,
  }) : super._();

  Future<void> setMode(VtkConnectivityMode mode) => _session._invoke(
    target: this,
    operation: .setConnectivityMode,
    arguments: [mode],
  );

  Future<void> setClosestPoint(VtkVector3 point) => _session._invoke(
    target: this,
    operation: .setClosestPoint,
    arguments: point.values,
  );

  Future<void> setColorRegions(bool enabled) => _session._invoke(
    target: this,
    operation: .setColorRegions,
    arguments: [enabled],
  );
}

final class VtkWindowedSincPolyDataFilter extends _VtkAlgorithm {
  VtkWindowedSincPolyDataFilter._new({
    required super.session,
    required super.handle,
  }) : super._();

  Future<void> setNumberOfIterations(int iterations) {
    if (iterations < 0) {
      throw const VtkApiValidationException(
        field: 'iterations',
        message: 'Iteration count cannot be negative',
      );
    }
    return _session._invoke(
      target: this,
      operation: .setNumberOfIterations,
      arguments: [iterations],
    );
  }

  Future<void> setPassBand(double passBand) {
    _validateFinite(value: passBand, field: 'passBand');
    if (passBand <= 0 || passBand > 2) {
      throw const VtkApiValidationException(
        field: 'passBand',
        message: 'Pass band must be greater than 0 and at most 2',
      );
    }
    return _session._invoke(
      target: this,
      operation: .setPassBand,
      arguments: [passBand],
    );
  }

  Future<void> setBoundarySmoothing(bool enabled) => _session._invoke(
    target: this,
    operation: .setBoundarySmoothing,
    arguments: [enabled],
  );

  Future<void> setFeatureEdgeSmoothing(bool enabled) => _session._invoke(
    target: this,
    operation: .setFeatureEdgeSmoothing,
    arguments: [enabled],
  );

  Future<void> setNormalizeCoordinates(bool enabled) => _session._invoke(
    target: this,
    operation: .setNormalizeCoordinates,
    arguments: [enabled],
  );
}

final class VtkPolyDataMapper extends _VtkMapper {
  VtkPolyDataMapper._new({required super.session, required super.handle})
    : super._();

  Future<void> setScalarVisibility(bool visible) => _session._invoke(
    target: this,
    operation: .setScalarVisibility,
    arguments: [visible],
  );
}

final class VtkActor extends VtkObject {
  VtkActor._new({required super.session, required super.handle}) : super._();

  Future<void> setMapper(VtkPolyDataMapper mapper) => _session._invoke(
    target: this,
    operation: .setMapper,
    arguments: [mapper],
  );

  Future<void> setProperty(VtkProperty property) => _session._invoke(
    target: this,
    operation: .setProperty,
    arguments: [property],
  );
}

final class VtkProperty extends VtkObject {
  VtkProperty._new({required super.session, required super.handle}) : super._();

  Future<void> setColor(VtkColor color) => _session._invoke(
    target: this,
    operation: .setColor,
    arguments: color.values,
  );

  Future<void> setOpacity(double opacity) {
    _validateUnitInterval(value: opacity, field: 'opacity');
    return _session._invoke(
      target: this,
      operation: .setOpacity,
      arguments: [opacity],
    );
  }

  Future<void> setRepresentation(VtkRepresentation representation) =>
      _session._invoke(
        target: this,
        operation: .setRepresentation,
        arguments: [representation],
      );

  Future<void> setLineWidth(double width) {
    _validatePositiveDouble(value: width, field: 'width');
    return _session._invoke(
      target: this,
      operation: .setLineWidth,
      arguments: [width],
    );
  }
}

final class VtkRenderer extends VtkObject {
  VtkRenderer._new({required super.session, required super.handle}) : super._();

  Future<void> addActor(VtkObject actor) {
    if (actor is! VtkActor && actor is! VtkImageActor) {
      throw const VtkApiValidationException(
        field: 'actor',
        message: 'Renderer actors must be VtkActor or VtkImageActor',
      );
    }
    return _session._invoke(
      target: this,
      operation: .addActor,
      arguments: [actor],
    );
  }

  Future<void> removeActor(VtkObject actor) {
    if (actor is! VtkActor && actor is! VtkImageActor) {
      throw const VtkApiValidationException(
        field: 'actor',
        message: 'Renderer actors must be VtkActor or VtkImageActor',
      );
    }
    return _session._invoke(
      target: this,
      operation: .removeActor,
      arguments: [actor],
    );
  }

  Future<void> addVolume(VtkVolume volume) => _session._invoke(
    target: this,
    operation: .addVolume,
    arguments: [volume],
  );

  Future<void> removeVolume(VtkVolume volume) => _session._invoke(
    target: this,
    operation: .removeVolume,
    arguments: [volume],
  );

  Future<void> setBackground(VtkColor color) => _session._invoke(
    target: this,
    operation: .setBackground,
    arguments: color.values,
  );

  Future<void> setActiveCamera(VtkCamera camera) => _session._invoke(
    target: this,
    operation: .setActiveCamera,
    arguments: [camera],
  );

  Future<void> resetCamera() =>
      _session._invoke(target: this, operation: .resetCamera);
}

final class VtkCamera extends VtkObject {
  VtkCamera._new({required super.session, required super.handle}) : super._();

  Future<void> setPosition(VtkVector3 position) => _session._invoke(
    target: this,
    operation: .setPosition,
    arguments: position.values,
  );

  Future<void> setFocalPoint(VtkVector3 focalPoint) => _session._invoke(
    target: this,
    operation: .setFocalPoint,
    arguments: focalPoint.values,
  );

  Future<void> setViewUp(VtkVector3 viewUp) {
    if (viewUp.isZero) {
      throw const VtkApiValidationException(
        field: 'viewUp',
        message: 'View-up vector cannot be zero',
      );
    }
    return _session._invoke(
      target: this,
      operation: .setViewUp,
      arguments: viewUp.values,
    );
  }

  Future<void> setParallelProjection(bool enabled) => _session._invoke(
    target: this,
    operation: .setParallelProjection,
    arguments: [enabled],
  );

  Future<void> setParallelScale(double scale) {
    _validatePositiveDouble(value: scale, field: 'scale');
    return _session._invoke(
      target: this,
      operation: .setParallelScale,
      arguments: [scale],
    );
  }

  Future<void> setClippingRange({required double near, required double far}) {
    _validateFinite(value: near, field: 'near');
    _validateFinite(value: far, field: 'far');
    if (near < 0 || far <= near) {
      throw const VtkApiValidationException(
        field: 'clippingRange',
        message: 'Clipping range requires 0 <= near < far',
      );
    }
    return _session._invoke(
      target: this,
      operation: .setClippingRange,
      arguments: [near, far],
    );
  }

  Future<void> azimuth(double degrees) =>
      _rotate(operation: .azimuth, degrees: degrees);

  Future<void> elevation(double degrees) =>
      _rotate(operation: .elevation, degrees: degrees);

  Future<void> roll(double degrees) =>
      _rotate(operation: .roll, degrees: degrees);

  Future<void> zoom(double factor) {
    _validatePositiveDouble(value: factor, field: 'factor');
    return _session._invoke(
      target: this,
      operation: .zoom,
      arguments: [factor],
    );
  }

  Future<void> dolly(double factor) {
    _validatePositiveDouble(value: factor, field: 'factor');
    return _session._invoke(
      target: this,
      operation: .dolly,
      arguments: [factor],
    );
  }

  Future<void> _rotate({
    required VtkBackendOperation operation,
    required double degrees,
  }) {
    _validateFinite(value: degrees, field: 'degrees');
    return _session._invoke(
      target: this,
      operation: operation,
      arguments: [degrees],
    );
  }
}
