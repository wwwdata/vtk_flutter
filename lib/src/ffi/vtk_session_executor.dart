import 'vtk_session_executor_base.dart';
import 'vtk_session_executor_stub.dart'
    if (dart.library.ffi) 'vtk_session_executor_native.dart'
    as implementation;

export 'vtk_session_executor_base.dart';

VtkSessionExecutorFactory? createDefaultVtkSessionExecutorFactory() =>
    implementation.createDefaultVtkSessionExecutorFactory();
