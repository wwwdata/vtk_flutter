import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vtk_flutter/vtk_flutter.dart';

import 'synthetic_volume.dart';

void main() => runApp(const RendererLabApp());

final class RendererLabApp extends StatelessWidget {
  const RendererLabApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'vtk_flutter renderer lab',
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff55b6d9),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xff0b1017),
    ),
    home: const RendererLabPage(),
  );
}

final class RendererLabPage extends StatefulWidget {
  const RendererLabPage({super.key});

  @override
  State<RendererLabPage> createState() => _RendererLabPageState();
}

final class _RendererLabPageState extends State<RendererLabPage>
    with WidgetsBindingObserver {
  final _renderer = VtkRenderer();

  VtkCapabilities? _capabilities;
  VtkRenderSession? _session;
  VtkFrameMetrics? _metrics;
  VtkViewport _viewport = VtkViewport(width: 640, height: 360);
  VtkRenderMode _mode = .obliqueMpr;
  String? _error;
  bool _busy = true;
  double _windowCenter = 350;
  double _windowWidth = 1800;
  double _planePosition = 0;
  double _planeAngle = 20;
  double _azimuth = 35;
  double _elevation = 20;
  double _zoom = 1.35;
  Timer? _resizeTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == .resumed && _session != null) unawaited(_render());
  }

  Future<void> _initialize() async {
    await _guard(() async {
      final capabilities = await _renderer.capabilities();
      if (!capabilities.isSupported) {
        throw const VtkPlatformException(
          code: 'unsupported',
          message: 'This platform does not expose a VTK renderer.',
        );
      }
      _mode = VtkRenderMode.values.firstWhere(
        capabilities.renderModes.contains,
      );
      final session = await _renderer.open(_viewport);
      await session.setVolume(createSyntheticVolume());
      if (!mounted) {
        await session.close();
        return;
      }
      setState(() {
        _capabilities = capabilities;
        _session = session;
      });
      await _render();
    });
  }

  Future<void> _render() async {
    final session = _session;
    if (session == null) return;
    await _guard(() async {
      final metrics = await session.render(_request());
      if (mounted) setState(() => _metrics = metrics);
    });
  }

  Future<void> _replaceVolume() async {
    final session = _session;
    if (session == null) return;
    await _guard(() async {
      await session.setVolume(createSyntheticVolume(markerOffset: 7));
      await _render();
    });
  }

  Future<void> _recreateSession() async {
    await _guard(() async {
      await _session?.close();
      if (mounted) setState(() => _session = null);
      final session = await _renderer.open(_viewport);
      await session.setVolume(createSyntheticVolume());
      if (!mounted) {
        await session.close();
        return;
      }
      setState(() => _session = session);
      await _render();
    });
  }

  Future<void> _recreateContext() async {
    final session = _session;
    if (session == null) return;
    await _guard(() async {
      await session.recreateGraphicsContext();
      await _render();
    });
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      await action();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  VtkRenderRequest _request() => switch (_mode) {
    .obliqueMpr => VtkObliqueMprRequest(
      windowCenter: _windowCenter,
      windowWidth: _windowWidth,
      origin: [0, 0, _planePosition],
      normal: [0, math.sin(_planeAngle * math.pi / 180), 1],
    ),
    .volume3d => VtkVolume3dRequest(
      windowCenter: _windowCenter,
      windowWidth: _windowWidth,
      azimuth: _azimuth,
      elevation: _elevation,
      zoom: _zoom,
    ),
    .volumeLocator => VtkVolumeLocatorRequest(
      azimuth: _azimuth,
      elevation: _elevation,
      zoom: _zoom,
    ),
  };

  void _scheduleResize(BoxConstraints constraints) {
    final width = math.max(1, constraints.maxWidth.round());
    final height = math.max(1, constraints.maxHeight.round());
    if (width == _viewport.width && height == _viewport.height) return;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 120), () async {
      final session = _session;
      if (!mounted || session == null) return;
      final viewport = VtkViewport(width: width, height: height);
      await _guard(() async {
        await session.resize(viewport);
        _viewport = viewport;
        await _render();
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resizeTimer?.cancel();
    unawaited(_session?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('vtk_flutter renderer lab'),
      actions: [
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(16),
            child: SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    ),
    body: LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 800) {
          return Column(
            children: [
              SizedBox(
                height: math.min(360, constraints.maxHeight * 0.48),
                child: _rendererPane(),
              ),
              Expanded(
                child: _controls(const EdgeInsets.fromLTRB(16, 0, 16, 16)),
              ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: _rendererPane()),
            SizedBox(
              width: 360,
              child: _controls(const EdgeInsets.fromLTRB(0, 16, 16, 16)),
            ),
          ],
        );
      },
    ),
  );

  Widget _rendererPane() => Padding(
    padding: const EdgeInsets.all(16),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: Colors.white12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            _scheduleResize(constraints);
            final session = _session;
            if (_error case final error?) {
              return _Message(message: error, color: Colors.orange);
            }
            if (session == null) {
              return const _Message(message: 'Opening VTK session…');
            }
            return VtkView(session: session);
          },
        ),
      ),
    ),
  );

  Widget _controls(EdgeInsets padding) => SingleChildScrollView(
    padding: padding,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ModeSelector(
          capabilities: _capabilities,
          selected: _mode,
          onChanged: (mode) {
            setState(() => _mode = mode);
            unawaited(_render());
          },
        ),
        const SizedBox(height: 16),
        _slider(
          label: 'Window center',
          value: _windowCenter,
          minimum: -1000,
          maximum: 2000,
          onChanged: (value) => _windowCenter = value,
        ),
        _slider(
          label: 'Window width',
          value: _windowWidth,
          minimum: 1,
          maximum: 4000,
          onChanged: (value) => _windowWidth = value,
        ),
        if (_mode == .obliqueMpr) ...[
          _slider(
            label: 'Plane position',
            value: _planePosition,
            minimum: -60,
            maximum: 60,
            onChanged: (value) => _planePosition = value,
          ),
          _slider(
            label: 'Plane angle',
            value: _planeAngle,
            minimum: -80,
            maximum: 80,
            onChanged: (value) => _planeAngle = value,
          ),
        ] else ...[
          _slider(
            label: 'Azimuth',
            value: _azimuth,
            minimum: -180,
            maximum: 180,
            onChanged: (value) => _azimuth = value,
          ),
          _slider(
            label: 'Elevation',
            value: _elevation,
            minimum: -80,
            maximum: 80,
            onChanged: (value) => _elevation = value,
          ),
          _slider(
            label: 'Zoom',
            value: _zoom,
            minimum: 0.5,
            maximum: 4,
            onChanged: (value) => _zoom = value,
          ),
        ],
        FilledButton(
          onPressed: _busy ? null : _render,
          child: const Text('Render'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _busy ? null : _replaceVolume,
          child: const Text('Replace synthetic volume'),
        ),
        OutlinedButton(
          onPressed: _busy ? null : _recreateSession,
          child: const Text('Dispose and recreate session'),
        ),
        if (!kIsWeb)
          OutlinedButton(
            onPressed: _busy ? null : _recreateContext,
            child: const Text('Recreate graphics context'),
          ),
        const SizedBox(height: 16),
        _MetricsPanel(metrics: _metrics, viewport: _viewport),
      ],
    ),
  );

  Widget _slider({
    required String label,
    required double value,
    required double minimum,
    required double maximum,
    required ValueChanged<double> onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$label: ${value.toStringAsFixed(1)}'),
      Slider(
        value: value.clamp(minimum, maximum),
        min: minimum,
        max: maximum,
        onChanged: (next) => setState(() => onChanged(next)),
        onChangeEnd: (_) => unawaited(_render()),
      ),
    ],
  );
}

