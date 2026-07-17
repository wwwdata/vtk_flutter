import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vtk_flutter/vtk_flutter.dart';
import 'package:vtk_flutter_example/main.dart';
import 'package:vtk_flutter_example/recipes.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders and switches every supported recipe', (tester) async {
    final capabilityProbe = VtkRuntime();
    final capabilities = await capabilityProbe.capabilities();
    await capabilityProbe.close();
    final supportedRecipes = ShowcaseRecipe.values
        .where((recipe) => recipe.isSupportedBy(capabilities))
        .toList();

    try {
      await tester.pumpWidget(const ShowcaseApp());
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
    }
  });
}

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
