import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets/common.dart';

/// Privacy policy and terms, shipped inside the app.
///
/// The same document is hosted at `docs/privacy.html`, but linking out from the
/// app is a dead end when the device is offline or the host moves.
///
/// This describes what the app does **today**. When the voice session lands it
/// gains a section of its own; a policy that describes a feature before it
/// exists is worth no more than one that omits a feature that does.
class LegalScreen extends StatelessWidget {
  const LegalScreen._({required this.title, required this.sections});

  final String title;
  final List<(String, String)> sections;

  static Future<void> showPrivacy(BuildContext context) => _show(
        context,
        LegalScreen._(title: 'Privacy policy', sections: _privacy),
      );

  static Future<void> showTerms(BuildContext context) => _show(
        context,
        LegalScreen._(title: 'Terms of use', sections: _terms),
      );

  static Future<void> _show(BuildContext context, LegalScreen screen) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        top: false,
        child: Readable(
          child: ListView(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.xl),
          children: [
            Text('Last updated 10 September 2026',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: Space.lg),
            for (final (heading, body) in sections) ...[
              Text(heading, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Space.sm),
              Text(body, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: Space.lg),
            ],
          ],
        ),
      ),
        ),
    );
  }

  static List<(String, String)> get _privacy => <(String, String)>[
    (
      'The short version',
      'Your meals, your goal, your preferences and your history stay on this '
          'device and are never uploaded. There is no account, no sign-in and '
          'nothing to create. The exceptions are the two things that cost money to '
          'run: the spoken conversation, and having a plate drawn. Those stream '
          'audio to be transcribed, and send one list of food names to be drawn — '
          'and then both are discarded. Everything else works with no network at '
          'all.'
    ),
    (
      'What is stored on this device',
      'Your goal, your dietary and budget preferences, the meals you have saved, '
          'your after-meal check answers, and the picture drawn for each patch you '
          'saved. All of it lives in this app’s own storage and none of it is '
          'uploaded. Removing a saved patch deletes its picture with it, and '
          'uninstalling Plate One deletes the lot.'
    ),
    (
      'What happens to what you say',
      'While the microphone is on, audio is streamed from this device straight '
          'to AssemblyAI, which turns it into text and answers out loud. It does '
          'not pass through Plate One’s server, and no recording is kept — on '
          'this device or anywhere else. The transcript on screen lives only in '
          'the app’s memory and is gone when the conversation ends.'
    ),
    (
      'What happens to the picture of your plate',
      'The names of the foods on the plate and the one addition being suggested '
          'are sent to Plate One’s server as catalogue ids — nothing else, and no '
          'free text, so nothing you said can reach the model that draws it. A picture of that plate is drawn by Cloudflare '
          'Workers AI from a fixed description built out of the app’s own food '
          'list. Neither the list nor the picture is stored on the server beyond '
          'the 24-hour expiry. This part is decoration: the suggestion itself is '
          'worked out on this device by a fixed set of rules, so the result still '
          'tells you what to add with no network at all.'
    ),
    (
      'The anonymous device id',
      'The first time you speak or a plate is drawn, this device is '
          'given a random id. It is not linked to you, to an email address, or to '
          'anything Google or Apple knows about you. Its only job is to count how '
          'many calls have been made today, so the service cannot be run up by one '
          'device. You can delete it at any time from Settings, which forgets the '
          'device on the server as well as here.'
    ),
    (
      'Children',
      'Plate One is not directed at children under 13 and does not knowingly '
          'collect anything from them. It is a general-audience app about food.'
    ),
    (
      'Not medical advice',
      'Plate One suggests one ordinary food to add to a meal. It is not a '
          'dietitian, it does not diagnose anything, and it does not know about '
          'your allergies, your medication or any condition you have. If you have '
          'one, ask someone qualified rather than an app.'
    ),
    (
      'Getting in touch',
      'Questions about any of this, or a request to delete something, go to '
          'the address on the project’s repository.'
    ),
  ];

  static List<(String, String)> get _terms => <(String, String)>[
    (
      'What this is',
      'Plate One looks at what you say is on your plate, works out which of '
          'protein, fibre or healthy fat the meal is light on, and names one '
          'ordinary thing to add. That is the whole product. It is offered as it '
          'is, free, with no account and no subscription.'
    ),
    (
      'It is not medical advice',
      'Nothing here is a diagnosis, a treatment, or a plan. Plate One does not '
          'know your allergies, your medication, or any condition you have, and it '
          'cannot take them into account. Use your own judgement about what you '
          'eat, and ask a professional when it matters.'
    ),
    (
      'What is asked of you',
      'Do not use Plate One to break the law, do not try to extract the service’s '
          'credentials or exceed its limits deliberately, and do not use the '
          'microphone to send it other people’s conversations. The daily allowance '
          'exists so the service stays available to everyone using it.'
    ),
    (
      'AI-generated content',
      'What you say is transcribed by a model, and the picture of a patched plate '
          'is drawn by one. Both are approximations: the food in a generated '
          'picture is illustrative, portion sizes in it mean nothing, and speech '
          'can be heard wrongly. Check the list the app shows you before you rely '
          'on it. '
          'The recommendation itself is not generated — it comes from a fixed set '
          'of rules running on this device, and the same plate always gives the '
          'same answer.'
    ),
    (
      'No warranty',
      'Plate One is provided “as is”, without warranty of any kind. It is an '
          'open-source project published under the MIT licence; the licence text '
          'travels with the source and governs the software itself.'
    ),
    (
      'Changes',
      'If these terms change, the date at the top of this page changes with them.'
    ),
  ];
}
