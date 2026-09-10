/// The wire format of the AssemblyAI Voice Agent API, and nothing else.
///
/// No sockets, no microphone, no audio device — this file turns JSON into Dart
/// and Dart into JSON, so the parts of voice that are easy to get wrong can be
/// tested without a network or a browser. Every shape here was read off a live
/// session before it was written down.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Audio is 16-bit signed little-endian mono at this rate, in both directions.
/// It is the API's default for `audio/pcm`; the telephony encodings run at
/// 8 kHz and we do not use them.
const int voiceSampleRate = 24000;

/// Something the server said.
sealed class VoiceEvent {
  const VoiceEvent();

  /// Parses one inbound frame.
  ///
  /// An unrecognised `type` becomes [UnknownVoiceEvent] rather than an
  /// exception: the API can add events, and a new one must not end a
  /// conversation someone is in the middle of.
  factory VoiceEvent.fromJson(Map<String, dynamic> json) {
    String? str(String key) => json[key] as String?;

    return switch (json['type']) {
      'session.ready' => SessionReady(
          sessionId: str('session_id') ?? '',
          resumeToken: str('resume_token'),
          expiresAt: (json['expires_at'] as num?)?.toDouble(),
        ),
      'session.updated' => const SessionUpdated(),
      'session.ended' => SessionEnded(
          sessionSeconds: (json['session_duration_seconds'] as num?)?.toDouble() ?? 0,
          audioSeconds: (json['audio_duration_seconds'] as num?)?.toDouble(),
        ),
      'input.speech.started' => const SpeechStarted(),
      'input.speech.stopped' => const SpeechStopped(),
      'transcript.user.delta' => UserTranscriptDelta(str('text') ?? ''),
      'transcript.user' => UserTranscript(str('text') ?? ''),
      'reply.started' => ReplyStarted(str('reply_id') ?? ''),
      'reply.audio' => ReplyAudio(
          replyId: str('reply_id') ?? '',
          // Decoded here so nothing downstream has to know it arrived as text.
          pcm16: _decodeAudio(str('data')),
        ),
      'transcript.agent.delta' => AgentTranscriptDelta(str('delta') ?? ''),
      'transcript.agent' => AgentTranscript(
          text: str('text') ?? '',
          interrupted: json['interrupted'] == true,
        ),
      'reply.done' => ReplyDone(
          replyId: str('reply_id') ?? '',
          interrupted: str('status') == 'interrupted',
        ),
      'tool.call' => ToolCall(
          callId: str('call_id') ?? '',
          name: str('name') ?? '',
          arguments: switch (json['arguments']) {
            final Map<String, dynamic> args => args,
            _ => const {},
          },
        ),
      'session.error' => VoiceSessionError(
          code: str('code') ?? 'unknown',
          message: str('message') ?? 'The conversation could not continue.',
          param: str('param'),
        ),
      final String type => UnknownVoiceEvent(type),
      _ => const UnknownVoiceEvent(''),
    };
  }

  /// Parses a raw frame. Anything unparseable is an [UnknownVoiceEvent] — the
  /// socket carries only JSON objects, but a truncated one must not throw out
  /// of a stream listener.
  static VoiceEvent decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return const UnknownVoiceEvent('');
      return VoiceEvent.fromJson(json);
    } catch (_) {
      return const UnknownVoiceEvent('');
    }
  }

  static Uint8List _decodeAudio(String? data) {
    if (data == null || data.isEmpty) return Uint8List(0);
    try {
      return base64Decode(data);
    } catch (_) {
      return Uint8List(0);
    }
  }
}

/// The session is live. Audio may start now, and not before.
final class SessionReady extends VoiceEvent {
  const SessionReady({required this.sessionId, this.resumeToken, this.expiresAt});

  final String sessionId;

  /// Redeemable for 30 seconds after an unclean disconnect.
  final String? resumeToken;
  final double? expiresAt;
}

/// The configuration was accepted.
final class SessionUpdated extends VoiceEvent {
  const SessionUpdated();
}

/// The last thing a clean teardown sends. Billing has stopped.
final class SessionEnded extends VoiceEvent {
  const SessionEnded({required this.sessionSeconds, this.audioSeconds});

  final double sessionSeconds;
  final double? audioSeconds;
}

/// Turn detection heard the user start.
final class SpeechStarted extends VoiceEvent {
  const SpeechStarted();
}

/// Turn detection heard the user stop.
final class SpeechStopped extends VoiceEvent {
  const SpeechStopped();
}

/// A growing guess at what the user is saying.
final class UserTranscriptDelta extends VoiceEvent {
  const UserTranscriptDelta(this.text);
  final String text;
}

