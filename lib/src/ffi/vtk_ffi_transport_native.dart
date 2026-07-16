import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../exceptions.dart';
import '../models.dart';
import 'vtk_ffi_transport_base.dart';
import 'vtk_flutter_bindings.g.dart';

VtkFfiTransport createDefaultVtkFfiTransport() => VtkNativeFfiTransport();

final class VtkNativeFfiTransport implements VtkFfiTransport {
  VtkFlutterBindings? _loadedBindings;

  @override
  Future<void> setVolume({
    required int sessionAddress,
    required VtkVolume volume,
  }) async {
    final nativeVolume = calloc<VtkFlutterVolume>();
    final voxels = calloc<Int16>(volume.voxelCount);
    final status = calloc<VtkFlutterStatus>();
    try {
      voxels.cast<Uint8>().asTypedList(volume.byteCount).setAll(0, volume.data);
      nativeVolume.ref
        ..voxels = voxels
        ..voxel_count = volume.voxelCount
        ..width = volume.dimensions[0]
        ..height = volume.dimensions[1]
        ..depth = volume.dimensions[2];
      for (var index = 0; index < volume.affine.length; index++) {
        nativeVolume.ref.index_to_patient[index] = volume.affine[index];
      }

      final result = _bindings.vtk_flutter_session_set_volume(
        Pointer<VtkFlutterSession>.fromAddress(sessionAddress),
        nativeVolume,
        status,
      );
      _throwIfFailed(result: result, status: status);
    } finally {
      calloc.free(status);
      calloc.free(voxels);
      calloc.free(nativeVolume);
    }
  }

  @override
  Future<VtkFrameMetrics> render({
    required int sessionAddress,
    required int textureId,
    required VtkViewport viewport,
    required VtkRenderRequest request,
  }) async {
    final nativeRequest = calloc<VtkFlutterRenderRequest>();
    final metrics = calloc<VtkFlutterMetrics>();
    final status = calloc<VtkFlutterStatus>();
    try {
      _writeRequest(
        target: nativeRequest,
        viewport: viewport,
        request: request,
      );
      final result = _bindings.vtk_flutter_session_render(
        Pointer<VtkFlutterSession>.fromAddress(sessionAddress),
        nativeRequest,
        metrics,
        status,
      );
      _throwIfFailed(result: result, status: status);
      return _readMetrics(textureId: textureId, metrics: metrics.ref);
    } finally {
      calloc.free(status);
      calloc.free(metrics);
      calloc.free(nativeRequest);
    }
  }

  VtkFlutterBindings get _bindings {
    final existing = _loadedBindings;
    if (existing != null) return existing;
    try {
      final bindings = VtkFlutterBindings(_openLibrary());
      final version = bindings.vtk_flutter_abi_version();
      if (version != VTK_FLUTTER_ABI_VERSION) {
        throw VtkPlatformException(
          code: 'ffi_abi',
          message:
              'Unsupported VTK ABI $version; expected '
              '$VTK_FLUTTER_ABI_VERSION',
        );
      }
      return _loadedBindings = bindings;
    } on VtkException {
      rethrow;
    } on Object catch (error) {
      throw VtkPlatformException(
        code: 'ffi_load',
        message: 'Unable to load the native VTK library: $error',
      );
    }
  }
}

DynamicLibrary _openLibrary() {
  if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();
  if (Platform.isAndroid) return DynamicLibrary.open('libvtk_flutter.so');
  if (Platform.isWindows) {
    return DynamicLibrary.open('vtk_flutter_plugin.dll');
  }
  throw const VtkPlatformException(
    code: 'ffi_unsupported',
    message: 'Native VTK FFI is unsupported on this platform',
  );
}

void _writeRequest({
  required Pointer<VtkFlutterRenderRequest> target,
  required VtkViewport viewport,
  required VtkRenderRequest request,
}) {
  target.ref
    ..mode = request.mode.index + 1
    ..window_center = 400
    ..window_width = 1800
    ..camera_zoom = 1;
  target.ref.viewport
    ..width = viewport.width
    ..height = viewport.height;
  target.ref.plane_normal[2] = 1;

  switch (request) {
    case VtkObliqueMprRequest(
      :final windowCenter,
      :final windowWidth,
      :final origin,
      :final normal,
    ):
      target.ref
        ..window_center = windowCenter
        ..window_width = windowWidth;
      for (var index = 0; index < 3; index++) {
        target.ref.plane_origin[index] = origin[index];
        target.ref.plane_normal[index] = normal[index];
      }
    case VtkVolume3dRequest(
      :final windowCenter,
      :final windowWidth,
      :final azimuth,
      :final elevation,
      :final zoom,
    ):
      target.ref
        ..window_center = windowCenter
        ..window_width = windowWidth
        ..camera_azimuth_degrees = azimuth
        ..camera_elevation_degrees = elevation
        ..camera_zoom = zoom;
    case VtkVolumeLocatorRequest(:final azimuth, :final elevation, :final zoom):
      target.ref
        ..camera_azimuth_degrees = azimuth
        ..camera_elevation_degrees = elevation
        ..camera_zoom = zoom;
  }
}

VtkFrameMetrics _readMetrics({
  required int textureId,
  required VtkFlutterMetrics metrics,
}) {
  final contentEvidence = metrics.surface_unique_byte_values == 0
      ? null
      : VtkFrameContentEvidence(
          fingerprint:
              'fnv1a64-rgba-v1:'
              '${metrics.surface_checksum.toUnsigned(64).toRadixString(16).padLeft(16, '0')}',
          changedPixelCount: metrics.surface_changed_pixels,
          uniqueByteValueCount: metrics.surface_unique_byte_values,
        );
  return VtkFrameMetrics(
    textureId: textureId,
    width: metrics.frame_width,
    height: metrics.frame_height,
    volumeBytes: metrics.volume_bytes,
    frameBytes: metrics.frame_bytes,
    residentBytes: metrics.volume_bytes + metrics.surface_allocation_bytes,
    renderMicroseconds: (metrics.render_ms * 1000).round(),
    blitSubmitMicroseconds: (metrics.surface_submit_ms * 1000).round(),
    gpuSyncWaitMicroseconds: (metrics.gpu_sync_wait_ms * 1000).round(),
    readbackMicroseconds: (metrics.cpu_readback_ms * 1000).round(),
    frameId: 0,
    presentedFrameCount: 0,
    presentedFrameId: 0,
    graphicsContextGeneration: 0,
    handoffMode: 'ffi',
    contentEvidence: contentEvidence,
    patientToClip: metrics.patient_to_clip_valid == 0
        ? null
        : [
            for (var index = 0; index < 16; index++)
              metrics.patient_to_clip[index],
          ],
  );
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
  throw VtkPlatformException(
    code: 'ffi_$result',
    message: messageBytes.isEmpty
        ? 'Native VTK operation failed'
        : String.fromCharCodes(messageBytes),
  );
}
