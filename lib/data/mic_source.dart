import 'dart:typed_data';

import 'package:record/record.dart';

import 'voice_agent_events.dart';

/// The microphone, as a stream of bytes the API can take unchanged.
///
/// An interface rather than a direct call into `record` for one reason: a test
/// has no microphone. Everything above this can be driven by a fake.
abstract class MicSource {
  /// Whether the user has already agreed, or will be asked.
  Future<bool> hasPermission();

  /// Opens the microphone. The stream carries 16-bit signed little-endian mono
  /// at [voiceSampleRate] — exactly what `input.audio` wants, so nothing
  /// between here and the socket has to convert anything.
  Future<Stream<Uint8List>> start();

  /// Closes the microphone. Safe to call when it was never open.
  Future<void> stop();

  Future<void> dispose();
}

/// [MicSource] over the `record` package.
///
/// On the web this runs an AudioWorklet that resamples to 24 kHz and converts
/// to PCM16 before the bytes ever reach Dart. On Android it is the platform
/// recorder. Both give the same stream, which is the point.
class RecorderMicSource implements MicSource {
  RecorderMicSource({AudioRecorder? recorder}) : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  /// Echo cancellation is not a nicety here. Without it the agent's own voice
  /// comes back through the microphone, the server hears "the user" talking
  /// over it, and every reply interrupts itself.
  static const _config = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: voiceSampleRate,
    numChannels: 1,
    echoCancel: true,
    noiseSuppress: true,
    autoGain: true,
  );

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start() => _recorder.startStream(_config);

  @override
  Future<void> stop() async {
    if (await _recorder.isRecording()) await _recorder.stop();
  }

  @override
  Future<void> dispose() async {
    await _recorder.dispose();
  }
}
