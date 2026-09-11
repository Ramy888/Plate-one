import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plateone/data/prefs_repository.dart';
import 'package:plateone/data/api.dart';
import 'package:plateone/state/plate_providers.dart';
import 'package:plateone/state/providers.dart';
import 'package:plateone/state/api_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A Worker that draws slowly and counts how often it was asked.
///
/// The count is the whole point: a conversation moves faster than a picture,
/// and the failure this guards against is paying for plates nobody ever sees.
class _SlowApi implements ScanApi {
  _SlowApi({this.delay = const Duration(milliseconds: 200)});

  final Duration delay;
  final drawn = <String>[];

  @override
  Future<ChatReply> plate({
    required String deviceToken,
    required List<String> foodIds,
    required String additionId,
  }) async {
    drawn.add('${foodIds.join(',')}|$additionId');
    await Future<void>.delayed(delay);
    return ChatReply(
      messageId: 'm${drawn.length}',
      reply: '',
      foodIds: foodIds,
      additionId: additionId,
      imageUrl: null,
      disclaimer: 'test',
      quota: ScanQuota(
        previews: 9,
        voice: 9,
        resetsAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
  }

  @override
  Future<DeviceRegistration> registerDevice({required String platform}) async =>
      DeviceRegistration(
        token: 'device-token',
        quota: ScanQuota(
            previews: 9,
          voice: 9,
          resetsAt: DateTime.fromMillisecondsSinceEpoch(0),
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not part of this test');
}

Future<ProviderContainer> _container(_SlowApi api) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = PrefsRepository(await SharedPreferences.getInstance());
  final container = ProviderContainer(
    overrides: [
      prefsRepositoryProvider.overrideWithValue(prefs),
      scanApiProvider.overrideWithValue(api),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a meal named in pieces is drawn once, not once per piece', () async {
    // "Rice" then "and chicken" then "and a salad" arrives over a couple of
    // seconds. Each is a separate tool call, and each used to start its own
    // picture.
    final api = _SlowApi();
    final container = await _container(api);
    final plate = container.read(plateVisualProvider.notifier);

    plate.request(foodIds: ['white_rice']);
    plate.request(foodIds: ['white_rice', 'chicken']);
    plate.request(foodIds: ['white_rice', 'chicken', 'salad']);

    await Future<void>.delayed(const Duration(milliseconds: 1400));

    expect(api.drawn, hasLength(1));
    expect(api.drawn.single, contains('salad'), reason: 'the latest meal wins');
  });

  test('a change mid-draw waits rather than racing it', () async {
    // The sync problem: the conversation moves on while a picture is being
    // drawn. Starting a second draw in parallel means paying for the first one
    // and throwing it away.
    final api = _SlowApi(delay: const Duration(milliseconds: 400));
    final container = await _container(api);
    final plate = container.read(plateVisualProvider.notifier);

    plate.request(foodIds: ['white_rice'], now: true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(api.drawn, hasLength(1), reason: 'the first one is in flight');

    // Two more changes arrive while it is still drawing.
    plate.request(foodIds: ['white_rice', 'chicken'], now: true);
    plate.request(foodIds: ['white_rice', 'chicken', 'salad'], now: true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(api.drawn, hasLength(1), reason: 'nothing races the draw in flight');

    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(api.drawn, hasLength(2), reason: 'one catch-up draw, not two');
    expect(api.drawn.last, contains('salad'));
  });

  test('choosing a patch draws at once — someone is waiting for it', () async {
    final api = _SlowApi();
    final container = await _container(api);
    final plate = container.read(plateVisualProvider.notifier);

    plate.request(foodIds: ['white_rice'], additionId: 'hummus', now: true);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(api.drawn, hasLength(1), reason: 'no settling delay on a tap');
    expect(api.drawn.single, endsWith('|hummus'));
  });

  test('clearing the plate cancels a draw that has not started', () async {
    // Ending the conversation must not be followed, a second later, by a
    // picture of the meal that was just cleared away.
    final api = _SlowApi();
    final container = await _container(api);
    final plate = container.read(plateVisualProvider.notifier);

    plate.request(foodIds: ['white_rice']);
    plate.clear();
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(api.drawn, isEmpty);
  });

  test('the picture on screen stays while the next one is drawn', () async {
    // A plate that blanks out every time you mention a food reads as a bug
    // rather than as progress.
    final api = _SlowApi(delay: const Duration(milliseconds: 300));
    final container = await _container(api);
    final plate = container.read(plateVisualProvider.notifier);

    // Pretend one has already been drawn.
    plate.state = PlateVisual(image: Uint8List.fromList([1, 2, 3]));

    plate.request(foodIds: ['white_rice'], now: true);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(container.read(plateVisualProvider).loading, isTrue);
    expect(container.read(plateVisualProvider).image, isNotNull);
  });
}
