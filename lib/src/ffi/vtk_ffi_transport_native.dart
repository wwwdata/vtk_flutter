import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../api/vtk_api.dart';
import 'vtk_ffi_transport_base.dart';
import 'vtk_flutter_bindings.g.dart';

VtkFfiTransport createDefaultVtkFfiTransport() => VtkNativeFfiTransport();

final class VtkNativeFfiTransport implements VtkFfiTransport {
  bool _validated = false;

  @override
  int get presentationApiAddress {
    _validateBindings();
    final api = vtk_flutter_get_presentation_api();
    if (api == nullptr ||
        api.ref.version != VTK_FLUTTER_PRESENTATION_API_VERSION ||
        api.ref.struct_size < sizeOf<VtkFlutterPresentationApi>()) {
      throw const VtkApiStateException(
        'The native library returned an unsupported presentation API',
      );
    }
    return api.address;
  }

  @override
  Future<int> createSession() async {
    _validateBindings();
    final outSession = calloc<Pointer<VtkFlutterSession>>();
    final status = calloc<VtkFlutterStatus>();
    try {
      final result = vtk_flutter_session_create(outSession, status);
      _throwIfFailed(result: result, status: status);
      final session = outSession.value;
      if (session == nullptr) {
        throw const VtkApiStateException(
          'The native library returned no VTK session',
        );
      }
      return session.address;
    } finally {
      calloc.free(status);
      calloc.free(outSession);
    }
  }

  @override
  Future<void> destroySession(int sessionAddress) async {
    if (sessionAddress <= 0) return;
    _validateBindings();
    vtk_flutter_session_destroy(
      Pointer<VtkFlutterSession>.fromAddress(sessionAddress),
    );
  }

  @override
  Future<VtkBackendObjectHandle> createObject({
    required int sessionAddress,
    required VtkObjectType type,
  }) {
    final className = _classNames[type];
    if (className == null) {
      throw VtkUnsupportedCapabilityException(type);
    }
    return createDynamicObject(
      sessionAddress: sessionAddress,
      className: className,
    );
  }

  @override
  Future<VtkBackendObjectHandle> createDynamicObject({
    required int sessionAddress,
    required String className,
  }) async {
    final nativeClassName = className.toNativeUtf8();
    final outObject = calloc<Uint32>();
    final status = calloc<VtkFlutterStatus>();
    try {
      _validateBindings();
      final result = vtk_flutter_object_create(
        _session(sessionAddress),
        nativeClassName.cast(),
        outObject,
        status,
      );
      _throwIfFailed(result: result, status: status);
      return _checkedHandle(outObject.value);
    } finally {
      calloc.free(status);
      calloc.free(outObject);
      calloc.free(nativeClassName);
    }
  }

  @override
  Future<VtkBackendObjectHandle> createImageData({
    required int sessionAddress,
    required VtkScalarImageInput input,
  }) async {
    final image = calloc<VtkFlutterImageData>();
    final values = calloc<Uint8>(input.byteCount);
    final outObject = calloc<Uint32>();
    final status = calloc<VtkFlutterStatus>();
    try {
      values.asTypedList(input.byteCount).setAll(0, input.bytes);
      image.ref
        ..values = values.cast()
        ..value_count = input.valueCount
        ..byte_count = input.byteCount
        ..scalar_type = _scalarTypes[input.scalarType]!
        ..component_count = input.componentCount;
      for (var index = 0; index < 3; index++) {
        image.ref.dimensions[index] = input.dimensions.values[index];
        image.ref.origin[index] = input.origin.values[index];
        image.ref.spacing[index] = input.spacing.values[index];
      }
      for (var index = 0; index < 9; index++) {
        image.ref.direction[index] = input.direction.values[index];
      }

      _validateBindings();
      final result = vtk_flutter_image_data_create(
        _session(sessionAddress),
        image,
        outObject,
        status,
      );
      _throwIfFailed(result: result, status: status);
      return _checkedHandle(outObject.value);
    } finally {
      calloc.free(status);
      calloc.free(outObject);
      calloc.free(values);
      calloc.free(image);
    }
  }

