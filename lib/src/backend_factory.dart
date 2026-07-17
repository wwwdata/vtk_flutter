import 'api/vtk_api.dart';
import 'native_backend.dart'
    if (dart.library.js_interop) 'web/vtk_web_backend.dart'
    as implementation;

VtkBackend createDefaultVtkBackend() =>
    implementation.createDefaultVtkBackend();
