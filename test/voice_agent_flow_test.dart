import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:plateone/data/patch_images.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plateone/data/voice_agent_events.dart';
import 'package:plateone/data/voice_agent_session.dart';
import 'package:plateone/data/catalog.dart';
import 'package:plateone/data/prefs_repository.dart';
import 'package:plateone/state/providers.dart';
import 'package:plateone/data/api.dart';
import 'package:plateone/state/api_providers.dart';
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
  FakeSession({this.failOnStart, this.throwOnStart});

  /// When set, `start()` throws and reports this.
  final String? failOnStart;

  /// When set, `start()` throws this instead — for the refusals that are not
  /// a voice failure at all, like a spent try.
  final Object? throwOnStart;

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
    if (throwOnStart case final error?) throw error;
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
  late MemoryPatchImages savedImages;
  late _KeepApi keepApi;

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
    Object? throwOnStart,
  }) async {
    session = FakeSession(failOnStart: failOnStart, throwOnStart: throwOnStart);
    savedImages = MemoryPatchImages();
    keepApi = _KeepApi();
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
          // Saving writes the picture to disk. There is no disk here.
          patchImagesProvider.overrideWithValue(savedImages),
          // Keeping a plate tells the server the try is over.
          apiProvider.overrideWithValue(keepApi),
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
  ///
  /// It is in two places by design: the big one under the plate while the
  /// screen is idle, and — once there is a conversation on a phone — an icon in
  /// the app bar, because the thread has taken the screen by then.
  Future<void> tapMic(WidgetTester tester) async {
    final big = find.descendant(
      of: find.byType(MicButton),
      matching: find.byType(InkWell),
    );
    // Specifically the microphone. The app bar has buttons of its own, and
    // "the first InkWell" quietly became the bookmark icon.
    await tester.tap(
      big.evaluate().isNotEmpty
          ? big
          : find.byTooltip('End the conversation'),
    );
    // Not pumpAndSettle: the mic's ring is a real animation and settling on it
    // is slower than it is useful.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Keeps the plate the way a phone does it: the plate lives behind a handle,
  /// so the button that acts on it is only reachable once the sheet is down.
  Future<void> keepPlate(WidgetTester tester) async {
    final handle = find.text('See your plate');
    if (handle.evaluate().isNotEmpty) {
      await tester.tap(handle);
      // The first frame starts the slide; the second one runs it out.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.tap(find.byTooltip('Add this plate to favourite plates'));
    // Saving is a round trip before it is a toast.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('opens quiet, and says what to do', (tester) async {
    await openHome(tester);
    // Idle is the plate, the microphone and the one line saying what to do.
    // There is no transcript yet and no empty panel pretending to be one.
    expect(find.text('Describe your meal'), findsOneWidget);
    expect(find.byType(MicButton), findsOneWidget);
    expect(find.textContaining('Tap the microphone'), findsNothing);
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
    ]) {
      session.becomes(next);
      // Twice: the state arrives on a stream, and the frame that renders it
      // is the next one.
      await tester.pump();
      await tester.pump();
      expect(find.text(label), findsOneWidget, reason: 'state $next');
    }

    // Ended reads the same as idle, because it is the same: an empty plate
    // waiting to be told about.
    session.becomes(VoiceAgentState.ended);
    await tester.pump();
    await tester.pump();
    expect(find.text('Describe your meal'), findsOneWidget);
    for (final label in ['Listening', 'Thinking', 'Speaking']) {
      expect(find.text(label), findsNothing, reason: 'after ending');
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
    await tester.pump();
    expect(find.text('rice'), findsOneWidget);

    session.says(const UserTranscriptDelta('rice and'));
    session.says(const UserTranscriptDelta('rice and chicken'));
    await tester.pump();
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
    // Bare words, the way the wire sends them: no leading space, and the
    // question mark stuck to the word before it. This fixture used to carry
    // its own trailing spaces, which is why every reply read
    // "Whatisonyourplate?" on screen while a test said otherwise.
    session.says(const AgentTranscriptDelta('What'));
    session.says(const AgentTranscriptDelta('is'));
    session.says(const AgentTranscriptDelta('on'));
    session.says(const AgentTranscriptDelta('your'));
    session.says(const AgentTranscriptDelta('plate?'));
    await tester.pump();
    await tester.pump();

    expect(find.text('What is on your plate?'), findsOneWidget);
  });

  testWidgets('punctuation stays attached to the word it follows', (tester) async {
    await openHome(tester);
    await tapMic(tester);

    session.says(const ReplyStarted('r1'));
    for (final word in ['Rice', ',', 'chicken', 'and', 'salad', '.']) {
      session.says(AgentTranscriptDelta(word));
    }
    // A delta that brings its own space must not get a second one.
    session.says(const AgentTranscriptDelta(' Good'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Rice, chicken and salad. Good'), findsOneWidget);
  });

  testWidgets('a settled turn stays in the thread', (tester) async {
    await openHome(tester);
    await tapMic(tester);

    session.says(const SpeechStarted());
    session.says(const UserTranscript('rice and chicken'));
    session.says(const ReplyStarted('r1'));
    session.says(const AgentTranscript(text: 'Anything green?', interrupted: false));
    await tester.pump();
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
          // Starting a conversation reaches the agent's tools, and those read
          // the catalogue. Faking the session hid that; it is real either way,
          // since the real factory reads the same provider.
          catalogProvider.overrideWithValue(catalog),
          // The app bar counts the plates left, which means reading the device.
          prefsRepositoryProvider.overrideWithValue(await _prefs()),
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

    container.read(mealDraftProvider.notifier).toggleFood('white_rice');
    // Running the engine puts the row in the conversation by itself — that is
    // the same callback the agent's own tool call goes through.
    container.read(agentToolsProvider).recommendNow();
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
    await tester.pump();

    expect(container.read(chosenPatchProvider), isNull);
    // The thread scrolls itself; find the card where it ended up.
    // The plate slides out of the way when the conversation starts; let it
    // land before reaching for anything.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.ensureVisible(find.text(offered.first.addition.name));
    await tester.pump();
    await tester.tap(find.text(offered.first.addition.name));
    await tester.pump();

    expect(container.read(chosenPatchProvider)?.addition.id, offered.first.addition.id);
    // On a phone the plate is behind a handle, so the way to keep it is behind
    // the same one. The sheet is built either way — it is parked above the top
    // of the screen — so this asks where it is, not whether it exists.
    // Past the opening peek, which puts the sheet down and takes it back up.
    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pump(const Duration(milliseconds: 500));

    final save = find.byTooltip('Add this plate to favourite plates');
    expect(tester.getTopLeft(save).dy, lessThan(0), reason: 'the sheet parks up out of sight');

    await tester.tap(find.text('See your plate'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.getTopLeft(save).dy, greaterThanOrEqualTo(0),
        reason: 'pulling the handle brings the plate down over the thread');
  });

  testWidgets('the cards arrive under the sentence that introduces them',
      (tester) async {
    // The engine answers in milliseconds; the sentence about its answer takes
    // ten seconds to say. Shown when the tool returns, the cards land above
    // their own explanation, and the reply points "below" at a row already
    // above it.
    final container = await openHome(tester);
    container.read(mealDraftProvider.notifier).toggleFood('white_rice');
    await tapMic(tester);

    await container.read(agentToolsProvider).dispatch(const ToolCall(
      callId: 'c1',
      name: 'get_recommendation',
      arguments: <String, dynamic>{},
    ));
    await tester.pump();
    expect(find.text('Tap one to see it on your plate'), findsNothing,
        reason: 'the agent has not said anything about them yet');

    // The tool call has a reply all of its own, and it ends the moment the
    // engine answers — nine seconds before a word is spoken about it. That
    // ending must not be mistaken for the agent having introduced anything.
    session.says(const ReplyDone(replyId: 'tools', interrupted: false));
    await tester.pump();
    expect(find.text('Tap one to see it on your plate'), findsNothing,
        reason: 'a tool call finishing is not the agent speaking');

    session.says(const ReplyStarted('r1'));
    session.says(const AgentTranscript(text: 'You could add a salad.', interrupted: false));
    await tester.pump();
    await tester.pump();

    expect(find.text('Tap one to see it on your plate'), findsOneWidget);
    // It used to be a second button that ran the engine. Two controls doing
    // the same job only makes someone wonder which is the real one.
    expect(find.text('Select from patches below'), findsOneWidget);
    expect(find.text('Add patch now'), findsNothing);
  });

  testWidgets('a reply with no cards under it does not point at any',
      (tester) async {
    // "I did not recognise those" and "I can only talk about what is on the
    // plate" both used to carry a line telling someone to select from patches
    // below, with nothing below to select.
    await openHome(tester);
    await tapMic(tester);

    session.says(const ReplyStarted('r1'));
    session.says(const AgentTranscript(text: 'Anything green?', interrupted: false));
    await tester.pump();
    await tester.pump();

    expect(find.text('Anything green?'), findsOneWidget);
    expect(find.text('Select from patches below'), findsNothing);
  });

  testWidgets('a fourth card reveals one more, without a second round trip',
      (tester) async {
    final container = await openHome(tester);
    container.read(mealDraftProvider.notifier).toggleFood('white_rice');
    final offered = container.read(agentToolsProvider).recommendNow();
    await tester.pump();

    expect(offered.length, greaterThan(3), reason: 'the engine has more to give');
    final shownAtFirst = container.read(voiceConversationProvider).turns.last.shown;
    expect(shownAtFirst, 3);

    // The row scrolls; the fourth card starts off the right-hand edge.
    await tester.ensureVisible(find.text('Show more'));
    await tester.pump();
    await tester.tap(find.text('Show more'));
    await tester.pump();

    expect(container.read(voiceConversationProvider).turns.last.shown, 4);
    expect(find.text(offered[3].addition.name), findsOneWidget);
  });

  testWidgets('the newest line is the one on screen', (tester) async {
    // A transcript that does not follow itself is a transcript nobody reads:
    // the newest line is the one being spoken.
    await openHome(tester);
    await tapMic(tester);

    for (var i = 0; i < 25; i++) {
      session.says(const SpeechStarted());
      session.says(UserTranscript('line number $i on the plate'));
      session.says(const ReplyStarted('r'));
      session.says(AgentTranscript(text: 'reply number $i', interrupted: false));
    }
    // The events, the frame that renders them, then the scroll that follows.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('reply number 24'), findsOneWidget);
    expect(find.text('line number 0 on the plate'), findsNothing,
        reason: 'the top of a long thread is scrolled away, not still showing');
  });

  testWidgets('a wide window puts the plate beside the conversation',
      (tester) async {
    // A chat stretched across sixteen hundred pixels is a chat nobody can read
    // a line of.
    tester.view.physicalSize = const Size(2400, 1400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final container = await openHome(tester);
    container.read(mealDraftProvider.notifier).toggleFood('white_rice');
    final offered = container.read(agentToolsProvider).recommendNow();
    await tester.pump();

    // The plate slides out of the way when the conversation starts; let it
    // land before reaching for anything.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.ensureVisible(find.text(offered.first.addition.name));
    await tester.pump();
    await tester.tap(find.text(offered.first.addition.name));
    await tester.pump();

    // The plate column and the thread are side by side, and what was chosen
    // sits under the plate rather than at the end of the conversation.
    expect(find.byType(Row), findsWidgets);
    expect(find.text('Add this plate to favourite plates'), findsOneWidget);
    final plate = tester.getCenter(find.byType(MicButton));
    expect(plate.dx, greaterThan(600), reason: 'the mic is in the right-hand column');
  });

  testWidgets('the plate is empty before anything is described', (tester) async {
    // There has to be something to look at before there is anything to show.
    await openHome(tester);

    expect(find.byIcon(LucideIcons.utensils), findsOneWidget);
    expect(find.byType(Image), findsOneWidget, reason: 'the brand mark only');
  });

  testWidgets('ending the conversation clears the plate and the thread',
      (tester) async {
    // Leaving the last plate and its transcript on screen would mean the next
    // person to speak starts by clearing away somebody else's dinner.
    final container = await openHome(tester);
    await tapMic(tester);
    session.becomes(VoiceAgentState.listening);
    session.says(const SpeechStarted());
    session.says(const UserTranscript('rice and chicken'));
    await tester.pump();
    await tester.pump();
    expect(find.text('rice and chicken'), findsOneWidget);

    await container.read(voiceConversationProvider.notifier).stop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('rice and chicken'), findsNothing);
    expect(container.read(voiceConversationProvider).turns, isEmpty);
    expect(container.read(chosenPatchProvider), isNull);
    expect(container.read(mealDraftProvider).foodIds, isEmpty);
    // Back to idle: the plate, the microphone, and nothing else.
    expect(find.byType(MicButton), findsOneWidget);
    expect(find.text('Describe your meal'), findsOneWidget);
  });

  testWidgets('the app bar says how many plates are left', (tester) async {
    // Running out is the one thing that stops this app working — the
    // microphone will not open without a plate — and it used to be invisible
    // until the moment it bit.
    final container = await openHome(tester);
    container.read(deviceProvider.notifier).noteQuota(
          Allowance(
            plates: 7,
            previews: 9,
            voice: 9,
            resetsAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );
    await tester.pump();

    expect(find.text('7'), findsOneWidget);
    expect(find.byTooltip('7 plates left today'), findsOneWidget);
  });

  testWidgets('the count appears as soon as the device registers', (tester) async {
    // The path production actually takes: nothing is known until the first
    // call, and registering is what first reports an allowance.
    final container = await openHome(tester);
    expect(find.byTooltip('1 plate left today'), findsNothing);

    await container.read(deviceProvider.notifier).token();
    await tester.pump();

    expect(find.byTooltip('1 plate left today'), findsOneWidget);
  });

  testWidgets('an empty count says where more come from', (tester) async {
    final container = await openHome(tester);
    container.read(deviceProvider.notifier).noteQuota(
          Allowance(
            plates: 0,
            previews: 9,
            voice: 9,
            resetsAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );
    await tester.pump();

    expect(find.byTooltip('No plates left today. A promo code opens more.'),
        findsOneWidget);

    // And it is the way back in, not just a readout.
    await tester.tap(find.text('0'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Have a promo code?'), findsOneWidget);
  });

  testWidgets('the plate peeks out once when the conversation opens', (tester) async {
    // The plate lives behind a handle on a phone, which makes it easy to never
    // discover. It comes down by itself as the conversation starts, holds long
    // enough to be read, and goes back up.
    await openHome(tester);
    await tapMic(tester);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Hide plate'), findsOneWidget,
        reason: 'the plate should show itself without being asked');

    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('See your plate'), findsOneWidget,
        reason: 'and then get out of the way again');
  });

  testWidgets('the peek happens once, not on every turn', (tester) async {
    // The sheet is shown as the conversation opens. It must not come back down
    // every time a line arrives — the thread updates constantly while someone
    // is talking, and a plate that drops over it each time is unusable.
    final container = await openHome(tester);
    await tapMic(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('See your plate'), findsOneWidget, reason: 'peek is over');

    for (final line in ['rice', 'and chicken', 'and salad']) {
      session.says(const ReplyStarted('r'));
      session.says(AgentTranscript(text: line, interrupted: false));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }
    container.read(mealDraftProvider.notifier).toggleFood('white_rice');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('See your plate'), findsOneWidget,
        reason: 'the sheet stayed where it was left');
  });

  testWidgets('a peek does not fight someone who opened it themselves',
      (tester) async {
    await openHome(tester);
    await tapMic(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Closed by hand while the peek is still counting down. The timer must not
    // come along afterwards and move it again.
    await tester.tap(find.text('Hide plate'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('See your plate'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Hide plate'), findsOneWidget,
        reason: 'left where the person put it');
  });

  testWidgets('saying "save it" keeps the plate, same as the button', (tester) async {
    // The agent declares a `save_patch` tool. Wiring it needs a BuildContext —
    // the save shows a toast — and the provider that builds the tools has none,
    // so the screen has to hand one over. Left unwired the tool can only ever
    // refuse, and the agent cheerfully offers to save and then apologises. The
    // unit test for the tool passes either way: it supplies its own `onSave`.
    final container = await openHome(tester);
    await tapMic(tester);
    container.read(mealDraftProvider.notifier).toggleFood('white_rice');
    final offered = container.read(agentToolsProvider).recommendNow();
    await tester.pump(const Duration(milliseconds: 500));
    final tools = container.read(agentToolsProvider);

    // Chosen by the agent, not by a tap: this is the spoken path end to end,
    // and `choose_patch` is what puts the addition where `save_patch` looks.
    await tools.dispatch(ToolCall(
      callId: 'c0',
      name: 'choose_patch',
      arguments: {'addition_id': offered.first.addition.id},
    ));
    await tester.pump(const Duration(milliseconds: 500));

    expect(tools.onSave, isNotNull, reason: 'the screen never wired save_patch');

    // Through the tool, exactly as a spoken "save it" arrives.
    final result = await tools.dispatch(const ToolCall(
      callId: 'c1',
      name: 'save_patch',
      arguments: <String, dynamic>{},
    ));
    await tester.pump();
    await tester.pump();

    expect((result! as Map<String, dynamic>)['saved'], isTrue);
    expect(container.read(historyProvider), hasLength(1));
    expect(find.textContaining('favourites'), findsOneWidget, reason: 'the toast');

    // Unlike the button, this one leaves the conversation running: the agent is
    // still mid-turn saying it saved, and stopping here cuts it off.
    await tester.pump(const Duration(milliseconds: 600));
    expect(container.read(voiceConversationProvider).isLive, isTrue);
  });

  testWidgets('keeping the plate says so, then clears the screen', (tester) async {
    final container = await openHome(tester);
    await tapMic(tester);
    container.read(mealDraftProvider.notifier).toggleFood('white_rice');
    final offered = container.read(agentToolsProvider).recommendNow();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.ensureVisible(find.text(offered.first.addition.name));
    await tester.pump();
    await tester.tap(find.text(offered.first.addition.name));
    await tester.pump();

    // The offer to keep it sits above the plate, not at the end of the thread.
    await keepPlate(tester);
    await tester.pump();
    await tester.pump();

    // A toast the width of its own text, not a bar across the window.
    final toast = tester.getSize(find.ancestor(
      of: find.textContaining('favourites'),
      matching: find.byType(Container),
    ).first);
    expect(toast.width, lessThan(500));
    expect(find.textContaining('favourites'), findsOneWidget, reason: 'the toast');
    expect(container.read(historyProvider), hasLength(1));

    await tester.pump(const Duration(milliseconds: 600));
    expect(container.read(chosenPatchProvider), isNull,
        reason: 'the screen goes back to idle once the plate is kept');
  });

  testWidgets('the picture is kept with the plate, not just shown once',
      (tester) async {
    // The server deletes its copy within a day, so a saved plate keeps its own.
    // A history of grey placeholders is not worth keeping.
    final container = await openHome(tester);
    await tapMic(tester);
    container.read(mealDraftProvider.notifier).toggleFood('white_rice');
    final offered = container.read(agentToolsProvider).recommendNow();
    await tester.pump(const Duration(milliseconds: 500));

    // A plate that has been drawn. A real one-pixel PNG, because the screen
    // decodes whatever it is given.
    container.read(plateVisualProvider.notifier).state =
        PlateVisual(image: _onePixelPng);

    await tester.ensureVisible(find.text(offered.first.addition.name));
    await tester.pump();
    await tester.tap(find.text(offered.first.addition.name));
    await tester.pump();
    await keepPlate(tester);
    await tester.pump();
    await tester.pump();

    final saved = container.read(historyProvider).single;
    expect(saved.imagePath, isNotNull, reason: 'the picture was filed with it');
    expect(await savedImages.get(saved.imagePath), isNotEmpty);
  });

  testWidgets('keeping the plate ends the day\'s try', (tester) async {
    // Trying all three suggestions is free — it is one try either way. This is
    // the act that spends it.
    final container = await openHome(tester);
    await tapMic(tester);
    container.read(mealDraftProvider.notifier).toggleFood('white_rice');
    final offered = container.read(agentToolsProvider).recommendNow();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.ensureVisible(find.text(offered.first.addition.name));
    await tester.pump();
    await tester.tap(find.text(offered.first.addition.name));
    await tester.pump();

    expect(keepApi.kept, 0);
    await keepPlate(tester);
    await tester.pump();
    await tester.pump();

    expect(keepApi.kept, 1, reason: 'the server was told the try is over');
  });

  testWidgets('a spent try says so on the plate, with the way past it',
      (tester) async {
    // Said on the plate, because the plate is the thing that is not happening.
    // A message anywhere else leaves someone looking at an empty dish.
    final container = await openHome(tester);
    container.read(plateVisualProvider.notifier).state =
        const PlateVisual(blocked: true);
    await tester.pump();

    expect(find.textContaining('free plate'), findsOneWidget);
    expect(find.text('Tap to enter a code'), findsOneWidget);
  });

  testWidgets('a plate that could not be drawn says so', (tester) async {
    // Silence here is what "the image generation is not working" looks like
    // from the outside: an empty dish, no message, no way to tell whether it
    // is still coming.
    final container = await openHome(tester);
    container.read(plateVisualProvider.notifier).state =
        const PlateVisual(unavailable: true);
    await tester.pump();

    expect(find.textContaining('could not'), findsOneWidget);
    // And it has to say what still works, or it reads as a dead end.
    expect(find.textContaining('suggestion still stands'), findsOneWidget);
  });

  testWidgets('the microphone is refused when the try is used, and says where',
      (tester) async {
    // Said at the microphone rather than three minutes in, when somebody has
    // described their dinner to nothing.
    final container = await openHome(
      tester,
      throwOnStart: const ApiFailure(
        ApiError.tryUsed,
        'Today\u2019s free plate is used.',
      ),
    );
    await tapMic(tester);

    expect(container.read(plateVisualProvider).blocked, isTrue);
    expect(find.text('Tap to enter a code'), findsOneWidget);
    // Not an apology in the thread: the plate already said it.
    expect(container.read(voiceConversationProvider).failure, isNull);
    expect(container.read(voiceConversationProvider).turns, isEmpty);
  });

  testWidgets('a redeemed code leaves the count on the plate', (tester) async {
    // A toast is gone in three seconds. The number is the thing somebody wants
    // to check, so the plate holds it until the next conversation starts.
    final container = await openHome(tester);
    container.read(plateVisualProvider.notifier).showGranted(10);
    await tester.pump();

    expect(find.text('10 plates available'), findsOneWidget);
    expect(find.text('Tap the microphone'), findsOneWidget);
  });

  testWidgets('starting a conversation clears what the plate was saying',
      (tester) async {
    final container = await openHome(tester);
    container.read(plateVisualProvider.notifier).showGranted(10);
    await tester.pump();
    expect(find.text('10 plates available'), findsOneWidget);

    await tapMic(tester);

    expect(find.text('10 plates available'), findsNothing);
  });

  testWidgets('the answer time is put in front of whoever is watching',
      (tester) async {
    // The demo's headline number, measured from the first turn rather than
    // bolted on at the end.
    await openHome(tester);
    await tapMic(tester);

    // Anchored on the last word heard, not on input.speech.stopped — the
    // server sends that only after it has already decided to reply, so
    // measuring from it reported single-digit milliseconds.
    session.says(const UserTranscriptDelta('rice and chicken'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    session.says(const ReplyStarted('r1'));
    session.says(ReplyAudio(replyId: 'r1', pcm16: Uint8List.fromList([1, 2])));
    await tester.pump();
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

/// The smallest valid PNG. Stands in for a drawn plate wherever the widget
/// under test actually decodes the bytes.
final _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
  'hQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// A Worker that only answers the two calls this screen makes.
class _KeepApi implements PlateApi {
  int kept = 0;

  @override
  Future<DeviceRegistration> registerDevice({required String platform}) async =>
      DeviceRegistration(token: 'device-token', quota: _allowance);

  @override
  Future<Allowance> keepPlate(String deviceToken) async {
    kept++;
    return _allowance;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not part of this test');
}

final _allowance = Allowance(
  plates: 1,
  previews: 9,
  voice: 9,
  resetsAt: DateTime.fromMillisecondsSinceEpoch(0),
);
