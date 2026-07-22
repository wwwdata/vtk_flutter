import 'package:vtk_flutter/src/api/vtk_api.dart';

final class RecordingVtkBackend implements VtkBackend {
  RecordingVtkBackend({VtkCapabilities? capabilities})
    : _capabilities =
          capabilities ??
          VtkCapabilities(
            supportedObjectTypes: VtkObjectType.values.toSet(),
            supportedScalarTypes: VtkScalarType.values.toSet(),
            maxImageBytes: vtkMaximumImageBytes,
            supportsRendering: true,
          );

  final VtkCapabilities _capabilities;
  final sessions = <RecordingVtkBackendSession>[];
  int closeCount = 0;

  @override
  Future<VtkCapabilities> capabilities() async => _capabilities;

  @override
  Future<VtkBackendSession> openSession() async {
    final session = RecordingVtkBackendSession();
    sessions.add(session);
    return session;
  }

  @override
  Future<void> close() async {
    closeCount++;
  }
}

final class RecordingVtkBackendSession implements VtkBackendSession {
  @override
  final int viewId = 1;

  final createdTypes = <VtkObjectType>[];
  final imageInputs = <VtkScalarImageInput>[];
  final calls = <RecordedVtkCall>[];
  final destroyedObjects = <VtkBackendObjectHandle>[];
  List<VtkBackendRenderLayer>? lastRenderLayers;
  int? lastPrimaryLayer;
  final _objectTypes = <VtkBackendObjectHandle, VtkObjectType>{};
  final _outputSources = <VtkBackendObjectHandle, VtkBackendObjectHandle>{};
  int closeCount = 0;
  int _nextHandle = 1;

  VtkObjectType objectTypeOf(VtkBackendObjectHandle handle) =>
      _objectTypes[handle] ??
      (throw StateError('No recorded object for handle $handle'));

  VtkObjectType outputSourceTypeOf(VtkBackendObjectHandle handle) {
    final source = _outputSources[handle];
    if (source == null) {
      throw StateError('Handle $handle is not a recorded algorithm output');
    }
    return objectTypeOf(source);
  }

  Iterable<RecordedVtkCall> callsFor(VtkObjectType type) =>
      calls.where((call) => objectTypeOf(call.target) == type);

  @override
  Future<VtkBackendObjectHandle> createImageData({
    required VtkScalarImageInput input,
  }) async {
    imageInputs.add(input);
    return _createHandle(VtkObjectType.imageData);
  }

  @override
  Future<VtkBackendObjectHandle> createObject({
    required VtkObjectType type,
  }) async => _createHandle(type);

  @override
  Future<Object?> invoke({
    required VtkBackendObjectHandle target,
    required VtkBackendOperation operation,
    List<Object?> arguments = const [],
  }) async {
    calls.add(
      RecordedVtkCall(
        target: target,
        operation: operation,
        arguments: List.unmodifiable(arguments),
      ),
    );
    if (operation == VtkBackendOperation.getOutputPort) {
      final output = _createHandle(VtkObjectType.algorithmOutput);
      _outputSources[output] = target;
      return output;
    }
    return null;
  }

  @override
  Future<void> destroyObject({required VtkBackendObjectHandle object}) async {
    destroyedObjects.add(object);
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
    lastRenderLayers = List.unmodifiable(layers);
    lastPrimaryLayer = primaryLayer;
    return VtkRenderResult(
      viewport: viewport,
      frameBytes: viewport.pixelCount * 4,
      surfaceAllocationBytes: viewport.pixelCount * 4,
      renderTime: const Duration(milliseconds: 1),
      surfaceSubmitTime: Duration.zero,
      gpuSyncWaitTime: Duration.zero,
      cpuReadbackTime: Duration.zero,
      worldToClip: VtkMatrix4.identity(),
    );
  }

  @override
  Future<void> close() async {
    closeCount++;
  }

  VtkBackendObjectHandle _createHandle(VtkObjectType type) {
    final handle = VtkBackendObjectHandle(_nextHandle++);
    createdTypes.add(type);
    _objectTypes[handle] = type;
    return handle;
  }
}

final class RecordedVtkCall {
  const RecordedVtkCall({
    required this.target,
    required this.operation,
    required this.arguments,
  });

  final VtkBackendObjectHandle target;
  final VtkBackendOperation operation;
  final List<Object?> arguments;
}
