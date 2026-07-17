import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// Flutter web plugin registration is intentionally passive.
///
/// The generic runtime selects its vtk.js backend through the conditional
/// backend factory; this shim exists only for Flutter's generated registrant.
final class VtkFlutterWeb {
  static void registerWith(Registrar registrar) {}
}
