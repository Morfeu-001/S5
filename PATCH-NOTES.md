# S5 0.14.1: storage-location signature validation

Local derivative of official S5 tag v0.14.1, commit `7b9fc6def87644c66c33274f9a6b217a29231efd`. This is not an unmodified official binary or a new upstream release.

`vendor/lib5` originates from the official lib5 0.2.0 archive whose SHA256 is `cd3d867a150bb7aacd07cfd23729da75cc2416b9c4099d722e499bfaa392e7b7`, matching the original server lockfile. `pubspec_overrides.yaml` uses this directory and fixes all three upstream Git dependencies to their original lockfile revisions, preserving the original http1.0.0 override. No dependency version upgrade is intended.

The P2P storage-location receiver previously awaited Ed25519 verification but discarded its boolean result before persisting and forwarding the record. It also allowed an authentic expired record to replace a current claim. The patch checks framing, expiry, and the signature before any cache write, forwarding, or removal of the pending routing entry. It preserves valid archive records with zero parts and the existing binary protocol.

Product diff: 21 added lines and one replaced line in `vendor/lib5/lib/src/node/service/p2p.dart`. No store or hash algorithm change.

## Validation status

RED was executed by the coordinating agent on albums in the isolated build workspace, with Linux Dart SDK3.3.1, before the patch. The first eight-test version produced four passes and four expected failures: invalid signature, tampered URL, expired authentic replay, and signed nonzero terminator were accepted instead of rejected. The coordinator retained the command output; this directory does not claim to contain that remote log.

The final test file has nine tests, adding a positive archive/138-byte control and checking that rejected records preserve the pending route. Tests use real Ed25519 and the real upstream receiver, with in-memory DB/peers; they do not contact public peers or load the Rust library.

Command:

```sh
dart test test/storage_location_validation_test.dart -r expanded
```

Independent read-only review by the backend reviewer found no remaining blocker in this scoped diff and its nine tests. The coordinator then confirmed GREEN on Linux with Dart3.3.1: all nine tests passed (18.871s elapsed, 9.354s CPU). Native executable compilation succeeded, but startup via the private loader failed because Dart AOT inspected the loader through /proc/self/exe. No successful runtime startup or reader availability is claimed. The coordinator is testing an explicit AOT snapshot with the verified Dart3.3.1 dartaotruntime instead; runtime remains a separate acceptance gate. The remote final lockfile has been copied back and checked: only the three Git refs and the lib5 source changed, with no package version updates. `git diff --check` passed locally. No production runtime was started by the patch author.

## Frozen file hashes

- Final Linux build lockfile: `31f52dc6d7620a5e71ae4cb5a5e8fea0e36a433c0ee8ced53ac442be724fd642`
- Receiver: `90ea9fb77075772807cf19bd94155f8c8d80e276b239b23060af0c12479efac7`
- Tests: `66d651e01b30a0757c92f661e59e6b02184ccab4584d58e02ecae998a79c3408`
- Dependency overrides: `a8e6608e7e38300c374d09194cd99cc8ca4bfa2c45eaefcf61bae7eae6670848`

## Explicit limits

This patch is not a general audit of S5. Outstanding upstream limitations include pending queries without expiry cleanup, limits on WebSocket frame traffic not provided by Nginx handshake throttling, and the need to verify local bytes before making a path available to LocalObjectStore. Client-side signature/hash/size checks remain mandatory. The deployment pilot is eight previously verified files, not a capacity claim for the full image collection.
