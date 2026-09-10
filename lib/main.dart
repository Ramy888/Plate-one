import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/catalog.dart';
import 'data/prefs_repository.dart';
import 'state/providers.dart';
import 'ui/voice_agent_screen.dart';
import 'ui/onboarding_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Both are local: bundled JSON and on-device preferences. Nothing here can
  // hang on a network call, so there is no splash screen to get stuck on.
  final prefs = await PrefsRepository.open();
  final catalog = await Catalog.load();

  runApp(
    ProviderScope(
      overrides: [
        prefsRepositoryProvider.overrideWithValue(prefs),
        catalogProvider.overrideWithValue(catalog),
      ],
      child: const PlateOneApp(),
    ),
  );
}

class PlateOneApp extends StatelessWidget {
  const PlateOneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Plate One',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const _RootGate(),
    );
  }
}

class _RootGate extends ConsumerWidget {
  const _RootGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onboarded = ref.watch(settingsProvider.select((s) => s.onboarded));
    return onboarded ? const VoiceAgentScreen() : const OnboardingScreen();
  }
}
