import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plateone/data/voice_agent_events.dart';
import 'package:plateone/data/voice_agent_session.dart';
import 'package:plateone/data/catalog.dart';
import 'package:plateone/data/prefs_repository.dart';
import 'package:plateone/state/providers.dart';
import 'package:plateone/state/plate_providers.dart';
import 'package:plateone/state/voice_conversation.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:plateone/ui/theme.dart';
import 'package:plateone/ui/voice_agent_screen.dart';
import 'package:plateone/ui/widgets/mic_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A conversation with nothing behind it.
///
/// The screen is written to draw from [VoiceConversationState] alone, which is
/// what makes this possible: no socket, no microphone, no browser, and every
/// event arrives exactly when the test says so.
class FakeSession implements VoiceSession {
  FakeSession({this.failOnStart});

  /// When set, `start()` throws and reports this.
  final String? failOnStart;

  final _events = StreamController<VoiceEvent>.broadcast();
  final _states = StreamController<VoiceAgentState>.broadcast();

  bool started = false;
  bool stopped = false;
  bool disposed = false;

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  Stream<VoiceAgentState> get state => _states.stream;

  @override
  VoiceAgentState currentState = VoiceAgentState.idle;

  @override
  String? failure;

  /// Pushes an event as the server would.
  void says(VoiceEvent event) => _events.add(event);

  /// Moves the session, the way the real one moves itself.
  void becomes(VoiceAgentState next) {
    currentState = next;
    _states.add(next);
  }

  @override
  Future<void> start() async {
    started = true;
    if (failOnStart case final message?) {
      failure = message;
      throw VoiceFailure(message);
    }
    becomes(VoiceAgentState.connecting);
  }

  @override
  Future<void> stop() async {
    stopped = true;
    becomes(VoiceAgentState.ended);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
    await _states.close();
  }
}

