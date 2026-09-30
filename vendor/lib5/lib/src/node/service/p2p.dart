import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:lib5/constants.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/src/node/model/signed_message.dart';
import 'package:lib5/src/node/node.dart';
import 'package:lib5/util.dart';
import 'package:s5_msgpack/s5_msgpack.dart';
import 'package:tint/tint.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

abstract class Peer {
  late final NodeID id;
  final List<Uri> connectionUris;
  bool isConnected = false;
  late final Uint8List challenge;

  Peer({required this.connectionUris});

  void sendMessage(Uint8List message);

  void listenForMessages(
    Function callback, {
    dynamic onDone,
    Function? onError,
    required Logger logger,
  });

  String renderLocationUri();

  Future<void> close() async {}
}

class WebSocketChannelPeer extends Peer {
  final WebSocketChannel _socket;
  final String locationUri;
  StreamSubscription? _subscription;
  bool _closed = false;

  WebSocketChannelPeer(
    this._socket, {
    required this.locationUri,
    required super.connectionUris,
  });

  @override
  void sendMessage(Uint8List message) {
    _socket.sink.add(message);
  }

  @override
  void listenForMessages(
    Function callback, {
    dynamic onDone,
    Function? onError,
    required Logger logger,
  }) {
    _subscription = _socket.stream.listen(
      (event) async {
        if (_closed) return;
        try {
          await callback(event);
        } catch (e, st) {
          // A refused record is not a transport disconnect. Letting this
          // escape to the connection zone used to leak a socket on every retry.
          logger.catched(e, st);
          if (!isConnected) onError?.call(e);
        }
      },
      onDone: onDone,
      onError: onError,
      cancelOnError: false,
    );
  }

  @override
  String renderLocationUri() {
    return locationUri;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final closing = _socket.sink.close();
    await _subscription?.cancel();
    await closing.timeout(const Duration(seconds: 2));
  }
}

class P2PService {
  final S5NodeBase node;
  final int Function() _queryNow;
  final WebSocketChannel Function(Uri) _connectChannel;

  late KeyPairEd25519 nodeKeyPair;

  String? networkId;

  P2PService(this.node, {int Function()? queryNow,
      WebSocketChannel Function(Uri)? connectChannel})
      : _queryNow = queryNow ?? _monotonicClock(),
        _connectChannel = connectChannel ?? WebSocketChannel.connect {
    networkId = node.config['p2p']?['network'];
  }

