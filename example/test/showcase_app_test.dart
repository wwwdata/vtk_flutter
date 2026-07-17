import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vtk_flutter/src/api/vtk_api.dart';
import 'package:vtk_flutter_example/main.dart';
import 'package:vtk_flutter_example/recipes.dart';

import 'support/recording_vtk_backend.dart';

void main() {
  testWidgets('shows the generic showcase shell', (tester) async {
    final backend = RecordingVtkBackend();
    final runtime = createVtkRuntimeForBackend(backend);

    try {
      await tester.pumpWidget(ShowcaseApp(runtime: runtime));
      await tester.pumpAndSettle();

      expect(find.text('vtk_flutter generic showcase'), findsOneWidget);
      expect(find.text('Recipe'), findsOneWidget);
      expect(find.text('Build pipeline and render'), findsOneWidget);
      expect(find.text('Capabilities'), findsOneWidget);
      expect(find.text('Rendering'), findsOneWidget);
      expect(find.text('Unsigned 16-bit scalars'), findsOneWidget);
      expect(find.text('available'), findsNWidgets(2));
      expect(find.text('Selected recipe'), findsOneWidget);
      expect(find.text('supported'), findsOneWidget);
      expect(find.text('Timing'), findsOneWidget);
      expect(find.text('Pipeline build'), findsOneWidget);
      expect(find.text('VTK render'), findsOneWidget);
      expect(find.text('1.00 ms'), findsOneWidget);
      await _selectRecipe(tester: tester, recipe: .volumeRayCast);
      await _selectRecipe(tester: tester, recipe: .extractedSurface);

      expect(backend.sessions, hasLength(3));
      for (final session in backend.sessions) {
        expect(session.calls, isNotEmpty);
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await runtime.close();
    }

    expect(backend.closeCount, 1);
    expect(
      backend.sessions.map((session) => session.closeCount),
      everyElement(1),
    );
  });
}

Future<void> _selectRecipe({
  required WidgetTester tester,
  required ShowcaseRecipe recipe,
}) async {
  final selector = tester.widget<DropdownButtonFormField<ShowcaseRecipe>>(
    find.descendant(
      of: find.byKey(const Key('recipe_selector')),
      matching: find.byType(DropdownButtonFormField<ShowcaseRecipe>),
    ),
  );
  selector.onChanged?.call(recipe);
  await tester.pumpAndSettle();

  expect(find.text(recipe.label), findsWidgets);
  expect(find.byKey(const Key('showcase_error')), findsNothing);
}
