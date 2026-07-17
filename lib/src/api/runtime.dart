part of 'vtk_api.dart';

typedef _VtkObjectFactory<T extends VtkObject> =
    T Function({
      required VtkSession session,
      required VtkBackendObjectHandle handle,
    });

abstract interface class _VtkOwnedObject {
  VtkBackendObjectHandle get _ownedHandle;

  bool get _ownedDisposed;

  void _markDisposed();
}

final class VtkRuntime {
  factory VtkRuntime() => VtkRuntime._(createDefaultVtkBackend());

  VtkRuntime._(this._backend);

  final VtkBackend _backend;
  final _queue = _SerialQueue();
  final _sessions = <VtkSession>{};
  VtkCapabilities? _capabilities;
  Future<void>? _closeOperation;
  bool _backendClosed = false;
  bool _closeStarted = false;
  bool _closed = false;

  bool get isClosed => _closeStarted;

  Future<VtkCapabilities> capabilities() {
    _ensureOpen();
    return _queue.add(() async {
      final cached = _capabilities;
      if (cached != null) return cached;
      final capabilities = await _backend.capabilities();
      _capabilities = capabilities;
      return capabilities;
    });
  }

  Future<VtkSession> openSession() {
    _ensureOpen();
    return _queue.add(() async {
      final capabilities = _capabilities ?? await _backend.capabilities();
      _capabilities = capabilities;
      final backendSession = await _backend.openSession();
      if (_closeStarted) {
        await backendSession.close();
        throw const VtkApiStateException('The VTK runtime is closed');
      }
      late final VtkSession session;
      session = VtkSession._(
        backend: backendSession,
        capabilities: capabilities,
        onClosed: () => _sessions.remove(session),
      );
      _sessions.add(session);
      return session;
    });
  }

  Future<void> close() async {
    if (_closed) return;
    final currentClose = _closeOperation;
    if (currentClose != null) return currentClose;

    _closeStarted = true;
    final operation = _queue.add(_closeResources);
    _closeOperation = operation;
    try {
      await operation;
      _closed = true;
    } on Object {
      if (_backendClosed) {
        _closed = true;
      } else {
        _closeOperation = null;
      }
      rethrow;
    }
  }

