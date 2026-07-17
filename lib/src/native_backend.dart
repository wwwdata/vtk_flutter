import 'api/vtk_api.dart';
import 'ffi/vtk_ffi_transport.dart';
import 'vtk_flutter_platform_interface.dart';

VtkBackend createDefaultVtkBackend() => VtkNativeBackend();

final class VtkNativeBackend implements VtkBackend {
  VtkNativeBackend({VtkFfiTransport? transport, VtkFlutterPlatform? platform})
    : _transport = transport ?? _requiredTransport(),
      _platform = platform ?? VtkFlutterPlatform.instance;

  final VtkFfiTransport _transport;
  final VtkFlutterPlatform _platform;
  VtkNativeBackendSession? _activeSession;
  Future<void>? _closeOperation;
  bool _closeStarted = false;
  bool _closed = false;

  @override
  Future<VtkCapabilities> capabilities() async {
    _ensureOpen();
    return VtkCapabilities(
      supportedObjectTypes: VtkObjectType.values.toSet(),
      supportedScalarTypes: VtkScalarType.values.toSet(),
      maxImageBytes: vtkMaximumImageBytes,
      supportsRendering: true,
    );
  }

  @override
  Future<VtkBackendSession> openSession() async {
    _ensureOpen();
    if (_activeSession != null) {
      throw const VtkApiStateException(
        'The native backend supports one active presentation session',
      );
    }

    final address = await _transport.createSession();
    final viewport = VtkViewport(width: 1, height: 1);
    try {
      final viewId = await _platform.createView(
        viewport: viewport,
        presentationApiAddress: _transport.presentationApiAddress,
        nativeSessionAddress: address,
      );
      late final VtkNativeBackendSession session;
      session = VtkNativeBackendSession(
        transport: _transport,
        platform: _platform,
        sessionAddress: address,
        viewId: viewId,
        viewport: viewport,
        onClosed: () {
          if (identical(_activeSession, session)) _activeSession = null;
        },
      );
      _activeSession = session;
      return session;
    } on Object catch (error, stackTrace) {
      late final VtkNativeBackendSession cleanupSession;
      cleanupSession = VtkNativeBackendSession(
        transport: _transport,
        platform: _platform,
        sessionAddress: address,
        viewId: 0,
        viewport: viewport,
        onClosed: () {
          if (identical(_activeSession, cleanupSession)) {
            _activeSession = null;
          }
        },
      );
      _activeSession = cleanupSession;
      try {
        await cleanupSession.close();
      } on Object {
        // The retained cleanup session lets backend.close() retry safely.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    final currentClose = _closeOperation;
    if (currentClose != null) return currentClose;

    _closeStarted = true;
    final operation = _activeSession?.close() ?? Future<void>.value();
    _closeOperation = operation;
    try {
      await operation;
      _closed = true;
    } on Object {
      _closeOperation = null;
      rethrow;
    }
  }

  void _ensureOpen() {
    if (_closeStarted) {
      throw const VtkApiStateException('The native VTK backend is closed');
    }
  }
}

final class VtkNativeBackendSession
    implements VtkBackendSession, VtkDynamicBackendSession {
  VtkNativeBackendSession({
    required this._transport,
    required this._platform,
    required this._sessionAddress,
    required this.viewId,
    required this._viewport,
    required this._onClosed,
  });

  final VtkFfiTransport _transport;
  final VtkFlutterPlatform _platform;
  final int _sessionAddress;
  final void Function() _onClosed;

  @override
  final int viewId;

  VtkViewport _viewport;
  Future<void>? _closeOperation;
  bool _closeStarted = false;
  bool _viewDisposed = false;
  bool _sessionDestroyed = false;
  bool _closed = false;

  @override
  Future<VtkBackendObjectHandle> createObject({required VtkObjectType type}) {
    _ensureOpen();
    return _transport.createObject(sessionAddress: _sessionAddress, type: type);
  }

  @override
  Future<VtkBackendObjectHandle> createDynamicObject({
    required String className,
  }) {
    _ensureOpen();
    return _transport.createDynamicObject(
      sessionAddress: _sessionAddress,
      className: className,
    );
  }

  @override
  Future<VtkBackendObjectHandle> createImageData({
    required VtkScalarImageInput input,
  }) {
    _ensureOpen();
    return _transport.createImageData(
      sessionAddress: _sessionAddress,
      input: input,
    );
  }

  @override
  Future<Object?> invoke({
    required VtkBackendObjectHandle target,
    required VtkBackendOperation operation,
    List<Object?> arguments = const [],
  }) {
    _ensureOpen();
    return _transport.invoke(
      sessionAddress: _sessionAddress,
      target: target,
      operation: operation,
      arguments: arguments,
    );
  }

  @override
  Future<Object?> invokeDynamic({
    required VtkBackendObjectHandle target,
    required String methodName,
    List<Object?> arguments = const [],
  }) {
    _ensureOpen();
    return _transport.invokeDynamic(
      sessionAddress: _sessionAddress,
      target: target,
      methodName: methodName,
      arguments: arguments,
    );
  }

  @override
  Future<void> destroyObject({required VtkBackendObjectHandle object}) {
    _ensureOpen();
    return _transport.destroyObject(
      sessionAddress: _sessionAddress,
      object: object,
    );
  }

  @override
  Future<VtkRenderResult> render({
    required VtkBackendObjectHandle renderer,
    required VtkViewport viewport,
  }) async {
    _ensureOpen();
    if (_viewport != viewport) {
      await _platform.resize(viewport);
      _viewport = viewport;
    }
    final result = await _transport.render(
      sessionAddress: _sessionAddress,
      renderer: renderer,
      viewport: viewport,
    );
    await _platform.presentFrame();
    return result;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    final currentClose = _closeOperation;
    if (currentClose != null) return currentClose;

    _closeStarted = true;
    final operation = _closeResources();
    _closeOperation = operation;
    try {
      await operation;
      _closed = true;
      _onClosed();
    } on Object {
      _closeOperation = null;
      rethrow;
    }
  }

  Future<void> _closeResources() async {
    if (!_viewDisposed) {
      await _platform.disposeView();
      _viewDisposed = true;
    }
    if (!_sessionDestroyed) {
      await _transport.destroySession(_sessionAddress);
      _sessionDestroyed = true;
    }
  }

  void _ensureOpen() {
    if (_closeStarted) {
      throw const VtkApiStateException('The native VTK session is closed');
    }
  }
}

VtkFfiTransport _requiredTransport() {
  final transport = createDefaultVtkFfiTransport();
  if (transport == null) {
    throw const VtkApiStateException(
      'Dart FFI is unavailable on this platform',
    );
  }
  return transport;
}
