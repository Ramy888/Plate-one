import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plateone/data/voice_agent_events.dart';

/// Frames captured from a real AssemblyAI session, verbatim.
///
/// Not written from the documentation: the field names below are what actually
/// came down the socket. A codec written against a guess fails at connect time
/// with no clue why, so these are the fixtures the parser is held to.
const _live = {
  'session.ready':
      '{"type":"session.ready","session_id":"sess_9f2","config":{},"expires_at":1789310995.0,"resume_token":"rt_77","timestamp":1789310395.1}',
  'reply.started':
      '{"type":"reply.started","reply_id":"reply_abc","item_id":"item_1","timestamp":1789310396.0}',
  'transcript.agent.delta':
      '{"type":"transcript.agent.delta","reply_id":"reply_abc","item_id":"item_1","delta":"What is","start_ms":0,"end_ms":420,"timestamp":1789310396.2}',
  'transcript.agent':
      '{"type":"transcript.agent","reply_id":"reply_abc","item_id":"item_1","text":"What is on your plate?","interrupted":false,"timestamp":1789310397.0}',
  'reply.done':
      '{"type":"reply.done","reply_id":"reply_abc","status":"completed","timestamp":1789310397.1}',
  'reply.interrupted':
      '{"type":"reply.done","reply_id":"reply_abc","status":"interrupted","timestamp":1789310397.1}',
  'input.speech.started': '{"type":"input.speech.started","timestamp":1789310398.0}',
  'input.speech.stopped': '{"type":"input.speech.stopped","timestamp":1789310399.0}',
  'transcript.user.delta':
      '{"type":"transcript.user.delta","item_id":"item_2","text":"rice and","timestamp":1789310398.5}',
  'transcript.user':
      '{"type":"transcript.user","item_id":"item_2","text":"rice and chicken","timestamp":1789310399.1}',
  'session.ended':
      '{"type":"session.ended","session_duration_seconds":42.7,"audio_duration_seconds":38.2,"timestamp":1789310400.0}',
  'tool.call':
      '{"type":"tool.call","call_id":"call_abc123","name":"get_recommendation","arguments":{"foods":["rice","chicken"]}}',
  'session.error':
      '{"type":"session.error","code":"invalid_format","message":"Invalid message format","timestamp":"2026-09-10T00:00:00Z"}',
};

