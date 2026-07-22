part of 'vtk_api.dart';

const int vtkMaximumImageBytes = 256 * 1024 * 1024;
const int vtkMaximumRenderLayers = 64;
const int _maximumInt32 = 0x7fffffff;
const int _maximumExactJavaScriptInteger = 0x1fffffffffffff;

sealed class VtkApiException implements Exception {
  const VtkApiException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class VtkApiValidationException extends VtkApiException {
  const VtkApiValidationException({
    required this.field,
    required String message,
  }) : super(message);

  final String field;

  @override
  String toString() => '$runtimeType($field): $message';
}

final class VtkApiStateException extends VtkApiException {
  const VtkApiStateException(super.message);
}

final class VtkUnsupportedCapabilityException extends VtkApiException {
  const VtkUnsupportedCapabilityException(this.objectType)
    : super('The backend does not support $objectType');

  final VtkObjectType objectType;
}

enum VtkScalarType {
  uint8(bytesPerValue: 1),
  int8(bytesPerValue: 1),
  uint16(bytesPerValue: 2),
  int16(bytesPerValue: 2),
  uint32(bytesPerValue: 4),
  int32(bytesPerValue: 4),
  float32(bytesPerValue: 4),
  float64(bytesPerValue: 8);

  const VtkScalarType({required this.bytesPerValue});

  final int bytesPerValue;
}

enum VtkInterpolation { nearest, linear, cubic }

enum VtkVolumeBlendMode {
  composite,
  maximumIntensity,
  minimumIntensity,
  averageIntensity,
  additive,
  isoSurface,
}

enum VtkConnectivityMode { allRegions, largestRegion, closestPointRegion }

enum VtkRepresentation { points, wireframe, surface }

final class VtkCapabilities {
  VtkCapabilities({
    required Set<VtkObjectType> supportedObjectTypes,
    required Set<VtkScalarType> supportedScalarTypes,
    required this.maxImageBytes,
    required this.supportsRendering,
  }) : supportedObjectTypes = Set.unmodifiable(supportedObjectTypes),
       supportedScalarTypes = Set.unmodifiable(supportedScalarTypes) {
    if (maxImageBytes < 0) {
      throw const VtkApiValidationException(
        field: 'maxImageBytes',
        message: 'Maximum image bytes cannot be negative',
      );
    }
  }

  final Set<VtkObjectType> supportedObjectTypes;
  final Set<VtkScalarType> supportedScalarTypes;
  final int maxImageBytes;
  final bool supportsRendering;

  bool supportsObject(VtkObjectType type) =>
      supportedObjectTypes.contains(type);

  bool supportsScalarType(VtkScalarType type) =>
      supportedScalarTypes.contains(type);
}

final class VtkViewport {
  VtkViewport({required this.width, required this.height}) {
    _validatePositiveInt32(value: width, field: 'width');
    _validatePositiveInt32(value: height, field: 'height');
  }

  final int width;
  final int height;

  int get pixelCount => width * height;

  @override
  bool operator ==(Object other) =>
      other is VtkViewport && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

final class VtkNormalizedViewport {
  factory VtkNormalizedViewport({
    required double left,
    required double bottom,
    required double right,
    required double top,
  }) {
    _validateUnitInterval(value: left, field: 'left');
    _validateUnitInterval(value: bottom, field: 'bottom');
    _validateUnitInterval(value: right, field: 'right');
    _validateUnitInterval(value: top, field: 'top');
    if (left >= right) {
      throw const VtkApiValidationException(
        field: 'viewport',
        message: 'Viewport left must be less than right',
      );
    }
    if (bottom >= top) {
      throw const VtkApiValidationException(
        field: 'viewport',
        message: 'Viewport bottom must be less than top',
      );
    }
    return VtkNormalizedViewport._(
      left: left,
      bottom: bottom,
      right: right,
      top: top,
    );
  }

  const VtkNormalizedViewport._({
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
  });

  static const full = VtkNormalizedViewport._(
    left: 0,
    bottom: 0,
    right: 1,
    top: 1,
  );

  final double left;
  final double bottom;
  final double right;
  final double top;

  @override
  bool operator ==(Object other) =>
      other is VtkNormalizedViewport &&
      other.left == left &&
      other.bottom == bottom &&
      other.right == right &&
      other.top == top;

