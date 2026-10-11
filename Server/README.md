# Atlas Field API

A runnable Node 24 TypeScript/Fastify service for the iOS application's team workflow. Data persists in SQLite; there are no seeded users, pretend subscription purchases, or cloud processing responses.

## Run

```sh
npm ci
npm run build
npm test
npm start
```

The service defaults to `127.0.0.1:3000`, `./data/atlas.sqlite`, and a private `./data/assets` original-file directory. Set `HOST`, `PORT`, `DATABASE_PATH`, `ASSET_DIRECTORY`, and optional comma-separated `CORS_ORIGINS` in the process environment. `MAX_ORGANIZATION_ASSET_BYTES` bounds declared storage per organization (8 GiB by default, minimum 1 GiB). `npm run dev` starts a TypeScript watcher. `.env.example` documents variables; the server does not automatically load `.env` files.

Use HTTPS through a reverse proxy when connecting from an iPhone over a network. Do not expose the development HTTP listener as a public production service. Native iOS does not need CORS. Browser origins are denied unless configured.

`GET /health` returns the service status. All `/v1` routes except registration and login require `Authorization: Bearer <token>`.

## Accounts and organization ownership

`POST /v1/auth/register` accepts:

```json
{
  "email": "surveyor@example.com",
  "password": "a-password-with-at-least-12-characters",
  "displayName": "Field operator",
  "organizationName": "Survey team"
}
```

It returns `{token, expiresAt, user, organization}` and creates an actual **Free** organization with the new user as owner. `POST /v1/auth/login` accepts `{email,password}` and returns `{token,expiresAt,user}`. `POST /v1/auth/logout` revokes that session. `GET /v1/me` returns the current user and organization memberships.

Passwords are salted and hashed with scrypt. Only hashes of random bearer tokens are persisted. Sessions expire after 30 days, survive server restarts, and never contain a client-selected identity. Responses do not include password hashes or session hashes.

Organization APIs:

- `GET /v1/organizations` → `{organizations:[{id,name,plan,createdAt,role}]}`.
- `POST /v1/organizations` with `{name}` creates another organization owned by the current account.
- `GET /v1/organizations/:organizationID/members` lists the team. Contact emails are shown to management roles only.
- `POST /v1/organizations/:organizationID/members` with `{email,role}` adds an **already registered account**. This version does not send invitations or email.
- `PATCH /v1/organizations/:organizationID/members/:userID` with `{role}` changes a role.
- `DELETE` on that membership removes access. Removing or demoting the last owner is rejected.

Roles are `owner`, `admin`, `manager`, `surveyor`, `reviewer`, `viewer`. Owner/admin manage membership. Owner/admin/manager manage business workorders. Surveyors edit field features and their tasks. Reviewers accept feature revisions and review task outcomes, but cannot edit feature content. Viewers read field data. Only owners can grant/remove ownership.

Client organization IDs are selectors, never proof of ownership. Access is checked from the authenticated session and database membership for every project. Technical UUIDs are normalized to lowercase; free text attributes preserve their spelling.

## Projects and records

`POST /v1/projects` accepts `{id?,organizationID,name,kind,coordinateReference,notes?,requiresIndependentReview?}`. `id` can be an offline-generated UUID. Retrying identical creation with that ID returns the existing initial project (200 instead of 201), so a lost response does not duplicate the project. A different payload, another organization, or a project subsequently edited returns 409 and needs an explicit reload. Supported kinds: `cemetery`, `building`, `objectScan`, `site`.

Coordinate references preserve the Swift Codable enum structure:

```json
{"localMeters":{"frameID":"7f426080-73e7-4ba0-bcb2-1b289e729b1a"}}
```

or `{"wgs84":{}}`. Tagged DTOs `{type:"localMeters",frameID}` / `{type:"wgs84"}` are also accepted. Metric frames must match the project; geographic polygons require WGS84.

`GET /v1/projects?organizationID=...` returns `{projects:[...]}`. Each project contains `id`, `organizationID`, `name`, `kind`, `coordinateReference`, `notes`, `requiresIndependentReview`, `revision`, `createdAt`, `updatedAt`. `GET /v1/projects/:projectID` gets one project. `PATCH` accepts `{baseRevision,name?,notes?,requiresIndependentReview?}` and requires a management role. Coordinate reference changes are intentionally not offered after creating a project.

For each of `features`, `tasks`, and `workorders` under `/v1/projects/:projectID`:

