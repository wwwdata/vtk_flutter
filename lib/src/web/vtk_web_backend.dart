import 'dart:typed_data';

import '../api/vtk_api.dart';
import 'vtk_js_module_stub.dart'
    if (dart.library.js_interop) 'vtk_js_module.dart';
import 'vtk_web_frame_store.dart';
import 'vtk_web_module.dart';

VtkBackend createDefaultVtkBackend() => VtkWebBackend();

final class VtkWebBackend implements VtkBackend {
  VtkWebBackend({VtkWebModule? module}) : _module = module ?? VtkJsModule();

  final VtkWebModule _module;
  final _sessions = <VtkWebBackendSession>{};
  VtkCapabilities? _capabilities;
  Map<String, String>? _limitations;
  Future<void>? _closeOperation;
  bool _closeStarted = false;
  bool _closed = false;

  Future<Map<String, String>> capabilityLimitations() async {
    _ensureOpen();
    await capabilities();
    return _limitations!;
  }

  @override
  Future<VtkCapabilities> capabilities() async {
    _ensureOpen();
    final cached = _capabilities;
    if (cached != null) return cached;
    final report = await _guard(_module.capabilities);
    final capabilities = VtkCapabilities(
      supportedObjectTypes: report.supportedObjectTypes
          .map(_objectTypeFromWire)
          .toSet(),
      supportedScalarTypes: report.supportedScalarTypes
          .map(_scalarTypeFromWire)
          .toSet(),
      maxImageBytes: report.maxImageBytes,
      supportsRendering: report.supportsRendering,
    );
    _limitations = Map.unmodifiable(report.limitations);
    return _capabilities = capabilities;
  }

  @override
  Future<VtkBackendSession> openSession() async {
    _ensureOpen();
    await capabilities();
    final sessionId = await _guard(_module.openSession);
    if (sessionId <= 0) {
      throw const VtkApiStateException(
        'vtk.js returned an invalid session identifier',
      );
    }
    if (_closeStarted) {
      await _guard(() => _module.closeSession(sessionId));
      throw const VtkApiStateException('The vtk.js backend is closed');
    }
    VtkWebFrameStore.register(sessionId);
    late final VtkWebBackendSession session;
    session = VtkWebBackendSession(
      module: _module,
      sessionId: sessionId,
      onClosed: () {
        VtkWebFrameStore.unregister(sessionId);
        _sessions.remove(session);
      },
    );
    _sessions.add(session);
    return session;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    final currentClose = _closeOperation;
    if (currentClose != null) return currentClose;

    _closeStarted = true;
    final operation = _closeSessions();
    _closeOperation = operation;
    try {
      await operation;
      _closed = true;
    } on Object {
      _closeStarted = false;
      _closeOperation = null;
      rethrow;
    }
  }

  Future<void> _closeSessions() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final session in _sessions.toList().reversed) {
      try {
        await session.close();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }

  void _ensureOpen() {
    if (_closeStarted) {
      throw const VtkApiStateException('The vtk.js backend is closed');
    }
  }
}