void main() {
  late FakeSession session;

  // Loaded once. Reading the bundled catalogue on every test is slow and, more
  // to the point, the asset bundle does not enjoy being asked repeatedly.
  late Catalog catalog;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    catalog = await Catalog.load();
  });

  /// Opens the home screen with the app's real providers behind it, and hands
  /// back the container so a test can drive state the way the agent would.
  Future<ProviderContainer> openHome(
    WidgetTester tester, {
    String? failOnStart,
  }) async {
    session = FakeSession(failOnStart: failOnStart);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsRepositoryProvider.overrideWithValue(await _prefs()),
          catalogProvider.overrideWithValue(catalog),
          voiceSessionFactoryProvider.overrideWithValue(() => session),
          // No network in a widget test. Drawing a plate is a Worker call and
          // a model behind it; what is under test here is what the screen does
          // with the answer, not the asking.
          plateVisualProvider.overrideWith(_NoDrawing.new),
        ],
        child: MediaQuery(
          // The skeleton sweep is deliberately endless; a test that settles on
          // it never finishes.
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(theme: buildTheme(), home: const VoiceAgentScreen()),
        ),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(VoiceAgentScreen)));
  }

  /// Taps the microphone and lets the state settle.
  Future<void> tapMic(WidgetTester tester) async {
    // Specifically the microphone. The app bar now has buttons of its own, and
    // "the first InkWell" quietly became the bookmark icon.
    await tester.tap(
      find.descendant(of: find.byType(MicButton), matching: find.byType(InkWell)),
    );
    // Not pumpAndSettle: the mic's ring is a real animation and settling on it
    // is slower than it is useful.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('opens quiet, and says what to do', (tester) async {
    await openHome(tester);
    expect(find.text('Tap to talk'), findsOneWidget);
    expect(find.textContaining('Tap the microphone'), findsOneWidget);
    expect(session.started, isFalse, reason: 'nothing is spent by arriving');
  });

  testWidgets('the microphone starts the conversation', (tester) async {
    await openHome(tester);
    await tapMic(tester);

    expect(session.started, isTrue);
    expect(find.text('Connecting…'), findsOneWidget);
  });

  testWidgets('the state is on screen at every step', (tester) async {
    // A demo is watched, not used. Whoever is watching has to be able to tell
    // listening from thinking from speaking without being told.
    await openHome(tester);
    await tapMic(tester);

    for (final (next, label) in [
      (VoiceAgentState.listening, 'Listening'),
      (VoiceAgentState.thinking, 'Thinking'),
      (VoiceAgentState.speaking, 'Speaking'),
      (VoiceAgentState.ended, 'Ended'),
    ]) {
      session.becomes(next);
      await tester.pump();
      expect(find.text(label), findsOneWidget, reason: 'state $next');
    }
  });

  testWidgets('a user partial is replaced, never concatenated', (tester) async {
    // Each `transcript.user.delta` is the whole transcript so far. Appending
    // them renders "rice rice and rice and chicken".
    await openHome(tester);
    await tapMic(tester);
    session.becomes(VoiceAgentState.listening);

    session.says(const SpeechStarted());
    session.says(const UserTranscriptDelta('rice'));
    await tester.pump();
    expect(find.text('rice'), findsOneWidget);

    session.says(const UserTranscriptDelta('rice and'));
    session.says(const UserTranscriptDelta('rice and chicken'));
    await tester.pump();

    expect(find.text('rice and chicken'), findsOneWidget);
    expect(find.text('rice'), findsNothing);
    expect(find.text('rice and'), findsNothing);
  });

  testWidgets('an agent partial is appended, never replaced', (tester) async {
    // And this one is the opposite: `delta` is the next word.
    await openHome(tester);
    await tapMic(tester);

    session.says(const ReplyStarted('r1'));
    session.says(const AgentTranscriptDelta('What is '));
    session.says(const AgentTranscriptDelta('on your '));
    session.says(const AgentTranscriptDelta('plate?'));
    await tester.pump();

    expect(find.text('What is on your plate?'), findsOneWidget);
  });

  testWidgets('a settled turn stays in the thread', (tester) async {
    await openHome(tester);
    await tapMic(tester);

    session.says(const SpeechStarted());
    session.says(const UserTranscript('rice and chicken'));
    session.says(const ReplyStarted('r1'));
    session.says(const AgentTranscript(text: 'Anything green?', interrupted: false));
    await tester.pump();

    expect(find.text('rice and chicken'), findsOneWidget);
    expect(find.text('Anything green?'), findsOneWidget);
  });

  testWidgets('an interruption is shown, because it is the point', (tester) async {
    await openHome(tester);
    await tapMic(tester);

    session.says(const ReplyStarted('r1'));
    session.says(const AgentTranscript(text: 'Rice is a good base', interrupted: true));
    await tester.pump();

    expect(find.text('you jumped in'), findsOneWidget);
  });

  testWidgets('the microphone ends a live conversation', (tester) async {
    await openHome(tester);
    await tapMic(tester);
    session.becomes(VoiceAgentState.listening);
    await tester.pump();

    await tapMic(tester);
    expect(session.stopped, isTrue);
  });

  testWidgets('a refusal keeps the words and offers a way out', (tester) async {
    // The standing rule: an AI failure is never a dead end.
    await openHome(
      tester,
      failOnStart: 'Plate One has answered as many questions as it can today.',
    );
    await tapMic(tester);

    expect(find.textContaining('as many questions as it can today'), findsOneWidget);
    expect(find.text('Build it by hand'), findsOneWidget);
  });

  testWidgets('leaving the screen ends the conversation', (tester) async {
    // A back-swipe that leaves the microphone lit is the same billing leak as
    // a socket left open, one screen up.
    session = FakeSession();
    final key = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voiceSessionFactoryProvider.overrideWithValue(() => session),
        ],
        child: MaterialApp(
          navigatorKey: key,
          theme: buildTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const VoiceAgentScreen()),
                ),
                child: const Text('talk'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('talk'));
    await tester.pumpAndSettle();
    await tapMic(tester);
    expect(session.started, isTrue);

    key.currentState!.pop();
    await tester.pumpAndSettle();

    expect(session.disposed, isTrue);
  });

  testWidgets('the engine\'s options arrive as cards you can try', (tester) async {
    // Three things to choose between is something you tap, not a sentence you
    // listen to twice.
    final container = await openHome(tester);

    final options = container.read(agentToolsProvider);
    container.read(mealDraftProvider.notifier).toggleFood('white_rice');
    container.read(voiceConversationProvider.notifier).offer(options.recommendNow());
    await tester.pump();

    expect(find.text('Tap one to see it on your plate'), findsOneWidget);
    final offered = container.read(patchResultProvider).patches;
    expect(offered, isNotEmpty);
    expect(find.text(offered.first.addition.name), findsOneWidget);
  });

  testWidgets('tapping an option puts it on the plate', (tester) async {
    final container = await openHome(tester);

    container.read(mealDraftProvider.notifier).toggleFood('white_rice');
    final offered = container.read(agentToolsProvider).recommendNow();
    container.read(voiceConversationProvider.notifier).offer(offered);
    await tester.pump();

    expect(container.read(chosenPatchProvider), isNull);
    await tester.tap(find.text(offered.first.addition.name));
    await tester.pump();

    expect(container.read(chosenPatchProvider)?.addition.id, offered.first.addition.id);
    expect(find.text('Keep this'), findsOneWidget);
  });

  testWidgets('every settled reply offers the answer without waiting for it',
      (tester) async {
    // "Add patch now" — for someone who does not want to talk their way to the
    // question.
    final container = await openHome(tester);
    container.read(mealDraftProvider.notifier).toggleFood('white_rice');
    // Nothing listens to the session until the conversation has been started.
    await tapMic(tester);

    session.says(const ReplyStarted('r1'));
    session.says(const AgentTranscript(text: 'Anything green?', interrupted: false));
    await tester.pump();

    expect(find.text('Add patch now'), findsOneWidget);
    await tester.tap(find.text('Add patch now'));
    await tester.pump();

    expect(find.text('Tap one to see it on your plate'), findsOneWidget);
  });

  testWidgets('the plate is empty before anything is described', (tester) async {
    // There has to be something to look at before there is anything to show.
    await openHome(tester);

    expect(find.byIcon(LucideIcons.utensils), findsOneWidget);
    expect(find.byType(Image), findsOneWidget, reason: 'the brand mark only');
  });

  testWidgets('the answer time is put in front of whoever is watching',
      (tester) async {
    // The demo's headline number, measured from the first turn rather than
    // bolted on at the end.
    await openHome(tester);
    await tapMic(tester);

    session.says(const SpeechStopped());
    await tester.pump(const Duration(milliseconds: 120));
    session.says(const ReplyStarted('r1'));
    session.says(ReplyAudio(replyId: 'r1', pcm16: Uint8List.fromList([1, 2])));
    await tester.pump();

    expect(find.textContaining('ms'), findsOneWidget);
  });
}

Future<PrefsRepository> _prefs() async {
  SharedPreferences.setMockInitialValues({});
  return PrefsRepository(await SharedPreferences.getInstance());
}

/// A plate that is never drawn. Keeps the widget tests off the network.
class _NoDrawing extends PlateVisualController {
  @override
  Future<void> load({required List<String> foodIds, String additionId = ''}) async {}
}
