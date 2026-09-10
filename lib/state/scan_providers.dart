import 'dart:io' show Platform;


import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/image_pipeline.dart';
import '../data/prefs_repository.dart';
import '../data/scan_api.dart';
import '../domain/food_matcher.dart';
import '../domain/models.dart';
import 'providers.dart';

/// State for the scan flow.
///
/// The rule that shapes all of it: **an AI failure is never a dead end.** Every
/// error path here ends with the user able to build the meal by hand, because
/// that path has no network, no quota and no model in it.

final scanApiProvider = Provider<ScanApi>((ref) {
  final api = ScanApi(baseUrl: ScanApi.defaultBaseUrl);
  ref.onDispose(api.close);
  return api;
});

final imagePipelineProvider = Provider<ImagePipeline>((ref) => const ImagePipeline());

final foodMatcherProvider = Provider<FoodMatcher>(
  (ref) => FoodMatcher(ref.watch(catalogProvider).foods),
);

/// What the scan screen is doing right now.
enum ScanStage { idle, processing, uploading, done, failed }

@immutable
class ScanState {
  const ScanState({
    this.stage = ScanStage.idle,
    this.quota,
    this.recognized = const [],
    this.scanId,
    this.photo,
    this.failure,
    this.rejection,
    this.preview,
    this.previewFailure,
  });

  final ScanStage stage;
  final ScanQuota? quota;

  /// What the model saw, already matched against the catalogue.
  final List<RecognizedFood> recognized;
  final String? scanId;

  /// The processed photo, kept so a preview can reuse it without a second
  /// capture. Never leaves the device except as a scan or preview request.
  final Uint8List? photo;

  /// Why the request failed, if it did.
  final ScanFailure? failure;

  /// Why the photo itself was refused before any request was made.
  final PhotoRejection? rejection;

  /// The generated preview image, once it arrives. Device-only.
  final Uint8List? preview;

  /// Why a preview could not be produced. Kept apart from [failure] so a
  /// preview problem never looks like the patch itself failed.
  final ScanFailure? previewFailure;

  bool get isBusy => stage == ScanStage.processing || stage == ScanStage.uploading;

  /// The one line the UI shows when something went wrong.
  String? get problem => rejection?.message ?? failure?.message;

  ScanState copyWith({
    ScanStage? stage,
    ScanQuota? quota,
    List<RecognizedFood>? recognized,
    String? scanId,
    Uint8List? photo,
    ScanFailure? failure,
    PhotoRejection? rejection,
    Uint8List? preview,
    ScanFailure? previewFailure,
    bool clearProblem = false,
    bool clearPreview = false,
  }) =>
      ScanState(
        stage: stage ?? this.stage,
        quota: quota ?? this.quota,
        recognized: recognized ?? this.recognized,
        scanId: scanId ?? this.scanId,
        photo: photo ?? this.photo,
        failure: clearProblem ? null : (failure ?? this.failure),
        rejection: clearProblem ? null : (rejection ?? this.rejection),
        preview: clearPreview ? null : (preview ?? this.preview),
        previewFailure: clearPreview ? null : (previewFailure ?? this.previewFailure),
      );
}

class ScanController extends Notifier<ScanState> {
  @override
  ScanState build() => const ScanState();

  ScanApi get _api => ref.read(scanApiProvider);
  PrefsRepository get _prefs => ref.read(prefsRepositoryProvider);

  static String get _platform {
    if (kIsWeb) return 'android';
    return Platform.isIOS ? 'ios' : 'android';
  }

  /// The device token, registering on first use. Chat needs the same one the
  /// camera does, and registration is shared rather than duplicated.
  Future<String> deviceToken() => _deviceToken();

  /// Records a quota the server reported on some other call, so the camera's
  /// "N left" stays honest after a chat turn spends one.
  void noteQuota(ScanQuota quota) => state = state.copyWith(quota: quota);

  /// Returns the device token, registering on first use.
  ///
  /// Registration is lazy on purpose: someone who only ever builds meals by
  /// hand never touches the network at all.
  Future<String> _deviceToken() async {
    final existing = _prefs.deviceToken;
    if (existing != null) return existing;

    final registration = await _api.registerDevice(platform: _platform);
    await _prefs.setDeviceToken(registration.token);
    state = state.copyWith(quota: registration.quota);
    return registration.token;
  }

  /// Reads the allowance without spending any. Failures are swallowed: not
  /// knowing the quota is not worth an error in front of someone.
  Future<void> refreshQuota() async {
    try {
      final token = _prefs.deviceToken;
      if (token == null) return;
      state = state.copyWith(quota: await _api.quota(token));
    } on ScanFailure {
      // Leave the last known value in place.
    }
  }

