import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lib5/lib5.dart';
import 'package:path/path.dart' as path;

import 'base.dart';

/// Operator-owned, externally byte-verified index. No image copies, network,
/// directory scans or global in-memory index are needed to answer a query.
class RemoteLocationObjectStore extends ObjectStore {
  final Directory root;
  final int ttlSeconds;
  final int Function() _now;
  static const _maxRecordBytes = 16384;
  static const _maxExpiry = 0xffffffff;
  static const _fields = {'version', 'cid', 'size', 'url', 'verified_at'};

  RemoteLocationObjectStore(
    this.root, {
    this.ttlSeconds = 300,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch ~/ 1000) {
    if (ttlSeconds <= 0) throw ArgumentError('remote_location_invalid_ttl');
  }

  @override
  bool get uploadsSupported => false;

  @override
  Future<void> init() async {
    await _rootPath();
  }

  @override
  Future<bool> canProvide(Multihash hash, List<int> types) async =>
      types.contains(3) && await contains(hash);

  @override
  Future<bool> contains(Multihash hash) async => await _record(hash) != null;

  @override
  Future<StorageLocation> provide(Multihash hash, List<int> types) async {
    if (!types.contains(3)) throw StateError('remote_location_unavailable');
    final record = await _record(hash);
    final now = _now();
    if (record == null || now < 0 || now >= _maxExpiry) {
      throw StateError('remote_location_unavailable');
    }
    final expiry = ttlSeconds > _maxExpiry - now
        ? _maxExpiry
        : now + ttlSeconds;
    return StorageLocation(3, [record['url'] as String], expiry);
  }

  Future<String> _rootPath() async {
    final canonical = path.normalize(root.absolute.path);
    if (!path.isAbsolute(root.path) ||
        canonical != root.path ||
        await FileSystemEntity.type(canonical, followLinks: false) !=
            FileSystemEntityType.directory ||
        await root.resolveSymbolicLinks() != canonical) {
      throw StateError('remote_location_invalid_root');
    }
    return canonical;
  }

  Future<File> _entry(String digest) async {
    var current = await _rootPath();
    for (final segment in [digest.substring(0, 2), digest.substring(2, 4)]) {
      current = path.join(current, segment);
      if (await FileSystemEntity.type(current, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw StateError('remote_location_unavailable');
      }
    }
    final file = File(path.join(current, '$digest.json'));
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('remote_location_unavailable');
    }
    return file;
  }

  Future<Map<String, dynamic>?> _record(Multihash hash) async {
    final bytes = Uint8List.fromList(hash.fullBytes);
    if (bytes.length != 33 || bytes[0] != 0x1f) return null;
    final digest = bytes
        .skip(1)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    try {
      final file = await _entry(digest);
      // Read the actual stream with a bound, not an unbounded readAsBytes after stat.
      final input = await file.open(mode: FileMode.read);
      final buffer = BytesBuilder(copy: false);
      try {
        while (buffer.length <= _maxRecordBytes) {
          final chunk = await input.read(_maxRecordBytes + 1 - buffer.length);
          if (chunk.isEmpty) break;
          buffer.add(chunk);
        }
      } finally {
        await input.close();
      }
      if (buffer.length > _maxRecordBytes) return null;
      await _entry(digest); // Reject path type/symlink changes around the read.
      final record = jsonDecode(utf8.decode(buffer.takeBytes()));
      final now = _now();
      if (record is! Map<String, dynamic> ||
          record.length != _fields.length ||
          !record.keys.every(_fields.contains) ||
          record['version'] is! int ||
          record['version'] != 1 ||
          record['size'] is! int ||
          record['size'] < 0 ||
          record['cid'] is! String ||
          record['verified_at'] is! int ||
          record['verified_at'] < 0 ||
          record['verified_at'] > now ||
          now < 0 ||
          now >= _maxExpiry ||
          !_matchesCid(record['cid'], record['size'], bytes) ||
          !_publicUrl(record['url'])) {
        return null;
      }
      return record;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on StateError {
      return null;
    }
  }

  // lib5 0.2's CID parser predates the 5b821e BlobId. Validate its bounded,
  // canonical base32 and minimal LE uint64 here, without mutating the query.
  static bool _matchesCid(String cid, int size, Uint8List hash) {
    if (!RegExp(r'^b[a-z2-7]{56,69}$').hasMatch(cid)) return false;
    const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
    final raw = <int>[];
    var bits = 0, value = 0;
    for (final char in cid.substring(1).codeUnits) {
      value = (value << 5) | alphabet.indexOf(String.fromCharCode(char));
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        raw.add((value >> bits) & 255);
        value &= (1 << bits) - 1;
      }
    }
    if (value != 0 ||
        raw.length < 35 ||
        raw.length > 43 ||
        (raw.length * 8 + 4) ~/ 5 != cid.length - 1 ||
        raw[0] != 0x5b ||
        raw[1] != 0x82 ||
        raw[2] != 0x1e ||
        (raw.length > 35 && raw.last == 0)) {
      return false;
    }
    for (var i = 0; i < 32; i++) {
      if (raw[i + 3] != hash[i + 1]) return false;
    }
    var decodedSize = BigInt.zero;
    for (var i = raw.length - 1; i >= 35; i--) {
      decodedSize = (decodedSize << 8) | BigInt.from(raw[i]);
    }
    return decodedSize == BigInt.from(size);
  }

  static bool _publicUrl(dynamic value) {
    if (value is! String ||
        value.length > 2048 ||
        value.contains('\\') ||
        value.codeUnits.any((c) => c <= 32 || c >= 127) ||
        RegExp(r'(^|/)\.\.?(/|$)').hasMatch(value) ||
        RegExp(r'%(?:2e|2f|5c)', caseSensitive: false).hasMatch(value)) {
      return false;
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.hasPort && uri.port != 443) ||
        uri.path.isEmpty ||
        uri.pathSegments.any((segment) => segment == '.' || segment == '..')) {
      return false;
    }
    final host = uri.host;
    return host.length <= 253 &&
        host.contains('.') &&
        // WHATWG treats a numeric final label as IPv4, including hexadecimal.
        !RegExp(r'^(?:[0-9]+|0x[0-9a-f]*)$').hasMatch(host.split('.').last) &&
        !RegExp(r'(^|\.)(localhost|local|internal|lan|home)$').hasMatch(host) &&
        host
            .split('.')
            .every(
              (label) => RegExp(
                r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$',
              ).hasMatch(label),
            );
  }

  @override
  Future<void> put(Multihash hash, Stream<Uint8List> data, int length) async =>
      throw UnsupportedError('remote_location_read_only');
  @override
  Future<void> putBaoOutboardBytes(Multihash hash, Uint8List outboard) async =>
      throw UnsupportedError('remote_location_read_only');
  @override
  Future<void> delete(Multihash hash) async =>
      throw UnsupportedError('remote_location_read_only');
  @override
  Future<Iterable<Multihash>> getStoredHashes() async =>
      throw UnsupportedError('remote_location_read_only');
}