  @override
  int get hashCode => Object.hash(left, bottom, right, top);
}

final class VtkRenderLayer {
  const VtkRenderLayer({required this.renderer, required this.viewport});

  final VtkRenderer renderer;
  final VtkNormalizedViewport viewport;

  @override
  bool operator ==(Object other) =>
      other is VtkRenderLayer &&
      other.renderer == renderer &&
      other.viewport == viewport;

  @override
  int get hashCode => Object.hash(renderer, viewport);
}

final class VtkDimensions {
  VtkDimensions({required this.x, required this.y, required this.z}) {
    _validatePositiveInt32(value: x, field: 'x');
    _validatePositiveInt32(value: y, field: 'y');
    _validatePositiveInt32(value: z, field: 'z');
    final product = x * y * z;
    if (product > _maximumExactJavaScriptInteger) {
      throw const VtkApiValidationException(
        field: 'dimensions',
        message: 'Voxel count exceeds the cross-platform exact integer limit',
      );
    }
  }

  final int x;
  final int y;
  final int z;

  int get valueCount => x * y * z;

  List<int> get values => List.unmodifiable([x, y, z]);

  @override
  bool operator ==(Object other) =>
      other is VtkDimensions && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);
}

final class VtkVector3 {
  VtkVector3({required this.x, required this.y, required this.z}) {
    _validateFinite(value: x, field: 'x');
    _validateFinite(value: y, field: 'y');
    _validateFinite(value: z, field: 'z');
  }

  factory VtkVector3.zero() => VtkVector3(x: 0, y: 0, z: 0);

  factory VtkVector3.one() => VtkVector3(x: 1, y: 1, z: 1);

  final double x;
  final double y;
  final double z;

  bool get isZero => x == 0 && y == 0 && z == 0;

  List<double> get values => List.unmodifiable([x, y, z]);

  @override
  bool operator ==(Object other) =>
      other is VtkVector3 && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);
}

final class VtkColor {
  VtkColor({required this.red, required this.green, required this.blue}) {
    _validateUnitInterval(value: red, field: 'red');
    _validateUnitInterval(value: green, field: 'green');
    _validateUnitInterval(value: blue, field: 'blue');
  }

  final double red;
  final double green;
  final double blue;

  List<double> get values => List.unmodifiable([red, green, blue]);

  @override
  bool operator ==(Object other) =>
      other is VtkColor &&
      other.red == red &&
      other.green == green &&
      other.blue == blue;

  @override
  int get hashCode => Object.hash(red, green, blue);
}

final class VtkMatrix3 {
  VtkMatrix3({required List<double> values})
    : values = _validatedMatrix(
        values: values,
        expectedLength: 9,
        field: 'matrix3',
      );

  factory VtkMatrix3.identity() =>
      VtkMatrix3(values: const [1, 0, 0, 0, 1, 0, 0, 0, 1]);

  final List<double> values;

  @override
  bool operator ==(Object other) =>
      other is VtkMatrix3 && _listsEqual(values, other.values);

  @override
  int get hashCode => Object.hashAll(values);
}

final class VtkMatrix4 {
  VtkMatrix4({required List<double> values})
    : values = _validatedMatrix(
        values: values,
        expectedLength: 16,
        field: 'matrix4',
      );

  factory VtkMatrix4.identity() => VtkMatrix4(
    values: const [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
  );

  final List<double> values;

  @override
  bool operator ==(Object other) =>
      other is VtkMatrix4 && _listsEqual(values, other.values);

  @override
  int get hashCode => Object.hashAll(values);
}

final class VtkScalarImageInput {
  VtkScalarImageInput({
    required TypedData values,
    required this.dimensions,
    this.componentCount = 1,
    VtkVector3? origin,
    VtkVector3? spacing,
    VtkMatrix3? direction,
  }) : scalarType = _scalarTypeOf(values),
       origin = origin ?? VtkVector3.zero(),
       spacing = spacing ?? VtkVector3.one(),
       direction = direction ?? VtkMatrix3.identity(),
       _bytes = _copyBytes(values) {
    if (componentCount <= 0 || componentCount > _maximumInt32) {
      throw const VtkApiValidationException(
        field: 'componentCount',
        message: 'Component count must be a positive 32-bit integer',
      );
    }
    if (this.spacing.x <= 0 || this.spacing.y <= 0 || this.spacing.z <= 0) {
      throw const VtkApiValidationException(
        field: 'spacing',
        message: 'Image spacing must be positive on every axis',
      );
    }
    final expectedValueCount = dimensions.valueCount * componentCount;
    final actualValueCount = values.lengthInBytes ~/ scalarType.bytesPerValue;
    if (actualValueCount != expectedValueCount) {
      throw VtkApiValidationException(
        field: 'values',
        message:
            'Expected $expectedValueCount scalar values for the dimensions '
            'and component count, got $actualValueCount',
      );
    }
    if (_bytes.length > vtkMaximumImageBytes) {
      throw VtkApiValidationException(
        field: 'values',
        message: 'Image data exceeds the $vtkMaximumImageBytes byte API limit',
      );
    }
  }

