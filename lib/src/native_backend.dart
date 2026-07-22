import 'dart:async';

import 'api/vtk_api.dart';
import 'ffi/vtk_session_executor.dart';
import 'vtk_flutter_platform_interface.dart';

VtkBackend createDefaultVtkBackend() => VtkNativeBackend();

final class VtkNativeBackend implements VtkBackend {
  VtkNativeBackend({
    VtkSessionExecutorFactory? executorFactory,
    VtkFlutterPlatform? platform,
  }) : _executorFactory = executorFactory ?? _requiredExecutorFactory(),
       _platform = platform ?? VtkFlutterPlatform.instance;

  final VtkSessionExecutorFactory _executorFactory;
  final VtkFlutterPlatform _platform;
  final Map<int, VtkNativeBackendSession> _sessions = {};
  int _openingSessionCount = 0;
  Completer<void>? _openingSessionsDrained;
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
    if (!_platform.supportsIndependentSessionViews &&
        (_openingSessionCount > 0 || _sessions.isNotEmpty)) {
      throw const VtkApiStateException(
        'The native backend supports one active presentation session',
      );
    }
    _openingSessionCount++;
    try {
      final executor = await _executorFactory.create();
      final address = executor.nativeSessionAddress;
      final viewport = VtkViewport(width: 1, height: 1);
      try {
        _ensureOpen();
        final viewId = await _platform.createView(
          viewport: viewport,
          presentationApiAddress: executor.presentationApiAddress,
          nativeSessionAddress: address,
        );
        _ensureOpen();
        late final VtkNativeBackendSession session;
        session = VtkNativeBackendSession(
          executor: executor,
          platform: _platform,
          sessionAddress: address,
          viewId: viewId,
          viewport: viewport,
          onClosed: () {
            if (identical(_sessions[address], session)) {
              _sessions.remove(address);
            }
          },
        );
        _sessions[address] = session;
        return session;
      } on Object catch (error, stackTrace) {
        late final VtkNativeBackendSession cleanupSession;
        cleanupSession = VtkNativeBackendSession(
          executor: executor,
          platform: _platform,
          sessionAddress: address,
          viewId: 0,
          viewport: viewport,
          onClosed: () {
            if (identical(_sessions[address], cleanupSession)) {
              _sessions.remove(address);
            }
          },
        );
        _sessions[address] = cleanupSession;
        try {
          await cleanupSession.close();
        } on Object catch (cleanupError, cleanupStackTrace) {
          final combinedError = VtkApiStateException(
            'Native presentation view creation failed: $error. '
            'Its retained cleanup also failed and will be retried when the '
            'backend closes: $cleanupError',
          );
          Error.throwWithStackTrace(
            combinedError,
            StackTrace.fromString(
              '$stackTrace\nCleanup failure:\n$cleanupStackTrace',
            ),
          );
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    } finally {
      _openingSessionCount--;
      if (_openingSessionCount == 0) {
        _openingSessionsDrained?.complete();
        _openingSessionsDrained = null;
      }
    }
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
      _closeOperation = null;
      rethrow;
    }
  }

  Future<void> _closeSessions() async {
    if (_openingSessionCount > 0) {
      final drained = _openingSessionsDrained ??= Completer<void>();
      await drained.future;
    }
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final session in [..._sessions.values]) {
      try {
        await session.close();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if ((firstError, firstStackTrace) case (
      final Object error,
      final StackTrace stackTrace,
    )) {
      Error.throwWithStackTrace(error, stackTrace);
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
    required this._executor,
    required this._platform,
    required this._sessionAddress,
    required this.viewId,
    required this._viewport,
    required this._onClosed,
  });

  final VtkSessionExecutor _executor;
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
    return _executor.createObject(type: type);
  }

  @override
  Future<VtkBackendObjectHandle> createDynamicObject({
    required String className,
  }) {
    _ensureOpen();
    return _executor.createDynamicObject(className: className);
  }

  @override
  Future<VtkBackendObjectHandle> createImageData({
    required VtkScalarImageInput input,
  }) {
    _ensureOpen();
    return _executor.createImageData(input: input);
  }

  @override
  Future<Object?> invoke({
    required VtkBackendObjectHandle target,
    required VtkBackendOperation operation,
    List<Object?> arguments = const [],
  }) {
    _ensureOpen();
    return _executor.invoke(
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
    return _executor.invokeDynamic(
      target: target,
      methodName: methodName,
      arguments: arguments,
    );
  }

  @override
  Future<void> destroyObject({required VtkBackendObjectHandle object}) {
    _ensureOpen();
    return _executor.destroyObject(object: object);
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
    if (_viewport != viewport) {
      await _platform.resize(
        nativeSessionAddress: _sessionAddress,
        viewport: viewport,
      );
      _viewport = viewport;
    }
    final result = await _executor.renderLayout(
      layers: layers,
      viewport: viewport,
      primaryLayer: primaryLayer,
    );
    await _platform.presentFrame(nativeSessionAddress: _sessionAddress);
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
      await _platform.disposeView(nativeSessionAddress: _sessionAddress);
      _viewDisposed = true;
    }
    if (!_sessionDestroyed) {
      await _executor.close();
      _sessionDestroyed = true;
    }
  }

  void _ensureOpen() {
    if (_closeStarted) {
      throw const VtkApiStateException('The native VTK session is closed');
    }
  }
}

VtkSessionExecutorFactory _requiredExecutorFactory() {
  final factory = createDefaultVtkSessionExecutorFactory();
  if (factory == null) {
    throw const VtkApiStateException(
      'Dart FFI is unavailable on this platform',
    );
  }
  return factory;
}
