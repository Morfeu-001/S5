import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:lib5/lib5.dart';
import 'package:lib5/constants.dart';
import 'package:lib5/node.dart';
import 'package:lib5/util.dart';
import 'package:test/test.dart';

// Public test seeds, real Ed25519 and the real P2P receiver; no network.
void main() {
  late Fixture f;
  setUp(() async { f = await Fixture.create(); });
  tearDown(() { f.node.httpClient.close(); });

  test('valid signed location persists and reaches a waiting peer', () async {
    final message = await f.message();
    await f.origin.receive(message);
    final locations = f.node.getCachedStorageLocations(f.hash, [3]);
    expect(locations.keys, contains(f.service.localNodeId));
    expect(locations[f.service.localNodeId]!.parts,
        ['https://provider.example.test/object']);
    expect(f.waiter.sent, hasLength(1));
    expect(f.waiter.sent.single, orderedEquals(message));
    expect(f.db.values, hasLength(1));
  });
  test('valid archive with no parts keeps its 138-byte framing', () async {
    final message = await f.service.prepareProvideMessage(f.hash,
        StorageLocation(storageLocationTypeArchive, [], now() + 3600));
    expect(message, hasLength(138));
    await f.origin.receive(message);
    expect(f.node.getCachedStorageLocations(f.hash, [storageLocationTypeArchive]),
        hasLength(1));
    expect(f.waiter.sent.single, orderedEquals(message));
  });
  test('invalid signature never persists or forwards', () async {
    final message = await f.message();
    message[message.length - 1] ^= 1;
    await expectLater(f.origin.receive(message), throwsA(anything));
    expect(f.db.values, isEmpty);
    expect(f.waiter.sent, isEmpty);
    expect(f.service.hashQueryRoutingTable[f.hash], contains(f.waiter.id));
  });
  test('tampered signed URL never persists or forwards', () async {
    final message = await f.message();
    message[42] ^= 1;
    await expectLater(f.origin.receive(message), throwsA(anything));
    expect(f.db.values, isEmpty);
    expect(f.waiter.sent, isEmpty);
    expect(f.service.hashQueryRoutingTable[f.hash], contains(f.waiter.id));
  });
  test('expired authentic replay cannot replace a current claim', () async {
    await f.origin.receive(await f.message());
    final before = Uint8List.fromList(f.db.values.values.single);
    f.waiter.sent.clear();
    f.service.hashQueryRoutingTable[f.hash] = {f.waiter.id};
    final expired = await f.message(expiry: now() - 3600);
    await expectLater(f.origin.receive(expired), throwsA(anything));
    expect(f.db.values.values.single, orderedEquals(before));
    expect(f.node.getCachedStorageLocations(f.hash, [3]), hasLength(1));
    expect(f.waiter.sent, isEmpty);
    expect(f.service.hashQueryRoutingTable[f.hash], contains(f.waiter.id));
  });
  test('signed nonzero record terminator is refused', () async {
    final message = await f.message();
    final signedLength = message.length - 97;
    message[signedLength - 1] = 1;
    final signature = await f.crypto.signEd25519(kp: f.service.nodeKeyPair,
        message: Uint8List.sublistView(message, 0, signedLength));
    message.setRange(message.length - 64, message.length, signature);
    await expectLater(f.origin.receive(message), throwsA(anything));
    expect(f.db.values, isEmpty);
    expect(f.waiter.sent, isEmpty);
    expect(f.service.hashQueryRoutingTable[f.hash], contains(f.waiter.id));
  });
  test('truncated record is refused without state changes', () async {
    final message = await f.message();
    await expectLater(f.origin.receive(message.sublist(0, 50)), throwsA(anything));
    expect(f.db.values, isEmpty);
    expect(f.waiter.sent, isEmpty);
    expect(f.service.hashQueryRoutingTable[f.hash], contains(f.waiter.id));
  });
  test('URL length cannot consume the signature trailer', () async {
    final message = await f.message();
    message[40] = 255;
    message[41] = 255;
    await expectLater(f.origin.receive(message), throwsA(anything));
    expect(f.db.values, isEmpty);
    expect(f.waiter.sent, isEmpty);
    expect(f.service.hashQueryRoutingTable[f.hash], contains(f.waiter.id));
  });
  test('extra bytes after signature are refused', () async {
    final message = await f.message();
    await expectLater(f.origin.receive(Uint8List.fromList([...message, 0])),
        throwsA(anything));
    expect(f.db.values, isEmpty);
    expect(f.waiter.sent, isEmpty);
    expect(f.service.hashQueryRoutingTable[f.hash], contains(f.waiter.id));
  });
}
int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

