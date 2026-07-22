import 'dart:async';
import 'dart:isolate';

import '../api/vtk_api.dart';
import 'vtk_ffi_transport_base.dart';
import 'vtk_ffi_transport_native.dart';
import 'vtk_session_executor_base.dart';

typedef VtkFfiTransportFactory = VtkFfiTransport Function();

VtkSessionExecutorFactory createDefaultVtkSessionExecutorFactory() =>
    const VtkIsolateSessionExecutorFactory();

final class VtkIsolateSessionExecutorFactory
    implements VtkSessionExecutorFactory {
  const VtkIsolateSessionExecutorFactory({
    this.transportFactory = createDefaultVtkFfiTransport,
  });

  final VtkFfiTransportFactory transportFactory;

  @override
  Future<VtkSessionExecutor> create() =>
      VtkIsolateSessionExecutor.spawn(transportFactory: transportFactory);
}

final class VtkIsolateSessionExecutor implements VtkSessionExecutor {
  VtkIsolateSessionExecutor._(this._responses, this._transportFactory);

  static Future<VtkIsolateSessionExecutor> spawn({
    required VtkFfiTransportFactory transportFactory,
  }) async {
    final responses = ReceivePort();
    final executor = VtkIsolateSessionExecutor._(responses, transportFactory);
    responses.listen(executor._handleWorkerMessage);
    try {
      executor._isolate = await Isolate.spawn(
        _runVtkSessionWorker,
        _WorkerStart(
          responsePort: responses.sendPort,
          transportFactory: transportFactory,
        ),
        onError: responses.sendPort,
        onExit: responses.sendPort,
        errorsAreFatal: true,
        debugName: 'vtk_flutter_session',
      );
      await executor._ready.future;
      return executor;
    } on Object {
      executor._disposeRootResources();
      rethrow;
    }
  }

  final ReceivePort _responses;
  final VtkFfiTransportFactory _transportFactory;
  final Completer<void> _ready = Completer<void>();
  final Map<int, Completer<Object?>> _pending = {};
  Isolate? _isolate;
  SendPort? _requests;
  int _nextRequestId = 1;
  int? _presentationApiAddress;
  int? _nativeSessionAddress;
  Future<void>? _closeOperation;
  bool _closeStarted = false;
  bool _closed = false;
  bool _workerExited = false;
  bool _rootResourcesDisposed = false;

  @override
  int get presentationApiAddress =>
      _presentationApiAddress ??
      (throw const VtkApiStateException(
        'The native VTK session executor is not ready',
      ));

  @override
  int get nativeSessionAddress =>
      _nativeSessionAddress ??
      (throw const VtkApiStateException(
        'The native VTK session executor is not ready',
      ));

  @override
  Future<VtkBackendObjectHandle> createObject({required VtkObjectType type}) {
    _ensureOpen();
    return _request(
      _VtkExecutorOperation.createObject,
      type,
    ).then((result) => result as VtkBackendObjectHandle);
  }

  @override
  Future<VtkBackendObjectHandle> createDynamicObject({
    required String className,
  }) {
    _ensureOpen();
    return _request(
      _VtkExecutorOperation.createDynamicObject,
      className,
    ).then((result) => result as VtkBackendObjectHandle);
  }

  @override
  Future<VtkBackendObjectHandle> createImageData({
    required VtkScalarImageInput input,
  }) {
    _ensureOpen();
    return _request(
      _VtkExecutorOperation.createImageData,
      input,
    ).then((result) => result as VtkBackendObjectHandle);
  }

  @override
  Future<Object?> invoke({
    required VtkBackendObjectHandle target,
    required VtkBackendOperation operation,
    required List<Object?> arguments,
  }) {
    _ensureOpen();
    return _request(_VtkExecutorOperation.invoke, (
      target: target,
      operation: operation,
      arguments: arguments,
    ));
  }

  @override
  Future<Object?> invokeDynamic({
    required VtkBackendObjectHandle target,
    required String methodName,
    required List<Object?> arguments,
  }) {
    _ensureOpen();
    return _request(_VtkExecutorOperation.invokeDynamic, (
      target: target,
      methodName: methodName,
      arguments: arguments,
    ));
  }

  @override
  Future<void> destroyObject({required VtkBackendObjectHandle object}) {
    _ensureOpen();
    return _request(_VtkExecutorOperation.destroyObject, object);
  }

