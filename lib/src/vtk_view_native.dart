import 'package:flutter/widgets.dart';

import 'renderer.dart';

final class VtkView extends StatelessWidget {
  const VtkView({
    required this.session,
    this.filterQuality = FilterQuality.medium,
    super.key,
  });

  final VtkRenderSession session;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) =>
      Texture(textureId: session.textureId, filterQuality: filterQuality);
}
