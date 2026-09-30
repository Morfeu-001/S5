import 'dart:io';
import 'dart:typed_data';

import 'package:hive/hive.dart';
import 'package:lib5/lib5.dart';
import 'package:lib5/node.dart';
import 'package:s5_server/db/hive_key_value_db.dart';
import 'package:test/test.dart';

import 'storage_location_validation_test.dart' as fixture;

void main() {
  test('a signed own location remains readable in native Hive across reopening', () async {
    final root = await Directory.systemTemp.createTemp('m2-hive-location-');
    final f = await fixture.Fixture.create();
    Hive.init(root.path);
    var box = await Hive.openBox<Uint8List>('objects');
    final node = S5NodeBase(config: {}, logger: fixture.SilentLogger(), crypto: f.crypto)
      ..objectsBox = HiveKeyValueDB(box);
    final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300;
    final location = StorageLocation(3, ['https://provider.example.test/object'], expiry);
    final message = await f.service.prepareProvideMessage(f.hash, location);
    try {
      node.addStorageLocation(f.hash, f.service.localNodeId, location, message: message);
      expect(node.getCachedStorageLocations(f.hash, [3, 5]), hasLength(1));
      await box.flush(); await box.close();
      box = await Hive.openBox<Uint8List>('objects');
      final reopened = S5NodeBase(config: {}, logger: fixture.SilentLogger(), crypto: f.crypto)
        ..objectsBox = HiveKeyValueDB(box);
      final cached = reopened.getCachedStorageLocations(f.hash, [3, 5]);
      expect(cached, hasLength(1));
      expect(cached[f.service.localNodeId]!.expiry, expiry);
      expect(cached[f.service.localNodeId]!.providerMessage, orderedEquals(message));
      reopened.httpClient.close();
    } finally {
      await box.close(); await root.delete(recursive: true);
      f.node.httpClient.close();
      node.httpClient.close();
    }
  });
}