final class VtkWebBackendSession
    implements VtkBackendSession, VtkDynamicBackendSession {
  VtkWebBackendSession({
    required this._module,
    required int sessionId,
    required this._onClosed,
  }) : viewId = sessionId;

  final VtkWebModule _module;
  final void Function() _onClosed;
  final _objectTypes = <int, VtkObjectType>{};
  bool _closed = false;

  @override
  final int viewId;

  @override
  Future<VtkBackendObjectHandle> createObject({
    required VtkObjectType type,
  }) async {
    _ensureOpen();
    final handle = await _guard(
      () => _module.createObject(sessionId: viewId, type: _wireType(type)),
    );
    return _recordHandle(handle, type);
  }

  @override
  Future<VtkBackendObjectHandle> createDynamicObject({
    required String className,
  }) {
    final type = _dynamicObjectType(className);
    return createObject(type: type);
  }

  @override
  Future<VtkBackendObjectHandle> createImageData({
    required VtkScalarImageInput input,
  }) async {
    _ensureOpen();
    final handle = await _guard(
      () => _module.createImageData(
        sessionId: viewId,
        input: VtkWebImageInput(
          bytes: input.bytes,
          scalarType: _wireScalarType(input.scalarType),
          dimensions: input.dimensions.values,
          componentCount: input.componentCount,
          origin: input.origin.values,
          spacing: input.spacing.values,
          direction: input.direction.values,
        ),
      ),
    );
    return _recordHandle(handle, .imageData);
  }

  @override
  Future<Object?> invoke({
    required VtkBackendObjectHandle target,
    required VtkBackendOperation operation,
    List<Object?> arguments = const [],
  }) async {
    _ensureOpen();
    final result = await _guard(
      () => _module.invoke(
        sessionId: viewId,
        target: target.value,
        operation: _wireOperation(operation),
        arguments: arguments.map(_wireArgument).toList(growable: false),
      ),
    );
    if (operation == VtkBackendOperation.getOutputPort) {
      if (result == null) {
        throw const VtkApiStateException(
          'vtk.js returned no algorithm output handle',
        );
      }
      return _recordHandle(result, .algorithmOutput);
    }
    if (result != null) {
      throw VtkApiStateException(
        'vtk.js returned an unexpected result for $operation',
      );
    }
    return null;
  }

  @override
  Future<Object?> invokeDynamic({
    required VtkBackendObjectHandle target,
    required String methodName,
    List<Object?> arguments = const [],
  }) {
    _ensureOpen();
    final targetType = _objectTypes[target.value];
    if (targetType == null) {
      throw VtkApiStateException(
        'Unknown vtk.js object handle ${target.value}',
      );
    }
    final invocation = _dynamicInvocation(
      targetType: targetType,
      methodName: methodName,
      arguments: arguments,
    );
    return invoke(
      target: target,
      operation: invocation.operation,
      arguments: invocation.arguments,
    );
  }

  @override
  Future<void> destroyObject({required VtkBackendObjectHandle object}) async {
    _ensureOpen();
    await _guard(
      () => _module.destroyObject(sessionId: viewId, object: object.value),
    );
    _objectTypes.remove(object.value);
  }

  @override
  Future<VtkRenderResult> render({
    required VtkBackendObjectHandle renderer,
    required VtkViewport viewport,
  }) => renderLayout(
    layers: [
      VtkBackendRenderLayer(
        renderer: renderer,
        viewport: VtkNormalizedViewport.full,
      ),
    ],
    viewport: viewport,
    primaryLayer: 0,
  );

  @override
  Future<VtkRenderResult> renderLayout({
    required List<VtkBackendRenderLayer> layers,
    required VtkViewport viewport,
    required int primaryLayer,
  }) async {
    _ensureOpen();
    for (var index = 0; index < layers.length; index++) {
      final handle = layers[index].renderer.value;
      if (_objectTypes[handle] != VtkObjectType.renderer) {
        throw VtkApiStateException(
          'Render layer $index must identify a live renderer in this session',
        );
      }
    }
    final frame = await _guard(
      () => _module.renderLayout(
        sessionId: viewId,
        layers: [
          for (final layer in layers)
            VtkWebRenderLayer(
              renderer: layer.renderer.value,
              left: layer.viewport.left,
              bottom: layer.viewport.bottom,
              right: layer.viewport.right,
              top: layer.viewport.top,
            ),
        ],
        width: viewport.width,
        height: viewport.height,
        primaryLayer: primaryLayer,
      ),
    );
    if (frame.width != viewport.width || frame.height != viewport.height) {
      throw const VtkApiStateException(
        'vtk.js returned a frame with unexpected dimensions',
      );
    }
    final pngBytes = _decodePng(frame.pngDataUrl);
    VtkWebFrameStore.present(
      viewId: viewId,
      viewport: viewport,
      pngBytes: pngBytes,
    );
    return VtkRenderResult(
      viewport: viewport,
      frameBytes: pngBytes.lengthInBytes,
      surfaceAllocationBytes: viewport.pixelCount * 4,
      renderTime: Duration(microseconds: frame.renderMicroseconds),
      surfaceSubmitTime: Duration.zero,
      gpuSyncWaitTime: Duration.zero,
      cpuReadbackTime: Duration(microseconds: frame.captureMicroseconds),
      worldToClip: VtkMatrix4(values: frame.worldToClip),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    await _guard(() => _module.closeSession(viewId));
    _objectTypes.clear();
    _closed = true;
    _onClosed();
  }

  VtkBackendObjectHandle _recordHandle(int value, VtkObjectType type) {
    final handle = _checkedHandle(value);
    if (_objectTypes.containsKey(value)) {
      throw VtkApiStateException('vtk.js reused live object handle $value');
    }
    _objectTypes[value] = type;
    return handle;
  }

  void _ensureOpen() {
    if (_closed) {
      throw const VtkApiStateException('The vtk.js session is closed');
    }
  }
}

VtkBackendObjectHandle _checkedHandle(int value) {
  if (value <= 0) {
    throw const VtkApiStateException(
      'vtk.js returned an invalid object handle',
    );
  }
  return VtkBackendObjectHandle(value);
}

Uint8List _decodePng(String dataUrl) {
  final data = Uri.tryParse(dataUrl)?.data;
  if (data == null || data.mimeType != 'image/png') {
    throw const VtkApiStateException('vtk.js returned an invalid PNG frame');
  }
  return Uint8List.fromList(data.contentAsBytes());
}

Future<T> _guard<T>(Future<T> Function() operation) async {
  try {
    return await operation();
  } on VtkApiException {
    rethrow;
  } on Object catch (error) {
    throw VtkApiStateException('vtk.js operation failed: $error');
  }
}

Object? _wireArgument(Object? argument) => switch (argument) {
  null => null,
  VtkBackendObjectHandle(:final value) => value,
  VtkMatrix3(:final values) => values,
  VtkMatrix4(:final values) => values,
  VtkInterpolation() => _wireInterpolation(argument),
  VtkVolumeBlendMode() => _wireVolumeBlendMode(argument),
  VtkConnectivityMode() => _wireConnectivityMode(argument),
  VtkRepresentation() => _wireRepresentation(argument),
  List<Object?>() => argument.map(_wireArgument).toList(growable: false),
  bool() || int() || double() => argument,
  _ => throw VtkApiStateException(
    'No vtk.js argument mapping exists for $argument',
  ),
};

String _wireType(VtkObjectType type) => switch (type) {
  .imageData => 'imageData',
  .imageReslice => 'imageReslice',
  .imageMapToWindowLevelColors => 'imageMapToWindowLevelColors',
  .imageActor => 'imageActor',
  .imageSliceMapper => 'imageSliceMapper',
  .imageProperty => 'imageProperty',
  .smartVolumeMapper => 'smartVolumeMapper',
  .colorTransferFunction => 'colorTransferFunction',
  .piecewiseFunction => 'piecewiseFunction',
  .volumeProperty => 'volumeProperty',
  .volume => 'volume',
  .flyingEdges3D => 'flyingEdges3D',
  .polyDataConnectivityFilter => 'polyDataConnectivityFilter',
  .windowedSincPolyDataFilter => 'windowedSincPolyDataFilter',
  .polyDataMapper => 'polyDataMapper',
  .actor => 'actor',
  .property => 'property',
  .renderer => 'renderer',
  .camera => 'camera',
  .algorithmOutput => 'algorithmOutput',
};

String _wireOperation(VtkBackendOperation operation) => switch (operation) {
  .setInputData => 'setInputData',
  .setInputConnection => 'setInputConnection',
  .getOutputPort => 'getOutputPort',
  .setResliceAxes => 'setResliceAxes',
  .setOutputDimensionality => 'setOutputDimensionality',
  .setResliceInterpolation => 'setResliceInterpolation',
  .setAutoCropOutput => 'setAutoCropOutput',
  .setWindow => 'setWindow',
  .setLevel => 'setLevel',
  .setMapper => 'setMapper',
  .setProperty => 'setProperty',
  .setImageInterpolation => 'setImageInterpolation',
  .setColorWindow => 'setColorWindow',
  .setColorLevel => 'setColorLevel',
  .setVolumeBlendMode => 'setVolumeBlendMode',
  .setSampleDistance => 'setSampleDistance',
  .addRgbPoint => 'addRgbPoint',
  .removeAllPoints => 'removeAllPoints',
  .addOpacityPoint => 'addOpacityPoint',
  .setColorTransferFunction => 'setColorTransferFunction',
  .setScalarOpacity => 'setScalarOpacity',
  .setVolumeInterpolation => 'setVolumeInterpolation',
  .setShade => 'setShade',
  .setAmbient => 'setAmbient',
  .setDiffuse => 'setDiffuse',
  .setSpecular => 'setSpecular',
  .setSpecularPower => 'setSpecularPower',
  .setScalarOpacityUnitDistance => 'setScalarOpacityUnitDistance',
  .setIsoValue => 'setIsoValue',
  .setComputeNormals => 'setComputeNormals',
  .setConnectivityMode => 'setConnectivityMode',
  .setClosestPoint => 'setClosestPoint',
  .setColorRegions => 'setColorRegions',
  .setNumberOfIterations => 'setNumberOfIterations',
  .setPassBand => 'setPassBand',
  .setBoundarySmoothing => 'setBoundarySmoothing',
  .setFeatureEdgeSmoothing => 'setFeatureEdgeSmoothing',
  .setNormalizeCoordinates => 'setNormalizeCoordinates',
  .setScalarVisibility => 'setScalarVisibility',
  .setColor => 'setColor',
  .setOpacity => 'setOpacity',
  .setRepresentation => 'setRepresentation',
  .setLineWidth => 'setLineWidth',
  .addActor => 'addActor',
  .removeActor => 'removeActor',
  .addVolume => 'addVolume',
  .removeVolume => 'removeVolume',
  .setBackground => 'setBackground',
  .setActiveCamera => 'setActiveCamera',
  .resetCamera => 'resetCamera',
  .setPosition => 'setPosition',
  .setFocalPoint => 'setFocalPoint',
  .setViewUp => 'setViewUp',
  .setParallelProjection => 'setParallelProjection',
  .setParallelScale => 'setParallelScale',
  .setClippingRange => 'setClippingRange',
  .azimuth => 'azimuth',
  .elevation => 'elevation',
  .roll => 'roll',
  .zoom => 'zoom',
  .dolly => 'dolly',
};

String _wireScalarType(VtkScalarType type) => switch (type) {
  .uint8 => 'uint8',
  .int8 => 'int8',
  .uint16 => 'uint16',
  .int16 => 'int16',
  .uint32 => 'uint32',
  .int32 => 'int32',
  .float32 => 'float32',
  .float64 => 'float64',
};

VtkObjectType _objectTypeFromWire(String type) => switch (type) {
  'imageData' => .imageData,
  'imageReslice' => .imageReslice,
  'imageMapToWindowLevelColors' => .imageMapToWindowLevelColors,
  'imageActor' => .imageActor,
  'imageSliceMapper' => .imageSliceMapper,
  'imageProperty' => .imageProperty,
  'smartVolumeMapper' => .smartVolumeMapper,
  'colorTransferFunction' => .colorTransferFunction,
  'piecewiseFunction' => .piecewiseFunction,
  'volumeProperty' => .volumeProperty,
  'volume' => .volume,
  'flyingEdges3D' => .flyingEdges3D,
  'polyDataConnectivityFilter' => .polyDataConnectivityFilter,
  'windowedSincPolyDataFilter' => .windowedSincPolyDataFilter,
  'polyDataMapper' => .polyDataMapper,
  'actor' => .actor,
  'property' => .property,
  'renderer' => .renderer,
  'camera' => .camera,
  'algorithmOutput' => .algorithmOutput,
  _ => throw VtkApiStateException(
    'vtk.js reported an unknown object capability $type',
  ),
};

VtkScalarType _scalarTypeFromWire(String type) => switch (type) {
  'uint8' => .uint8,
  'int8' => .int8,
  'uint16' => .uint16,
  'int16' => .int16,
  'uint32' => .uint32,
  'int32' => .int32,
  'float32' => .float32,
  'float64' => .float64,
  _ => throw VtkApiStateException(
    'vtk.js reported an unknown scalar capability $type',
  ),
};

String _wireInterpolation(VtkInterpolation value) => switch (value) {
  .nearest => 'nearest',
  .linear => 'linear',
  .cubic => 'cubic',
};

String _wireVolumeBlendMode(VtkVolumeBlendMode value) => switch (value) {
  .composite => 'composite',
  .maximumIntensity => 'maximumIntensity',
  .minimumIntensity => 'minimumIntensity',
  .averageIntensity => 'averageIntensity',
  .additive => 'additive',
  .isoSurface => 'isoSurface',
};

String _wireConnectivityMode(VtkConnectivityMode value) => switch (value) {
  .allRegions => 'allRegions',
  .largestRegion => 'largestRegion',
  .closestPointRegion => 'closestPointRegion',
};

String _wireRepresentation(VtkRepresentation value) => switch (value) {
  .points => 'points',
  .wireframe => 'wireframe',
  .surface => 'surface',
};

VtkObjectType _dynamicObjectType(String className) => switch (className) {
  'vtkImageReslice' => .imageReslice,
  'vtkImageActor' => .imageActor,
  'vtkImageSliceMapper' => .imageSliceMapper,
  'vtkImageProperty' => .imageProperty,
  'vtkSmartVolumeMapper' => .smartVolumeMapper,
  'vtkColorTransferFunction' => .colorTransferFunction,
  'vtkPiecewiseFunction' => .piecewiseFunction,
  'vtkVolumeProperty' => .volumeProperty,
  'vtkVolume' => .volume,
  'vtkFlyingEdges3D' => .flyingEdges3D,
  'vtkWindowedSincPolyDataFilter' => .windowedSincPolyDataFilter,
  'vtkPolyDataMapper' => .polyDataMapper,
  'vtkActor' => .actor,
  'vtkProperty' => .property,
  'vtkRenderer' => .renderer,
  'vtkCamera' => .camera,
  _ => throw VtkApiStateException(
    'Dynamic vtk.js class $className is not whitelisted',
  ),
};

typedef _DynamicInvocation = ({
  VtkBackendOperation operation,
  List<Object?> arguments,
});

_DynamicInvocation _dynamicInvocation({
  required VtkObjectType targetType,
  required String methodName,
  required List<Object?> arguments,
}) {
  final special = switch ((targetType, methodName)) {
    (.imageReslice, 'SetInterpolationMode') => (
      operation: VtkBackendOperation.setResliceInterpolation,
      arguments: [_dynamicResliceInterpolation(arguments)],
    ),
    (.imageProperty, 'SetInterpolationType') => (
      operation: VtkBackendOperation.setImageInterpolation,
      arguments: [_dynamicPropertyInterpolation(arguments)],
    ),
    (.volumeProperty, 'SetInterpolationType') => (
      operation: VtkBackendOperation.setVolumeInterpolation,
      arguments: [_dynamicPropertyInterpolation(arguments)],
    ),
    (.volumeProperty, 'SetColor') => (
      operation: VtkBackendOperation.setColorTransferFunction,
      arguments: arguments,
    ),
    (.property, 'SetColor') => (
      operation: VtkBackendOperation.setColor,
      arguments: arguments,
    ),
    (.smartVolumeMapper, 'SetBlendModeToComposite') => (
      operation: VtkBackendOperation.setVolumeBlendMode,
      arguments: const [VtkVolumeBlendMode.composite],
    ),
    (.smartVolumeMapper, 'SetBlendModeToMaximumIntensity') => (
      operation: VtkBackendOperation.setVolumeBlendMode,
      arguments: const [VtkVolumeBlendMode.maximumIntensity],
    ),
    (.smartVolumeMapper, 'SetBlendModeToMinimumIntensity') => (
      operation: VtkBackendOperation.setVolumeBlendMode,
      arguments: const [VtkVolumeBlendMode.minimumIntensity],
    ),
    (.smartVolumeMapper, 'SetBlendModeToAverageIntensity') => (
      operation: VtkBackendOperation.setVolumeBlendMode,
      arguments: const [VtkVolumeBlendMode.averageIntensity],
    ),
    (.smartVolumeMapper, 'SetBlendModeToAdditive') => (
      operation: VtkBackendOperation.setVolumeBlendMode,
      arguments: const [VtkVolumeBlendMode.additive],
    ),
    (.smartVolumeMapper, 'SetBlendModeToIsoSurface') => (
      operation: VtkBackendOperation.setVolumeBlendMode,
      arguments: const [VtkVolumeBlendMode.isoSurface],
    ),
    (.property, 'SetRepresentationToPoints') => (
      operation: VtkBackendOperation.setRepresentation,
      arguments: const [VtkRepresentation.points],
    ),
    (.property, 'SetRepresentationToWireframe') => (
      operation: VtkBackendOperation.setRepresentation,
      arguments: const [VtkRepresentation.wireframe],
    ),
    (.property, 'SetRepresentationToSurface') => (
      operation: VtkBackendOperation.setRepresentation,
      arguments: const [VtkRepresentation.surface],
    ),
    _ => null,
  };
  if (special != null) return special;

  final operation = switch (methodName) {
    'SetInputData' => VtkBackendOperation.setInputData,
    'SetInputConnection' => VtkBackendOperation.setInputConnection,
    'GetOutputPort' => VtkBackendOperation.getOutputPort,
    'SetResliceAxes' => VtkBackendOperation.setResliceAxes,
    'SetOutputDimensionality' => VtkBackendOperation.setOutputDimensionality,
    'SetAutoCropOutput' => VtkBackendOperation.setAutoCropOutput,
    'SetWindow' => VtkBackendOperation.setWindow,
    'SetLevel' => VtkBackendOperation.setLevel,
    'SetMapper' => VtkBackendOperation.setMapper,
    'SetProperty' => VtkBackendOperation.setProperty,
    'SetColorWindow' => VtkBackendOperation.setColorWindow,
    'SetColorLevel' => VtkBackendOperation.setColorLevel,
    'SetSampleDistance' => VtkBackendOperation.setSampleDistance,
    'AddRGBPoint' => VtkBackendOperation.addRgbPoint,
    'RemoveAllPoints' => VtkBackendOperation.removeAllPoints,
    'AddPoint' => VtkBackendOperation.addOpacityPoint,
    'SetScalarOpacity' => VtkBackendOperation.setScalarOpacity,
    'SetShade' => VtkBackendOperation.setShade,
    'SetAmbient' => VtkBackendOperation.setAmbient,
    'SetDiffuse' => VtkBackendOperation.setDiffuse,
    'SetSpecular' => VtkBackendOperation.setSpecular,
    'SetSpecularPower' => VtkBackendOperation.setSpecularPower,
    'SetScalarOpacityUnitDistance' =>
      VtkBackendOperation.setScalarOpacityUnitDistance,
    'SetValue' => VtkBackendOperation.setIsoValue,
    'SetComputeNormals' => VtkBackendOperation.setComputeNormals,
    'SetNumberOfIterations' => VtkBackendOperation.setNumberOfIterations,
    'SetPassBand' => VtkBackendOperation.setPassBand,
    'SetBoundarySmoothing' => VtkBackendOperation.setBoundarySmoothing,
    'SetFeatureEdgeSmoothing' => VtkBackendOperation.setFeatureEdgeSmoothing,
    'SetNormalizeCoordinates' => VtkBackendOperation.setNormalizeCoordinates,
    'SetScalarVisibility' => VtkBackendOperation.setScalarVisibility,
    'SetOpacity' => VtkBackendOperation.setOpacity,
    'SetLineWidth' => VtkBackendOperation.setLineWidth,
    'AddActor' => VtkBackendOperation.addActor,
    'RemoveActor' => VtkBackendOperation.removeActor,
    'AddVolume' => VtkBackendOperation.addVolume,
    'RemoveVolume' => VtkBackendOperation.removeVolume,
    'SetBackground' => VtkBackendOperation.setBackground,
    'SetActiveCamera' => VtkBackendOperation.setActiveCamera,
    'ResetCamera' => VtkBackendOperation.resetCamera,
    'SetPosition' => VtkBackendOperation.setPosition,
    'SetFocalPoint' => VtkBackendOperation.setFocalPoint,
    'SetViewUp' => VtkBackendOperation.setViewUp,
    'SetParallelProjection' => VtkBackendOperation.setParallelProjection,
    'SetParallelScale' => VtkBackendOperation.setParallelScale,
    'SetClippingRange' => VtkBackendOperation.setClippingRange,
    'Azimuth' => VtkBackendOperation.azimuth,
    'Elevation' => VtkBackendOperation.elevation,
    'Roll' => VtkBackendOperation.roll,
    'Zoom' => VtkBackendOperation.zoom,
    'Dolly' => VtkBackendOperation.dolly,
    _ => throw VtkApiStateException(
      'Dynamic vtk.js method $methodName is not whitelisted',
    ),
  };
  return (operation: operation, arguments: arguments);
}

VtkInterpolation _dynamicResliceInterpolation(List<Object?> arguments) {
  final value = _singleDynamicInt(arguments, 'SetInterpolationMode');
  return switch (value) {
    0 => .nearest,
    1 => .linear,
    2 || 3 => .cubic,
    _ => throw VtkApiStateException(
      'Dynamic vtk.js interpolation mode $value is not whitelisted',
    ),
  };
}

VtkInterpolation _dynamicPropertyInterpolation(List<Object?> arguments) {
  final value = _singleDynamicInt(arguments, 'SetInterpolationType');
  return switch (value) {
    0 => .nearest,
    1 => .linear,
    2 => .cubic,
    _ => throw VtkApiStateException(
      'Dynamic vtk.js interpolation type $value is not whitelisted',
    ),
  };
}

int _singleDynamicInt(List<Object?> arguments, String methodName) {
  if (arguments case [final int value]) return value;
  throw VtkApiStateException(
    'Dynamic vtk.js method $methodName expects one integer argument',
  );
}
