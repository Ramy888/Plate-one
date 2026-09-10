import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plateone/data/catalog.dart';
import 'package:plateone/data/patch_images.dart';
import 'package:plateone/data/prefs_repository.dart';
import 'package:plateone/data/scan_api.dart';
import 'package:plateone/domain/models.dart';
import 'package:plateone/state/providers.dart';
import 'package:plateone/state/scan_providers.dart';
import 'package:plateone/ui/scan_confirm_screen.dart';
import 'package:plateone/ui/theme.dart';
import 'package:plateone/ui/widgets/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

Catalog realCatalog() {
  List<T> parse<T>(String name, T Function(Map<String, dynamic>) fromJson) =>
      (jsonDecode(File('assets/data/$name.json').readAsStringSync()) as List<dynamic>)
          .map((j) => fromJson(j as Map<String, dynamic>))
          .toList();
  return Catalog(
    foods: parse('foods', FoodItem.fromJson),
    additions: parse('additions', Addition.fromJson),
  );
}

Uint8List realPhoto() => File('test/fixtures/meal_rice_chicken.jpg').readAsBytesSync();

/// Stands in for the Worker. Nothing here touches the network, so no test can
/// ever spend a scan or a cent.
class FakeScanApi implements ScanApi {
  FakeScanApi({
    this.response,
    this.failure,
    this.forgetThrows = false,
    this.previewFailure,
  });

  ScanResponse? response;
  ScanFailure? failure;
  final bool forgetThrows;
  final ScanFailure? previewFailure;

  /// What a chat turn will answer with, and what it was asked.
  ChatReply? chatReply;
  ScanFailure? chatFailure;
  final chatMessages = <String>[];
  final voiceClips = <int>[];
  final plateCalls = <(List<String>, String)>[];
  final signInTokens = <String>[];
  int signOuts = 0;
  ScanFailure? signInFailure;
  ScanFailure? plateFailure;
  String? plateImageUrl;
  final ratings = <(String, bool)>[];

  int registrations = 0;
  int scans = 0;
  int forgotten = 0;
  final reports = <Map<String, String?>>[];

  @override
  String get baseUrl => 'fake';

  @override
  Duration get timeout => const Duration(seconds: 1);

  ScanQuota quotaValue = ScanQuota(
    scans: 4,
    previews: 2,
    resetsAt: DateTime.fromMillisecondsSinceEpoch(1789310995000),
  );

  @override
  Future<ChatReply> plate({
    required String deviceToken,
    required List<String> foodIds,
    required String additionId,
  }) async {
    plateCalls.add((foodIds, additionId));
    if (plateFailure != null) throw plateFailure!;
    return ChatReply(
      messageId: 'msg_plate',
      reply: 'A good plate, rounded out.',
      foodIds: foodIds,
      additionId: additionId,
      imageUrl: plateImageUrl,
      disclaimer: 'AI visual preview — appearance and serving size are illustrative.',
      quota: quotaValue,
    );
  }

  @override
  Future<DeviceRegistration> registerDevice({
    required String platform,
  }) async {
    registrations++;
    return DeviceRegistration(token: 'dv_fake', quota: quotaValue);
  }

  @override
  Future<ScanQuota> quota(String deviceToken) async => quotaValue;

  @override
  Future<ScanResponse> scan({required String deviceToken, required Uint8List jpeg}) async {
    scans++;
    final f = failure;
    if (f != null) throw f;
    return response!;
  }

  @override
  Future<void> report({
    required String deviceToken,
    required String targetType,
    required String targetId,
    required String reason,
    String? note,
  }) async {
    reports.add({'reason': reason, 'note': note, 'targetId': targetId});
  }

  PreviewResult? previewResult;
  int previews = 0;
  String? lastAdditionId;