  @override
  Future<VtkRenderResult> renderLayout({
    required List<VtkBackendRenderLayer> layers,
    required VtkViewport viewport,
    required int primaryLayer,
  }) {
    _ensureOpen();
    return _request(_VtkExecutorOperation.renderLayout, (
      layers: layers,
      viewport: viewport,
      primaryLayer: primaryLayer,
    )).then((result) => result as VtkRenderResult);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    final currentClose = _closeOperation;
    if (currentClose != null) return currentClose;

    _closeStarted = true;
    final operation = _workerExited
        ? _destroyExitedWorkerSession()
        : _request(_VtkExecutorOperation.close, null);
    _closeOperation = operation;
    try {
      await operation;
      _closed = true;
      _disposeRootResources();
    } on Object {
      _closeOperation = null;
      rethrow;
    }
  }

  Future<void> _destroyExitedWorkerSession() async {
    final sessionAddress = _nativeSessionAddress;
    if (sessionAddress == null) {
      throw const VtkApiStateException(
        'The exited native VTK session worker returned no session address',
      );
    }
    _transportFactory().destroySession(sessionAddress);
  }

  Future<T> _request<T>(_VtkExecutorOperation operation, Object? payload) {
    final requests = _requests;
    if (requests == null || _workerExited) {
      return Future.error(
        const VtkApiStateException('The native VTK session worker exited'),
      );
    }
    final requestId = _nextRequestId++;
    final completer = Completer<Object?>();
    _pending[requestId] = completer;
    try {
      requests.send(
        _WorkerRequest(
          requestId: requestId,
          operation: operation,
          payload: payload,
        ),
      );
    } on Object catch (error, stackTrace) {
      _pending.remove(requestId);
      completer.completeError(error, stackTrace);
    }
    return completer.future.then((result) => result as T);
  }

  void _handleWorkerMessage(Object? message) {
    switch (message) {
      case _WorkerReady(
        :final requestPort,
        :final presentationApiAddress,
        :final nativeSessionAddress,
      ):
        _requests = requestPort;
        _presentationApiAddress = presentationApiAddress;
        _nativeSessionAddress = nativeSessionAddress;
        if (!_ready.isCompleted) _ready.complete();
      case _WorkerSuccess(:final requestId, :final result):
        _pending.remove(requestId)?.complete(result);
      case _WorkerFailure(:final requestId, :final error, :final stackTrace):
        final trace = StackTrace.fromString(stackTrace);
        if (requestId == null) {
          if (!_ready.isCompleted) _ready.completeError(error, trace);
        } else {
          _pending.remove(requestId)?.completeError(error, trace);
        }
      case [final Object error, final String stackTrace]:
        _handleWorkerExit(error, StackTrace.fromString(stackTrace));
      case null:
        _handleWorkerExit(
          const VtkApiStateException('The native VTK session worker exited'),
          StackTrace.current,
        );
      default:
        _handleWorkerExit(
          const VtkApiStateException(
            'The native VTK session worker sent an invalid response',
          ),
          StackTrace.current,
        );
    }
  }

  void _handleWorkerExit(Object error, StackTrace stackTrace) {
    if (_workerExited) return;
    _workerExited = true;
    if (!_ready.isCompleted) _ready.completeError(error, stackTrace);
    for (final pending in _pending.values) {
      pending.completeError(error, stackTrace);
    }
    _pending.clear();
    _disposeRootResources(killWorker: false);
  }

  void _disposeRootResources({bool killWorker = true}) {
    if (_rootResourcesDisposed) return;
    _rootResourcesDisposed = true;
    _responses.close();
    if (killWorker && !_workerExited) _isolate?.kill();
  }

  void _ensureOpen() {
    if (_closeStarted) {
      throw const VtkApiStateException('The native VTK session is closed');
    }
  }
}

enum _VtkExecutorOperation {
  createObject,
  createDynamicObject,
  createImageData,
  invoke,
  invokeDynamic,
  destroyObject,
  renderLayout,
  close,
}

final class _WorkerStart {
  const _WorkerStart({
    required this.responsePort,
    required this.transportFactory,
  });

  final SendPort responsePort;
  final VtkFfiTransportFactory transportFactory;
}

final class _WorkerReady {
  const _WorkerReady({
    required this.requestPort,
    required this.presentationApiAddress,
    required this.nativeSessionAddress,
  });

  final SendPort requestPort;
  final int presentationApiAddress;
  final int nativeSessionAddress;
}

final class _WorkerRequest {
  const _WorkerRequest({
    required this.requestId,
    required this.operation,
    required this.payload,
  });

  final int requestId;
  final _VtkExecutorOperation operation;
  final Object? payload;
}

final class _WorkerSuccess {
  const _WorkerSuccess({required this.requestId, required this.result});

  final int requestId;
  final Object? result;
}

final class _WorkerFailure {
  const _WorkerFailure({
    required this.requestId,
    required this.error,
    required this.stackTrace,
  });

  final int? requestId;
  final Object error;
  final String stackTrace;
}