  @override
  Future<Object?> invoke({
    required int sessionAddress,
    required VtkBackendObjectHandle target,
    required VtkBackendOperation operation,
    required List<Object?> arguments,
  }) async {
    Object? result;
    for (final invocation in createVtkNativeInvocations(
      operation: operation,
      arguments: arguments,
    )) {
      result = await invokeDynamic(
        sessionAddress: sessionAddress,
        target: target,
        methodName: invocation.method,
        arguments: invocation.arguments,
      );
    }
    return result;
  }

  @override
  Future<Object?> invokeDynamic({
    required int sessionAddress,
    required VtkBackendObjectHandle target,
    required String methodName,
    required List<Object?> arguments,
  }) async {
    final nativeMethodName = methodName.toNativeUtf8();
    final encodedArguments = jsonEncode(
      arguments.map(encodeVtkNativeArgument).toList(growable: false),
    ).toNativeUtf8();
    final outResult = calloc<Pointer<Char>>();
    final status = calloc<VtkFlutterStatus>();
    try {
      _validateBindings();
      final result = vtk_flutter_object_invoke(
        _session(sessionAddress),
        target.value,
        nativeMethodName.cast(),
        encodedArguments.cast(),
        outResult,
        status,
      );
      _throwIfFailed(result: result, status: status);
      final resultPointer = outResult.value;
      if (resultPointer == nullptr) {
        throw const VtkApiStateException(
          'The native library returned no invocation result',
        );
      }
      try {
        return _decodeResult(
          jsonDecode(resultPointer.cast<Utf8>().toDartString()),
        );
      } finally {
        vtk_flutter_string_free(resultPointer);
      }
    } finally {
      calloc.free(status);
      calloc.free(outResult);
      calloc.free(encodedArguments);
      calloc.free(nativeMethodName);
    }
  }

  @override
  Future<void> destroyObject({
    required int sessionAddress,
    required VtkBackendObjectHandle object,
  }) async {
    final status = calloc<VtkFlutterStatus>();
    try {
      _validateBindings();
      final result = vtk_flutter_object_destroy(
        _session(sessionAddress),
        object.value,
        status,
      );
      _throwIfFailed(result: result, status: status);
    } finally {
      calloc.free(status);
    }
  }

  @override
  Future<VtkRenderResult> render({
    required int sessionAddress,
    required VtkBackendObjectHandle renderer,
    required VtkViewport viewport,
  }) async {
    final nativeViewport = calloc<VtkFlutterViewport>();
    final metrics = calloc<VtkFlutterFrameMetrics>();
    final status = calloc<VtkFlutterStatus>();
    try {
      nativeViewport.ref
        ..width = viewport.width
        ..height = viewport.height;
      _validateBindings();
      final result = vtk_flutter_session_render(
        _session(sessionAddress),
        renderer.value,
        nativeViewport,
        metrics,
        status,
      );
      _throwIfFailed(result: result, status: status);
      return VtkRenderResult(
        viewport: VtkViewport(
          width: metrics.ref.frame_width,
          height: metrics.ref.frame_height,
        ),
        frameBytes: metrics.ref.frame_bytes,
        surfaceAllocationBytes: metrics.ref.surface_allocation_bytes,
        renderTime: _durationFromMilliseconds(metrics.ref.render_ms),
        surfaceSubmitTime: _durationFromMilliseconds(
          metrics.ref.surface_submit_ms,
        ),
        gpuSyncWaitTime: _durationFromMilliseconds(
          metrics.ref.gpu_sync_wait_ms,
        ),
        cpuReadbackTime: _durationFromMilliseconds(metrics.ref.cpu_readback_ms),
        worldToClip: metrics.ref.world_to_clip_valid == 0
            ? null
            : VtkMatrix4(
                values: [
                  for (var index = 0; index < 16; index++)
                    metrics.ref.world_to_clip[index],
                ],
              ),
      );
    } finally {
      calloc.free(status);
      calloc.free(metrics);
      calloc.free(nativeViewport);
    }
  }

