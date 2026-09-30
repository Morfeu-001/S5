import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:base_codecs/base_codecs.dart';
import 'package:http/http.dart' as http;
import 'package:lib5/lib5.dart';
import 'package:s5_server/node.dart';
import 'package:s5_server/store/create.dart';
import 'package:s5_server/store/remote_locations.dart';
import 'package:test/test.dart';
import 'storage_location_validation_test.dart' as wire;

// Metadata-only TEST fixtures. These synthetic digests do not assert possession
// or a download/hash verification; the production index producer does that.
void main() {
  late Directory root;
  late RemoteLocationObjectStore store;
  final digest = List<int>.filled(32, 4);
  final hash = Multihash(Uint8List.fromList([0x1f, ...digest]));
  int now = 1700000000;
  String blobId(List<int> digest, BigInt size, {bool redundant = false}) {
    final bytes = <int>[0x5b, 0x82, 0x1e, ...digest];
    while (size > BigInt.zero) {
      bytes.add((size & BigInt.from(255)).toInt());
      size >>= 8;
    }
    if (redundant) bytes.add(0);
    return 'b${base32Rfc.encode(Uint8List.fromList(bytes)).replaceAll('=', '').toLowerCase()}';
  }

  Map<String, dynamic> record() => {
    'version': 1,
    'cid': blobId(digest, BigInt.from(68)),
    'size': 68,
    'url': 'https://bucket.example.org/full/path/1.avif',
    'verified_at': 1699999000,
  };
  File entry() =>
      File('${root.path}/04/04/${List.filled(32, '04').join()}.json');
  Future<void> write([Map<String, dynamic>? value]) async {
    await entry().parent.create(recursive: true);
    await entry().writeAsString(jsonEncode(value ?? record()));
  }

  Future<void> refused() async {
    expect(await store.contains(hash), isFalse);
    expect(await store.canProvide(hash, [3, 5]), isFalse);
    await expectLater(store.provide(hash, [3]), throwsA(isA<StateError>()));
  }

  setUp(() async {
    final temporary = await Directory.systemTemp.createTemp(
      's5-remote-location-test-',
    );
    root = Directory(await temporary.resolveSymbolicLinks());
    now = 1700000000;
    store = RemoteLocationObjectStore(root, ttlSeconds: 300, now: () => now);
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'provides an exact public URL without any local image or network request',
    () async {
      await write();
      await store.init();
      expect(await store.canProvide(hash, [5, 3]), isTrue);
      final location = await store.provide(hash, [5, 3]);
      expect(location.type, 3);
      expect(location.parts, ['https://bucket.example.org/full/path/1.avif']);
      expect(location.expiry, now + 300);
      expect(store.uploadsSupported, isFalse);
    },
  );
  test('does not advertise archive or full/BAO support', () async {
    await write();
    for (final types in <List<int>>[
      [],
      [0],
      [5],
      [0, 5],
    ]) {
      expect(await store.canProvide(hash, types), isFalse);
      await expectLater(store.provide(hash, types), throwsA(isA<StateError>()));
    }
  });
  test(
    'missing records are unavailable and init does not scan unrelated files',
    () async {
      await File('${root.path}/unrelated.json').writeAsString('malformed');
      await Link('${root.path}/unrelated-link').create('/not-present');
      await store.init();
      await refused();
      await write();
      expect(await store.contains(hash), isTrue);
    },
  );
  test(
    'checks the full legacy hash prefix and digest before deriving a path',
    () async {
      await write();
      for (final bytes in <List<int>>[
        [],
        [0x1f],
        [0x1e, ...digest],
        [0x1f, ...digest, 0],
        [0x1f, ...List.filled(32, 5)],
      ]) {
        expect(
          await store.canProvide(Multihash(Uint8List.fromList(bytes)), [3]),
          isFalse,
        );
      }
    },
  );
  test('binds canonical BlobId hash and size to the requested hash', () async {
    for (final patch in <Map<String, dynamic>>[
      {'cid': blobId(List.filled(32, 5), BigInt.from(68))},
      {'size': 67},
      {'size': '68'},
      {'size': 68.0},
      {'size': -1},
      {'cid': blobId(digest, BigInt.from(68), redundant: true)},
      {'cid': record()['cid'].toString().toUpperCase()},
      {'cid': '${record()['cid']}='},
      {'cid': 'not-a-cid'},
      {'cid': 'uAAAA'},
      {
        'cid': blobId(digest, (BigInt.one << 64) - BigInt.one),
        'size': 9223372036854775807,
      },
    ]) {
      await write({...record(), ...patch});
      await refused();
    }
  });
  test(
    'supports canonical zero and large signed-int sizes without an image-profile cap',
    () async {
      for (final size in [0, 10000000000, 9223372036854775807]) {
        await write({
          ...record(),
          'cid': blobId(digest, BigInt.from(size)),
          'size': size,
        });
        expect(await store.contains(hash), isTrue);
      }
    },
  );
  test('rejects malformed schema and verification timestamps', () async {
    for (final patch in <Map<String, dynamic>>[
      {'version': 2},
      {'extra': true},
      {'verified_at': now + 1},
      {'verified_at': -1},
      {'verified_at': '1699999000'},
      {'verified_at': 1699999000.0},
      {'url': null},
    ]) {
      await write({...record(), ...patch});
      await refused();
    }
    final missing = record()..remove('verified_at');
    await write(missing);
    await refused();
  });
  test('rejects noncanonical CID prefix and padding bits', () async {
    await write({
      ...record(),
      'cid':
          'b${base32Rfc.encode(Uint8List.fromList([0x5b, 0x82, 0x1f, ...digest, 68])).replaceAll('=', '').toLowerCase()}',
    });
    await refused();
    final cid = record()['cid'] as String;
    const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
    final alternate =
        cid.substring(0, cid.length - 1) +
        alphabet[alphabet.indexOf(cid[cid.length - 1]) + 1];
    await write({...record(), 'cid': alternate});
    await refused();
  });
  test(
    'accepts only public stable HTTPS URLs without credentials, query or redirect rewriting',
    () async {
      for (final url in [
        'http://bucket.example.org/a',
        'https://user:secret@bucket.example.org/a',
        'https://bucket.example.org/a?X-Amz-Signature=secret',
        'https://bucket.example.org/a?',
        'https://bucket.example.org/a#fragment',
        'https://bucket.example.org:8443/a',
        'https://127.0.0.1/a',
        'https://[::1]/a',
        'https://localhost/a',
        'https://printer.local/a',
        'https://example.internal/a',
        'https://0x7f.0.0.1/a',
        'https://0x7f.0x0.0x0.0x1/a',
        'https://bucket.example.org/a/../b',
        'https://bucket.example.org/a\n',
        'https://bucket.example.org/a\\b',
        'https://bucket.example.org/${'a' * 2049}',
        'https://bucket.example.org/%2e%2e/a',
      ]) {
        await write({...record(), 'url': url});
        await refused();
      }
    },
  );
  test('rejects symlink entries and shards without following them', () async {
    await write();
    final real = File('${root.path}/real.json');
    await entry().rename(real.path);
    await Link(entry().path).create(real.path);
    await refused();
    await Link(entry().path).delete();
    await entry().parent.delete();
    await Link(entry().parent.path).create(root.path);
    await refused();
  });
  test('rejects symlink roots and ancestors', () async {
    final link = Link('${root.path}/alias');
    await link.create(root.path);
    final linked = RemoteLocationObjectStore(Directory(link.path));
    await expectLater(linked.init(), throwsA(isA<StateError>()));
    final nested = RemoteLocationObjectStore(Directory('${link.path}/nested'));
    await expectLater(nested.init(), throwsA(isA<StateError>()));
  });
  test(
    'rejects nonregular, malformed, oversized and non-UTF8 inputs',
    () async {
      await write();
      await entry().delete();
      await Directory(entry().path).create();
      await refused();
      await Directory(entry().path).delete();
      await entry().writeAsString('{');
      await refused();
      await entry().writeAsString('x' * 16385);
      await refused();
      await entry().writeAsBytes([255, 255]);
      await refused();
    },
  );
  test(
    'does not hold stale records in RAM and recomputes TTL on demand',
    () async {
      await write();
      final first = await store.provide(hash, [3]);
      now += 100;
      await write({
        ...record(),
        'url': 'https://other-bucket.example.org/real-key',
      });
      final second = await store.provide(hash, [3]);
      expect(second.expiry, first.expiry + 100);
      expect(second.parts.single, 'https://other-bucket.example.org/real-key');
      await entry().delete();
      await refused();
    },
  );
  test('validates TTL and bounds expiry to the unsigned wire field', () async {
    expect(
      () => RemoteLocationObjectStore(root, ttlSeconds: 0),
      throwsArgumentError,
    );
    expect(
      () => RemoteLocationObjectStore(root, ttlSeconds: -1),
      throwsArgumentError,
    );
    store = RemoteLocationObjectStore(
      root,
      ttlSeconds: 1 << 40,
      now: () => now,
    );
    await write();
    expect((await store.provide(hash, [3])).expiry, 0xffffffff);
    now = 0xffffffff;
    await refused();
  });
  test(
    'all mutation operations refuse and never consume upload bytes',
    () async {
      await write();
      final before = await entry().readAsBytes();
      Stream<Uint8List> bytes() async* {
        fail('read-only store consumed upload');
      }

      await expectLater(store.put(hash, bytes(), 68), throwsUnsupportedError);
      await expectLater(
        store.putBaoOutboardBytes(hash, Uint8List(2)),
        throwsUnsupportedError,
      );
      await expectLater(store.delete(hash), throwsUnsupportedError);
      await expectLater(store.getStoredHashes(), throwsUnsupportedError);
      expect(await entry().readAsBytes(), orderedEquals(before));
    },
  );
  test('configuration constructs only the readonly remote store with no network', () async {
    final stores = createStoresFromConfig({'store': {'remote_locations': {
      'path': root.path, 'ttlSeconds': 100,
    }}}, httpClient: NoNetworkClient(), node: UnusedNode());
    expect(stores.keys, ['remote_locations']);
    expect(stores.values.single, isA<RemoteLocationObjectStore>());
    await stores.values.single.init(); await write();
    expect(await stores.values.single.canProvide(hash, [3]), isTrue);
    for (final config in <Map<String, dynamic>>[
      {'path': root.path, 'ttlSeconds': '300'}, {'path': 7},
      {'path': root.path, 'unknown': 'ignored'}, {'path': root.path, 'ttlSeconds': 0},
    ]) {
      expect(() => createStoresFromConfig({'store': {'remote_locations': config}},
          httpClient: NoNetworkClient(), node: UnusedNode()), throwsArgumentError);
    }
  });
  test('the real P2P signer and receiver accept this remote file announcement', () async {
    final fixture = await wire.Fixture.create();
    try {
      now = DateTime.now().millisecondsSinceEpoch ~/ 1000; await write();
      final location = await store.provide(hash, [3]);
      final message = await fixture.service.prepareProvideMessage(hash, location);
      await fixture.origin.receive(message);
      final accepted = fixture.node.getCachedStorageLocations(hash, [3]);
      expect(accepted[fixture.service.localNodeId]!.parts, location.parts);
      expect(accepted[fixture.service.localNodeId]!.expiry, location.expiry);
      expect(fixture.waiter.sent.single, orderedEquals(message));
    } finally { fixture.node.httpClient.close(); }
  });
}

class NoNetworkClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      throw StateError('Remote location lookup must never use HTTP');
}
class UnusedNode implements S5Node {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Remote store construction must not access node state');
}
