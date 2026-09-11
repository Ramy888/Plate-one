import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'patch_images.dart';

/// Pictures in a browser, in IndexedDB.
///
/// Not `localStorage`: a drawn plate is tens of kilobytes and the whole of
/// local storage is about five megabytes, shared with everything else the app
/// keeps. A saved plate is meant to still be there next week, and running a
/// history into a quota error is not the way to keep that promise.
///
/// Nothing here leaves the browser. The store goes when site data is cleared,
/// when the patch is removed, or when "Delete my data" is used.
class PlatformPatchImages implements PatchImages {
  PlatformPatchImages();

  static const _dbName = 'plateone';
  static const _store = 'patch_images';

  Future<web.IDBDatabase>? _opening;

  Future<web.IDBDatabase> _db() => _opening ??= _open();

  Future<web.IDBDatabase> _open() {
    final done = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(_dbName, 1);

    request.onupgradeneeded = ((web.Event _) {
      final db = request.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_store)) db.createObjectStore(_store);
    }).toJS;
    request.onsuccess = ((web.Event _) {
      done.complete(request.result as web.IDBDatabase);
    }).toJS;
    request.onerror = ((web.Event _) {
      // A browser in private mode can refuse to open one at all. That is a
      // history without pictures, not a broken app.
      done.completeError(StateError('indexeddb unavailable'));
    }).toJS;

    return done.future;
  }

  /// Runs one request to completion. Every call here is a single operation, so
  /// the transaction is opened and closed around it.
  Future<JSAny?> _run(
    String mode,
    web.IDBRequest Function(web.IDBObjectStore store) operation,
  ) async {
    final db = await _db();
    final store = db.transaction(_store.toJS, mode).objectStore(_store);
    final request = operation(store);

    final done = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) => done.complete(request.result)).toJS;
    request.onerror = ((web.Event _) => done.completeError(StateError('idb failed'))).toJS;
    return done.future;
  }

  @override
  Future<String?> put(String patchId, Uint8List bytes) async {
    final name = '$patchId.jpg';
    try {
      await _run('readwrite', (store) => store.put(bytes.toJS, name.toJS));
      return name;
    } catch (_) {
      // A saved patch with no picture is fine. A failed save because of one
      // is not.
      return null;
    }
  }

  @override
  Future<Uint8List?> get(String? name) async {
    if (name == null || name.isEmpty) return null;
    try {
      final stored = await _run('readonly', (store) => store.get(name.toJS));
      if (stored == null) return null;
      return (stored as JSUint8Array).toDart;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> remove(String? name) async {
    if (name == null || name.isEmpty) return;
    try {
      await _run('readwrite', (store) => store.delete(name.toJS));
    } catch (_) {
      // Nothing useful to do, and nothing worth telling anyone.
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _run('readwrite', (store) => store.clear());
    } catch (_) {
      // As above.
    }
  }
}