- `GET /<collection>?limit=100&offset=0` → `{<collection>:[...],hasMore,nextOffset}`. Maximum page size: 200.
- `GET /<collection>/:id` gets a record.
- `POST /<collection>` with `{id?,operationID,data}` creates a record.
- `PUT /<collection>/:id` with `{operationID,baseRevision,data}` creates or replaces a revision. Creation uses `baseRevision:0`.
- `DELETE /<collection>/:id` with `{operationID,baseRevision}` creates a tombstone; it does not destroy history.
- `GET /<collection>/:id/revisions/:revision` returns `{id,projectID,revision,snapshot,contentHash,authorID,createdAt,deleted,reviews}`.

If a creation has no explicit ID, its operation ID becomes the record ID, so retrying a lost response does not create another record. Records are UUIDs owned by one project. Linking to a different project or organization is rejected, even if the caller knows the identifier.

### Feature data

```json
{
  "label": "A-001",
  "category": "grave",
  "geometry": {
    "metricPolygon": {
      "_0": {
        "frameID": "7f426080-73e7-4ba0-bcb2-1b289e729b1a",
        "vertices": [{"x":0,"y":0},{"x":2,"y":0},{"x":2,"y":3},{"x":0,"y":3}],
        "holes": []
      }
    }
  },
  "attributes": {"source":"field observation"},
  "notes": "",
  "reviewStatus": "needsReview",
  "links": []
}
```

Categories match AtlasCore: `grave`, `sector`, `path`, `building`, `boundary`, `other`. Geometry also accepts the same `metricPolygon` without `_0`, or a `{type:"metricPolygon",frameID,vertices,holes}` DTO. Geographic vertices are `{longitude,latitude}` under `geographicPolygon`.

Polygons are checked for finite coordinates, valid frame, zero area, self-intersections, invalid holes, and coordinate bounds. Geometry supports up to 2048 total vertices and 64 holes. This is a bounded polygon API, not a point-cloud upload endpoint. Polygons crossing the antimeridian must be split before import.

`attributes` is a string map. `links:[{relation,targetID}]` is the explicit, tenant-checked relationship mechanism; arbitrary strings in attributes are not interpreted as database links. Features referenced by tasks or other features cannot be deleted until those references are removed.

The server manages `id`, `projectID`, `organizationID`, `revision`, timestamps, `deleted`, and acceptance. Input `reviewStatus` can be `draft` or `needsReview`. A client cannot claim `reviewed` by uploading that status.

### Tasks and workorders

Task data: `{title,description?,status?,assigneeID?,targetFeatureID?,priority?,dueAt?}`. Statuses: `open`, `in_progress`, `submitted`, `accepted`, `needs_revision`, `blocked`, `cancelled`; priorities: `low`, `normal`, `high`. Assignees must be working members of the same organization. Accepting a task linked to a feature requires acceptance of the feature's **current** revision.

Workorder data: `{title,clientName?,description?,status?,currency?,estimatedAmountMinor?,actualAmountMinor?,dueAt?}`. Statuses: `draft`, `quoted`, `approved`, `in_progress`, `delivered`, `accepted`, `closed`, `cancelled`. Amounts are nonnegative integer minor currency units. These are business bookkeeping records, not payment receipts or customer electronic signatures. Workorder reads and changes require a management role; financial changes are excluded from field staff's sync feed.

## Review and immutable acceptance

`POST /v1/projects/:projectID/reviews` accepts `{operationID,featureID,revision,verdict,note?}`; verdict is `accepted` or `changes_requested`. The specified revision must still be current. `GET /v1/projects/:projectID/reviews` is paginated.

Acceptance fixes one immutable revision. Later editing creates another draft while preserving the accepted snapshot and review. SQLite triggers prohibit updating or deleting historical revisions and reviews. With `requiresIndependentReview:true`, the author of the submitted revision cannot accept it. Review notes also remain immutable.

Feature responses expose `reviewStatus` and `acceptedRevision`; editing revision 3 after accepting revision 2 does not make revision 3 accepted.

## Offline synchronization

`POST /v1/projects/:projectID/sync/push`:

```json
{
  "operations": [
    {
      "operationID": "7d494a47-167a-48ae-85b5-8b9088dd898f",
      "entity": "feature",
      "action": "upsert",
      "id": "bcbb5429-a83c-44b8-be52-a6664de2f0da",
      "baseRevision": 0,
      "data": {"label":"A-001","category":"grave","geometry":{},"attributes":{}}
    }
  ]
}
```