  void _validateBindings() {
    if (_validated) return;
    try {
      final version = vtk_flutter_abi_version();
      if (version != VTK_FLUTTER_ABI_VERSION) {
        throw VtkApiStateException(
          'Unsupported native VTK ABI $version; expected '
          '$VTK_FLUTTER_ABI_VERSION',
        );
      }
      _validated = true;
    } on VtkApiException {
      rethrow;
    } on Object catch (error) {
      throw VtkApiStateException(
        'Unable to load the native VTK library: $error',
      );
    }
  }
}

/// One serialized VTK invocation produced by the native transport mapping.
///
/// This type lives under `lib/src` and is exposed only so the complete
/// transport mapping can be verified without loading a native library.
final class VtkNativeInvocation {
  const VtkNativeInvocation({required this.method, required this.arguments});

  final String method;
  final List<Object?> arguments;
}

List<VtkNativeInvocation> createVtkNativeInvocations({
  required VtkBackendOperation operation,
  required List<Object?> arguments,
}) {
  if (operation == VtkBackendOperation.setResliceAxes) {
    final matrix = arguments.single;
    if (matrix is! VtkMatrix4) {
      throw const VtkApiStateException('Reslice axes require a VtkMatrix4');
    }
    final values = matrix.values;
    return [
      VtkNativeInvocation(
        method: 'SetResliceAxesDirectionCosines',
        arguments: [
          values[0],
          values[4],
          values[8],
          values[1],
          values[5],
          values[9],
          values[2],
          values[6],
          values[10],
        ],
      ),
      VtkNativeInvocation(
        method: 'SetResliceAxesOrigin',
        arguments: [values[3], values[7], values[11]],
      ),
    ];
  }
  final directMethod = _methodNames[operation];
  if (directMethod != null) {
    return [VtkNativeInvocation(method: directMethod, arguments: arguments)];
  }
  final invocation = switch (operation) {
    .setResliceInterpolation => VtkNativeInvocation(
      method: 'SetInterpolationMode',
      arguments: [_resliceInterpolation(arguments.single)],
    ),
    .setImageInterpolation => VtkNativeInvocation(
      method: 'SetInterpolationType',
      arguments: [_imageInterpolation(arguments.single)],
    ),
    .setVolumeInterpolation => VtkNativeInvocation(
      method: 'SetInterpolationType',
      arguments: [_volumeInterpolation(arguments.single)],
    ),
    .setVolumeBlendMode => VtkNativeInvocation(
      method: _volumeBlendMethod(arguments.single),
      arguments: const [],
    ),
    .setConnectivityMode => VtkNativeInvocation(
      method: _connectivityMethod(arguments.single),
      arguments: const [],
    ),
    .setRepresentation => VtkNativeInvocation(
      method: _representationMethod(arguments.single),
      arguments: const [],
    ),
    _ => throw VtkApiStateException(
      'No native invocation mapping exists for $operation',
    ),
  };
  return [invocation];
}

Object? encodeVtkNativeArgument(Object? argument) => switch (argument) {
  VtkBackendObjectHandle(:final value) => {'Id': value},
  VtkMatrix3(:final values) => values,
  VtkMatrix4(:final values) => values,
  bool() => argument ? 1 : 0,
  Enum() => throw VtkApiStateException(
    'No native argument mapping exists for $argument',
  ),
  _ => argument,
};

Object? _decodeResult(Object? value) {
  if (value case {'Id': final num id}) {
    return _checkedHandle(id.toInt());
  }
  return value;
}

