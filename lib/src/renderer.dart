import '../vtk_flutter_platform_interface.dart';
import 'exceptions.dart';
import 'models.dart';

final class VtkRenderer {
  VtkRenderer({VtkFlutterPlatform? platform})
    : _platform = platform ?? VtkFlutterPlatform.instance {
    _reservation = _reservations[_platform] ??= _SessionReservation();
  }

  static final _reservations = Expando<_SessionReservation>();

  final VtkFlutterPlatform _platform;
  late final _SessionReservation _reservation;

  Future<VtkCapabilities> capabilities() => _platform.capabilities();

  Future<VtkRenderSession> open(VtkViewport viewport) async {
    if (_reservation.isReserved) {
      throw const VtkSessionAlreadyOpenException();
    }
    _reservation.isReserved = true;
    try {
      final textureId = await _platform.createSession(viewport);
      return VtkRenderSession._(
        platform: _platform,
        textureId: textureId,
        onClosed: _releaseSession,
      );
    } on Object {
      _reservation.isReserved = false;
      rethrow;
    }
  }

  void _releaseSession() => _reservation.isReserved = false;
}

final class VtkRenderSession {
  VtkRenderSession._({
    required this._platform,
    required this.textureId,
    required this._onClosed,
  });

  final VtkFlutterPlatform _platform;
  final void Function() _onClosed;
  final int textureId;
  Future<void> _pendingOperations = Future.value();
  Future<void>? _closeOperation;
  bool _closeStarted = false;
  bool _disposed = false;

  bool get isClosed => _closeStarted;

  Future<void> setVolume(VtkVolume volume) async =>
      _schedule(() => _platform.setVolume(volume));

  Future<VtkFrameMetrics> render(VtkRenderRequest request) async =>
      _schedule(() => _platform.render(request));

  Future<VtkSessionStatus> status() async => _schedule(_platform.status);

  Future<void> resize(VtkViewport viewport) async =>
      _schedule(() => _platform.resize(viewport));

  Future<int> recreateGraphicsContext() async =>
      _schedule(_platform.recreateGraphicsContext);

  Future<void> close() async {
    if (_disposed) return;
    final currentClose = _closeOperation;
    if (currentClose != null) return currentClose;

    _closeStarted = true;
    final operation = _disposeAfterPendingOperations();
    _closeOperation = operation;
    try {
      await operation;
    } on Object {
      _closeOperation = null;
      rethrow;
    }
  }

  Future<void> _disposeAfterPendingOperations() async {
    await _pendingOperations;
    await _platform.disposeSession();
    _disposed = true;
    _onClosed();
  }

  Future<T> _schedule<T>(Future<T> Function() operation) {
    _ensureOpen();
    final result = _pendingOperations.then((_) => operation());
    _pendingOperations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _ensureOpen() {
    if (_closeStarted) throw const VtkSessionClosedException();
  }
}

final class _SessionReservation {
  bool isReserved = false;
}