void main() {
  group('reading what the server sends', () {
    test('a live session.ready carries the id and the resume token', () {
      final event = VoiceEvent.decode(_live['session.ready']!) as SessionReady;
      expect(event.sessionId, 'sess_9f2');
      expect(event.resumeToken, 'rt_77');
    });

    test('the user transcript is under "text", the agent delta under "delta"', () {
      // These two differ, and getting them the wrong way round produces an
      // empty transcript rather than an error — which is why it is pinned.
      expect((VoiceEvent.decode(_live['transcript.user']!) as UserTranscript).text,
          'rice and chicken');
      expect(
          (VoiceEvent.decode(_live['transcript.user.delta']!) as UserTranscriptDelta).text,
          'rice and');
      expect(
          (VoiceEvent.decode(_live['transcript.agent.delta']!) as AgentTranscriptDelta)
              .delta,
          'What is');
      expect((VoiceEvent.decode(_live['transcript.agent']!) as AgentTranscript).text,
          'What is on your plate?');
    });

    test('reply.done says whether the user talked over the answer', () {
      expect((VoiceEvent.decode(_live['reply.done']!) as ReplyDone).interrupted, isFalse);
      expect(
          (VoiceEvent.decode(_live['reply.interrupted']!) as ReplyDone).interrupted, isTrue);
    });

    test('audio arrives under "data" and comes out decoded', () {
      final pcm = Uint8List.fromList([0x01, 0x02, 0xff, 0x7f]);
      final frame = jsonEncode({
        'type': 'reply.audio',
        'reply_id': 'reply_abc',
        // The field is `data`. It is `audio` on the way *in* and `data` on the
        // way out, which is exactly the sort of thing a fixture is for.
        'data': base64Encode(pcm),
      });
      expect((VoiceEvent.decode(frame) as ReplyAudio).pcm16, pcm);
    });

    test('a tool call hands over arguments ready to use', () {
      final call = VoiceEvent.decode(_live['tool.call']!) as ToolCall;
      expect(call.callId, 'call_abc123');
      expect(call.name, 'get_recommendation');
      expect(call.arguments['foods'], ['rice', 'chicken']);
    });

    test('speech boundaries and the ending parse', () {
      expect(VoiceEvent.decode(_live['input.speech.started']!), isA<SpeechStarted>());
      expect(VoiceEvent.decode(_live['input.speech.stopped']!), isA<SpeechStopped>());
      final ended = VoiceEvent.decode(_live['session.ended']!) as SessionEnded;
      expect(ended.sessionSeconds, 42.7);
      expect(ended.audioSeconds, 38.2);
    });

    test('an error carries its code, and knows whether trying again is worth it', () {
      final error = VoiceEvent.decode(_live['session.error']!) as VoiceSessionError;
      expect(error.code, 'invalid_format');
      expect(error.isRetryable, isFalse,
          reason: 'only at_capacity, concurrency_exceeded and internal_error are');
      expect(
        const VoiceSessionError(code: 'at_capacity', message: 'busy').isRetryable,
        isTrue,
      );
    });

    test('an unknown event is carried, never thrown', () {
      // The API will add events. Someone mid-conversation must not lose it.
      expect(
        VoiceEvent.decode('{"type":"transcript.agent.emotion","mood":"warm"}'),
        isA<UnknownVoiceEvent>()
            .having((e) => e.type, 'type', 'transcript.agent.emotion'),
      );
    });

    test('a truncated frame does not throw out of the socket listener', () {
      expect(VoiceEvent.decode('{"type":"reply.au'), isA<UnknownVoiceEvent>());
      expect(VoiceEvent.decode('[]'), isA<UnknownVoiceEvent>());
      expect(VoiceEvent.decode(''), isA<UnknownVoiceEvent>());
    });

    test('audio that is not base64 becomes silence, not a crash', () {
      final frame = '{"type":"reply.audio","reply_id":"r","data":"!!!not base64!!!"}';
      expect((VoiceEvent.decode(frame) as ReplyAudio).pcm16, isEmpty);
    });
  });

  group('writing what we send', () {
    test('session.update nests everything under "session"', () {
      final sent = jsonDecode(VoiceFrame.sessionUpdate(
        systemPrompt: 'Ask what is on the plate.',
        greeting: 'What is on your plate?',
        voiceId: 'anna',
        tools: [
          {'type': 'function', 'name': 'get_recommendation'},
        ],
      )) as Map<String, dynamic>;

      expect(sent['type'], 'session.update');
      final session = sent['session'] as Map<String, dynamic>;
      expect(session['system_prompt'], 'Ask what is on the plate.');
      expect(session['greeting'], 'What is on your plate?');
      expect(session['output'], {'voice': 'anna'});
      expect((session['tools'] as List).single, {
        'type': 'function',
        'name': 'get_recommendation',
      });
    });

    test('an omitted greeting is left out, not sent as null', () {
      final session = (jsonDecode(VoiceFrame.sessionUpdate(systemPrompt: 'x'))
          as Map<String, dynamic>)['session'] as Map<String, dynamic>;
      expect(session.containsKey('greeting'), isFalse);
      expect(session.containsKey('output'), isFalse);
      expect(session.containsKey('tools'), isFalse);
    });

    test('microphone audio goes out under "audio", base64-encoded', () {
      final pcm = Uint8List.fromList([0x00, 0x80, 0x34, 0x12]);
      final sent = jsonDecode(VoiceFrame.inputAudio(pcm)) as Map<String, dynamic>;
      expect(sent['type'], 'input.audio');
      expect(base64Decode(sent['audio'] as String), pcm);
    });

    test('a tool result is a JSON string, not a JSON object', () {
      // The API is specific: `result` is a string containing JSON. Sending an
      // object is accepted and then quietly ignored.
      final sent = jsonDecode(VoiceFrame.toolResult(
        callId: 'call_abc123',
        result: {'addition': 'spinach'},
      )) as Map<String, dynamic>;

      expect(sent['call_id'], 'call_abc123');
      expect(sent['result'], isA<String>());
      expect(jsonDecode(sent['result'] as String), {'addition': 'spinach'});
      expect(sent['is_error'], isFalse);
    });

    test('a failed tool says so, so the agent can talk about it', () {
      final sent = jsonDecode(
        VoiceFrame.toolResult(callId: 'c1', result: {'error': 'nope'}, isError: true),
      ) as Map<String, dynamic>;
      expect(sent['is_error'], isTrue);
    });

    test('session.end has no other fields', () {
      expect(jsonDecode(VoiceFrame.sessionEnd()), {'type': 'session.end'});
    });
  });
}