Replace the shortened example geometry with a valid polygon. Maximum 50 operations and 1 MiB per request. Entities are `feature`, `task`, `workorder`, `review`. Normal records use `upsert` or `delete`. Review operations use `entity:"review"`, `action:"review"`, `id:<featureID>`, `baseRevision:<feature revision>`, `data:{verdict,note}`.

Response: `{results:[{operationID,status,record?,revision?,cursor?,current?,code?,message?}],cursor}`. Status is `applied`, `conflict`, or `rejected`. Operations execute in order and independently; one rejected operation does not roll back earlier successful operations. Create dependencies before their dependants.

Every applied operation and validated conflict/rejection is persisted under `(user,project,operationID)`. The same operation and payload return the same result after network loss or restart. Reusing the ID with different content is rejected. To resolve a conflict, fetch the current record, rebase the desired change, and submit a **new** operation ID. Do not automatically overwrite the newer revision.

`GET /v1/projects/:projectID/sync/pull?cursor=0&limit=100` returns `{changes:[{sequence,entity,id,revision,action,data,createdAt}],cursor,hasMore}`. Maintain a cursor **per project** and persist it with locally applied changes. The cursor advances past hidden finance events without exposing them. A cursor ahead of the project's log is rejected so a client can recover after restoring another database.

The existing account, project, record and sync APIs use ISO8601 UTC strings with milliseconds. The iOS decoder should accept both fractional and whole seconds. The versioned material-transfer API instead uses AtlasJSON's numeric Unix milliseconds, including capture/geo dates; neither API uses Swift's default Apple-epoch Date encoding.

## Resumable original materials

The service now transfers real photos, meshes, RoomPlan originals, plans, polygons and project snapshots as authenticated immutable packages. The native app chooses **automatic** or **manual** dispatch, with an independent **Wi-Fi only** preference. An offline queue remains local until dispatch; submitted metadata stays incomplete and hidden from colleagues' collections until every original file is verified. Queue time, upload time and original capture time are kept separate.

The [v1 material API contract](MATERIAL_TRANSFER.md) specifies manifest fields, original geolocation/correction provenance, 1 MiB binary chunks, lost-response/restart recovery, finalization, private original download, cancellation, role checks and storage bounds. Original-file transfer is a **Free baseline beta capability** with deployment-level storage limits, rather than a fabricated paid entitlement.

Other devices need a working shared backend with HTTPS, this API and authenticated accounts. Installing the app or entering a chat/video-conference URL does not deploy storage. This module can be reused behind an existing project's backend after real authentication/storage integration; no family-archive or messaging service is hardcoded or claimed as deployed.

## Optional real Apple billing

With no Apple configuration, `GET /v1/organizations/:organizationID/billing` returns `{plan:"free",paymentProvider:"not_configured",verifiedEntitlement:null,appleVerificationAvailable:false,prototypeMode:true}`. Free organizations can use implemented prototype workflows subject to roles; this mode grants no paid entitlement. Verification returns **503 `billing_not_configured`**.

The service includes Apple's official `@apple/app-store-server-library`. To enable it, set:

- `APPLE_BUNDLE_ID`: the actual app bundle identifier.
- `APPLE_ENVIRONMENT`: exactly `Sandbox` or `Production`. Xcode local StoreKit receipts do not grant a server entitlement.
- `APPLE_APP_ID`: the numeric App Store Connect app ID; required for Production.
- `APPLE_ROOT_CERT_PATHS`: comma-separated local DER/PEM Apple root CA certificates obtained from [Apple PKI](https://www.apple.com/certificateauthority/). Configure the appropriate current Apple roots; arbitrary self-signed certificates are not production trust anchors.
- Optional `APPLE_ALLOWED_PRODUCT_IDS`: a subset of the six fixed IDs below. By default all six are allowed.

| Product ID | Plan | Editor seats |
| --- | --- | --- |
| `com.atlasfield.pro.monthly` / `com.atlasfield.pro.yearly` | pro | 1 |
| `com.atlasfield.business3.monthly` / `com.atlasfield.business3.yearly` | business | 3 |
| `com.atlasfield.business10.monthly` / `com.atlasfield.business10.yearly` | business | 10 |

There is no Enterprise IAP product. Product prices and subscription periods are configured in App Store Connect and displayed by StoreKit, not fabricated by this server. Verification needs public Apple root certificates; an App Store API private key is not required for this JWS verification path.

`POST /v1/organizations/:organizationID/billing/apple/verify` accepts only `{signedTransaction}` and requires an owner/admin bearer session. Apple certificate chain, signature, OCSP revocation, bundle, environment, auto-renewable type, ownership, dates, and allowed product are checked. `appAccountToken` must equal the authenticated Atlas user UUID. The native purchase must use that UUID in StoreKit's `.appAccountToken(...)` after signing in.

An original subscription is permanently bound to one organization and purchaser. It cannot be restored into a second organization. A newer transaction supersedes older signed data; replaying old data does not erase a recorded revocation. There is no manual Free-to-paid endpoint.

Successful verification returns the current state, which may honestly be expired or revoked:

```json
{
  "plan": "business",
  "paymentProvider": "apple",
  "appleVerificationAvailable": true,
  "prototypeMode": false,
  "verifiedEntitlement": {
    "tier": "business",
    "scope": {"organization":{"_0":"organization-uuid"}},
    "source": "serverVerified",
    "status": "active",
    "capabilities": ["captureLiDAR","editGeometry","measure","exportOwnData","advancedPlans","teamManagement","businessWorkflow"],
    "validUntil": "2026-11-09T12:00:00.000Z",
    "offlineValidUntil": "2026-10-10T12:00:00.000Z",
    "verifiedAt": "2026-10-09T12:00:00.000Z",
    "revision": 1,
    "quotas": {"editorSeats":3,"cloudStorageBytes":null,"computeCredits":null}
  }
}
```

The DTO matches AtlasCore's entitlement enum structure. The offline lease lasts at most 24 hours and never extends past expiry. It is a cache/display lease; each server request independently checks current billing and membership. Material transfer is available as the implemented Free baseline with deployment storage limits, rather than a fabricated paid `cloudUpload` entitlement. No cloud processing or enterprise integration capability is granted.

When billing is configured, adding team members and writing business workorders requires an active Business subscription. Editor seats are counted across non-viewer memberships. After expiry or downgrade, the owner and oldest eligible members retain writes up to the current quota; other members retain read/export access. A malformed partial Apple configuration keeps paid operations unavailable rather than silently enabling prototype privileges. Baseline own-data workflows remain available for the owner's Free seat.

Configure App Store Server Notifications V2 at the HTTPS URL `POST /v1/billing/apple/notifications` with `{signedPayload}`. This endpoint requires Apple signature verification instead of a bearer token. It verifies both the outer notification and nested signed transaction/renewal data, deduplicates notification UUIDs, and records renewal, refund, revocation, upgrade, and signed billing-grace information. Unknown subscriptions are stored without granting an organization entitlement, then considered when the purchaser binds the subscription. Refund reversal can clear revocation only through a verified `REFUND_REVERSED` notification. `TEST` notifications are acknowledged without a grant.

A forged payload returns an error and grants nothing. A temporary certificate-check outage returns a retryable 503. Production needs a working notification delivery/retry path to keep revocations current; signature verification of a saved transaction alone is not a live subscription-status query. App Store Server API reconciliation/recovery is a follow-up operational integration, not claimed as available here.

## Storage, checks, and practical limits

Writes use synchronous `BEGIN IMMEDIATE` transactions, WAL, foreign keys, composite tenant ownership constraints, and a busy timeout. No transaction spans an asynchronous network or password operation. A lock timeout returns a retryable error, never a success. This design is suitable for one small deployment, not a horizontally scaled PostGIS fleet.

Run `npm run check`, `npm run build`, and `npm test`. Integration tests cover authentication, organization isolation, references, roles, idempotency, competing revisions, immutable acceptance, restart persistence, finance filtering, original material metadata/bytes, resumable offsets, lost responses, hash failures, partial visibility, revocation, private paths, cancellation and storage reservation limits.

This service stores project data, JSON polygon revisions, independently verified Apple billing state, and authenticated immutable original material packages. It does **not** reconstruct 3D models, perform OCR, charge cards, provide email verification/password recovery, or expose the complete future grave/person/rights-holder registry. A production rollout also needs consistent database/original-file backup/restore, HTTPS, account recovery, operational monitoring, storage cleanup/reconciliation, and migrations. A future PostGIS/object-storage migration should keep the UUID/revision/transfer contracts and move spatial indexing and geometry validation into the spatial database.
