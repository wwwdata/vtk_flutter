import 'package:flutter/widgets.dart';

import 'api/vtk_api.dart';

final class VtkView extends StatelessWidget {
  const VtkView({
    required this.session,
    this.filterQuality = FilterQuality.medium,
    super.key,
  });

  final VtkSession session;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) =>
      Texture(textureId: session.viewId, filterQuality: filterQuality);
}