  static int Function() _monotonicClock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsedMilliseconds;
  }

  Logger get logger => node.logger;

  late final KeyValueDB nodesBox;

  late final NodeID localNodeId;

  final peers = <NodeID, Peer>{};
  final reconnectDelay = <NodeID, int>{};
  final _connections = <NodeID>{};

  final List<Uri> selfConnectionUris = [];

  // Pending queries are bounded and lazily expire after thirty seconds.
  final hashQueryRoutingTable = <Multihash, Set<NodeID>>{};
  final _queryExpiry = <Multihash, int>{};

  Future<void> init(KeyValueDB nodesDB) async {
    localNodeId = NodeID(nodeKeyPair.publicKey);

    nodesBox = nodesDB;
  }

  List<String> blockedPeers = [];

  bool get autoConnectToNewNodes =>
      node.config['p2p']?['peers']?['autoConnectToNewNodes'] ?? true;

  Future<void> start() async {
/*     final String? domain = node.config['http']?['api']?['domain'];
    if (domain != null && node.config['p2p']?['self']?['disabled'] != true) {
      selfConnectionUris.add(
        Uri.parse('wss://$domain/s5/p2p'),
      );
    }
    logger.info('connection uris: $selfConnectionUris'); */

    final initialPeers = node.config['p2p']?['peers']?['initial'] ?? [];
    blockedPeers = node.config['p2p']?['peers']?['block'] ?? [];

    for (final p in initialPeers) {
      connectToNode([Uri.parse(p)]);
    }
  }

  Future<void> onNewPeer(Peer peer, {required bool verifyId}) async {
    peer.challenge = node.crypto.generateRandomBytes(32);

    final initialAuthPayloadPacker = Packer();
    initialAuthPayloadPacker.packInt(protocolMethodHandshakeOpen);
    initialAuthPayloadPacker.packBinary(peer.challenge);
    if (networkId != null) {
      initialAuthPayloadPacker.packString(networkId);
    }

    final completer = Completer();
    void retirePeer() {
      peer.isConnected = false;
      try {
        if (identical(peers[peer.id], peer)) peers.remove(peer.id);
      } catch (_) { /* An incoming peer may fail before assigning its ID. */ }
    }
    final handshakeTimer = Timer(const Duration(seconds: 10), () {
      if (!peer.isConnected && !completer.isCompleted) {
        retirePeer();
        completer.completeError('Handshake timeout');
        unawaited(peer.close().catchError((_) {}));
      }
    });

    final supportedFeatures = 3; // 0b00000011

    peer.listenForMessages(
      (Uint8List event) async {
        Unpacker u = Unpacker(event);
        final method = u.unpackInt();
        if (method == protocolMethodHandshakeOpen) {
          final p = Packer();
          p.packInt(protocolMethodHandshakeDone);
          p.packBinary(u.unpackBinary());
          String? peerNetworkId;
          try {
            peerNetworkId = u.unpackString();
          } catch (_) {/* No custom network */}

          if (peerNetworkId != networkId) {
            throw 'Peer in different network: $peerNetworkId';
          }

          p.packInt(supportedFeatures);
          p.packInt(selfConnectionUris.length);
          for (final uri in selfConnectionUris) {
            p.packString(uri.toString());
          }
          // TODO Protocol version
          // p.packInt(protocolVersion);
          peer.sendMessage(await signMessageSimple(p.takeBytes()));
          return;
        } else if (method == recordTypeRegistryEntry) {
          final sre = SignedRegistryEntry.deserialize(event);
          await node.registry.set(sre, receivedFrom: peer);
          return;
        } else if (method == recordTypeStreamMessage) {
          final sre = SignedStreamMessage.deserialize(event);
          await node.stream.set(sre, receivedFrom: peer);
          return;
        } else if (method == recordTypeStorageLocation) {
          // Header (40), terminator (1), Ed25519 key (33), signature (64).
          const trailerLength = 1 + 33 + 64;
          if (event.length < 40 + trailerLength) {
            throw 'Invalid storage location framing';
          }
          final hash = Multihash(event.sublist(1, 34));
          final type = event[34];
          final expiry = decodeEndian(event.sublist(35, 39));
          final partCount = event[39];
          final parts = <String>[];
          int cursor = 40;
          for (int i = 0; i < partCount; i++) {
            if (cursor + 2 > event.length - trailerLength) {
              throw 'Invalid storage location framing';
            }
            final length = decodeEndian(event.sublist(cursor, cursor + 2));
            cursor += 2;
            if (length > event.length - trailerLength - cursor) {
              throw 'Invalid storage location framing';
            }
            parts.add(utf8.decode(event.sublist(cursor, cursor + length)));
            cursor += length;
          }
          if (cursor + trailerLength != event.length || event[cursor] != 0) {
            throw 'Invalid storage location framing';
          }
          cursor++;

          final publicKey = event.sublist(cursor, cursor + 33);
          final signature = event.sublist(cursor + 33);

          if (publicKey[0] != mkeyEd25519) {
            throw 'Unsupported public key type $mkeyEd25519';
          }

          if (expiry <= DateTime.now().millisecondsSinceEpoch ~/ 1000) {
            throw 'Expired storage location';
          }
          final isValid = await node.crypto.verifyEd25519(
            pk: publicKey.sublist(1),
            message: event.sublist(0, cursor),
            signature: signature,
          );
          if (!isValid) {
            throw 'Invalid storage location signature';
          }

          final nodeId = NodeID(publicKey);
          node.addStorageLocation(
            hash,
            nodeId,
            StorageLocation(type, parts, expiry),
            message: event,
          );

          final list = hashQueryRoutingTable[hash] ?? <NodeID>{};
          for (final peerId in list) {
            if (peerId == nodeId) continue;
            if (peerId == peer.id) continue;

            if (peers.containsKey(peerId)) {
              try {
                peers[peerId]!.sendMessage(event);
              } catch (e, st) {
                logger.catched(e, st);
              }
            }
          }
          hashQueryRoutingTable.remove(hash);
          _queryExpiry.remove(hash);
        }

        if (method == protocolMethodSignedMessage) {
          final sm = await unpackAndVerifySignature(u);
          u = Unpacker(sm.message);
          final method2 = u.unpackInt();

          /*   try {
            print('${peer.id} ${hex.encode(sm.message)}');
          } catch (_) {} */

          if (method2 == protocolMethodHandshakeDone) {
            final challenge = u.unpackBinary();

            if (!areBytesEqual(peer.challenge, challenge)) {
              throw 'Invalid challenge';
            }

            final pId = sm.nodeId;

            if (!verifyId) {
              peer.id = pId;
            } else {
              if (peer.id != pId) {
                throw 'Invalid peer id on initial list';
              }
            }

            final supportedFeatures = u.unpackInt();

            if (supportedFeatures != 3) {
              throw 'Remote node does not support required features';
            }

            final connectionUrisCount = u.unpackInt()!;

            peer.connectionUris.clear();
            for (int i = 0; i < connectionUrisCount; i++) {
              peer.connectionUris.add(Uri.parse(u.unpackString()!));
            }

            peer.isConnected = true;
            handshakeTimer.cancel();
            peers[peer.id] = peer;
            reconnectDelay[peer.id] = 1;

            logger.info(
              '${'[+]'.green().bold()} ${peer.id.toString().green()} (${(peer.renderLocationUri()).toString().cyan()})',
            );

            sendPublicPeersToPeer(peer, peers.values);
            for (final p in peers.values) {
              if (p.id == peer.id) continue;

              // TODO Maybe re-add
              /*  if (p.isConnected) {
                sendPublicPeersToPeer(p, [peer]);
              } */
            }

            return;
            /* } else if (method2 == protocolMethodHashQueryResponse) { */
          } else if (method2 == protocolMethodAnnouncePeers) {
            final length = u.unpackInt()!;
            for (int i = 0; i < length; i++) {
              final peerIdBinary = u.unpackBinary();
              final id = NodeID(peerIdBinary);

              final isConnected = u.unpackBool()!;

              final connectionUrisCount = u.unpackInt()!;

              final connectionUris = <Uri>[];

              for (int i = 0; i < connectionUrisCount; i++) {
                connectionUris.add(Uri.parse(u.unpackString()!));
              }

              if (autoConnectToNewNodes && connectionUris.isNotEmpty) {
                // TODO Fully support multiple connection uris
                final uri =
                    connectionUris.first.replace(userInfo: id.toBase58());
                if (!reconnectDelay.containsKey(NodeID.decode(uri.userInfo))) {
                  connectToNode([uri]);
                }
              }
            }
          }
        } else if (method == protocolMethodHashQuery) {
          final hash = Multihash(u.unpackBinary());
          final types = u.unpackList().cast<int>();

          // print('protocolMethodHashQuery $hash $types from ${peer.id}');
          // print(
          //     'protocolMethodHashQuery ${hash.toBase64Url()} $types from ${peer.id}');

          try {
            final map = node.getCachedStorageLocations(hash, types);

            if (map.isNotEmpty) {
              final availableNodes = map.keys.toList();
              sortNodesByScore(availableNodes);

              final entry = map[availableNodes.first]!;

              if (availableNodes.first == localNodeId) {
                _sendOwnLocation(peer, entry.providerMessage);
              } else {
                peer.sendMessage(entry.providerMessage);
              }

              return;
            }
          } catch (e, st) {
            logger.catched(e, st);
          }

          final contains = node.exposeStore &&
              await node.store!.canProvide(
                hash,
                types,
              );

          if (contains) {
            final location = await node.store!.provide(hash, types);

            final message = await prepareProvideMessage(hash, location);

            node.addStorageLocation(
              hash,
              localNodeId,
              location,
              message: message,
            );

            logger.verbose('[providing] $hash');

            _sendOwnLocation(peer, message);
            return;
          }

          final now = _queryNow();
          final expired = _queryExpiry.entries
              .where((entry) => entry.value <= now)
              .map((entry) => entry.key).toList();
          for (final stale in expired) {
            hashQueryRoutingTable.remove(stale);
            _queryExpiry.remove(stale);
          }
          if (hashQueryRoutingTable.containsKey(hash)) {
            if (!hashQueryRoutingTable[hash]!.contains(peer.id)) {
              if (hashQueryRoutingTable[hash]!.length < 64) {
                hashQueryRoutingTable[hash]!.add(peer.id);
              }
            }
          } else {
            if (hashQueryRoutingTable.length >= 4096) return;
            hashQueryRoutingTable[hash] = <NodeID>{peer.id};
            _queryExpiry[hash] = now + 30000;
            for (final p in peers.values) {
              if (p.id != peer.id) {
                p.sendMessage(event);
              }
            }
          }

          return;
        } else if (method == protocolMethodRegistryQuery) {
          // TODO looks like queries are not forwarded!
          final pk = u.unpackBinary();
          final sre = node.registry.getFromDB(pk);
          if (sre != null) {
            peer.sendMessage(sre.serialize());
          }
        } else if (method == protocolMethodMessageQuery) {
          final pk = u.unpackBinary();
          int? afterTimestamp;

          try {
            afterTimestamp = (u.unpackMap() as Map)[1] as int;
          } catch (_) {}

          final hash = Multihash(pk);

          if (node.stream.streamQueryRoutingTable.containsKey(hash)) {
            node.stream.streamQueryRoutingTable[hash]!.add(peer.id);
          } else {
            node.stream.streamQueryRoutingTable[hash] = <NodeID>{peer.id};
          }

          final local = await node.stream.getStoredMessages(
            pk,
            afterTimestamp: afterTimestamp,
          );
          for (final msg in local) {
            // TODO optimization: just read directly from DB instead of serialize/deserialize
            peer.sendMessage(msg.serialize());
          }
        }
      },
      onDone: () async {
        try {
          if (identical(peers[peer.id], peer)) {
            logger.info(
              '${'[-]'.red().bold()} ${peer.id.toString().red()} (${(peer.renderLocationUri()).toString().cyan()})',
            );
          }
        } catch (_) {
          logger.info('[-] ${peer.renderLocationUri()}');
        }
        retirePeer();
        if (!completer.isCompleted) completer.completeError('onDone');
      },
      onError: (e) {
        retirePeer();
        logger.warn('${peer.renderLocationUri()}: $e');
        if (!completer.isCompleted) completer.completeError(e);
        unawaited(peer.close().catchError((_) {}));
      },
      logger: logger,
    );
    peer.sendMessage(initialAuthPayloadPacker.takeBytes());

    return completer.future.whenComplete(handshakeTimer.cancel);
  }

  Future<Uint8List> prepareProvideMessage(
      Multihash hash, StorageLocation location) async {
    // TODO Use msgpack for these messages!
    final list = [recordTypeStorageLocation] +
        hash.fullBytes +
        [location.type] +
        encodeEndian(location.expiry, 4) +
        [location.parts.length];

    for (final part in location.parts) {
      final bytes = utf8.encode(part);
      list.addAll(encodeEndian(bytes.length, 2));
      list.addAll(bytes);
    }
    list.add(0);

    final signature = await node.crypto.signEd25519(
      kp: nodeKeyPair,
      message: Uint8List.fromList(list),
    );

    return Uint8List.fromList(list + nodeKeyPair.publicKey + signature);
  }

  void _sendOwnLocation(Peer requester, Uint8List message) {
    requester.sendMessage(message);
    // Share only this demanded, locally provided record. Connected relays may
    // still have pending routes from before this provider became available.
    // This is not a scan or periodic reannouncement of the object inventory.
    for (final relay in peers.values.toList()) {
      if (identical(relay, requester) || relay.id == requester.id || !relay.isConnected) continue;
      try { relay.sendMessage(message); } catch (e, st) { logger.catched(e, st); }
    }
  }

  void sendPublicPeersToPeer(Peer peer, Iterable<Peer> peersToSend) async {
    final p = Packer();
    p.packInt(protocolMethodAnnouncePeers);

    p.packInt(peersToSend.length);
    for (final pts in peersToSend) {
      p.packBinary(pts.id.bytes);
      p.packBool(pts.isConnected);
      p.packInt(pts.connectionUris.length);
      for (final uri in pts.connectionUris) {
        p.packString(uri.toString());
      }
    }
    peer.sendMessage(await signMessageSimple(p.takeBytes()));
  }

  // TODO nodes with a score below 0.2 should be disconnected immediately and responses dropped

  double getNodeScore(NodeID nodeId) {
    if (nodeId == localNodeId) {
      return 1;
    }
    final node = nodesBox.get(nodeId.bytes);
    if (node == null) {
      return 0.5;
    }
    final map = Unpacker(node).unpackMap().cast<int, int>();
    return calculateScore(map[1]!, map[2]!);
  }

  void _vote(NodeID nodeId, bool upvote) {
    final node = nodesBox.get(nodeId.bytes);
    final map = node == null
        ? <int, int>{1: 0, 2: 0}
        : Unpacker(node).unpackMap().cast<int, int>();

    if (upvote) {
      map[1] = map[1]! + 1;
    } else {
      map[2] = map[2]! + 1;
    }

    nodesBox.set(
      nodeId.bytes,
      (Packer()..pack(map)).takeBytes(),
    );
  }

  void upvote(NodeID nodeId) {
    _vote(nodeId, true);
  }

  void downvote(NodeID nodeId) {
    _vote(nodeId, false);
  }

  // TODO add a bit of randomness with multiple options
  void sortNodesByScore(List<NodeID> nodes) {
    nodes.sort(
      (a, b) {
        return -getNodeScore(a).compareTo(getNodeScore(b));
      },
    );
  }

  // TODO Only used for the handshake, should be removed as soon as QUIC+TLS or WSS is used
  Future<Uint8List> signMessageSimple(Uint8List message) async {
    final packer = Packer();

    final signature = await node.crypto.signEd25519(
      kp: nodeKeyPair,
      message: message,
    );

    packer.packInt(protocolMethodSignedMessage);
    packer.packBinary(localNodeId.bytes);

    packer.packBinary(signature);
    packer.packBinary(message);

    return packer.takeBytes();
  }

  Future<SignedP2PMessage> unpackAndVerifySignature(Unpacker u) async {
    final nodeId = NodeID(u.unpackBinary());
    final signature = u.unpackBinary();
    final message = u.unpackBinary();

    final isValid = await node.crypto.verifyEd25519(
      pk: nodeId.bytes.sublist(1),
      message: message,
      signature: signature,
    );

    if (!isValid) {
      throw 'Invalid signature found';
    }
    return SignedP2PMessage(
      nodeId: nodeId,
      message: message,
    );
  }

  void sendHashRequest(Multihash hash,
      /* [ */ List<int> types /* = const [storageLocationTypeFull]] */) {
    final p = Packer();

    p.packInt(protocolMethodHashQuery);
    p.packBinary(hash.fullBytes);
    p.pack(types);
    // TODO Maybe add int for hop count (or not because privacy concerns)

    final req = p.takeBytes();

    for (final peer in peers.values) {
      peer.sendMessage(req);
    }
  }

  void connectToNode(List<Uri> connectionUris) async {
    // TODO Add delay here if node is known
    final connectionUri = connectionUris.firstWhere(
      (uri) => ['ws', 'wss'].contains(uri.scheme),
      /*  orElse: () => connectionUris.firstWhere(
        (uri) => uri.scheme == 'tcp', */
      orElse: () => Uri(scheme: 'unsupported'),
      /*  ), */
    );
    if (connectionUri.scheme == 'unsupported') {
      return;
      // TODO
      // TODO throw 'None of the available connection URIs are supported ($connectionUris)';
    }

    final protocol = connectionUri.scheme;

    if (connectionUri.userInfo.isEmpty) {
      throw 'Connection URI does not contain node id';
    }
    final id = NodeID.decode(connectionUri.userInfo);

    if (blockedPeers.isNotEmpty) {
      final uri = connectionUri.toString();
      for (final b in blockedPeers) {
        if (uri.contains(b)) {
          reconnectDelay[id] = 1000000000;
          return;
        }
      }
    }

    reconnectDelay[id] = reconnectDelay[id] ?? 1;

    if (id == localNodeId) {
      return;
    }
    if (_connections.contains(id) || peers[id]?.isConnected == true) return;
    _connections.add(id);
    bool retried = false;
    WebSocketChannelPeer? ownedPeer;
    runZonedGuarded(
      () async {
        logger.verbose('[connect] $connectionUri');
        if (protocol == 'tcp') {
          throw UnimplementedError();
          /*   final ip = connectionUri.host;
          final port = connectionUri.port;
          final socket = await Socket.connect(ip, port);

          await onNewPeer(
            TcpPeer(
              socket,
              connectionUris: [connectionUri],
            )..id = id,
            verifyId: true,
          ); */
        } else if (protocol == 'wss' || protocol == 'ws') {
          final locationUri = connectionUri.replace(
            userInfo: '',
          );

          final channel = _connectChannel(
            locationUri,
          );

          ownedPeer = WebSocketChannelPeer(
              channel,
              locationUri: locationUri.toString(),
              connectionUris: [connectionUri],
            )..id = id;
          await onNewPeer(
            ownedPeer!,
            verifyId: true,
          );
        }
      },
      (e, st) async {
        if (retried) return;
        retried = true;

        final old = ownedPeer;
        if (old != null) {
          old.isConnected = false;
          if (identical(peers[id], old)) peers.remove(id);
          try { await old.close(); } catch (_) { /* Close was attempted; retry remains bounded. */ }
        }

        /*   if (e is SocketException) {
          if (e.message == 'Connection refused') {
            logger.warn('[!] $id: $e');
          } else {
            logger.catched(e, st);
          }
        } else { */
        logger.catched(e, st);
        /*  } */

        final delay = reconnectDelay[id]!.clamp(1, 60);
        reconnectDelay[id] = (delay * 2).clamp(1, 60);
        await Future.delayed(Duration(seconds: delay));
        _connections.remove(id);
        connectToNode(connectionUris);
      },
    );
    /*  if (nodeId ==
        NodeID.decode('z2DWuPbL5pweybXnEB618pMnV58ECj2VPDNfVGm3tFqBvjF')) {
      return 1;
    } */
  }
}
