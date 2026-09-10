import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'pcm_player.dart';
import 'voice_agent_events.dart';

/// Gapless playback through Web Audio.
///
/// Each arriving slice becomes an `AudioBufferSourceNode` scheduled at a
/// running cursor, so the browser's own audio clock decides when every sample
/// is heard. Nothing here sleeps or polls: `start(when)` is sample-accurate,
/// and a cursor that only ever moves forward cannot drift.
class PlatformPcmPlayer implements PcmPlayer {
  web.AudioContext? _context;

  /// When the next slice should begin, on the context clock.
  double _cursor = 0;

  /// Everything scheduled and not yet finished, so barge-in can stop it.
  final _live = <web.AudioBufferSourceNode>[];

  /// How far ahead of "now" a slice is scheduled when the queue has run dry.
  /// Enough to survive one late arrival, short enough not to be heard as lag.
  static const _leadIn = 0.06;

  @override
  Future<void> start() async {
    // Chrome hands out a suspended context unless it is created and resumed
    // during a user gesture. Both happen here, on the tap that starts the
    // conversation.
    final context = _context ??= web.AudioContext();
    if (context.state != 'running') {
      await context.resume().toDart;
    }
  }

  @override
  void enqueue(Uint8List pcm16) {
    final context = _context;
    if (context == null || pcm16.isEmpty) return;

    final samples = _toFloat32(pcm16);
    if (samples.isEmpty) return;

    // The buffer declares 24 kHz; the context may run at 48. Web Audio
    // resamples on playback, which is one less thing for us to get wrong.
    final buffer = context.createBuffer(1, samples.length, voiceSampleRate.toDouble());
    buffer.copyToChannel(samples.toJS, 0);

    final source = context.createBufferSource()..buffer = buffer;
    source.connect(context.destination);

    // Behind the clock means the queue ran dry — restart ahead of now rather
    // than scheduling in the past, which plays instantly and overlaps.
    final at = math.max(_cursor, context.currentTime + _leadIn);
    source.start(at);
    _cursor = at + buffer.duration;

    _live.add(source);
    source.onended = ((web.Event _) => _live.remove(source)).toJS;
  }

  @override
  void flush() {
    // Copied first: stopping fires `onended`, which mutates the list.
    for (final source in List.of(_live)) {
      try {
        source.stop();
      } catch (_) {
        // Already finished. Nothing to stop, nothing to report.
      }
    }
    _live.clear();
    _cursor = 0;
  }

  @override
  Future<void> dispose() async {
    flush();
    final context = _context;
    _context = null;
    if (context == null) return;
    try {
      await context.close().toDart;
    } catch (_) {
      // A context that is already closed is the state we wanted.
    }
  }

  /// 16-bit signed little-endian to the -1..1 floats Web Audio wants.
  static Float32List _toFloat32(Uint8List pcm16) {
    final frames = pcm16.lengthInBytes ~/ 2;
    final view = ByteData.sublistView(pcm16);
    final out = Float32List(frames);
    for (var i = 0; i < frames; i++) {
      out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }
}