/// What the user said, settled.
final class UserTranscript extends VoiceEvent {
  const UserTranscript(this.text);
  final String text;
}

final class ReplyStarted extends VoiceEvent {
  const ReplyStarted(this.replyId);
  final String replyId;
}

/// A slice of the agent's voice, already base64-decoded.
final class ReplyAudio extends VoiceEvent {
  const ReplyAudio({required this.replyId, required this.pcm16});

  final String replyId;

  /// 16-bit signed little-endian mono at [voiceSampleRate].
  final Uint8List pcm16;
}

final class AgentTranscriptDelta extends VoiceEvent {
  const AgentTranscriptDelta(this.delta);
  final String delta;
}

final class AgentTranscript extends VoiceEvent {
  const AgentTranscript({required this.text, required this.interrupted});
  final String text;
  final bool interrupted;
}

/// The agent finished — or was cut off. This is also the only moment a
/// `tool.result` may be sent.
final class ReplyDone extends VoiceEvent {
  const ReplyDone({required this.replyId, required this.interrupted});
  final String replyId;
  final bool interrupted;
}

/// The agent wants us to run something. [arguments] is ready to use.
final class ToolCall extends VoiceEvent {
  const ToolCall({required this.callId, required this.name, required this.arguments});
  final String callId;
  final String name;
  final Map<String, dynamic> arguments;
}

final class VoiceSessionError extends VoiceEvent {
  const VoiceSessionError({required this.code, required this.message, this.param});

  final String code;
  final String message;

  /// Names the offending field on a configuration rejection.
  final String? param;

  /// Codes AssemblyAI documents as transient. Everything else is fatal, so the
  /// default is to stop rather than to hammer a socket that will not open.
  static const _retryable = {'at_capacity', 'concurrency_exceeded', 'internal_error'};

  bool get isRetryable => _retryable.contains(code);

  /// Errors the server sends on a socket it intends to keep open — a rejected
  /// frame, not a dead session. `audio_rate_violation` is the one that matters:
  /// a backgrounded tab wakes up and flushes buffered microphone frames faster
  /// than real time, and ending the conversation over that would be absurd.
  static const _survivable = {
    'invalid_format',
    'invalid_audio',
    'invalid_value',
    'immutable_field',
    'invalid_config',
    'agent_id_not_first',
    'agent_not_found',
    'audio_rate_violation',
  };

  /// Whether the conversation is over. `session_expired` is deliberately not
  /// survivable, and `server_error` is ambiguous in the docs — it is treated as
  /// fatal, because the expensive mistake is holding a session open, not
  /// ending one early.
  bool get endsSession => !_survivable.contains(code);
}

/// An event this version does not know about. Carried, not thrown.
final class UnknownVoiceEvent extends VoiceEvent {
  const UnknownVoiceEvent(this.type);
  final String type;
}

/// Everything we send. Encoded as strings so the socket layer stays dumb.
abstract final class VoiceFrame {
  /// The one message that configures the whole conversation. Sent immediately
  /// on connect, before any audio.
  static String sessionUpdate({
    required String systemPrompt,
    String? greeting,
    String? voiceId,
    List<Map<String, dynamic>> tools = const [],
  }) =>
      jsonEncode({
        'type': 'session.update',
        'session': {
          'system_prompt': systemPrompt,
          'greeting': ?greeting,
          if (voiceId != null) 'output': {'voice': voiceId},
          if (tools.isNotEmpty) 'tools': tools,
        },
      });

  /// One slice of microphone audio. [pcm16] must be 16-bit little-endian mono
  /// at [voiceSampleRate]; the server rejects anything else, and streaming
  /// faster than real time is an error too.
  static String inputAudio(Uint8List pcm16) =>
      jsonEncode({'type': 'input.audio', 'audio': base64Encode(pcm16)});

  /// The answer to a [ToolCall]. `result` is a JSON *string*, not an object —
  /// the API is specific about that.
  static String toolResult({
    required String callId,
    required Object? result,
    bool isError = false,
  }) =>
      jsonEncode({
        'type': 'tool.result',
        'call_id': callId,
        'result': jsonEncode(result),
        'is_error': isError,
      });

  /// Reconnects to a session dropped less than 30 seconds ago.
  static String sessionResume(String sessionId) =>
      jsonEncode({'type': 'session.resume', 'session_id': sessionId});

  /// Ends the session and stops billing at once. Closing the socket without
  /// this leaves a 30-second grace window that is billed.
  static String sessionEnd() => jsonEncode({'type': 'session.end'});
}
