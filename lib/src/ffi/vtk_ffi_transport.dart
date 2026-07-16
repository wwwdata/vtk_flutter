import 'vtk_ffi_transport_base.dart';
import 'vtk_ffi_transport_stub.dart'
    if (dart.library.ffi) 'vtk_ffi_transport_native.dart'
    as implementation;

export 'vtk_ffi_transport_base.dart';

VtkFfiTransport? createDefaultVtkFfiTransport() =>
    implementation.createDefaultVtkFfiTransport();
