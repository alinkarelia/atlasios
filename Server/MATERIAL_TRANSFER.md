# Atlas original-material API v1

All routes require the existing bearer session. They are relative to `/v1/projects/:projectID/materials`. The server rechecks the current organization/project membership on every operation; UUIDs are selectors, never access credentials. The existing organization-wide project access model remains in effect. Original-file transfer is an implemented Free baseline beta capability, not a paid processing/storage claim or an already deployed external integration.

## Frozen manifest

`POST /materials` accepts **exactly** AtlasCore `FieldTransferManifest` v1. A package contains multiple scans/materials; root `id` is its API `captureID`. All dates in this contract are numeric **milliseconds since Unix epoch**, including geolocation observations and corrections. Input fields:

| Object | Fields |
| --- | --- |
| Root | `schemaVersion:1`, `id:UUID`, `projectID:UUID`, `title:String`, `createdAt:Date`, `timeZoneIdentifier:String`, `utcOffsetSeconds:Int`, optional `device`, `materials:[Material]`, `assets:[Asset]` |
| Device | `model:String`, `osVersion:String`, `appVersion:String` |
| Material | `id:UUID`, `sourceEntityID:UUID`, `kind`, optional `capturedAt:Date`, `endedAt:Date`, `importedAt:Date`, `frameID:UUID`, `geoTag` |
| Asset | `id:UUID`, `materialID:UUID`, `relativePath:String`, `mediaType:String`, `byteCount:Int64`, `sha256:String`, `kind` |

Material kinds: `photo`, `mesh`, `floorPlan`, `feature`, `measurement`, `project`. Asset kinds: `originalPhoto`, `mesh`, `roomPlan`, `metadata`, `floorPlan`, `feature`, `measurement`, `projectSnapshot`, `preview`, `other`. Each asset references a material in this package. IDs/paths must be unique. SHA-256 is 64 lowercase hexadecimal characters. Relative paths are descriptive metadata; server storage filenames come only from validated UUIDs.

`createdAt` is package creation time, not a rewritten capture clock. Preserve per-material capture/end/import times; absent original capture time stays absent. `device` may be absent for legacy material. The manifest is immutable after reservation. Repeating the same ID and content returns its existing status; changing any frozen metadata/file identity returns 409 `manifest_mismatch` and requires a new package ID.

Geotags match AtlasCore `GeoTag` exactly:

- Optional `automaticFix`: `coordinate:{latitude,longitude}`, optional `altitudeMeters`, `horizontalAccuracyMeters`, `verticalAccuracyMeters`, `observedAt:Date`, `source:deviceLocation|photoEXIF`, `isSimulated:Bool`.
- Ordered `corrections`: `id:UUID`, optional `coordinate`, `altitudeMeters`, `estimatedAccuracyMeters`, `note:String`, `changedAt:Date`. A correction without a coordinate restores the original automatic observation and cannot carry separate altitude/accuracy.

Original coordinates, accuracy, source, simulation flag and correction/reset history are retained. Manual edits require a new immutable package. A GPS observation is not a claim that AR vertices are georeferenced or survey-grade. Client dates/device/location are acquisition observations; the server does not attest their accuracy.

## Status and original author

POST returns 201 for a new package, 200 for an identical retry. `GET /materials/:captureID` returns the same status and authoritative resume offsets:

```json
{
  "captureID":"de554ee9-a44a-4849-9dc3-283de1d24686",
  "projectID":"b7312275-5701-420a-8655-6ad93986bc58",
  "state":"incomplete",
  "author":{"userID":"0d4cb2ed-722b-49dd-9aae-f75d4d7041c9","displayName":"Field operator"},
  "receivedAt":1791691300789,
  "manifest":{},
  "assets":[{"id":"aab96f86-4b11-4f92-a826-a5964612d481","byteCount":3470012,"uploadedBytes":0,"verified":false}],
  "chunkSize":1048576
}
```

Actual `manifest` contains the full frozen input, not the shortened `{}` above. State is `incomplete` or `complete`; complete status includes numeric `completedAt`. `author` is the authenticated **uploader**, determined solely from the current bearer session and stored with their display name at submission. No client-selected author, organization, upload state/offset or completion timestamp is accepted. `receivedAt`/`completedAt` are server clocks. Historical capture author cannot be inferred from a later uploader identity.

