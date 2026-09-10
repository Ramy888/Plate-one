import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

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
}

/// The real one, writing into the app's own documents directory.
///
/// Behind an interface because a widget test has no platform channels: asking
/// for the documents directory there does not fail, it simply never answers,
/// which hangs the test rather than failing it.
class DevicePatchImages implements PatchImages {
  const DevicePatchImages();

  static const _folder = 'patch_images';

  Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_folder');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// Writes the picture for a saved patch and returns the file name to store
  /// against it. Returns null if it could not be written — a saved patch with
  /// no picture is fine, a failed save because of one is not.
  @override
  Future<String?> put(String patchId, Uint8List bytes) async {
    try {
      final dir = await _dir();
      final name = '$patchId.jpg';
      await File('${dir.path}/$name').writeAsBytes(bytes, flush: true);
      return name;
    } catch (_) {
      return null;
    }
  }

  /// The bytes for a stored name, or null if it is gone. A file that has been
  /// cleared by the system is a missing picture, never an error.
  @override
  Future<Uint8List?> get(String? name) async {
    if (name == null || name.isEmpty) return null;
    try {
      final file = File('${(await _dir()).path}/$name');
      if (!file.existsSync()) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> remove(String? name) async {
    if (name == null || name.isEmpty) return;
    try {
      final file = File('${(await _dir()).path}/$name');
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // Nothing useful to do, and nothing worth telling anyone.
    }
  }

  /// Everything, for "Delete my data".
  @override
  Future<void> clear() async {
    try {
      final dir = await _dir();
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {
      // As above.
    }
  }
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