  Future<void> _closeResources() async {
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
    if (!_backendClosed) {
      try {
        await _backend.close();
        _backendClosed = true;
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    final error = firstError;
    final stackTrace = firstStackTrace;
    if (error != null && stackTrace != null) {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void _ensureOpen() {
    if (_closeStarted) {
      throw const VtkApiStateException('The VTK runtime is closed');
    }
  }
}

/// Creates a runtime around an adapter implementation for package tests.
///
/// This function is intentionally hidden by the stable package entrypoint.
VtkRuntime createVtkRuntimeForBackend(VtkBackend backend) =>
    VtkRuntime._(backend);

final class VtkSession {
  factory VtkSession._({
    required VtkBackendSession backend,
    required VtkCapabilities capabilities,
    required void Function() onClosed,
  }) => VtkSession._internal(
    backend: backend,
    capabilities: capabilities,
    onClosed: onClosed,
  );

  VtkSession._internal({
    required this._backend,
    required this.capabilities,
    required this._onClosed,
  });

  final VtkBackendSession _backend;
  final void Function() _onClosed;
  final _queue = _SerialQueue();
  final _objects = <_VtkOwnedObject>[];
  final VtkCapabilities capabilities;
  Future<void>? _closeOperation;
  bool _backendClosed = false;
  bool _closeStarted = false;
  bool _closed = false;

  bool get isClosed => _closeStarted;

  /// Identifies the Flutter presentation surface owned by this session.
  ///
  /// Native backends expose an external texture identifier. Web backends use
  /// the same value to look up the latest captured frame.
  int get viewId => _backend.viewId;

  Future<VtkImageData> createImageData(VtkScalarImageInput input) async {
    _ensureImageSupported(input);
    _ensureOpen();
    return _queue.add(() async {
      final handle = await _backend.createImageData(input: input);
      return _adopt(
        type: .imageData,
        handle: handle,
        factory: VtkImageData._new,
      );
    });
  }

  Future<VtkImageReslice> createImageReslice() =>
      _create(type: .imageReslice, factory: VtkImageReslice._new);

  Future<VtkImageMapToWindowLevelColors> createImageMapToWindowLevelColors() =>
      _create(
        type: .imageMapToWindowLevelColors,
        factory: VtkImageMapToWindowLevelColors._new,
      );

  Future<VtkImageActor> createImageActor() =>
      _create(type: .imageActor, factory: VtkImageActor._new);

  Future<VtkImageSliceMapper> createImageSliceMapper() =>
      _create(type: .imageSliceMapper, factory: VtkImageSliceMapper._new);

  Future<VtkImageProperty> createImageProperty() =>
      _create(type: .imageProperty, factory: VtkImageProperty._new);

  Future<VtkSmartVolumeMapper> createSmartVolumeMapper() =>
      _create(type: .smartVolumeMapper, factory: VtkSmartVolumeMapper._new);

  Future<VtkColorTransferFunction> createColorTransferFunction() => _create(
    type: .colorTransferFunction,
    factory: VtkColorTransferFunction._new,
  );

  Future<VtkPiecewiseFunction> createPiecewiseFunction() =>
      _create(type: .piecewiseFunction, factory: VtkPiecewiseFunction._new);

  Future<VtkVolumeProperty> createVolumeProperty() =>
      _create(type: .volumeProperty, factory: VtkVolumeProperty._new);

  Future<VtkVolume> createVolume() =>
      _create(type: .volume, factory: VtkVolume._new);

  Future<VtkFlyingEdges3D> createFlyingEdges3D() =>
      _create(type: .flyingEdges3D, factory: VtkFlyingEdges3D._new);

  Future<VtkPolyDataConnectivityFilter> createPolyDataConnectivityFilter() =>
      _create(
        type: .polyDataConnectivityFilter,
        factory: VtkPolyDataConnectivityFilter._new,
      );

  Future<VtkWindowedSincPolyDataFilter> createWindowedSincPolyDataFilter() =>
      _create(
        type: .windowedSincPolyDataFilter,
        factory: VtkWindowedSincPolyDataFilter._new,
      );

  Future<VtkPolyDataMapper> createPolyDataMapper() =>
      _create(type: .polyDataMapper, factory: VtkPolyDataMapper._new);

  Future<VtkActor> createActor() =>
      _create(type: .actor, factory: VtkActor._new);

  Future<VtkProperty> createProperty() =>
      _create(type: .property, factory: VtkProperty._new);

  Future<VtkRenderer> createRenderer() =>
      _create(type: .renderer, factory: VtkRenderer._new);

  Future<VtkCamera> createCamera() =>
      _create(type: .camera, factory: VtkCamera._new);

  Future<VtkRenderResult> render({
    required VtkRenderer renderer,
    required VtkViewport viewport,
  }) async {
    if (!capabilities.supportsRendering) {
      throw const VtkApiStateException(
        'The backend does not support rendering',
      );
    }
    final rendererHandle = _handleOf(renderer);
    return _queue.add(() async {
      return _backend.render(renderer: rendererHandle, viewport: viewport);
    });
  }

  Future<void> close() async {
    if (_closed) return;
    final currentClose = _closeOperation;
    if (currentClose != null) return currentClose;

    _closeStarted = true;
    final operation = _queue.add(_closeResources);
    _closeOperation = operation;
    try {
      await operation;
      _finishClose();
    } on Object {
      if (_backendClosed) {
        _finishClose();
      } else {
        _closeOperation = null;
      }
      rethrow;
    }
  }

  Future<T> _create<T extends VtkObject>({
    required VtkObjectType type,
    required _VtkObjectFactory<T> factory,
  }) async {
    _ensureSupported(type);
    _ensureOpen();
    return _queue.add(() async {
      final handle = await _backend.createObject(type: type);
      return _adopt(type: type, handle: handle, factory: factory);
    });
  }

  T _adopt<T extends VtkObject>({
    required VtkObjectType type,
    required VtkBackendObjectHandle handle,
    required _VtkObjectFactory<T> factory,
  }) {
    if (handle.value <= 0) {
      throw VtkApiStateException(
        'The backend returned an invalid handle for $type',
      );
    }
    for (final object in _objects) {
      if (object._ownedHandle == handle && object is T) return object;
    }
    final object = factory(session: this, handle: handle);
    _objects.add(object);
    return object;
  }

  VtkDynamicObject _adoptDynamic({
    required VtkDynamicSession dynamicSession,
    required VtkBackendObjectHandle handle,
  }) {
    if (handle.value <= 0) {
      throw const VtkApiStateException(
        'The backend returned an invalid dynamic object handle',
      );
    }
    for (final object in _objects) {
      if (object._ownedHandle == handle && object is VtkDynamicObject) {
        return object;
      }
    }
    final object = VtkDynamicObject._(session: dynamicSession, handle: handle);
    _objects.add(object);
    return object;
  }

  Future<VtkAlgorithmOutput> _output({
    required VtkObject algorithm,
    required int port,
  }) async {
    if (port < 0) {
      throw const VtkApiValidationException(
        field: 'port',
        message: 'Output port cannot be negative',
      );
    }
    final result = await _invoke(
      target: algorithm,
      operation: .getOutputPort,
      arguments: [port],
    );
    if (result is! VtkBackendObjectHandle) {
      throw VtkApiStateException(
        'The backend returned ${result.runtimeType} for an algorithm output',
      );
    }
    return _adopt(
      type: .algorithmOutput,
      handle: result,
      factory: VtkAlgorithmOutput._new,
    );
  }

  Future<Object?> _invoke({
    required VtkObject target,
    required VtkBackendOperation operation,
    List<Object?> arguments = const [],
  }) async {
    final targetHandle = _handleOf(target);
    final backendArguments = [
      for (final argument in arguments)
        if (argument is VtkObject) _handleOf(argument) else argument,
    ];
    return _queue.add(() async {
      target._ensureUsable();
      return _backend.invoke(
        target: targetHandle,
        operation: operation,
        arguments: backendArguments,
      );
    });
  }

  Future<void> _disposeObject(_VtkOwnedObject object) {
    if (object._ownedDisposed) return Future.value();
    if (_closeStarted) {
      return close();
    }
    return _queue.add(() async {
      if (object._ownedDisposed) return;
      await _backend.destroyObject(object: object._ownedHandle);
      _markHandleDisposed(object._ownedHandle);
    });
  }

  VtkBackendObjectHandle _handleOf(VtkObject object) {
    _ensureOpen();
    if (!identical(object._session, this)) {
      throw const VtkApiStateException(
        'VTK objects from different sessions cannot be connected',
      );
    }
    object._ensureUsable();
    return object._handle;
  }

  VtkBackendObjectHandle _dynamicHandleOf(VtkDynamicObject object) {
    _ensureOpen();
    if (!identical(object._session._session, this)) {
      throw const VtkApiStateException(
        'VTK objects from different sessions cannot be connected',
      );
    }
    object._ensureUsable();
    return object._ownedHandle;
  }

  Future<void> _closeResources() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    final attemptedHandles = <VtkBackendObjectHandle>{};
    for (final object in _objects.toList().reversed) {
      if (object._ownedDisposed || !attemptedHandles.add(object._ownedHandle)) {
        continue;
      }
      try {
        await _backend.destroyObject(object: object._ownedHandle);
        _markHandleDisposed(object._ownedHandle);
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (!_backendClosed) {
      try {
        await _backend.close();
        _backendClosed = true;
        for (final object in _objects) {
          object._markDisposed();
        }
        _objects.clear();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    final error = firstError;
    final stackTrace = firstStackTrace;
    if (error != null && stackTrace != null) {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void _markHandleDisposed(VtkBackendObjectHandle handle) {
    final aliases = _objects
        .where((object) => object._ownedHandle == handle)
        .toList();
    for (final alias in aliases) {
      alias._markDisposed();
    }
    _objects.removeWhere((object) => object._ownedHandle == handle);
  }

  void _finishClose() {
    if (_closed) return;
    _closed = true;
    _onClosed();
  }

  void _ensureImageSupported(VtkScalarImageInput input) {
    _ensureSupported(.imageData);
    if (!capabilities.supportsScalarType(input.scalarType)) {
      throw VtkApiValidationException(
        field: 'scalarType',
        message: 'The backend does not support ${input.scalarType}',
      );
    }
    if (input.byteCount > capabilities.maxImageBytes) {
      throw VtkApiValidationException(
        field: 'values',
        message:
            'Image data exceeds the backend limit of '
            '${capabilities.maxImageBytes} bytes',
      );
    }
  }

  void _ensureSupported(VtkObjectType type) {
    if (!capabilities.supportsObject(type)) {
      throw VtkUnsupportedCapabilityException(type);
    }
  }

  void _ensureOpen() {
    if (_closeStarted) {
      throw const VtkApiStateException('The VTK session is closed');
    }
  }
}

final class _SerialQueue {
  Future<void> _tail = Future.value();

  Future<T> add<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await operation());
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }
}