An incomplete package is visible through its status only to the original uploader and is omitted from colleagues' normal collection. Owners/admins/managers/surveyors can upload; only the original uploader can append/finalize that package. Revocation or role change immediately stops further transfers. Existing sessions and old receipts cannot bypass current membership. All current authorized project readers can view/download complete packages.

## Bounded resumable upload

Persist the frozen package ID locally before the first POST. After a lost response, app/server restart, or network loss, fetch status and resume each asset at server `uploadedBytes`.

`PUT /materials/:captureID/assets/:assetID?offset=N` accepts 1–1,048,576 raw bytes with `Content-Type: application/octet-stream`. It returns `{id,byteCount,uploadedBytes,verified}`. Every write appends at the server offset. Replaying exactly already received bytes at an older offset returns the current state without duplicating bytes. Gaps/partial overlaps return 409 `offset_conflict`; different bytes at an already durable offset return 409 `chunk_mismatch`. Fetch status before retrying these conflicts.

The final byte triggers streaming full-file SHA-256 validation. 422 `hash_mismatch` resets only this asset's offset to zero; retain the immutable manifest and retransmit the original. Zero-byte assets require the SHA-256 of empty data, are marked verified at POST, and get an actual private empty file during finalization; send no zero-byte PUT.

`POST /materials/:captureID/finalize` accepts `{}`. It rejects partial packages with 409 `incomplete_package`, checks every physical file length/hash again, then atomically sets state `complete` with `completedAt`. Retrying returns the same final status. Complete manifests and files are immutable through this API.

## Retrieve complete original sets

`GET /materials?limit=100&offset=0` returns `{materials:[<full statuses>],hasMore,nextOffset}`. Only complete packages are listed. Maximum page size is 200.

`GET /materials/:captureID/assets/:assetID?offset=N&length=1048576` returns a bounded binary slice of a complete original. Length must be 1–1,048,576; the last response contains only remaining bytes. Offset can equal byte count for an empty terminal response. Headers: declared `Content-Type`, `X-Asset-SHA256`, `X-Asset-Byte-Count`, `X-Asset-Offset`, `Content-Disposition: attachment`, `X-Content-Type-Options: nosniff`, and `Cache-Control: no-store`. No redirect or unauthenticated public file URL is returned.

Download to a temporary private file, verify full size/SHA-256, then import atomically. Keep capture dates/location history from the manifest and actual original EXIF bytes. Do not expose partial downloads as complete local projects.

`DELETE /materials/:captureID` cancels an incomplete package, removes its transferred private files and releases reserved storage (204). Only its uploader or an owner/admin/manager may cancel; managers can clear uploads abandoned by a removed employee. Complete packages return 409 `package_complete`. Repeated cancellation returns 404 because the package is absent. Local acquisition originals are unaffected.

## Limits and durable storage

- JSON manifest: 1 MiB. Materials: 1–1000. Assets: 1–2048.
- File: at most 512 MiB. Package originals: at most 1 GiB. Split large sessions without silently dropping source files.
- Title: 240 characters. Timezone identifier: 100. Device fields: 160 each. Relative path: 1024. Geo correction history: 1000 entries.
- Outstanding incomplete packages: 100 per organization. All incomplete/complete declared bytes reserve the configured organization limit (`MAX_ORGANIZATION_ASSET_BYTES`, default 8 GiB, minimum 1 GiB). Full storage returns 413 `storage_limit`; too many pending packages returns 409 `pending_package_limit`. These deployment limits do not create a paid entitlement.

Originals are private files at `ASSET_DIRECTORY/<org UUID>/<project UUID>/<package UUID>/<asset UUID>.bin`, with directories 0700/files 0600 on POSIX. Existing directories/files with group/other permissions are rejected; a Windows deployment must provide equivalent private filesystem ACLs. Never mount this directory as a public/static web root. Client paths cannot select filesystem destinations; traversal, absolute/Windows paths, controls and empty components are rejected. Binary handles reject symlinks.

Uploads/finalization/cancellation are serialized per package in one process. Chunk files are synced before durable SQLite offsets are committed. Crash tails beyond the database offset are truncated; shorter-than-committed files reset that asset and return 409 `asset_restarted`, requiring status/retransmission rather than a false success. Finalization rechecks physical hashes. Membership is rechecked after file I/O before mutation/download response. Back up SQLite **and** originals consistently. Multiple workers require shared coordination/object storage before deployment; this code does not claim distributed lock or S3 support.