void _runVtkSessionWorker(_WorkerStart start) {
  final requests = ReceivePort();
  late final VtkFfiTransport transport;
  int? sessionAddress;
  try {
    transport = start.transportFactory();
    sessionAddress = transport.createSession();
    start.responsePort.send(
      _WorkerReady(
        requestPort: requests.sendPort,
        presentationApiAddress: transport.presentationApiAddress,
        nativeSessionAddress: sessionAddress,
      ),
    );
  } on Object catch (error, stackTrace) {
    var reportedError = error;
    var reportedStackTrace = stackTrace.toString();
    if (sessionAddress != null) {
      try {
        transport.destroySession(sessionAddress);
      } on Object catch (cleanupError, cleanupStackTrace) {
        reportedError = VtkApiStateException(
          'The native VTK session worker failed to clean up a session after '
          'initialization failed: $cleanupError. '
          'Initialization error: $error',
        );
        reportedStackTrace =
            '$reportedStackTrace\n'
            'Cleanup failure:\n'
            '$cleanupStackTrace';
      }
    }
    start.responsePort.send(
      _WorkerFailure(
        requestId: null,
        error: reportedError,
        stackTrace: reportedStackTrace,
      ),
    );
    requests.close();
    return;
  }

  final activeSessionAddress = sessionAddress;

  var queue = Future<void>.value();
  requests.listen((message) {
    if (message is! _WorkerRequest) return;
    queue = queue.then(
      (_) => _executeWorkerRequest(
        request: message,
        responsePort: start.responsePort,
        requestPort: requests,
        transport: transport,
        sessionAddress: activeSessionAddress,
      ),
    );
  });
}

Future<void> _executeWorkerRequest({
  required _WorkerRequest request,
  required SendPort responsePort,
  required ReceivePort requestPort,
  required VtkFfiTransport transport,
  required int sessionAddress,
}) async {
  try {
    final result = switch (request.operation) {
      .createObject => transport.createObject(
        sessionAddress: sessionAddress,
        type: request.payload as VtkObjectType,
      ),
      .createDynamicObject => transport.createDynamicObject(
        sessionAddress: sessionAddress,
        className: request.payload as String,
      ),
      .createImageData => transport.createImageData(
        sessionAddress: sessionAddress,
        input: request.payload as VtkScalarImageInput,
      ),
      .invoke => _invoke(transport, sessionAddress, request.payload),
      .invokeDynamic => _invokeDynamic(
        transport,
        sessionAddress,
        request.payload,
      ),
      .destroyObject => _destroyObject(
        transport,
        sessionAddress,
        request.payload,
      ),
      .renderLayout => _renderLayout(
        transport,
        sessionAddress,
        request.payload,
      ),
      .close => _destroySession(transport, sessionAddress),
    };
    responsePort.send(
      _WorkerSuccess(requestId: request.requestId, result: result),
    );
    if (request.operation == .close) requestPort.close();
  } on Object catch (error, stackTrace) {
    responsePort.send(
      _WorkerFailure(
        requestId: request.requestId,
        error: error,
        stackTrace: stackTrace.toString(),
      ),
    );
  }
}

Object? _invoke(
  VtkFfiTransport transport,
  int sessionAddress,
  Object? payload,
) {
  final (:target, :operation, :arguments) =
      payload
          as ({
            VtkBackendObjectHandle target,
            VtkBackendOperation operation,
            List<Object?> arguments,
          });
  return transport.invoke(
    sessionAddress: sessionAddress,
    target: target,
    operation: operation,
    arguments: arguments,
  );
}

Object? _invokeDynamic(
  VtkFfiTransport transport,
  int sessionAddress,
  Object? payload,
) {
  final (:target, :methodName, :arguments) =
      payload
          as ({
            VtkBackendObjectHandle target,
            String methodName,
            List<Object?> arguments,
          });
  return transport.invokeDynamic(
    sessionAddress: sessionAddress,
    target: target,
    methodName: methodName,
    arguments: arguments,
  );
}

Object? _destroyObject(
  VtkFfiTransport transport,
  int sessionAddress,
  Object? payload,
) {
  transport.destroyObject(
    sessionAddress: sessionAddress,
    object: payload as VtkBackendObjectHandle,
  );
  return null;
}

VtkRenderResult _renderLayout(
  VtkFfiTransport transport,
  int sessionAddress,
  Object? payload,
) {
  final (:layers, :viewport, :primaryLayer) =
      payload
          as ({
            List<VtkBackendRenderLayer> layers,
            VtkViewport viewport,
            int primaryLayer,
          });
  return transport.renderLayout(
    sessionAddress: sessionAddress,
    layers: layers,
    viewport: viewport,
    primaryLayer: primaryLayer,
  );
}

Object? _destroySession(VtkFfiTransport transport, int sessionAddress) {
  transport.destroySession(sessionAddress);
  return null;
}
