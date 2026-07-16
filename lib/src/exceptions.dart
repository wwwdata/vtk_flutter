sealed class VtkException implements Exception {
  const VtkException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class VtkValidationException extends VtkException {
  const VtkValidationException({required this.field, required String message})
    : super(message);

  final String field;
}

final class VtkSessionAlreadyOpenException extends VtkException {
  const VtkSessionAlreadyOpenException()
    : super('Only one VTK render session may be active');
}

final class VtkSessionClosedException extends VtkException {
  const VtkSessionClosedException() : super('The VTK render session is closed');
}

final class VtkPlatformException extends VtkException {
  const VtkPlatformException({required this.code, required String message})
    : super(message);

  final String code;
}

final class VtkProtocolException extends VtkException {
  const VtkProtocolException(super.message);
}
