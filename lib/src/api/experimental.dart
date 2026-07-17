part of 'vtk_api.dart';

extension VtkExperimentalSession on VtkSession {
  /// Opens the intentionally unstable string-based API for this session.
  VtkDynamicSession get dynamic => VtkDynamicSession._(this);
}

final class VtkDynamicSession {
  VtkDynamicSession._(this._session);

  final VtkSession _session;

  Future<VtkDynamicObject> create(String className) async {
    _session._ensureOpen();
    if (!_validClassName.hasMatch(className)) {
      throw const VtkApiValidationException(
        field: 'className',
        message: 'A VTK class name such as vtkRenderer is required',
      );
    }
    final backend = _dynamicBackend;
    final handle = await _session._queue.add(
      () => backend.createDynamicObject(className: className),
    );
    return _session._adoptDynamic(dynamicSession: this, handle: handle);
  }

  VtkDynamicBackendSession get _dynamicBackend {
    final backend = _session._backend;
    if (backend is! VtkDynamicBackendSession) {
      throw const VtkApiStateException(
        'This backend does not support the experimental dynamic API',
      );
    }
    return backend as VtkDynamicBackendSession;
  }
}

final class VtkDynamicObject implements _VtkOwnedObject {
  VtkDynamicObject._({required this._session, required this._handle});

  final VtkDynamicSession _session;
  final VtkBackendObjectHandle _handle;
  Future<void>? _disposeOperation;
  bool _disposeStarted = false;
  bool _disposed = false;

  bool get isDisposed => _disposeStarted || _disposed;

  @override
  VtkBackendObjectHandle get _ownedHandle => _handle;

  @override
  bool get _ownedDisposed => _disposed;

  Future<Object?> invoke(
    String methodName, [
    List<Object?> arguments = const [],
  ]) {
    _session._session._ensureOpen();
    _ensureUsable();
    if (!_validMethodName.hasMatch(methodName)) {
      throw const VtkApiValidationException(
        field: 'methodName',
        message: 'A VTK method name is required',
      );
    }
    final backend = _session._dynamicBackend;
    return _session._session._queue.add(() async {
      final result = await backend.invokeDynamic(
        target: _handle,
        methodName: methodName,
        arguments: [
          for (final argument in arguments)
            _encodeDynamicArgument(value: argument, session: _session),
        ],
      );
      if (result is VtkBackendObjectHandle) {
        return _session._session._adoptDynamic(
          dynamicSession: _session,
          handle: result,
        );
      }
      return result;
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    final currentDispose = _disposeOperation;
    if (currentDispose != null) return currentDispose;

    _disposeStarted = true;
    final operation = _session._session._disposeObject(this);
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
      throw const VtkApiStateException('The dynamic VTK object is disposed');
    }
  }

  @override
  void _markDisposed() {
    _disposeStarted = true;
    _disposed = true;
  }
}

Object? _encodeDynamicArgument({
  required Object? value,
  required VtkDynamicSession session,
}) {
  if (value is VtkDynamicObject) {
    return session._session._dynamicHandleOf(value);
  }
  if (value is VtkObject) {
    return session._session._handleOf(value);
  }
  if (value is List<Object?>) {
    return [
      for (final item in value)
        _encodeDynamicArgument(value: item, session: session),
    ];
  }
  if (value is Map<Object?, Object?>) {
    final encoded = <String, Object?>{};
    for (final MapEntry(:key, :value) in value.entries) {
      if (key is! String) {
        throw const VtkApiValidationException(
          field: 'arguments',
          message: 'Dynamic map argument keys must be strings',
        );
      }
      encoded[key] = _encodeDynamicArgument(value: value, session: session);
    }
    return encoded;
  }
  return value;
}

final _validClassName = RegExp(r'^vtk[A-Z][A-Za-z0-9_]*$');
final _validMethodName = RegExp(r'^[A-Z][A-Za-z0-9_]*$');
