import 'dart:typed_data';

import 'pcm_player.dart';

/// Playback off the web.
///
/// Voice ships on the web first — that is where the Application URL lives and
/// where a browser hands us microphone, playback and echo cancellation for
/// free. On Android the microphone works but nothing here plays raw PCM back,
/// so rather than half-ship a conversation the user can only speak into, this
/// accepts audio and drops it, and the UI keeps voice behind `kIsWeb`.
///
/// Everything above this line is platform-free, so the day an Android player
/// exists it is this file's job and nobody else's.
class PlatformPcmPlayer implements PcmPlayer {
  @override
  Future<void> start() async {}

  @override
  void enqueue(Uint8List pcm16) {}

  @override
  void flush() {}

  @override
  Future<void> dispose() async {}
}
