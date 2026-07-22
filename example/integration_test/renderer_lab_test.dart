import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vtk_flutter/vtk_flutter.dart';
import 'package:vtk_flutter_example/main.dart';
import 'package:vtk_flutter_example/recipes.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders and switches every supported recipe', (tester) async {
    final runtime = VtkRuntime();
    final capabilities = await runtime.capabilities();
    final supportedRecipes = ShowcaseRecipe.values
        .where((recipe) => recipe.isSupportedBy(capabilities))
        .toList();

    try {
      await tester.pumpWidget(ShowcaseApp(runtime: runtime));
      await _waitForRenderedFrame(tester: tester);

      expect(find.text('vtk_flutter generic showcase'), findsOneWidget);

      var renderedRecipeCount = 0;
      for (final recipe in supportedRecipes) {
        final previousRenderCount = _completedRenderCount(tester);
        final selector = tester.widget<DropdownButtonFormField<ShowcaseRecipe>>(
          find.descendant(
            of: find.byKey(const Key('recipe_selector')),
            matching: find.byType(DropdownButtonFormField<ShowcaseRecipe>),
          ),
        );
        selector.onChanged?.call(recipe);
        await tester.pump();
        await _waitForRenderedFrame(
          tester: tester,
          expectedRecipe: recipe,
          afterRenderCount: previousRenderCount,
        );

        renderedRecipeCount++;
      }

      expect(renderedRecipeCount, supportedRecipes.length);
      expect(renderedRecipeCount, greaterThan(0));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await _within(
        step: 'closing the showcase runtime',
        operation: runtime.close(),
      );
    }
  });

  testWidgets(
    'renders two independent sessions and keeps the survivor usable',
    (tester) async {
      final runtime = VtkRuntime();
      VtkSession? firstSession;
      VtkSession? secondSession;
      try {
        final capabilities = await runtime.capabilities();
        expect(capabilities.supportsRendering, isTrue);

        final openedFirstSession = await _within(
          step: 'opening the first session',
          operation: runtime.openSession(),
        );
        firstSession = openedFirstSession;
        final openedSecondSession = await _within(
          step: 'opening the second session',
          operation: runtime.openSession(),
        );
        secondSession = openedSecondSession;
        expect(openedFirstSession.viewId, isNot(openedSecondSession.viewId));

        final firstRenderer = await openedFirstSession.createRenderer();
        await firstRenderer.setBackground(
          VtkColor(red: 0.75, green: 0.05, blue: 0.05),
        );
        final secondRenderer = await openedSecondSession.createRenderer();
        await secondRenderer.setBackground(
          VtkColor(red: 0.05, green: 0.15, blue: 0.75),
        );
        final viewport = VtkViewport(width: 320, height: 240);

        await tester.pumpWidget(
          MaterialApp(
            home: Row(
              children: [
                Expanded(
                  child: VtkView(
                    key: const Key('first_session_view'),
                    session: openedFirstSession,
                  ),
                ),
                Expanded(
                  child: VtkView(
                    key: const Key('second_session_view'),
                    session: openedSecondSession,
                  ),
                ),
              ],
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(VtkView), findsNWidgets(2));

        final results = await _within(
          step: 'rendering both mounted sessions concurrently',
          operation: Future.wait([
            openedFirstSession.render(
              renderer: firstRenderer,
              viewport: viewport,
            ),
            openedSecondSession.render(
              renderer: secondRenderer,
              viewport: viewport,
            ),
          ]),
        );
        expect(results, everyElement(hasFrameBytes));
        await tester.pump();

        await _within(
          step: 'closing the first session',
          operation: openedFirstSession.close(),
        );
        firstSession = null;
        await secondRenderer.setBackground(
          VtkColor(red: 0.05, green: 0.7, blue: 0.2),
        );
        final survivorResult = await _within(
          step: 'rerendering the surviving session',
          operation: openedSecondSession.render(
            renderer: secondRenderer,
            viewport: viewport,
          ),
        );
        expect(survivorResult, hasFrameBytes);

        await tester.pumpWidget(
          MaterialApp(
            home: VtkView(
              key: const Key('surviving_session_view'),
              session: openedSecondSession,
            ),
          ),
        );
        await tester.pump();
        expect(find.byKey(const Key('surviving_session_view')), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await _within(
          step: 'cleaning up the first session',
          operation: firstSession?.close() ?? Future<void>.value(),
        );
        await _within(
          step: 'cleaning up the second session',
          operation: secondSession?.close() ?? Future<void>.value(),
        );
        await _within(step: 'closing the runtime', operation: runtime.close());
      }
    },
  );
}

final Matcher hasFrameBytes = isA<VtkRenderResult>().having(
  (result) => result.frameBytes,
  'frameBytes',
  greaterThan(0),
);

Future<T> _within<T>({required String step, required Future<T> operation}) =>
    operation.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw TimeoutException('Timed out while $step.'),
    );

Future<void> _waitForRenderedFrame({
  required WidgetTester tester,
  ShowcaseRecipe? expectedRecipe,
  int afterRenderCount = -1,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < timeout) {
    await tester.pump(const Duration(milliseconds: 100));

    final errorFinder = find.byKey(const Key('showcase_error'));
    if (errorFinder.evaluate().isNotEmpty) {
      final messages = tester
          .widgetList<Text>(
            find.descendant(of: errorFinder, matching: find.byType(Text)),
          )
          .map((text) => text.data)
          .whereType<String>()
          .join('\n');
      fail('The real showcase reported an error:\n$messages');
    }

    final frameFinder = find.byKey(const Key('frame_bytes_value'));
    if (find.byKey(const Key('showcase_busy_indicator')).evaluate().isEmpty &&
        find.byKey(const Key('vtk_view')).evaluate().isNotEmpty &&
        frameFinder.evaluate().isNotEmpty) {
      final frameBytes = tester.widget<Text>(frameFinder).data;
      final renderedRecipe = tester
          .widget<Text>(find.byKey(const Key('rendered_recipe_value')))
          .data;
      final renderCount = _completedRenderCount(tester);
      if (frameBytes != null &&
          frameBytes != '—' &&
          frameBytes != '0 B' &&
          renderCount > afterRenderCount &&
          (expectedRecipe == null || renderedRecipe == expectedRecipe.label)) {
        return;
      }
    }
  }

  fail('Timed out waiting for a nonzero rendered frame.');
}

int _completedRenderCount(WidgetTester tester) {
  final value = tester
      .widget<Text>(find.byKey(const Key('completed_render_count')))
      .data;
  return int.parse(value ?? '-1');
}
