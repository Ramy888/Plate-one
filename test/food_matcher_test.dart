import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plateone/data/catalog.dart';
import 'package:plateone/domain/food_matcher.dart';
import 'package:plateone/domain/models.dart';

List<FoodItem> loadCatalogue() =>
    (jsonDecode(File('assets/data/foods.json').readAsStringSync()) as List<dynamic>)
        .map((j) => FoodItem.fromJson(j as Map<String, dynamic>))
        .toList();

void main() {
  final matcher = FoodMatcher(loadCatalogue());

  String? idFor(String label, {MealSlot slot = MealSlot.lunchDinner}) =>
      matcher.match(label, 0.9, slot: slot).food?.id;

  group('the names the model actually returned', () {
    // Every string here came back from gemini-3.7-flash on a real photograph
    // during development. They are the reason the matcher exists.
    test('white rice', () => expect(idFor('white rice'), 'white_rice'));
    test('roast chicken thigh', () => expect(idFor('roast chicken thigh'), 'chicken'));
    test('roasted chicken thigh', () => expect(idFor('roasted chicken thigh'), 'chicken'));
    test('grilled chicken thigh', () => expect(idFor('grilled chicken thigh'), 'chicken'));
    test('rice', () => expect(idFor('rice'), 'white_rice'));
    test('cucumber and tomato salad', () => expect(idFor('cucumber and tomato salad'), 'salad'));
  });

  group('ordinary phrasings', () {
    test('descriptors are ignored', () {
      expect(idFor('a small bowl of plain white rice'), 'white_rice');
      expect(idFor('two slices of white bread'), 'white_bread');
      expect(idFor('fried eggs'), 'eggs');
    });

    test('an exact catalogue name matches itself', () {
      for (final food in loadCatalogue()) {
        expect(
          idFor(food.name, slot: food.slots.first),
          food.id,
          reason: '${food.name} does not match its own entry',
        );
      }
    });

    test('an "or" name matches either half', () {
      expect(idFor('beef'), 'red_meat');
      expect(idFor('lamb chops'), 'red_meat');
      expect(idFor('cake'), 'cake');
      expect(idFor('a pastry'), 'cake');
    });

    test('plurals and near-synonyms go through the alias list', () {
      expect(idFor('toast'), 'white_bread');
      expect(idFor('spaghetti'), 'pasta');
      expect(idFor('an omelette', slot: MealSlot.breakfast), 'eggs');
      expect(idFor('salmon fillet'), 'fish');
      expect(idFor('greek yoghurt', slot: MealSlot.breakfast), 'yogurt');
    });
  });

  group('what it must not match', () {
    test('chickpeas are not chicken', () {
      // Substring matching would get this wrong, which is why the matcher
      // compares whole tokens.
      expect(idFor('chickpeas'), isNot('chicken'));
      expect(idFor('chickpeas'), 'beans');
    });

    test('an unknown food stays unmatched rather than being forced', () {
      final result = matcher.match('seaweed', 0.6, slot: MealSlot.snack);
      expect(result.isMatched, isFalse);
      expect(result.food, isNull);
    });

    test('it over-matches rather than under-matches, on purpose', () {
      // "dragon fruit sorbet" resolves to Fruit because "fruit" is a catalogue
      // name in its own right. That is the intended bias: the confirm screen
      // lets someone remove a wrong item in one tap, whereas an item that was
      // never matched is food the engine cannot see at all.
      expect(idFor('dragon fruit sorbet', slot: MealSlot.snack), 'fruit');
    });

    test('an unmatched food is still shown, not silently dropped', () {
      // The user has to see what the model thought it saw, or a wrong reading
      // looks like the app simply missing something.
      final result = matcher.match('pickled turnip', 0.5, slot: MealSlot.lunchDinner);
      expect(result.displayName, 'Pickled turnip');
      expect(result.emoji, isNotEmpty);
    });

    test('empty or punctuation-only labels match nothing', () {
      expect(matcher.match('', 0.9, slot: MealSlot.snack).isMatched, isFalse);
      expect(matcher.match('...', 0.9, slot: MealSlot.snack).isMatched, isFalse);
      expect(matcher.match('a bowl of', 0.9, slot: MealSlot.snack).isMatched, isFalse);
    });
  });

  group('the meal being built breaks ties', () {
    test('slot membership is preferred', () {
      // "Eggs" belongs to every slot, so this mostly guards the tie-break from
      // regressing into ignoring the slot entirely.
      expect(idFor('eggs', slot: MealSlot.breakfast), 'eggs');
      expect(idFor('eggs', slot: MealSlot.lunchDinner), 'eggs');
    });
  });

  group('matching a whole plate at once', () {
    test('maps a real result onto catalogue foods', () {
      final matched = matcher.matchAll(
        [
          (name: 'white rice', confidence: 0.98),
          (name: 'roast chicken thigh', confidence: 0.95),
        ],
        slot: MealSlot.lunchDinner,
      );
      expect(matched.map((m) => m.food?.id), ['white_rice', 'chicken']);
      expect(matched.every((m) => m.isMatched), isTrue);
    });

    test('two labels for the same food are collapsed', () {
      // Otherwise the engine counts rice twice and thinks the plate has more
      // carbohydrate than it does.
      final matched = matcher.matchAll(
        [
          (name: 'rice', confidence: 0.9),
          (name: 'white rice', confidence: 0.8),
          (name: 'chicken', confidence: 0.9),
        ],
        slot: MealSlot.lunchDinner,
      );
      expect(matched, hasLength(2));
      expect(matched.map((m) => m.food?.id), ['white_rice', 'chicken']);
    });

    test('two different unmatched labels are both kept', () {
      final matched = matcher.matchAll(
        [
          (name: 'pickled turnip', confidence: 0.5),
          (name: 'dragon fruit', confidence: 0.4),
        ],
        slot: MealSlot.lunchDinner,
      );
      expect(matched, hasLength(2));
      expect(matched.every((m) => m.isMatched), isFalse);
    });

    test('confidence is carried through untouched', () {
      final matched = matcher.matchAll(
        [(name: 'rice', confidence: 0.98)],
        slot: MealSlot.lunchDinner,
      );
      expect(matched.single.confidence, 0.98);
    });
  });

  group('every alias points somewhere real', () {
    test('no alias names a food that does not exist', () {
      final ids = loadCatalogue().map((f) => f.id).toSet();
      // A typo here would silently disable an alias, and nothing else would
      // ever notice.
      final matched = <String>{};
      for (final food in loadCatalogue()) {
        matched.add(food.id);
      }
      expect(ids.containsAll(matched), isTrue);

      for (final label in [
        'bread', 'toast', 'pita', 'flatbread', 'noodles', 'spaghetti', 'macaroni',
        'potato', 'chips', 'egg', 'omelette', 'omelet', 'yoghurt', 'greens',
        'lettuce', 'vegetables', 'veg', 'broccoli', 'carrots', 'peas', 'beef',
        'lamb', 'steak', 'mince', 'salmon', 'tuna', 'sardines', 'apple',
        'orange', 'berries', 'grapes', 'biscuit', 'cookie', 'cookies', 'nut',
        'almonds', 'walnuts', 'peanuts', 'lentil', 'bean', 'chickpeas',
        'falafel', 'ful', 'foul',
      ]) {
        final result = matcher.match(label, 0.9, slot: MealSlot.lunchDinner);
        expect(result.isMatched, isTrue, reason: 'alias "$label" resolves to nothing');
      }
    });
  });

  group('the names people actually say', () {
    // Every case here came out of a live session or is the obvious spelling of
    // the dish. They all used to match nothing — "fuul" failed against a food
    // literally named "Fuul medames", because the name rule wanted every word
    // of the name and nobody says "medames".
    late FoodMatcher matcher;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      matcher = FoodMatcher((await Catalog.load()).foods);
    });

    String? hit(String said) => matcher
        .match(said, 1, slot: MealSlot.lunchDinner)
        .food
        ?.id;

    test('a distinctive word out of a multi-word dish is enough', () {
      expect(hit('fuul'), 'fuul');
      expect(hit('laban'), 'roz_bel_laban');
      expect(hit('koshari'), 'koshari');
    });

    test('the spellings a transcriber produces', () {
      // "tamia" and "phool" are verbatim from a recorded session.
      expect(hit('tamia'), 'taameya');
      expect(hit('phool'), 'fuul');
      expect(hit('kushari'), 'koshari');
      expect(hit('molokheya'), 'molokhia');
      expect(hit('aish'), 'baladi_bread');
    });

    test('a word shared by several foods still goes through the aliases', () {
      // "bread" belongs to three catalogue entries, so it is not distinctive
      // and must not be grabbed by whichever one happens to be scored first.
      expect(hit('bread'), 'white_bread');
      expect(hit('white bread'), 'white_bread');
      expect(hit('baladi bread'), 'baladi_bread');
    });

    test('a leaf is a vegetable, not a mystery', () {
      expect(hit('spinach'), 'cooked_veg');
    });
  });
}