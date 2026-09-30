import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:lib5/lib5.dart';
import 'package:lib5/node.dart';
import 'package:lib5/util.dart';
import 'package:s5_msgpack/s5_msgpack.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:s5_server/service/p2p.dart' as native;

import 'storage_location_validation_test.dart' as fixture;

void main() {
  test('invalid asynchronous frames stay inside the transport listener', () async {
    final channel = FakeChannel();
    final peer = WebSocketChannelPeer(channel,
        locationUri: 'test', connectionUris: [])..isConnected = true;
    final escaped = <Object>[];
    var calls = 0;
    runZonedGuarded(() {
      peer.listenForMessages((dynamic event) async {
        calls++;
        throw StateError('invalid signed frame');
      }, logger: fixture.SilentLogger());
    }, (error, stack) => escaped.add(error));
    channel.input.add(Uint8List.fromList([5]));
    channel.input.add(Uint8List.fromList([5]));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, 2);
    expect(escaped, isEmpty);
    await channel.input.close();
  });

  test('native incoming sockets also contain refused frame errors', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final request = server.first;
    final connecting = WebSocket.connect('ws://127.0.0.1:${server.port}/');
    final socket = await WebSocketTransformer.upgrade(await request);
    final client = await connecting;
    final peer = native.WebSocketPeer(socket, connectionUris: [])..isConnected = true;
    final escaped = <Object>[];
    var calls = 0;
    runZonedGuarded(() {
      peer.listenForMessages((dynamic event) async {
        calls++;
        throw StateError('invalid frame');
      }, logger: fixture.SilentLogger());
    }, (error, stack) => escaped.add(error));
    try {
      client.add(Uint8List.fromList([5])); client.add(Uint8List.fromList([5]));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 2); expect(escaped, isEmpty);
    } finally {
      await peer.close(); await client.close(); await server.close(force: true);
    }
  });

  test('closing an old socket does not remove its replacement', () async {
    final f = await fixture.Fixture.create();
    final old = ClosingPeer(f.origin.id);
    final replacement = ClosingPeer(f.origin.id)..isConnected = true;
    final lifetime = f.service.onNewPeer(old, verifyId: true);
    final closed = expectLater(lifetime, throwsA(anything));
    f.service.peers[old.id] = replacement;
    old.done();
    await closed;
    expect(f.service.peers[old.id], same(replacement));
    expect(old.isConnected, isFalse);
  });

  test('incoming transport errors retire the peer without an onDone event', () async {
    final f = await fixture.Fixture.create();
    final peer = ClosingPeer(f.origin.id)..isConnected = true;
    final lifetime = f.service.onNewPeer(peer, verifyId: true);
    final closed = expectLater(lifetime, throwsA(anything));
    f.service.peers[peer.id] = peer;
    peer.error(StateError('transport failed')); // Closing cancels the listener.
    await closed;
    expect(peer.isConnected, isFalse);
    expect(f.service.peers[peer.id], isNull);
    expect(peer.closeCalls, 1);
  });

  test('an unanswered query is forwarded again after its bounded lifetime', () async {
    final f = await fixture.Fixture.create();
    var clock = 0;
    final service = P2PService(f.node, queryNow: () => clock);
    service.nodeKeyPair = f.service.nodeKeyPair;
    service.localNodeId = f.service.localNodeId;
    final requester = ClosingPeer(f.origin.id);
    final provider = ClosingPeer(f.waiter.id)..isConnected = true;
    unawaited(service.onNewPeer(requester, verifyId: true).catchError((_) {}));
    final query = Packer()..packInt(4)..packBinary(f.hash.fullBytes)..pack([3]);
    final bytes = query.takeBytes();
    await requester.receive(bytes); // No provider available yet.
    service.peers[provider.id] = provider;
    await requester.receive(bytes);
    expect(provider.sent, isEmpty); // Coalesced within the lifetime.
    clock = 30001;
    await requester.receive(bytes);
    expect(provider.sent.single, orderedEquals(bytes));
    requester.done();
  });

  test('one connection attempt owns and closes its transport before retry', () async {
    final f = await fixture.Fixture.create();
    final channels = <FakeChannel>[];
    final service = P2PService(f.node, connectChannel: (_) {
      final channel = FakeChannel(); channels.add(channel); return channel;
    });
    service.nodeKeyPair = f.service.nodeKeyPair;
    service.localNodeId = f.service.localNodeId;
    final uri = Uri.parse('wss://${f.origin.id.toBase58()}@fixture.invalid/s5/p2p');
    service.connectToNode([uri]); service.connectToNode([uri]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(channels, hasLength(1));
    await channels.first.input.close();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(channels.first.output.closeCalls, 1);
    expect(channels, hasLength(2));
    // Stop the fixture's retry chain without adding a test-only product API.
    service.blockedPeers.add('fixture.invalid');
    await channels.last.input.close();
  });

  for (final invalid in ['challenge', 'features']) {
    test('a refused $invalid handshake closes its live stream before one retry', () async {
      final f = await fixture.Fixture.create();
      final remote = await f.crypto.newKeyPairEd25519(seed: Uint8List.fromList(List.filled(32, 2)));
      final remoteId = NodeID(remote.publicKey);
      final channels = <FakeChannel>[];
      final service = P2PService(f.node, connectChannel: (_) {
        final channel = FakeChannel(); channels.add(channel); return channel;
      });
      service.nodeKeyPair = f.service.nodeKeyPair;
      service.localNodeId = f.service.localNodeId;
      service.connectToNode([Uri.parse('wss://${remoteId.toBase58()}@fixture.invalid/s5/p2p')]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final open = Unpacker(channels.single.output.sent.first)..unpackInt();
      final challenge = open.unpackBinary();
      final done = Packer()..packInt(2)
          ..packBinary(invalid == 'challenge' ? Uint8List(32) : challenge)
          ..packInt(invalid == 'features' ? 999 : 3)..packInt(0);
      final payload = done.takeBytes();
      final signature = await f.crypto.signEd25519(kp: remote, message: payload);
      final signed = Packer()..packInt(10)..packBinary(remote.publicKey)
          ..packBinary(signature)..packBinary(payload);
      channels.single.input.add(signed.takeBytes()); // Keep the source stream open.
      await Future<void>.delayed(const Duration(milliseconds: 1150));
      expect(service.peers[remoteId], isNull);
      expect(channels.first.output.closeCalls, 1);
      expect(channels, hasLength(2));
      service.blockedPeers.add('fixture.invalid');
      await channels.first.input.close(); await channels.last.input.close();
    });
  }

  test('a demanded local location also reaches connected relays', () async {
    final f = await fixture.Fixture.create();
    final node = LocalProviderNode(f.crypto);
    node.objectsBox = fixture.MemoryDB();
    final service = P2PService(node);
    service.nodeKeyPair = f.service.nodeKeyPair;
    service.localNodeId = f.service.localNodeId;
    final requester = ClosingPeer(f.origin.id);
    final relay = ClosingPeer(f.waiter.id)..isConnected = true;
    service.peers[relay.id] = relay;
    unawaited(service.onNewPeer(requester, verifyId: true).catchError((_) {}));
    requester.sent.clear();
    final query = Packer()..packInt(4)..packBinary(f.hash.fullBytes)..pack([3]);
    await requester.receive(query.takeBytes());
    expect(requester.sent, hasLength(1));
    expect(relay.sent.single, orderedEquals(requester.sent.single));
    requester.done();
  });
}

class LocalProviderNode extends S5NodeBase {
  LocalProviderNode(fixture.TestCrypto crypto)
      : super(config: {}, logger: fixture.SilentLogger(), crypto: crypto);
  @override
  bool get exposeStore => true;
  @override
  ObjectStore get store => TestStore();
}

class TestStore implements ObjectStore {
  @override
  Future<bool> canProvide(Multihash hash, List<int> types) async => types.contains(3);
  @override
  Future<StorageLocation> provide(Multihash hash, List<int> types) async =>
      StorageLocation(3, ['https://provider.example.test/verified-object'], DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeChannel implements WebSocketChannel {
  final input = StreamController<dynamic>();
  final output = FakeSink();
  @override
  Stream<dynamic> get stream => input.stream;
  @override
  WebSocketSink get sink => output;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSink implements WebSocketSink {
  final controller = StreamController<dynamic>();
  int closeCalls = 0;
  final sent = <Uint8List>[];
  @override
  void add(dynamic data) { sent.add(Uint8List.fromList(data as List<int>)); controller.add(data); }
  @override
  Future<void> close([int? code, String? reason]) async { closeCalls++; unawaited(controller.close()); }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ClosingPeer extends fixture.TestPeer {
  late void Function() done;
  late Function error;
  int closeCalls = 0;
  ClosingPeer(super.nodeId);
  @override
  void listenForMessages(Function callback,
      {dynamic onDone, Function? onError, required Logger logger}) {
    super.listenForMessages(callback, onDone: onDone, onError: onError, logger: logger);
    done = onDone as void Function();
    error = onError!;
  }
  @override
  Future<void> close() async { closeCalls++; }
}