  void reset() => state = const ScanState();

  /// The whole scan: process the photo on the device, send it, match the
  /// results onto the catalogue.
  Future<void> scan(Uint8List raw, {required MealSlot slot}) async {
    state = const ScanState(stage: ScanStage.processing);

    final processed = ref.read(imagePipelineProvider).process(raw);
    if (processed is PhotoRejected) {
      // Refused here means no request, no quota spent, no cost.
      state = state.copyWith(stage: ScanStage.failed, rejection: processed.reason);
      return;
    }
    final accepted = processed as PhotoAccepted;
    state = state.copyWith(stage: ScanStage.uploading, photo: accepted.jpeg);

    try {
      final token = await _deviceToken();
      final response = await _api.scan(deviceToken: token, jpeg: accepted.jpeg);
      final matched = ref.read(foodMatcherProvider).matchAll(response.foods, slot: slot);

      state = state.copyWith(
        stage: ScanStage.done,
        recognized: matched,
        scanId: response.scanId,
        quota: response.quota,
        clearProblem: true,
      );
    } on ScanFailure catch (failure) {
      // A stale token — the device row was deleted server-side — should mean
      // one silent re-registration, not a permanent lockout.
      if (failure.error == ScanError.unauthorized) {
        await _prefs.setDeviceToken(null);
      }
      state = state.copyWith(stage: ScanStage.failed, failure: failure);
    }
  }

  /// Removes something the model got wrong.
  void remove(RecognizedFood food) {
    state = state.copyWith(
      recognized: state.recognized.where((f) => f != food).toList(),
    );
  }

  /// Adds a food the model missed, from the catalogue.
  void add(FoodItem food) {
    if (state.recognized.any((f) => f.food?.id == food.id)) return;
    state = state.copyWith(
      recognized: [
        ...state.recognized,
        RecognizedFood(label: food.name, confidence: 1, food: food),
      ],
    );
  }

  /// Hands the confirmed foods to the meal draft, which the existing rule
  /// engine already watches. From here the scan flow is over and the app
  /// behaves exactly as it does for a hand-built meal.
  void confirm(MealSlot slot) {
    final draft = ref.read(mealDraftProvider.notifier);
    draft.setSlot(slot);
    for (final item in state.recognized) {
      final food = item.food;
      if (food != null) draft.toggleFood(food.id);
    }
  }

  /// Draws the meal with one addition on it.
  ///
  /// A preview is a bonus. If it fails, the patch is untouched and the failure
  /// is kept in its own field so nothing about the suggestion looks broken.
  Future<void> generatePreview(String additionId) async {
    final photo = state.photo;
    final token = _prefs.deviceToken;
    if (photo == null || token == null) return;

    state = state.copyWith(clearPreview: true);
    try {
      final result = await _api.preview(
        deviceToken: token,
        jpeg: photo,
        additionId: additionId,
        scanId: state.scanId,
      );
      final bytes = await _api.previewImage(deviceToken: token, url: result.url);
      state = state.copyWith(preview: bytes, quota: result.quota);
    } on ScanFailure catch (failure) {
      state = state.copyWith(previewFailure: failure);
    }
  }

  /// Erases everything: the saved meals and preferences on this phone, and the
  /// device row, quota, scan records and reports on the server.
  ///
  /// The privacy policy promises this, so it has to do all of it. The server
  /// call is best-effort — a network failure must not stop local data being
  /// cleared, or someone asking to be forgotten leaves with nothing deleted.
  Future<void> deleteEverything() async {
    final token = _prefs.deviceToken;
    if (token != null) {
      try {
        await _api.forgetDevice(token);
      } on ScanFailure {
        // Logged by absence: the device row is orphaned and will be swept.
      }
      await _prefs.setDeviceToken(null);
    }
    await _prefs.setHistory(const []);
    await _prefs.setDietPrefs(const {});
    await ref.read(historyProvider.notifier).clear();
    ref.read(mealDraftProvider.notifier).reset();
    state = const ScanState();
  }

  /// Google Play requires this to exist and to be reachable in-app.
  Future<void> report({required String reason, String? note}) async {
    final token = _prefs.deviceToken;
    if (token == null) return;
    await _api.report(
      deviceToken: token,
      targetType: 'scan',
      targetId: state.scanId ?? 'unknown',
      reason: reason,
      note: note,
    );
  }
}

final scanControllerProvider =
    NotifierProvider<ScanController, ScanState>(ScanController.new);
