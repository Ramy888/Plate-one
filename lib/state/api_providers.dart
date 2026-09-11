import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/prefs_repository.dart';
import '../data/api.dart';
import '../domain/food_matcher.dart';
import 'providers.dart';

/// The device's relationship with the Worker: who it is, and what it has left.
///
/// There are no accounts. A device gets an anonymous id on first use, that id
/// carries a daily allowance, and nothing here knows anything about a person.
///
/// The rule that shapes all of it: **an AI failure is never a dead end.** Every
/// error path ends with the user able to build the meal by hand, because that
/// path has no network, no allowance and no model in it.

final apiProvider = Provider<PlateApi>((ref) {
  final api = PlateApi(baseUrl: PlateApi.defaultBaseUrl);
  ref.onDispose(api.close);
  return api;
});

final foodMatcherProvider = Provider<FoodMatcher>(
  (ref) => FoodMatcher(ref.watch(catalogProvider).foods),
);

/// What the app knows about its own standing with the Worker.
@immutable
class DeviceState {
  const DeviceState({this.quota});

  /// What is left today, as last reported. Null before the device has ever
  /// registered — which, for someone who only ever builds meals by hand, is
  /// forever.
  final Allowance? quota;

  DeviceState copyWith({Allowance? quota}) => DeviceState(quota: quota ?? this.quota);
}

class DeviceController extends Notifier<DeviceState> {
  @override
  DeviceState build() => const DeviceState();

  PlateApi get _api => ref.read(apiProvider);
  PrefsRepository get _prefs => ref.read(prefsRepositoryProvider);

  static String get _platform {
    if (kIsWeb) return 'web';
    return Platform.isIOS ? 'ios' : 'android';
  }

  /// The device token, registering on first use.
  ///
  /// Registration is lazy on purpose: someone who never speaks and never asks
  /// for a picture never touches the network at all.
  Future<String> token() async {
    final existing = _prefs.deviceToken;
    if (existing != null) return existing;

    final registration = await _api.registerDevice(platform: _platform);
    await _prefs.setDeviceToken(registration.token);
    state = state.copyWith(quota: registration.quota);
    return registration.token;
  }

  /// Records an allowance the server reported on some other call, so what the
  /// app shows stays honest after a conversation or a picture spends one.
  void noteQuota(Allowance quota) => state = state.copyWith(quota: quota);

  /// Reads the allowance without spending any. Failures are swallowed: not
  /// knowing the quota is not worth an error in front of someone.
  Future<void> refreshQuota() async {
    try {
      final saved = _prefs.deviceToken;
      if (saved == null) return;
      state = state.copyWith(quota: await _api.quota(saved));
    } on ApiFailure {
      // Leave the last known value in place.
    }
  }

  /// Backs the "delete my data" promise with a real call, then forgets
  /// everything on this device too.
  Future<void> deleteEverything() async {
    final saved = _prefs.deviceToken;
    if (saved != null) {
      try {
        await _api.forgetDevice(saved);
      } on ApiFailure {
        // Logged by absence: the device row is orphaned and will be swept.
      }
      await _prefs.setDeviceToken(null);
    }
    await _prefs.setHistory(const []);
    await _prefs.setDietPrefs(const {});
    await ref.read(historyProvider.notifier).clear();
    ref.read(mealDraftProvider.notifier).reset();
    state = const DeviceState();
  }

  /// Reporting an AI result. The rule is older than any store requirement: if
  /// software shows someone a picture it made up, there has to be a way to say
  /// so. It must never fail in front of them, so the API swallows everything.
  Future<void> report({
    required String targetId,
    required String reason,
    String? note,
  }) async {
    final saved = _prefs.deviceToken;
    if (saved == null) return;
    await _api.report(
      deviceToken: saved,
      targetType: 'plate',
      targetId: targetId,
      reason: reason,
      note: note,
    );
  }
}

final deviceProvider =
    NotifierProvider<DeviceController, DeviceState>(DeviceController.new);
