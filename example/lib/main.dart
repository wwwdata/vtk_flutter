import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vtk_flutter/vtk_flutter.dart';

import 'recipes.dart';
import 'scalar_field.dart';

void main() => runApp(const ShowcaseApp());

final class ShowcaseApp extends StatelessWidget {
  const ShowcaseApp({this.runtime, super.key});

  final VtkRuntime? runtime;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'vtk_flutter showcase',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      colorSchemeSeed: const Color(0xff43b5d9),
      useMaterial3: true,
    ),
    home: ShowcasePage(runtime: runtime),
  );
}

final class ShowcasePage extends StatefulWidget {
  const ShowcasePage({this.runtime, super.key});

  final VtkRuntime? runtime;

  @override
  State<ShowcasePage> createState() => _ShowcasePageState();
}

final class _ShowcasePageState extends State<ShowcasePage>
    with WidgetsBindingObserver {
  late final VtkRuntime _runtime;
  late final bool _ownsRuntime;

  VtkCapabilities? _capabilities;
  VtkSession? _session;
  VtkRecipeScene? _scene;
  VtkRenderResult? _renderResult;
  ShowcaseRecipe? _renderedRecipe;
  int _completedRenderCount = 0;
  VtkViewport _viewport = VtkViewport(width: 960, height: 720);
  ShowcaseRecipe _recipe = .obliqueReslice;
  Duration? _pipelineBuildTime;
  String? _error;
  bool _busy = true;
  Timer? _resizeTimer;

  double _resliceAngle = 28;
  double _sliceOffset = 0;
  double _window = 2600;
  double _level = 1450;
  double _parallelScale = 34;

  double _sampleDistance = 0.8;
  double _opacityScale = 1;
  bool _shade = true;

  double _isoValue = 2050;
  bool _smoothing = true;
  double _smoothingIterations = 16;
  double _passBand = 0.12;

  double _azimuth = 32;
  double _elevation = 18;
  double _zoom = 1.25;

  @override
  void initState() {
    super.initState();
    _ownsRuntime = widget.runtime == null;
    _runtime = widget.runtime ?? VtkRuntime();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() => _runOperation(() async {
    final capabilities = await _runtime.capabilities();
    _capabilities = capabilities;
    if (!capabilities.supportsRendering) {
      throw const VtkApiStateException(
        'This backend reports that rendering is unavailable.',
      );
    }
    final supportedRecipes = ShowcaseRecipe.values
        .where((recipe) => recipe.isSupportedBy(capabilities))
        .toList();
    if (supportedRecipes.isEmpty) {
      throw const VtkApiStateException(
        'This backend does not support the objects needed by the showcase.',
      );
    }
    _recipe = supportedRecipes.contains(_recipe)
        ? _recipe
        : supportedRecipes.first;
    if (!capabilities.supportsObject(
      VtkObjectType.windowedSincPolyDataFilter,
    )) {
      _smoothing = false;
    }
    await _replaceSceneAndRender();
  });

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == .resumed && !_busy && _scene != null) {
      unawaited(_runOperation(_renderCurrentScene));
    }
  }

  Future<void> _runOperation(Future<void> Function() operation) async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      await operation();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _replaceSceneAndRender() async {
    final previousSession = _session;
    if (mounted) {
      setState(() {
        _session = null;
        _scene = null;
        _renderResult = null;
        _renderedRecipe = null;
      });
    }
    await previousSession?.close();

    final session = await _runtime.openSession();
    try {
      final image = createSyntheticScalarField();
      final stopwatch = Stopwatch()..start();
      final scene = await switch (_recipe) {
        .obliqueReslice => buildObliqueResliceRecipe(
          session: session,
          image: image,
          settings: ObliqueResliceSettings(
            angleDegrees: _resliceAngle,
            sliceOffset: _sliceOffset,
            window: _window,
            level: _level,
            parallelScale: _parallelScale,
          ),
        ),
        .volumeRayCast => buildVolumeRayCastRecipe(
          session: session,
          image: image,
          settings: VolumeRayCastSettings(
            sampleDistance: _sampleDistance,
            opacityScale: _opacityScale,
            shade: _shade,
            azimuth: _azimuth,
            elevation: _elevation,
            zoom: _zoom,
          ),
        ),
        .extractedSurface => buildExtractedSurfaceRecipe(
          session: session,
          image: image,
          settings: ExtractedSurfaceSettings(
            isoValue: _isoValue,
            smoothing: _smoothing,
            smoothingIterations: _smoothingIterations.round(),
            passBand: _passBand,
            azimuth: _azimuth,
            elevation: _elevation,
            zoom: _zoom,
          ),
        ),
      };
      stopwatch.stop();
      final result = await session.render(
        renderer: scene.renderer,
        viewport: _viewport,
      );
      if (!mounted) {
        await session.close();
        return;
      }
      setState(() {
        _session = session;
        _scene = scene;
        _pipelineBuildTime = stopwatch.elapsed;
        _renderResult = result;
        _renderedRecipe = _recipe;
        _completedRenderCount++;
      });
    } on Object {
      await session.close();
      rethrow;
    }
  }

  Future<void> _renderCurrentScene() async {
    final session = _session;
    final scene = _scene;
    if (session == null || scene == null) return;
    final result = await session.render(
      renderer: scene.renderer,
      viewport: _viewport,
    );
    if (mounted) {
      setState(() {
        _renderResult = result;
        _renderedRecipe = _recipe;
        _completedRenderCount++;
      });
    }
  }

  Future<void> _resizeAndRender(VtkViewport viewport) async {
    final session = _session;
    final scene = _scene;
    if (session == null || scene == null) return;
    final result = await session.render(
      renderer: scene.renderer,
      viewport: viewport,
    );
    if (mounted) {
      setState(() {
        _viewport = viewport;
        _renderResult = result;
        _renderedRecipe = _recipe;
        _completedRenderCount++;
      });
    }
  }

  void _scheduleResize({
    required BoxConstraints constraints,
    required double pixelRatio,
  }) {
    if (!constraints.hasBoundedWidth ||
        !constraints.hasBoundedHeight ||
        constraints.maxWidth <= 0 ||
        constraints.maxHeight <= 0) {
      return;
    }
    final width = (constraints.maxWidth * pixelRatio)
        .round()
        .clamp(1, 2048)
        .toInt();
    final height = (constraints.maxHeight * pixelRatio)
        .round()
        .clamp(1, 2048)
        .toInt();
    final next = VtkViewport(width: width, height: height);
    if (next == _viewport) return;

    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 140), () {
      if (!mounted || _busy) return;
      unawaited(_runOperation(() => _resizeAndRender(next)));
    });
  }

  void _rebuildAfterChange() {
    if (!_busy) unawaited(_runOperation(_replaceSceneAndRender));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resizeTimer?.cancel();
    unawaited(_closeOwnedResources());
    super.dispose();
  }

  Future<void> _closeOwnedResources() async {
    try {
      if (_ownsRuntime) {
        await _runtime.close();
      } else {
        await _session?.close();
      }
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'vtk_flutter example',
          context: ErrorDescription('while closing showcase resources'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('vtk_flutter generic showcase'),
      actions: [
        IconButton(
          tooltip: 'Render current scene',
          onPressed: _busy || _scene == null
              ? null
              : () => unawaited(_runOperation(_renderCurrentScene)),
          icon: const Icon(Icons.refresh),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18),
            child: Center(
              child: SizedBox.square(
                key: Key('showcase_busy_indicator'),
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
      ],
    ),
    body: LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 900) {
          return Column(
            children: [
              SizedBox(
                height: constraints.maxHeight * 0.5,
                child: _buildViewer(),
              ),
              Expanded(child: _buildControls()),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: _buildViewer()),
            SizedBox(width: 390, child: _buildControls()),
          ],
        );
      },
    ),
  );

  Widget _buildViewer() => Padding(
    padding: const EdgeInsets.all(16),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: Colors.white12),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            _scheduleResize(
              constraints: constraints,
              pixelRatio: MediaQuery.devicePixelRatioOf(context),
            );
            return Stack(
              fit: StackFit.expand,
              children: [
                if (_session case final session?)
                  VtkView(key: const Key('vtk_view'), session: session)
                else
                  const _CenteredMessage(message: 'Preparing VTK scene…'),
                if (_error case final error?)
                  ColoredBox(
                    key: const Key('showcase_error'),
                    color: Colors.black87,
                    child: _CenteredMessage(
                      message: error,
                      color: Colors.orangeAccent,
                    ),
                  ),
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Text(
                        '${_renderedRecipe?.label ?? 'Preparing'}  •  '
                        '${_viewport.width} × ${_viewport.height}',
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _buildControls() => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(8, 8, 16, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeyedSubtree(
          key: const Key('recipe_selector'),
          child: DropdownButtonFormField<ShowcaseRecipe>(
            key: ValueKey(_recipe),
            initialValue: _recipe,
            decoration: const InputDecoration(
              labelText: 'Recipe',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final recipe in ShowcaseRecipe.values)
                DropdownMenuItem(
                  key: Key('recipe_option_${recipe.name}'),
                  value: recipe,
                  enabled:
                      _capabilities == null ||
                      recipe.isSupportedBy(_capabilities!),
                  child: Text(recipe.label),
                ),
            ],
            onChanged: _busy
                ? null
                : (recipe) {
                    if (recipe == null || recipe == _recipe) return;
                    setState(() => _recipe = recipe);
                    _rebuildAfterChange();
                  },
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _recipeDescription(),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        ..._recipeControls(),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy
              ? null
              : () => unawaited(_runOperation(_replaceSceneAndRender)),
          icon: const Icon(Icons.play_arrow),
          label: const Text('Build pipeline and render'),
        ),
        const SizedBox(height: 16),
        _buildCapabilitiesCard(),
        const SizedBox(height: 12),
        _buildTimingCard(),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(_error!),
            ),
          ),
        ],
      ],
    ),
  );

  String _recipeDescription() => switch (_recipe) {
    .obliqueReslice =>
      'ImageReslice → window/level colors → image mapper → image actor',
    .volumeRayCast =>
      'Smart volume mapper → color and opacity transfer functions → volume',
    .extractedSurface =>
      'FlyingEdges3D → connectivity → optional smoothing → mapper → actor',
  };

  List<Widget> _recipeControls() => switch (_recipe) {
    .obliqueReslice => [
      _slider(
        label: 'Reslice angle',
        value: _resliceAngle,
        minimum: -80,
        maximum: 80,
        suffix: '°',
        onChanged: (value) => _resliceAngle = value,
      ),
      _slider(
        label: 'Slice offset',
        value: _sliceOffset,
        minimum: -20,
        maximum: 20,
        onChanged: (value) => _sliceOffset = value,
      ),
      _slider(
        label: 'Window',
        value: _window,
        minimum: 100,
        maximum: 4095,
        onChanged: (value) => _window = value,
      ),
      _slider(
        label: 'Level',
        value: _level,
        minimum: 0,
        maximum: 4095,
        onChanged: (value) => _level = value,
      ),
      _slider(
        label: 'Parallel scale',
        value: _parallelScale,
        minimum: 18,
        maximum: 70,
        onChanged: (value) => _parallelScale = value,
      ),
    ],
    .volumeRayCast => [
      _slider(
        label: 'Sample distance',
        value: _sampleDistance,
        minimum: 0.3,
        maximum: 2,
        onChanged: (value) => _sampleDistance = value,
      ),
      _slider(
        label: 'Opacity scale',
        value: _opacityScale,
        minimum: 0.2,
        maximum: 1.4,
        onChanged: (value) => _opacityScale = value,
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Shading'),
        value: _shade,
        onChanged: _busy
            ? null
            : (value) {
                setState(() => _shade = value);
                _rebuildAfterChange();
              },
      ),
      ..._cameraControls(),
    ],
    .extractedSurface => [
      _slider(
        label: 'Iso value',
        value: _isoValue,
        minimum: 300,
        maximum: 3900,
        onChanged: (value) => _isoValue = value,
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Windowed-sinc smoothing'),
        subtitle: _supportsSmoothing
            ? null
            : const Text('Not reported by this backend'),
        value: _smoothing && _supportsSmoothing,
        onChanged: _busy || !_supportsSmoothing
            ? null
            : (value) {
                setState(() => _smoothing = value);
                _rebuildAfterChange();
              },
      ),
      if (_smoothing && _supportsSmoothing) ...[
        _slider(
          label: 'Smoothing iterations',
          value: _smoothingIterations,
          minimum: 0,
          maximum: 40,
          fractionDigits: 0,
          onChanged: (value) => _smoothingIterations = value,
        ),
        _slider(
          label: 'Pass band',
          value: _passBand,
          minimum: 0.02,
          maximum: 0.5,
          fractionDigits: 2,
          onChanged: (value) => _passBand = value,
        ),
      ],
      ..._cameraControls(),
    ],
  };

  List<Widget> _cameraControls() => [
    _slider(
      label: 'Camera azimuth',
      value: _azimuth,
      minimum: -180,
      maximum: 180,
      suffix: '°',
      onChanged: (value) => _azimuth = value,
    ),
    _slider(
      label: 'Camera elevation',
      value: _elevation,
      minimum: -80,
      maximum: 80,
      suffix: '°',
      onChanged: (value) => _elevation = value,
    ),
    _slider(
      label: 'Camera zoom',
      value: _zoom,
      minimum: 0.55,
      maximum: 2.5,
      onChanged: (value) => _zoom = value,
    ),
  ];

  Widget _slider({
    required String label,
    required double value,
    required double minimum,
    required double maximum,
    required ValueChanged<double> onChanged,
    String suffix = '',
    int fractionDigits = 1,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$label: ${value.toStringAsFixed(fractionDigits)}$suffix'),
      Slider(
        value: value.clamp(minimum, maximum),
        min: minimum,
        max: maximum,
        onChanged: _busy ? null : (next) => setState(() => onChanged(next)),
        onChangeEnd: _busy ? null : (_) => _rebuildAfterChange(),
      ),
    ],
  );

  bool get _supportsSmoothing =>
      _capabilities?.supportsObject(VtkObjectType.windowedSincPolyDataFilter) ??
      false;

  Widget _buildCapabilitiesCard() {
    final capabilities = _capabilities;
    final selectedSupported =
        capabilities != null && _recipe.isSupportedBy(capabilities);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Capabilities',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            _infoRow(
              label: 'Rendering',
              value: _availability(capabilities?.supportsRendering),
            ),
            _infoRow(
              label: 'Unsigned 16-bit scalars',
              value: _availability(
                capabilities?.supportsScalarType(VtkScalarType.uint16),
              ),
            ),
            _infoRow(
              label: 'Typed objects',
              value: capabilities == null
                  ? 'loading'
                  : '${capabilities.supportedObjectTypes.length}',
            ),
            _infoRow(
              label: 'Selected recipe',
              value: capabilities == null
                  ? 'loading'
                  : selectedSupported
                  ? 'supported'
                  : 'unavailable',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimingCard() {
    final result = _renderResult;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Timing', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _infoRow(
              label: 'Pipeline build',
              value: _duration(_pipelineBuildTime),
            ),
            _infoRow(label: 'VTK render', value: _duration(result?.renderTime)),
            _infoRow(
              label: 'Surface submit',
              value: _duration(result?.surfaceSubmitTime),
            ),
            _infoRow(
              label: 'GPU sync wait',
              value: _duration(result?.gpuSyncWaitTime),
            ),
            _infoRow(
              label: 'CPU readback',
              value: _duration(result?.cpuReadbackTime),
            ),
            _infoRow(
              label: 'Frame bytes',
              value: result == null ? '—' : _bytes(result.frameBytes),
              valueKey: const Key('frame_bytes_value'),
            ),
            _infoRow(
              label: 'Rendered recipe',
              value: _renderedRecipe?.label ?? '—',
              valueKey: const Key('rendered_recipe_value'),
            ),
            _infoRow(
              label: 'Completed renders',
              value: '$_completedRenderCount',
              valueKey: const Key('completed_render_count'),
            ),
            _infoRow(
              label: 'Surface allocation',
              value: result == null
                  ? '—'
                  : _bytes(result.surfaceAllocationBytes),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow({
    required String label,
    required String value,
    Key? valueKey,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ),
        Flexible(
          child: Text(value, key: valueKey, textAlign: TextAlign.end),
        ),
      ],
    ),
  );

  String _duration(Duration? duration) {
    if (duration == null) return '—';
    if (duration.inMicroseconds < 1000) {
      return '${duration.inMicroseconds} µs';
    }
    return '${(duration.inMicroseconds / 1000).toStringAsFixed(2)} ms';
  }

  String _availability(bool? available) => switch (available) {
    null => 'loading',
    true => 'available',
    false => 'unavailable',
  };

  String _bytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB';
  }
}

final class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.message, this.color});

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