final class _ModeSelector extends StatelessWidget {
  const _ModeSelector({
    required this.capabilities,
    required this.selected,
    required this.onChanged,
  });

  final VtkCapabilities? capabilities;
  final VtkRenderMode selected;
  final ValueChanged<VtkRenderMode> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<VtkRenderMode>(
    segments: [
      for (final mode in VtkRenderMode.values)
        ButtonSegment(
          value: mode,
          label: Text(switch (mode) {
            .obliqueMpr => 'MPR',
            .volume3d => '3D',
            .volumeLocator => 'Locator',
          }),
          enabled: capabilities?.renderModes.contains(mode) ?? false,
        ),
    ],
    selected: {selected},
    onSelectionChanged: (selection) => onChanged(selection.single),
  );
}

final class _MetricsPanel extends StatelessWidget {
  const _MetricsPanel({required this.metrics, required this.viewport});

  final VtkFrameMetrics? metrics;
  final VtkViewport viewport;

  @override
  Widget build(BuildContext context) {
    final value = metrics;
    final rows = <(String, String)>[
      ('Viewport', '${viewport.width} × ${viewport.height}'),
      if (value != null) ...[
        ('Handoff', value.handoffMode),
        ('Render', '${value.renderMicroseconds} µs'),
        ('Blit submit', '${value.blitSubmitMicroseconds} µs'),
        ('GPU sync', '${value.gpuSyncWaitMicroseconds} µs'),
        ('Readback', '${value.readbackMicroseconds} µs'),
        ('Resident', _bytes(value.residentBytes)),
        ('Frame', '${value.frameId} / presented ${value.presentedFrameId}'),
        ('Context generation', '${value.graphicsContextGeneration}'),
        ('Fingerprint', value.contentEvidence?.fingerprint ?? 'not reported'),
        ('Patient projection', value.patientToClip == null ? 'none' : '4 × 4'),
      ],
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Diagnostics', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: const TextStyle(color: Colors.white60),
                      ),
                    ),
                    Flexible(child: Text(value, textAlign: TextAlign.end)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _bytes(int bytes) =>
      '${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB';
}

final class _Message extends StatelessWidget {
  const _Message({required this.message, this.color});

  final String message;
  final Color? color;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(color: color),
      ),
    ),
  );
}