  @override
  Future<PreviewResult> preview({
    required String deviceToken,
    required Uint8List jpeg,
    required String additionId,
    String? scanId,
  }) async {
    previews++;
    lastAdditionId = additionId;
    final f = previewFailure;
    if (f != null) throw f;
    return previewResult ??
        PreviewResult(
          url: 'https://fake/v1/preview/abc.jpg',
          disclaimer: 'AI visual preview — appearance and serving size are illustrative.',
          quota: quotaValue,
        );
  }

  @override
  Future<Uint8List> previewImage({
    required String deviceToken,
    required String url,
  }) async =>
      previewBytes ?? Uint8List.fromList(List.filled(2048, 7));

  /// Set where a test needs bytes a decoder will actually accept.
  Uint8List? previewBytes;

  @override
  Future<void> forgetDevice(String deviceToken) async {
    if (forgetThrows) {
      throw const ScanFailure(ScanError.offline, 'No connection.');
    }
    forgotten++;
  }

  @override
  void close() {}
}

ScanResponse riceAndChicken() => ScanResponse.fromJson({
      'scanId': 'sc_test',
      'foods': [
        {'name': 'white rice', 'confidence': 0.98},
        {'name': 'roast chicken thigh', 'confidence': 0.95},
      ],
      'components': {
        'protein': 'present',
        'fibre': 'possibly_missing',
        'healthyFat': 'possibly_missing',
      },
      'quota': {
        'scans': 4,
        'previews': 2,
        'resetsAt': 1789310995,
        'pro': false,
        'trialActive': true,
        'trialDaysLeft': 7,
      },
    });

Future<ProviderContainer> pump(
  WidgetTester tester, {
  required FakeScanApi api,
  Map<String, Object> prefs = const {'onboarded': true},
  Widget? home,
}) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(prefs);
  final repo = PrefsRepository(await SharedPreferences.getInstance());
  final container = ProviderContainer(overrides: [
    prefsRepositoryProvider.overrideWithValue(repo),
    patchImagesProvider.overrideWithValue(MemoryPatchImages()),
    catalogProvider.overrideWithValue(realCatalog()),
    scanApiProvider.overrideWithValue(api),
  ]);
  addTearDown(container.dispose);

  if (home != null) {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: buildTheme(), home: home),
      ),
    );
    await tester.pumpAndSettle();
  }
  return container;
}

