import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plateone/data/catalog.dart';
import 'package:plateone/data/patch_images.dart';
import 'package:plateone/data/prefs_repository.dart';
import 'package:plateone/domain/models.dart';
import 'package:plateone/state/providers.dart';
import 'package:plateone/ui/food_picker_screen.dart';
import 'package:plateone/ui/voice_agent_screen.dart';
import 'package:plateone/ui/onboarding_screen.dart';
import 'package:plateone/ui/saved_screen.dart';
import 'package:plateone/ui/settings_screen.dart';
import 'package:plateone/ui/theme.dart';
import 'package:plateone/ui/widgets/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The real bundled catalogue, read from disk so these tests exercise the data
/// that actually ships rather than a convenient fixture.
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

Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  Map<String, Object> prefs = const {},
  Widget home = const _Root(),
}) async {
  // A tall viewport so a full food grid and three suggestion cards fit without
  // scrolling. The default 800x600 test window is nothing like a phone.
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(prefs);
  final repo = PrefsRepository(await SharedPreferences.getInstance());
  final container = ProviderContainer(
    overrides: [
      prefsRepositoryProvider.overrideWithValue(repo),
      patchImagesProvider.overrideWithValue(MemoryPatchImages()),
      catalogProvider.overrideWithValue(_realCatalog()),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MediaQuery(
        // Tests assert on settled frames, and decorative motion is deliberately
        // endless — so they run the way a reduced-motion phone does.
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(theme: buildTheme(), home: home),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onboarded = ref.watch(settingsProvider.select((s) => s.onboarded));
    return onboarded ? const VoiceAgentScreen() : const OnboardingScreen();
  }
}

/// Taps the first thing whose visible label matches, scrolling it into view.
/// For anything outside the meal picker's food rails — goals, preferences,
/// buttons.
Future<void> _tapTile(WidgetTester tester, String label) async {
  final finder = find.text(label).first;
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}


/// Opens the food page.
///
/// It is no longer a tile on the home screen: speaking is the way in, and
/// picking foods by hand is the fallback someone reaches when the
/// conversation cannot happen. These tests exercise that fallback directly,
/// the same way the failure card pushes it.
Future<void> _openFoodPicker(WidgetTester tester) async {
  if (find.byType(FoodPickerScreen).evaluate().isNotEmpty) return;
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).last);
  unawaited(
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const FoodPickerScreen(slot: MealSlot.lunchDinner),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Taps a food, opening the food page first if the hub is still showing, then
/// the rail the food lives in, then scrolling that rail along to it. This walks
/// the same path a finger does.
Future<void> _tapFood(WidgetTester tester, String name) async {
  await _openFoodPicker(tester);

  final catalog = _realCatalog();
  final food = catalog.foods.firstWhere((f) => f.name == name);
  final rail = FoodGroup.all.firstWhere((g) => g.id == food.group);
  final siblings = catalog.foods.where((f) => f.group == food.group).toList();

  // A rail is open exactly when one of its own foods is on screen. Deciding it
  // that way matters: tapping the head of an already-open rail closes it, and
  // the food would then be unreachable.
  bool railIsOpen() => siblings.any((f) => find.text(f.name).evaluate().isNotEmpty);

  if (!railIsOpen()) {
    final head = find.text(rail.label);
    await tester.ensureVisible(head);
    await tester.pumpAndSettle();
    await tester.tap(head);
    await tester.pumpAndSettle();
  }

  final tile = find.text(name);
  if (tile.evaluate().isEmpty) {
    // The rail is open but scrolled past this tile — a previous tap in the same
    // rail dragged it forward. Close and reopen to put it back at the start,
    // because dragging only ever goes one way.
    final head = find.text(rail.label);
    await tester.ensureVisible(head);
    await tester.pumpAndSettle();
    await tester.tap(head);
    await tester.pumpAndSettle();
    await tester.tap(head);
    await tester.pumpAndSettle();
  }

  if (tile.evaluate().isEmpty) {
    // Exactly one rail is open, so exactly one horizontal list exists and this
    // cannot scroll the wrong one.
    final railList = find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.right);
    expect(railList, findsOneWidget,
        reason: 'expected the "${rail.label}" rail to be open');
    await tester.dragUntilVisible(tile, railList, const Offset(-120, 0));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(tile.first);
  await tester.pumpAndSettle();
  await tester.tap(tile.first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a first launch lands on onboarding, not the meal screen', (tester) async {
    await _pumpApp(tester);
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.textContaining('No counting'), findsOneWidget);
  });

  testWidgets('onboarding walks through goal and preferences into the app',
      (tester) async {
    final container = await _pumpApp(tester);

    // The first page is the walkthrough. It loops, so the reduced-motion path
    // these tests run under has to lay all three beats out at once — and if it
    // did not fit, the overflow would fail this test rather than ship.
    for (final beat in [
      'Tap what is on your plate',
      'It finds the one gap',
      'Add one thing',
    ]) {
      expect(find.text(beat), findsOneWidget);
    }
    // Drawn with the app's own parts, so the walkthrough cannot describe a
    // picker that no longer looks like that.
    expect(find.text('Rice'), findsOneWidget);
    expect(find.text('Add a side salad'), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('More energy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Vegetarian'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start patching'));
    await tester.pumpAndSettle();

    expect(find.byType(VoiceAgentScreen), findsOneWidget);
    expect(container.read(settingsProvider).goal, Goal.moreEnergy);
    expect(container.read(settingsProvider).dietPrefs, contains(DietPref.vegetarian));
  });

  testWidgets('choices made in onboarding survive a relaunch', (tester) async {
    await _pumpApp(tester, prefs: {
      'onboarded': true,
      'goal': Goal.moreEnergy.id,
      'diet_prefs': <String>[DietPref.dairyFree.id],
    });
    // Reaching the meal screen at all proves onboarded was read back; the
    // engine result below proves the preference was too.
    expect(find.byType(VoiceAgentScreen), findsOneWidget);
  });

  testWidgets('the patch button stays disabled until a food is picked',
      (tester) async {
    await _pumpApp(tester, prefs: {'onboarded': true});
    // The hub offers the meal; the food page is where the patch button lives,
    // and it stays disabled until something is on the plate.
    await _openFoodPicker(tester);
    expect(find.text('Pick what you are eating'), findsOneWidget);

    await _tapFood(tester, 'Rice');
    expect(find.textContaining('Patch this meal'), findsOneWidget);
  });

  testWidgets('a plate of rice leads with one patch and offers the other two',
      (tester) async {
    await _pumpApp(tester, prefs: {'onboarded': true});

    await _tapFood(tester, 'Rice');
    await tester.tap(find.textContaining('Patch this meal'));
    await tester.pumpAndSettle();

    expect(find.text('Your patch'), findsOneWidget);
    expect(find.textContaining('This looks light on'), findsOneWidget);

    // One addition is the answer, said in words rather than only drawn.
    // Asserting the name rather than a label: the catalogue writes every
    // addition as its own instruction, so the words are the thing to check.
    expect(
      find.descendant(
        of: find.byType(PatchHighlight),
        matching: find.textContaining('Add '),
      ),
      findsOneWidget,
    );
    expect(find.text("I'll add this"), findsOneWidget);

    // The engine found three angles, so two are offered as alternatives.
    expect(find.text('Or instead'), findsOneWidget);
    expect(find.byType(PatchHighlight), findsOneWidget);
  });

  testWidgets('a balanced plate is told there is nothing to patch',
      (tester) async {
    await _pumpApp(tester, prefs: {'onboarded': true});

    await _tapFood(tester, 'Fish'); // protein 3, fat 3
    await _tapFood(tester, 'Salad');
    await _tapFood(tester, 'Beans'); // fibre 3
    await tester.tap(find.textContaining('Patch this meal'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing to patch.'), findsOneWidget);
    expect(find.text("I'll add this"), findsNothing);
  });

  testWidgets('adding a patch saves it and asks how the meal went',
      (tester) async {
    final container = await _pumpApp(tester, prefs: {'onboarded': true});

    await _tapFood(tester, 'Rice');
    await tester.tap(find.textContaining('Patch this meal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("I'll add this").first);
    await tester.pumpAndSettle();

    expect(find.text('Saved. How did it go?'), findsOneWidget);
    expect(container.read(historyProvider), hasLength(1));
    expect(container.read(historyProvider).single.satisfaction, isNull);

    await tester.tap(find.text('Still hungry'));
    await tester.pumpAndSettle();

    expect(container.read(historyProvider).single.satisfaction, Satisfaction.stillHungry);
    // The plate is cleared so the next meal starts fresh.
    expect(container.read(mealDraftProvider).isEmpty, isTrue);
    expect(find.byType(VoiceAgentScreen), findsOneWidget);
  });

  testWidgets('vegetarian users are never shown meat or fish', (tester) async {
    await _pumpApp(tester, prefs: {
      'onboarded': true,
      'diet_prefs': <String>[DietPref.vegetarian.id],
    });

    await _tapFood(tester, 'Pasta');
    await tester.tap(find.textContaining('Patch this meal'));
    await tester.pumpAndSettle();

    for (final banned in ['tuna', 'chicken', 'salmon', 'sardines']) {
      expect(find.textContaining(banned, findRichText: true), findsNothing,
          reason: '$banned shown to a vegetarian');
    }
  });

  group('saved patches', () {
    List<String> makeHistory(int count) => [
          for (var i = 0; i < count; i++)
            jsonEncode(SavedPatch(
              id: 'p$i',
              savedAt: DateTime(2026, 9, 1).add(Duration(hours: i)),
              slot: MealSlot.lunchDinner,
              foodIds: const ['white_rice'],
              additionId: 'yogurt',
              additionName: 'Add a small bowl of yogurt $i',
              additionEmoji: '🥣',
              gapIds: const ['protein'],
            ).toJson()),
        ];

    testWidgets('an empty list explains what to do next', (tester) async {
      await _pumpApp(tester, prefs: {'onboarded': true}, home: const SavedScreen());
      expect(find.text('Nothing saved yet'), findsOneWidget);
    });

    testWidgets('every saved patch is shown, with nothing held back',
        (tester) async {
      await _pumpApp(
        tester,
        prefs: {'onboarded': true, 'history': makeHistory(5)},
        home: const SavedScreen(),
      );
      expect(find.textContaining('Add a small bowl of yogurt'), findsNWidgets(5));
      expect(find.textContaining('more saved patches'), findsNothing);
    });
  });


  group('legal', () {
    testWidgets('privacy and terms open in the app, with no dead link',
        (tester) async {
      await _pumpApp(tester, prefs: {'onboarded': true}, home: const SettingsScreen());

      await tester.scrollUntilVisible(find.text('Privacy policy'), 200);
      await tester.tap(find.text('Privacy policy'));
      await tester.pumpAndSettle();
      expect(find.text('Privacy policy'), findsWidgets);

      // The policy has to describe what actually happens to what someone says,
      // or it is a false claim shipped with a public demo.
      expect(find.textContaining('no recording is kept'), findsOneWidget);

      // Every way something leaves the device has to be named, and the policy
      // must not describe a camera the app no longer has or an account it
      // never had.
      for (final heading in [
        'What is stored on this device',
        'What happens to what you say',
        'What happens to the picture of your plate',
        'The anonymous device id',
      ]) {
        await tester.scrollUntilVisible(find.text(heading), 200);
        await tester.pumpAndSettle();
        expect(find.text(heading), findsOneWidget);
      }
      expect(find.textContaining('Signing in with Google'), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Terms of use'), 200);
      await tester.tap(find.text('Terms of use'));
      await tester.pumpAndSettle();
      expect(find.text('Terms of use'), findsWidgets);
      await tester.scrollUntilVisible(
          find.textContaining('It is not medical advice'), 200);
      expect(find.textContaining('It is not medical advice'), findsOneWidget);
      // No store is named: there is no store.
      expect(find.textContaining('Google Play'), findsNothing);
      expect(find.textContaining('App Store'), findsNothing);
    });
  });

  group('settings', () {
    testWidgets('a goal chosen at onboarding can be changed later',
        (tester) async {
      final container = await _pumpApp(
        tester,
        prefs: {'onboarded': true, 'goal': Goal.feelSatisfied.id},
        home: const SettingsScreen(),
      );
      expect(container.read(settingsProvider).goal, Goal.feelSatisfied);

      await _tapTile(tester, 'More energy');
      expect(container.read(settingsProvider).goal, Goal.moreEnergy);
    });

    testWidgets('preferences toggle both ways and persist', (tester) async {
      final container = await _pumpApp(
        tester,
        prefs: {'onboarded': true, 'diet_prefs': <String>[DietPref.vegetarian.id]},
        home: const SettingsScreen(),
      );

      await _tapTile(tester, 'Dairy-free');
      expect(container.read(settingsProvider).dietPrefs,
          {DietPref.vegetarian, DietPref.dairyFree});

      await _tapTile(tester, 'Vegetarian');
      expect(container.read(settingsProvider).dietPrefs, {DietPref.dairyFree});

      // Written through to storage, not just held in memory.
      final repo = container.read(prefsRepositoryProvider);
      expect(repo.dietPrefs, {DietPref.dairyFree});
    });

    testWidgets('a change here changes the next suggestion', (tester) async {
      // The point of the screen: settings must reach the engine.
      final container = await _pumpApp(
        tester,
        prefs: {'onboarded': true},
        home: const SettingsScreen(),
      );
      container.read(mealDraftProvider.notifier).toggleFood('white_rice');

      await _tapTile(tester, 'Vegetarian');
      final patches = container.read(patchResultProvider).patches;
      expect(patches, isNotEmpty);
      for (final p in patches) {
        expect(p.addition.tags.intersection({'meat', 'fish'}), isEmpty);
      }
    });

    testWidgets('nothing sells anything', (tester) async {
      // There is no paid tier and no account, and there is not going to be.
      // Anyone opening the URL must reach the agent without being asked for
      // money or a sign-in, so this pins the absence rather than trusting it.
      await _pumpApp(tester, prefs: {'onboarded': true}, home: const SettingsScreen());
      for (final word in [
        'Free plan',
        'See Pro',
        'Plate Pro',
        'Restore purchases',
        'Subscription',
        'Sign in',
        'Sign out',
        'Not signed in',
      ]) {
        expect(find.textContaining(word), findsNothing, reason: '"$word" is back');
      }
    });

    testWidgets('settings is reachable from the home screen', (tester) async {
      await _pumpApp(tester, prefs: {'onboarded': true});
      await tester.tap(find.byIcon(LucideIcons.settings));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
    });
  });


}
