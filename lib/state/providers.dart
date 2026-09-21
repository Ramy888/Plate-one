import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/catalog.dart';
import '../data/prefs_repository.dart';
import '../data/patch_images.dart';
import '../domain/models.dart';
import '../domain/patch_engine.dart';

/// Both are resolved before `runApp` and injected as overrides, which keeps the
/// rest of the app free of `AsyncValue` plumbing for things that are always
/// ready by the time a widget builds.
final prefsRepositoryProvider = Provider<PrefsRepository>(
  (ref) => throw StateError('prefsRepositoryProvider must be overridden at startup'),
);

final catalogProvider = Provider<Catalog>(
  (ref) => throw StateError('catalogProvider must be overridden at startup'),
);

final patchEngineProvider = Provider<PatchEngine>(
  (ref) => PatchEngine(additions: ref.watch(catalogProvider).additions),
);

// ---------------------------------------------------------------- settings

class AppSettings {
  const AppSettings({
    required this.onboarded,
    required this.goal,
    required this.dietPrefs,
  });

  final bool onboarded;
  final Goal goal;
  final Set<DietPref> dietPrefs;

  AppSettings copyWith({bool? onboarded, Goal? goal, Set<DietPref>? dietPrefs}) => AppSettings(
        onboarded: onboarded ?? this.onboarded,
        goal: goal ?? this.goal,
        dietPrefs: dietPrefs ?? this.dietPrefs,
      );
}

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    final repo = ref.watch(prefsRepositoryProvider);
    return AppSettings(
      onboarded: repo.onboarded,
      goal: repo.goal,
      dietPrefs: repo.dietPrefs,
    );
  }

  PrefsRepository get _repo => ref.read(prefsRepositoryProvider);

  Future<void> setGoal(Goal goal) async {
    state = state.copyWith(goal: goal);
    await _repo.setGoal(goal);
  }

  Future<void> togglePref(DietPref pref) async {
    final next = {...state.dietPrefs};
    next.contains(pref) ? next.remove(pref) : next.add(pref);
    state = state.copyWith(dietPrefs: next);
    await _repo.setDietPrefs(next);
  }

  Future<void> completeOnboarding() async {
    state = state.copyWith(onboarded: true);
    await _repo.setOnboarded(true);
  }
}

final settingsProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

// ----------------------------------------------------------------- history

class HistoryController extends Notifier<List<SavedPatch>> {
  @override
  List<SavedPatch> build() => ref.watch(prefsRepositoryProvider).history;

  PrefsRepository get _repo => ref.read(prefsRepositoryProvider);

  Future<void> save(SavedPatch patch) async {
    state = [patch, ...state];
    await _repo.setHistory(state);
  }

  Future<void> recordSatisfaction(String id, Satisfaction satisfaction) async {
    state = [
      for (final p in state) p.id == id ? p.withSatisfaction(satisfaction) : p,
    ];
    await _repo.setHistory(state);
  }

  Future<void> remove(String id) async {
    // The picture goes with the patch. Leaving orphaned files behind would be a
    // slow leak of exactly the thing this app promises to keep small.
    final going = state.where((p) => p.id == id).firstOrNull;
    state = state.where((p) => p.id != id).toList();
    await _repo.setHistory(state);
    await ref.read(patchImagesProvider).remove(going?.imagePath);
  }

  /// Used by "Delete my data". Empties the list in memory as well as on disk,
  /// so the UI reflects it without a restart.
  Future<void> clear() async {
    state = const [];
    await _repo.setHistory(const []);
    await ref.read(patchImagesProvider).clear();
  }
}

final historyProvider =
    NotifierProvider<HistoryController, List<SavedPatch>>(HistoryController.new);

/// Every save, always. Nothing on this device is withheld from the person whose
/// device it is.
final visibleHistoryProvider = Provider<List<SavedPatch>>(
  (ref) => ref.watch(historyProvider),
);

/// Recent after-meal checks, turned into the nudge the engine applies.
final historyInsightProvider = Provider<HistoryInsight>(
  (ref) => HistoryInsight.fromHistory(ref.watch(historyProvider)),
);

// ------------------------------------------------------------- meal draft

/// What the user is building right now. Session-only: a half-finished meal is
/// not worth persisting, and restoring one would be confusing.
class MealDraft {
  const MealDraft({
    this.slot = MealSlot.lunchDinner,
    this.foodIds = const {},
    this.slotChosen = false,
  });

  final MealSlot slot;
  final Set<String> foodIds;

  /// Whether the user has actually picked a meal, as opposed to the default
  /// the rest of the app needs a concrete value for. The picker keeps the food
  /// rails closed until they have — thirty tiles before you have said what
  /// meal it is answers a question nobody asked.
  final bool slotChosen;

  bool get isEmpty => foodIds.isEmpty;

  MealDraft copyWith({MealSlot? slot, Set<String>? foodIds, bool? slotChosen}) =>
      MealDraft(
        slot: slot ?? this.slot,
        foodIds: foodIds ?? this.foodIds,
        slotChosen: slotChosen ?? this.slotChosen,
      );
}

class MealDraftController extends Notifier<MealDraft> {
  @override
  MealDraft build() => const MealDraft();

  /// Changing meal clears the plate: "rice" at dinner and "rice" at breakfast
  /// are not the same selection, and keeping stale tiles reads as a bug.
  void setSlot(MealSlot slot) => state = MealDraft(slot: slot, slotChosen: true);

  void toggleFood(String id) {
    final next = {...state.foodIds};
    next.contains(id) ? next.remove(id) : next.add(id);
    state = state.copyWith(foodIds: next);
  }

  void reset() => state = const MealDraft();
}

final mealDraftProvider = NotifierProvider<MealDraftController, MealDraft>(MealDraftController.new);

/// The whole recommendation, recomputed whenever anything it depends on moves.
/// Foods the catalogue does not contain, described by the server in the
/// engine's own terms and then treated exactly like catalogue ones.
///
/// Somebody says "pancakes". There is no pancake in the catalogue, and the
/// engine never needed the name anyway — it reasons over protein, fibre and
/// fat. Held here rather than inside the catalogue because the catalogue is
/// the shipped, fixed thing and these arrive during a conversation.
class DescribedFoods extends Notifier<Map<String, FoodItem>> {
  @override
  Map<String, FoodItem> build() => const {};

  void remember(Iterable<FoodItem> foods) {
    if (foods.isEmpty) return;
    state = {...state, for (final food in foods) food.id: food};
  }
}

final describedFoodsProvider =
    NotifierProvider<DescribedFoods, Map<String, FoodItem>>(DescribedFoods.new);

final patchResultProvider = Provider<PatchResult>((ref) {
  final draft = ref.watch(mealDraftProvider);
  final settings = ref.watch(settingsProvider);
  final catalog = ref.watch(catalogProvider);
  final described = ref.watch(describedFoodsProvider);
  return ref.watch(patchEngineProvider).patch(
        slot: draft.slot,
        // The catalogue first, then anything the conversation had described for
        // it. A described food is an input to the engine like any other.
        foods: [
          for (final id in draft.foodIds)
            catalog.foodById(id) ?? described[id],
        ].whereType<FoodItem>().toList(),
        goal: settings.goal,
        prefs: settings.dietPrefs,
        insight: ref.watch(historyInsightProvider),
        // The whole catalogue, for everyone. The engine keeps the parameter
        // because its tests exercise both sides of it; the app has only one.
        isPro: true,
      );
});

/// Pictures of saved patches, on this device only.
final patchImagesProvider = Provider<PatchImages>((ref) => PatchImages());