VtkBackendObjectHandle _checkedHandle(int value) {
  if (value <= 0) {
    throw const VtkApiStateException(
      'The native library returned an invalid VTK object handle',
    );
  }
  return VtkBackendObjectHandle(value);
}

Pointer<VtkFlutterSession> _session(int address) {
  if (address <= 0) {
    throw const VtkApiStateException('The VTK session address is invalid');
  }
  return Pointer<VtkFlutterSession>.fromAddress(address);
}

Duration _durationFromMilliseconds(double value) {
  if (!value.isFinite || value < 0) {
    throw const VtkApiStateException(
      'The native library returned an invalid render duration',
    );
  }
  return Duration(microseconds: (value * 1000).round());
}

void _throwIfFailed({
  required int result,
  required Pointer<VtkFlutterStatus> status,
}) {
  if (result == VtkFlutterStatusCode.VTK_FLUTTER_STATUS_OK.value) return;
  final messageBytes = <int>[];
  for (var index = 0; index < VTK_FLUTTER_STATUS_MESSAGE_CAPACITY; index++) {
    final byte = status.ref.message[index];
    if (byte == 0) break;
    messageBytes.add(byte & 0xff);
  }
  throw VtkApiStateException(
    messageBytes.isEmpty
        ? 'Native VTK operation failed with status $result'
        : utf8.decode(messageBytes, allowMalformed: true),
  );
}

const _classNames = <VtkObjectType, String>{
  .imageReslice: 'vtkImageReslice',
  .imageMapToWindowLevelColors: 'vtkImageMapToWindowLevelColors',
  .imageActor: 'vtkImageActor',
  .imageSliceMapper: 'vtkImageSliceMapper',
  .imageProperty: 'vtkImageProperty',
  .smartVolumeMapper: 'vtkSmartVolumeMapper',
  .colorTransferFunction: 'vtkColorTransferFunction',
  .piecewiseFunction: 'vtkPiecewiseFunction',
  .volumeProperty: 'vtkVolumeProperty',
  .volume: 'vtkVolume',
  .flyingEdges3D: 'vtkFlyingEdges3D',
  .polyDataConnectivityFilter: 'vtkPolyDataConnectivityFilter',
  .windowedSincPolyDataFilter: 'vtkWindowedSincPolyDataFilter',
  .polyDataMapper: 'vtkPolyDataMapper',
  .actor: 'vtkActor',
  .property: 'vtkProperty',
  .renderer: 'vtkRenderer',
  .camera: 'vtkCamera',
};

const _scalarTypes = <VtkScalarType, int>{
  .uint8: 1,
  .int8: 2,
  .uint16: 3,
  .int16: 4,
  .uint32: 5,
  .int32: 6,
  .float32: 7,
  .float64: 8,
};

