import 'dart:typed_data';

import 'pcm_player_stub.dart' if (dart.library.js_interop) 'pcm_player_web.dart' as impl;

/// Plays the agent's voice, one arriving slice at a time.
///
/// The chunks come off a WebSocket faster than real time and must be played
/// back-to-back with no gap between them. The way to get that wrong is to
/// sleep between chunks; timing drifts and the voice pops. Implementations
/// schedule against the audio clock instead.
abstract class PcmPlayer {
  /// Wakes the audio device.
  ///
  /// **Must be called from inside a user gesture.** A browser starts an
  /// audio context suspended, and nothing plays until a real tap resumes it —
  /// so this belongs on the button press that starts the conversation, not on
  /// the connect that follows it.
  Future<void> start();

  /// Queues one slice. 16-bit signed little-endian mono at
  /// [voiceSampleRate](voice_agent_events.dart).
  void enqueue(Uint8List pcm16);

  /// Drops everything not yet heard, immediately.
  ///
  /// This is the barge-in path: the user started talking over the agent, the
  /// server stopped generating, and the seconds already buffered here are now
  /// an answer to a question that moved on.
  void flush();

  /// Releases the audio device.
  Future<void> dispose();

  /// The implementation for this platform. On anything but the web this is a
  /// player that accepts audio and drops it — see [pcm_player_stub.dart].
  factory PcmPlayer() = impl.PlatformPcmPlayer;
}
