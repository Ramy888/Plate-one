import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plateone/ui/widgets/common.dart';
import 'package:plateone/data/catalog.dart';
import 'package:plateone/data/patch_images.dart';
import 'package:plateone/data/prefs_repository.dart';
import 'package:plateone/domain/models.dart';
import 'package:plateone/state/providers.dart';
import 'package:plateone/ui/saved_screen.dart';
import 'package:plateone/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Catalog _realCatalog() {
  List<T> parse<T>(String name, T Function(Map<String, dynamic>) fromJson) =>
      (jsonDecode(File('assets/data/$name.json').readAsStringSync()) as List<dynamic>)
          .map((j) => fromJson(j as Map<String, dynamic>))
          .toList();
  return Catalog(
    foods: parse('foods', FoodItem.fromJson),
    additions: parse('additions', Addition.fromJson),
  );
}

/// The smallest valid PNG, so Image.memory has something real to decode.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
  0x89, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
  0x42, 0x60, 0x82,
]);

SavedPatch _patch({String id = 'sp1', String? imagePath}) => SavedPatch(
      id: id,
      savedAt: DateTime.now(),
      slot: MealSlot.lunchDinner,
      foodIds: const ['white_rice', 'chicken'],
      additionId: 'side_salad',
      additionName: 'Add a side salad',
      additionEmoji: '🥗',
      gapIds: const ['fibre'],
      imagePath: imagePath,
    );

Future<(ProviderContainer, MemoryPatchImages)> _pump(
  WidgetTester tester, {
  required List<SavedPatch> history,
  Map<String, Uint8List> images = const {},
}) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({
    'onboarded': true,
    'history': history.map((p) => jsonEncode(p.toJson())).toList(),
  });
  final repo = PrefsRepository(await SharedPreferences.getInstance());
  final store = MemoryPatchImages();
  for (final entry in images.entries) {
    await store.put(entry.key.replaceAll('.jpg', ''), entry.value);
  }

  final container = ProviderContainer(
    overrides: [
      prefsRepositoryProvider.overrideWithValue(repo),
      patchImagesProvider.overrideWithValue(store),
      catalogProvider.overrideWithValue(_realCatalog()),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: buildTheme(), home: const SavedScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return (container, store);
}

void main() {
  testWidgets('a saved row shows the plate that was drawn', (tester) async {
    await _pump(
      tester,
      history: [_patch(imagePath: 'sp1.jpg')],
      images: {'sp1.jpg': _png},
    );
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('a row saved before pictures falls back to the glyph',
      (tester) async {
    await _pump(tester, history: [_patch()]);
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNothing);
    expect(find.text('Add a side salad'), findsOneWidget);
  });

  testWidgets('tapping a saved row opens its details', (tester) async {
    await _pump(tester, history: [_patch()]);

    await tester.tap(find.text('Add a side salad'));
    await tester.pumpAndSettle();

    expect(find.text('Saved patch'), findsOneWidget);
    // The addition is the headline there too, not buried in a picture.
    expect(
      find.descendant(
        of: find.byType(PatchHighlight),
        matching: find.text('Add a side salad'),
      ),
      findsOneWidget,
    );
    // And what was on the plate is named.
    expect(find.text('Rice'), findsOneWidget);
    expect(find.text('Chicken'), findsOneWidget);
  });

  testWidgets('removing a patch takes its picture with it', (tester) async {
    final (container, store) = await _pump(
      tester,
      history: [_patch(imagePath: 'sp1.jpg')],
      images: {'sp1.jpg': _png},
    );

    await container.read(historyProvider.notifier).remove('sp1');

    expect(await store.get('sp1.jpg'), isNull);
    expect(container.read(historyProvider), isEmpty);
  });

  testWidgets('clearing the history clears every picture', (tester) async {
    final (container, store) = await _pump(
      tester,
      history: [_patch(imagePath: 'sp1.jpg')],
      images: {'sp1.jpg': _png},
    );

    await container.read(historyProvider.notifier).clear();

    expect(await store.get('sp1.jpg'), isNull);
  });
}