  final VtkScalarType scalarType;
  final VtkDimensions dimensions;
  final int componentCount;
  final VtkVector3 origin;
  final VtkVector3 spacing;
  final VtkMatrix3 direction;
  final Uint8List _bytes;

  int get valueCount => dimensions.valueCount * componentCount;

  int get byteCount => _bytes.length;

  Uint8List get bytes => Uint8List.fromList(_bytes);
}

final class VtkRenderResult {
  VtkRenderResult({
    required this.viewport,
    required this.frameBytes,
    required this.surfaceAllocationBytes,
    required this.renderTime,
    required this.surfaceSubmitTime,
    required this.gpuSyncWaitTime,
    required this.cpuReadbackTime,
    this.worldToClip,
  }) {
    if (frameBytes < 0 || surfaceAllocationBytes < 0) {
      throw const VtkApiValidationException(
        field: 'renderBytes',
        message: 'Render byte counts cannot be negative',
      );
    }
    for (final duration in [
      renderTime,
      surfaceSubmitTime,
      gpuSyncWaitTime,
      cpuReadbackTime,
    ]) {
      if (duration.isNegative) {
        throw const VtkApiValidationException(
          field: 'renderDuration',
          message: 'Render durations cannot be negative',
        );
      }
    }
  }

  final VtkViewport viewport;
  final int frameBytes;
  final int surfaceAllocationBytes;
  final Duration renderTime;
  final Duration surfaceSubmitTime;
  final Duration gpuSyncWaitTime;
  final Duration cpuReadbackTime;
  final VtkMatrix4? worldToClip;
}

VtkScalarType _scalarTypeOf(TypedData values) => switch (values) {
  Uint8List() => .uint8,
  Int8List() => .int8,
  Uint16List() => .uint16,
  Int16List() => .int16,
  Uint32List() => .uint32,
  Int32List() => .int32,
  Float32List() => .float32,
  Float64List() => .float64,
  _ => throw VtkApiValidationException(
    field: 'values',
    message: 'Unsupported scalar list type ${values.runtimeType}',
  ),
};

Uint8List _copyBytes(TypedData values) => Uint8List.fromList(
  values.buffer.asUint8List(values.offsetInBytes, values.lengthInBytes),
);

List<double> _validatedMatrix({
  required List<double> values,
  required int expectedLength,
  required String field,
}) {
  if (values.length != expectedLength) {
    throw VtkApiValidationException(
      field: field,
      message: 'Expected $expectedLength row-major values',
    );
  }
  for (final value in values) {
    _validateFinite(value: value, field: field);
  }
  return List.unmodifiable(values);
}

void _validatePositiveInt32({required int value, required String field}) {
  if (value <= 0 || value > _maximumInt32) {
    throw VtkApiValidationException(
      field: field,
      message: 'Value must be a positive 32-bit integer',
    );
  }
}

void _validateFinite({required double value, required String field}) {
  if (!value.isFinite) {
    throw VtkApiValidationException(
      field: field,
      message: 'Value must be finite',
    );
  }
}

void _validateUnitInterval({required double value, required String field}) {
  _validateFinite(value: value, field: field);
  if (value < 0 || value > 1) {
    throw VtkApiValidationException(
      field: field,
      message: 'Value must be between 0 and 1',
    );
  }
}

void _validatePositiveDouble({required double value, required String field}) {
  _validateFinite(value: value, field: field);
  if (value <= 0) {
    throw VtkApiValidationException(
      field: field,
      message: 'Value must be positive',
    );
  }
}

bool _listsEqual<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