void main() {
  group('a successful scan', () {
    testWidgets('matches the model output onto catalogue foods', (tester) async {
      final api = FakeScanApi(response: riceAndChicken());
      final container = await pump(tester, api: api);

      await container
          .read(scanControllerProvider.notifier)
          .scan(realPhoto(), slot: MealSlot.lunchDinner);

      final state = container.read(scanControllerProvider);
      expect(state.stage, ScanStage.done);
      expect(state.recognized.map((f) => f.food?.id), ['white_rice', 'chicken']);
      expect(state.quota?.scans, 4);
    });

    testWidgets('registers the device once, then reuses the token', (tester) async {
      final api = FakeScanApi(response: riceAndChicken());
      final container = await pump(tester, api: api);
      final controller = container.read(scanControllerProvider.notifier);

      await controller.scan(realPhoto(), slot: MealSlot.lunchDinner);
      await controller.scan(realPhoto(), slot: MealSlot.lunchDinner);

      expect(api.registrations, 1);
      expect(api.scans, 2);
      expect(container.read(prefsRepositoryProvider).deviceToken, 'dv_fake');
    });

    testWidgets('never registers for someone who only builds by hand', (tester) async {
      final api = FakeScanApi(response: riceAndChicken());
      await pump(tester, api: api);
      // No scan attempted: the app has made no network call at all.
      expect(api.registrations, 0);
    });

    testWidgets('confirming hands the foods to the existing meal draft', (tester) async {
      final api = FakeScanApi(response: riceAndChicken());
      final container = await pump(tester, api: api);
      final controller = container.read(scanControllerProvider.notifier);

      await controller.scan(realPhoto(), slot: MealSlot.lunchDinner);
      controller.confirm(MealSlot.lunchDinner);

      final draft = container.read(mealDraftProvider);
      expect(draft.slot, MealSlot.lunchDinner);
      expect(draft.foodIds, {'white_rice', 'chicken'});

      // And the rule engine now produces a patch from it, exactly as it would
      // for a hand-built meal.
      final result = container.read(patchResultProvider);
      expect(result.gaps, contains(Nutrient.fibre));
      expect(result.patches, isNotEmpty);
    });
  });


  group('when the photo is not good enough', () {
    testWidgets('a blurry photo is refused without any request', (tester) async {
      final api = FakeScanApi(response: riceAndChicken());
      final container = await pump(tester, api: api);

      // A tiny image trips the size gate; nothing reaches the network.
      await container
          .read(scanControllerProvider.notifier)
          .scan(Uint8List.fromList([1, 2, 3]), slot: MealSlot.snack);

      final state = container.read(scanControllerProvider);
      expect(state.stage, ScanStage.failed);
      expect(state.problem, isNotNull);
      expect(api.scans, 0, reason: 'a rejected photo must not cost a scan');
      expect(api.registrations, 0);
    });
  });

  group('when the server says no', () {
    testWidgets('an exhausted allowance is reported as such', (tester) async {
      final api = FakeScanApi(
        failure: const ScanFailure(ScanError.quotaExhausted, 'You have used this week’s scans.'),
      );
      final container = await pump(tester, api: api);

      await container
          .read(scanControllerProvider.notifier)
          .scan(realPhoto(), slot: MealSlot.lunchDinner);

      final state = container.read(scanControllerProvider);
      expect(state.failure?.error.isOutOfAllowance, isTrue);
      expect(state.problem, contains('scans'));
    });

    testWidgets('every failure message offers the manual builder', (tester) async {
      for (final failure in [
        const ScanFailure(ScanError.busy, 'Recognition is busy. Try again, or build by hand.'),
        const ScanFailure(ScanError.noFoodFound, 'No food recognised. Or build the meal by hand.'),
        const ScanFailure(ScanError.offline, 'No connection. You can build the meal by hand.'),
      ]) {
        final api = FakeScanApi(failure: failure);
        final container = await pump(tester, api: api);
        await container
            .read(scanControllerProvider.notifier)
            .scan(realPhoto(), slot: MealSlot.lunchDinner);
        expect(
          container.read(scanControllerProvider).problem!.toLowerCase(),
          contains('hand'),
          reason: '${failure.error} leaves the user with nowhere to go',
        );
      }
    });

    testWidgets('a stale token is cleared so the next scan re-registers', (tester) async {
      final api = FakeScanApi(
        failure: const ScanFailure(ScanError.unauthorized, 'Sign in again.'),
      );
      final container = await pump(
        tester,
        api: api,
        prefs: {'onboarded': true, 'device_token': 'dv_stale'},
      );

      await container
          .read(scanControllerProvider.notifier)
          .scan(realPhoto(), slot: MealSlot.lunchDinner);

      expect(container.read(prefsRepositoryProvider).deviceToken, isNull);
    });
  });

  group('the confirm screen', () {
    Future<ProviderContainer> withResult(WidgetTester tester, ScanResponse response) async {
      final api = FakeScanApi(response: response);
      final container = await pump(tester, api: api);
      await container
          .read(scanControllerProvider.notifier)
          .scan(realPhoto(), slot: MealSlot.lunchDinner);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(),
            home: const ScanConfirmScreen(slot: MealSlot.lunchDinner),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('shows what the model saw', (tester) async {
      await withResult(tester, riceAndChicken());
      expect(find.text('Rice'), findsWidgets);
      expect(find.text('Chicken'), findsWidgets);
    });

    testWidgets('a wrong item can be removed in one tap', (tester) async {
      final container = await withResult(tester, riceAndChicken());
      await tester.tap(find.byTooltip('Remove Chicken'));
      await tester.pumpAndSettle();

      expect(container.read(scanControllerProvider).recognized.map((f) => f.food?.id),
          ['white_rice']);
    });

    testWidgets('an unmatched label is shown and marked as not counting', (tester) async {
      await withResult(
        tester,
        ScanResponse.fromJson({
          'scanId': 'sc_x',
          'foods': [
            {'name': 'white rice', 'confidence': 0.9},
            {'name': 'pickled turnip', 'confidence': 0.5},
          ],
          'components': {'protein': 'uncertain', 'fibre': 'uncertain', 'healthyFat': 'uncertain'},
          'quota': {
            'scans': 3,
            'previews': 2,
            'resetsAt': 1789310995,
            'pro': false,
            'trialActive': true,
            'trialDaysLeft': 7,
          },
        }),
      );
      expect(find.text('Pickled turnip'), findsOneWidget);
      expect(find.textContaining('will not count'), findsOneWidget);
    });

    testWidgets('says the result came from AI, and what happened to the photo',
        (tester) async {
      // Play expects this disclosure where the generated result is shown.
      await withResult(tester, riceAndChicken());
      expect(find.textContaining('Recognised by AI'), findsOneWidget);
      expect(find.textContaining('stripped of location data'), findsOneWidget);
    });

    testWidgets('offers the Play-required report control', (tester) async {
      await withResult(tester, riceAndChicken());
      expect(find.byTooltip('Report this result'), findsOneWidget);
    });

    testWidgets('a missed food can be added from the same catalogue', (tester) async {
      final container = await withResult(tester, riceAndChicken());
      final salad = find.widgetWithText(PlateChip, 'Salad');
      await tester.ensureVisible(salad);
      await tester.pumpAndSettle();
      await tester.tap(salad);
      await tester.pumpAndSettle();

      expect(
        container.read(scanControllerProvider).recognized.map((f) => f.food?.id),
        contains('salad'),
      );
    });

    testWidgets('cannot be confirmed with nothing on the plate', (tester) async {
      final container = await withResult(tester, riceAndChicken());
      final controller = container.read(scanControllerProvider.notifier);
      for (final food in [...container.read(scanControllerProvider).recognized]) {
        controller.remove(food);
      }
      await tester.pumpAndSettle();

      expect(find.text('Add what you are eating'), findsOneWidget);
      final button = tester.widget<FilledButton>(find.byType(FilledButton).last);
      expect(button.onPressed, isNull);
    });
  });

  group('delete my data', () {
    testWidgets('clears the phone and tells the server to forget the device',
        (tester) async {
      final api = FakeScanApi(response: riceAndChicken());
      final container = await pump(
        tester,
        api: api,
        prefs: {
          'onboarded': true,
          'device_token': 'dv_fake',
          'diet_prefs': <String>['vegetarian'],
        },
      );
      await container
          .read(scanControllerProvider.notifier)
          .scan(realPhoto(), slot: MealSlot.lunchDinner);
      container.read(scanControllerProvider.notifier).confirm(MealSlot.lunchDinner);
      await container.read(historyProvider.notifier).save(SavedPatch(
            id: 'p1',
            savedAt: DateTime(2026, 9, 6),
            slot: MealSlot.lunchDinner,
            foodIds: const ['white_rice'],
            additionId: 'yogurt',
            additionName: 'Add a small bowl of yogurt',
            additionEmoji: '🥣',
            gapIds: const ['protein'],
          ));

      await container.read(scanControllerProvider.notifier).deleteEverything();

      final repo = container.read(prefsRepositoryProvider);
      expect(api.forgotten, 1, reason: 'the server was not told to forget the device');
      expect(repo.deviceToken, isNull);
      expect(repo.history, isEmpty);
      expect(repo.dietPrefs, isEmpty);
      expect(container.read(historyProvider), isEmpty);
      expect(container.read(mealDraftProvider).isEmpty, isTrue);
      expect(container.read(scanControllerProvider).recognized, isEmpty);
    });

    testWidgets('still clears the phone when the server cannot be reached',
        (tester) async {
      // Someone asking to be forgotten must not leave with nothing deleted
      // because the network was down.
      final api = FakeScanApi(response: riceAndChicken(), forgetThrows: true);
      final container = await pump(
        tester,
        api: api,
        prefs: {'onboarded': true, 'device_token': 'dv_fake', 'diet_prefs': <String>['low_cost']},
      );

      await container.read(scanControllerProvider.notifier).deleteEverything();

      final repo = container.read(prefsRepositoryProvider);
      expect(repo.deviceToken, isNull);
      expect(repo.dietPrefs, isEmpty);
    });
  });

  group('visual preview', () {
    Future<ProviderContainer> scanned(WidgetTester tester, FakeScanApi api) async {
      final container = await pump(
        tester,
        api: api,
        prefs: {'onboarded': true, 'device_token': 'dv_fake'},
      );
      await container
          .read(scanControllerProvider.notifier)
          .scan(realPhoto(), slot: MealSlot.lunchDinner);
      return container;
    }

    testWidgets('sends the addition id, never its name', (tester) async {
      // The server looks the phrase up in a closed set. Sending a name would
      // put client-controlled text one step from an image prompt.
      final api = FakeScanApi(response: riceAndChicken());
      final container = await scanned(tester, api);

      await container.read(scanControllerProvider.notifier).generatePreview('side_salad');

      expect(api.lastAdditionId, 'side_salad');
      expect(container.read(scanControllerProvider).preview, isNotNull);
    });

    testWidgets('reuses the photo already taken, without a second capture',
        (tester) async {
      final api = FakeScanApi(response: riceAndChicken());
      final container = await scanned(tester, api);
      await container.read(scanControllerProvider.notifier).generatePreview('side_salad');
      expect(api.previews, 1);
      expect(api.scans, 1);
    });

    testWidgets('does nothing when there is no photo to edit', (tester) async {
      // A hand-built meal has no photograph, so there is nothing to draw on.
      final api = FakeScanApi(response: riceAndChicken());
      final container = await pump(
        tester,
        api: api,
        prefs: {'onboarded': true, 'device_token': 'dv_fake'},
      );

      await container.read(scanControllerProvider.notifier).generatePreview('side_salad');
      expect(api.previews, 0);
      expect(container.read(scanControllerProvider).preview, isNull);
    });

    testWidgets('a preview failure leaves the patch untouched', (tester) async {
      final api = FakeScanApi(
        response: riceAndChicken(),
        previewFailure: const ScanFailure(
          ScanError.busy,
          'Previews are busy right now. Your patch is unchanged.',
        ),
      );
      final container = await scanned(tester, api);
      await container.read(scanControllerProvider.notifier).generatePreview('side_salad');

      final state = container.read(scanControllerProvider);
      expect(state.previewFailure, isNotNull);
      expect(state.preview, isNull);
      // The recognised foods and the scan itself are unaffected.
      expect(state.failure, isNull);
      expect(state.recognized, isNotEmpty);
      expect(state.previewFailure!.message, contains('unchanged'));
    });
  });


  group('reporting', () {
    testWidgets('sends the reason and the scan it refers to', (tester) async {
      final api = FakeScanApi(response: riceAndChicken());
      final container = await pump(
        tester,
        api: api,
        prefs: {'onboarded': true, 'device_token': 'dv_fake'},
      );
      await container
          .read(scanControllerProvider.notifier)
          .scan(realPhoto(), slot: MealSlot.lunchDinner);
      await container
          .read(scanControllerProvider.notifier)
          .report(reason: 'wrong_food', note: 'that is not chicken');

      expect(api.reports.single['reason'], 'wrong_food');
      expect(api.reports.single['targetId'], 'sc_test');
    });
  });
}