class Fixture {
  final TestCrypto crypto;
  final MemoryDB db;
  final S5NodeBase node;
  final P2PService service;
  final TestPeer origin;
  final TestPeer waiter;
  final Multihash hash;
  Fixture(this.crypto, this.db, this.node, this.service, this.origin,
      this.waiter, this.hash);
  static Future<Fixture> create() async {
    final c = TestCrypto();
    final db = MemoryDB();
    final node = S5NodeBase(config: {}, logger: SilentLogger(), crypto: c);
    node.objectsBox = db;
    final service = P2PService(node);
    service.nodeKeyPair = await c.newKeyPairEd25519(
        seed: Uint8List.fromList(List.filled(32, 1)));
    service.localNodeId = NodeID(service.nodeKeyPair.publicKey);
    final origin = TestPeer(NodeID(Uint8List.fromList([0xed, ...List.filled(32, 2)])));
    final waiter = TestPeer(NodeID(Uint8List.fromList([0xed, ...List.filled(32, 3)])));
    final hash = Multihash(Uint8List.fromList([0x1f, ...List.filled(32, 4)]));
    service.peers[waiter.id] = waiter;
    service.hashQueryRoutingTable[hash] = {waiter.id};
    // Pending until socket closure; no socket exists in this fixture.
    unawaited(service.onNewPeer(origin, verifyId: false));
    await Future<void>.delayed(Duration.zero);
    return Fixture(c, db, node, service, origin, waiter, hash);
  }
  Future<Uint8List> message({int? expiry}) => service.prepareProvideMessage(hash,
      StorageLocation(3, ['https://provider.example.test/object'],
          expiry ?? now() + 3600));
}
class TestPeer extends Peer {
  late Function callback;
  final List<Uint8List> sent = [];
  TestPeer(NodeID nodeId) : super(connectionUris: []) { id = nodeId; }
  Future<void> receive(Uint8List message) async { await callback(message); }
  @override
  void sendMessage(Uint8List message) { sent.add(Uint8List.fromList(message)); }
  @override
  void listenForMessages(Function callback,
      {dynamic onDone, Function? onError, required Logger logger}) {
    this.callback = callback;
  }
  @override
  String renderLocationUri() => 'in-memory test peer';
}
class MemoryDB implements KeyValueDB {
  final Map<String, Uint8List> values = {};
  @override
  void set(Uint8List key, Uint8List value) {
    values[base64Encode(key)] = Uint8List.fromList(value);
  }
  @override
  Uint8List? get(Uint8List key) => values[base64Encode(key)];
  @override
  bool contains(Uint8List key) => values.containsKey(base64Encode(key));
  @override
  void delete(Uint8List key) { values.remove(base64Encode(key)); }
}
class TestCrypto implements CryptoImplementation {
  final crypto.Ed25519 ed25519 = crypto.Ed25519();
  @override
  Uint8List generateRandomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
  }
  @override
  Future<KeyPairEd25519> newKeyPairEd25519({required Uint8List seed}) async {
    final pair = await ed25519.newKeyPairFromSeed(seed);
    return KeyPairEd25519(Uint8List.fromList(
        [...seed, ...(await pair.extractPublicKey()).bytes]));
  }
  @override
  Future<Uint8List> signEd25519(
      {required KeyPairEd25519 kp, required Uint8List message}) async {
    final pair = await ed25519.newKeyPairFromSeed(kp.extractBytes().sublist(0, 32));
    return Uint8List.fromList((await ed25519.sign(message, keyPair: pair)).bytes);
  }
  @override
  Future<bool> verifyEd25519({required Uint8List pk,
      required Uint8List message, required Uint8List signature}) {
    return ed25519.verify(message, signature: crypto.Signature(signature,
        publicKey: crypto.SimplePublicKey(pk, type: crypto.KeyPairType.ed25519)));
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
class SilentLogger implements Logger {
  @override
  void info(String s) {}
  @override
  void verbose(String s) {}
  @override
  void warn(String s) {}
  @override
  void error(String s) {}
  @override
  void catched(dynamic e, dynamic st, [String? context]) {}
}
