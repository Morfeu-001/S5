# Read-only public remote locations

This store advertises an already verified object at its exact public HTTPS URL.
It does not require a local image copy. A reader receives the CID from its
catalog, discovers the signed S5 location, downloads directly from the bucket or
mirror, and verifies the complete size and BLAKE3 digest before displaying it.

```toml
[store]
expose = true

[store.remote_locations]
path = "/var/lib/s5/remote-locations"
ttlSeconds = 300
```

This is a configuration example, not an installed service or scheduled task.
Use only this store if the node must advertise these remote URLs: the upstream
merged store chooses its first matching store, and the P2P service can return an
older cached provider announcement before consulting any store.

The producer creates one UTF-8 JSON record with exactly these fields:

```json
{"version":1,"cid":"<canonical b... plaintext BlobId>","size":68,"url":"https://bucket.example.org/exact/key.avif","verified_at":1700000000}
```

For the 32-byte BLAKE3 digest encoded as 64 lowercase hex characters, the record
path is `<root>/<hex[0:2]>/<hex[2:4]>/<hex>.json`. The classic S5 query is exactly
`0x1f + digest`; the external BlobId remains `0x5b 0x82 0x1e + digest + minimal
little-endian size`. The record must bind both representations and the size.
The store accepts nonnegative sizes representable by the native Dart integer;
it does not impose the frontend's image-size profile on the inventory.

The index producer, outside this store, must verify the full remote bytes and
record their CID, size and exact URL. `verified_at` records that prior operation;
reading this timestamp does not verify bytes again or prove current availability.
Publish complete records atomically by rename. The store performs no scan,
HTTP/HEAD request, bucket listing, download, hash computation, or database query.
It reads only the requested record, at most 16 KiB, without a global CID map.

The root must be an existing absolute canonical directory without symlink
ancestors. Root, shards and records must be controlled by the operator, outside
the webroot, and not writable by network clients or the S5 process. The store
rejects symlinks and nonregular entries and rechecks paths around bounded reads;
this is not an adversarial writable-filesystem sandbox or an `openat`/`O_NOFOLLOW`
implementation. A regular record may be replaced atomically with a newer one.

Only stable public HTTPS URLs are supported: public DNS host, default port,
no credentials, query string, fragment, controls or encoded path separators or
dot segments. Private presigned URLs and local/private-IP endpoints are refused.
No DNS lookup occurs here; browser network policy and deployment controls still
apply to DNS resolution. Test anonymous GET and browser CORS for the exact URL.

Only `storageLocationTypeFile` (3) is advertised, with exactly one URL in
`parts`. Full/BAO (5), archive, upload, deletion and inventory enumeration are not
supported. Multiple parts are not independent bucket alternatives in this wire
format. Independent providers/mirrors can announce their own locations and keys.

The provider signs the response through the existing P2P service. Its expiry is
`min(now + ttlSeconds, 0xffffffff)`; the configured positive TTL is an announcement
lifetime, not a polling/cron interval. No claim is produced once the clock exceeds
the unsigned wire timestamp. Records are reread for each request, but already
cached signed claims elsewhere remain valid until their expiry. Removing a record
does not revoke those distributed claims instantly.

This implementation is a bounded lookup building block. An eight-object pilot
does not establish disk/inode cost, throughput or memory limits for 20M records.
Those capacity measurements and persistent provider operation are separate work.
