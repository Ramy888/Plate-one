import 'dart:typed_data';

import 'patch_images_io.dart'
    if (dart.library.js_interop) 'patch_images_web.dart' as impl;

/// Pictures of saved patches, kept on the phone.
///
/// A reply's picture is otherwise held in memory for the session only, because
/// the server deletes its own copy within a day. A patch you *saved* is a
/// different thing: it is meant to still be there next week, and a history of
/// grey placeholders is not worth keeping. So this writes one file per saved
/// patch, deleted with it.
///
/// Nothing here is uploaded. The files sit in the app's own directory and go
/// when the app is uninstalled, when the patch is removed, or when "Delete my
/// data" is used.
abstract class PatchImages {
  Future<String?> put(String patchId, Uint8List bytes);
  Future<Uint8List?> get(String? name);
  Future<void> remove(String? name);
  Future<void> clear();

  /// Whatever this platform can keep a picture in. A filesystem on a phone,
  /// IndexedDB in a browser — the difference stops at this line.
  factory PatchImages() = impl.PlatformPatchImages;
}

/// Keeps nothing. Used by tests, which have no filesystem to speak of and no
/// business writing to one.
class MemoryPatchImages implements PatchImages {
  final _files = <String, Uint8List>{};

  @override
  Future<String?> put(String patchId, Uint8List bytes) async {
    final name = '$patchId.jpg';
    _files[name] = bytes;
    return name;
  }

  @override
  Future<Uint8List?> get(String? name) async => name == null ? null : _files[name];

  @override
  Future<void> remove(String? name) async => _files.remove(name);

  @override
  Future<void> clear() async => _files.clear();
}
