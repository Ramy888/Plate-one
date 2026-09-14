import 'package:flutter_test/flutter_test.dart';
import 'package:plateone/data/catalog.dart';
import 'package:plateone/domain/models.dart';
import 'package:plateone/domain/patch_engine.dart';

/// Against the real catalogue, because this is about how the app feels to
/// somebody trying a few meals in a row — not about the arithmetic, which the
/// synthetic tests cover.
///
/// Both halves matter, and they pull against each other. Determinism is what
/// the whole design rests on: the engine decides, not the model, and the same
/// plate has to give the same answer every time. But the final tie-break used
/// to be alphabetical, so among additions that were equally fast and equally
/// good the same id won on every plate — "hummus, beans, avocado" came back
/// identically for five of the twelve plates below, which reads as a canned
/// response rather than something that looked at the food.
void main() {
  late PatchEngine engine;
  late Map<String, FoodItem> byId;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final catalog = await Catalog.load();
    engine = PatchEngine(additions: catalog.additions);
    byId = {for (final f in catalog.foods) f.id: f};
  });

  List<String> optionsFor(List<String> foodIds) {
    final foods = [for (final id in foodIds) byId[id]].whereType<FoodItem>().toList();
    expect(foods, hasLength(foodIds.length), reason: 'unknown food in $foodIds');
    return engine
        .patch(slot: MealSlot.lunchDinner, foods: foods, goal: Goal.feelSatisfied)
        .patches
        .map((p) => p.addition.id)
        .toList();
  }

  const plates = <List<String>>[
    ['white_rice'],
    ['white_rice', 'chicken'],
    ['pasta'],
    ['baladi_bread'],
    ['oats'],
    ['eggs'],
    ['koshari'],
    ['pizza'],
    ['soup'],
    ['sandwich'],
    ['burger', 'fries'],
    ['sushi'],
  ];

  test('the same plate gives the same options every time', () {
    for (final plate in plates) {
      final first = optionsFor(plate);
      for (var i = 0; i < 3; i++) {
        expect(optionsFor(plate), first, reason: 'unstable for $plate');
      }
    }
  });

  test('different plates do not all lead with the same addition', () {
    final leaders = {for (final plate in plates) optionsFor(plate).first};
    expect(leaders.length, greaterThan(2),
        reason: 'the same card led nearly every plate, which is what makes the '
            'app look like it is reading from a script');
  });

  test('no set of three comes back for more than a couple of plates', () {
    final counts = <String, int>{};
    for (final plate in plates) {
      final key = optionsFor(plate).join(',');
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final worst = counts.values.reduce((a, b) => a > b ? a : b);
    expect(worst, lessThan(4),
        reason: 'one trio answered $worst of ${plates.length} plates: $counts');
  });
}