const _methodNames = <VtkBackendOperation, String>{
  .setInputData: 'SetInputData',
  .setInputConnection: 'SetInputConnection',
  .getOutputPort: 'GetOutputPort',
  .setOutputDimensionality: 'SetOutputDimensionality',
  .setAutoCropOutput: 'SetAutoCropOutput',
  .setWindow: 'SetWindow',
  .setLevel: 'SetLevel',
  .setMapper: 'SetMapper',
  .setProperty: 'SetProperty',
  .setColorWindow: 'SetColorWindow',
  .setColorLevel: 'SetColorLevel',
  .setSampleDistance: 'SetSampleDistance',
  .addRgbPoint: 'AddRGBPoint',
  .removeAllPoints: 'RemoveAllPoints',
  .addOpacityPoint: 'AddPoint',
  .setColorTransferFunction: 'SetColor',
  .setScalarOpacity: 'SetScalarOpacity',
  .setShade: 'SetShade',
  .setAmbient: 'SetAmbient',
  .setDiffuse: 'SetDiffuse',
  .setSpecular: 'SetSpecular',
  .setSpecularPower: 'SetSpecularPower',
  .setScalarOpacityUnitDistance: 'SetScalarOpacityUnitDistance',
  .setIsoValue: 'SetValue',
  .setComputeNormals: 'SetComputeNormals',
  .setClosestPoint: 'SetClosestPoint',
  .setColorRegions: 'SetColorRegions',
  .setNumberOfIterations: 'SetNumberOfIterations',
  .setPassBand: 'SetPassBand',
  .setBoundarySmoothing: 'SetBoundarySmoothing',
  .setFeatureEdgeSmoothing: 'SetFeatureEdgeSmoothing',
  .setNormalizeCoordinates: 'SetNormalizeCoordinates',
  .setScalarVisibility: 'SetScalarVisibility',
  .setColor: 'SetColor',
  .setOpacity: 'SetOpacity',
  .setLineWidth: 'SetLineWidth',
  .addActor: 'AddActor',
  .removeActor: 'RemoveActor',
  .addVolume: 'AddVolume',
  .removeVolume: 'RemoveVolume',
  .setBackground: 'SetBackground',
  .setActiveCamera: 'SetActiveCamera',
  .resetCamera: 'ResetCamera',
  .setPosition: 'SetPosition',
  .setFocalPoint: 'SetFocalPoint',
  .setViewUp: 'SetViewUp',
  .setParallelProjection: 'SetParallelProjection',
  .setParallelScale: 'SetParallelScale',
  .setClippingRange: 'SetClippingRange',
  .azimuth: 'Azimuth',
  .elevation: 'Elevation',
  .roll: 'Roll',
  .zoom: 'Zoom',
  .dolly: 'Dolly',
};

int _resliceInterpolation(Object? value) => switch (value) {
  VtkInterpolation.nearest => 0,
  VtkInterpolation.linear => 1,
  VtkInterpolation.cubic => 3,
  _ => throw const VtkApiStateException('Invalid reslice interpolation'),
};

int _imageInterpolation(Object? value) => switch (value) {
  VtkInterpolation.nearest => 0,
  VtkInterpolation.linear => 1,
  VtkInterpolation.cubic => 2,
  _ => throw const VtkApiStateException('Invalid image interpolation'),
};

int _volumeInterpolation(Object? value) => switch (value) {
  VtkInterpolation.nearest => 0,
  VtkInterpolation.linear => 1,
  VtkInterpolation.cubic => throw const VtkApiStateException(
    'VTK volume properties do not support cubic interpolation',
  ),
  _ => throw const VtkApiStateException('Invalid volume interpolation'),
};

String _volumeBlendMethod(Object? value) => switch (value) {
  VtkVolumeBlendMode.composite => 'SetBlendModeToComposite',
  VtkVolumeBlendMode.maximumIntensity => 'SetBlendModeToMaximumIntensity',
  VtkVolumeBlendMode.minimumIntensity => 'SetBlendModeToMinimumIntensity',
  VtkVolumeBlendMode.averageIntensity => 'SetBlendModeToAverageIntensity',
  VtkVolumeBlendMode.additive => 'SetBlendModeToAdditive',
  VtkVolumeBlendMode.isoSurface => 'SetBlendModeToIsoSurface',
  _ => throw const VtkApiStateException('Invalid volume blend mode'),
};

String _connectivityMethod(Object? value) => switch (value) {
  VtkConnectivityMode.allRegions => 'SetExtractionModeToAllRegions',
  VtkConnectivityMode.largestRegion => 'SetExtractionModeToLargestRegion',
  VtkConnectivityMode.closestPointRegion =>
    'SetExtractionModeToClosestPointRegion',
  _ => throw const VtkApiStateException('Invalid connectivity mode'),
};

String _representationMethod(Object? value) => switch (value) {
  VtkRepresentation.points => 'SetRepresentationToPoints',
  VtkRepresentation.wireframe => 'SetRepresentationToWireframe',
  VtkRepresentation.surface => 'SetRepresentationToSurface',
  _ => throw const VtkApiStateException('Invalid representation'),
};
