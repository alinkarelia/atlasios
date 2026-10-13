import Fastify, { type FastifyInstance, type FastifyRequest, type FastifyReply, type FastifyContextConfig } from 'fastify';
import cors from '@fastify/cors';
import rateLimit from '@fastify/rate-limit';
import { randomUUID } from 'node:crypto';
import { dirname, join } from 'node:path';
import { Store } from './store.js';
import { AppleBilling } from './billing.js';
import { registerMaterialRoutes } from './materials.js';
import { registerCollaborationRoutes, type AssemblyProcessor } from './collaboration.js';
import { hashPassword, verifyPassword, tokenHash, newToken, contentHash, canonical } from './auth.js';
import { ApiError, type Role, type Entity, roles, object, keys, text, id, enumeration, integer,
  coordinateReference, featureData, taskData, workorderData, bodySchema, stringSchema,
  uuidSchema, uuidPattern, operationSchema } from './domain.js';

interface UserRow { id: string; email: string; display_name: string; password_hash: string; created_at: string }
interface OrgRow { id: string; name: string; plan: string; created_at: string }
interface ProjectRow {
  id: string; organization_id: string; name: string; kind: string; coordinate_reference: string;
  notes: string; requires_independent_review: number; revision: number; created_by: string; created_at: string; updated_at: string;
}
interface RecordRow {
  id: string; organization_id: string; project_id: string; entity: string; version: number;
  data_json: string; deleted: number; created_by: string; created_at: string; updated_at: string;
}
interface ReviewRow {
  id: string; organization_id: string; project_id: string; record_id: string; version: number;
  verdict: string; note: string; author_id: string; created_at: string;
}
interface Operation {
  operationID: string; entity: Entity; action: 'upsert' | 'delete' | 'review'; id: string;
  baseRevision: number; data?: Record<string, unknown>;
}
interface OperationResult {
  operationID: string; status: 'applied' | 'conflict' | 'rejected'; record?: Record<string, unknown>;
  current?: Record<string, unknown>; revision?: number; cursor?: number; code?: string; message?: string;
}
interface SessionPrincipal { user: UserRow; tokenHash: string }
declare module 'fastify' { interface FastifyRequest { atlasPrincipal?: SessionPrincipal } }

export interface AppOptions {
  databasePath?: string; logger?: boolean; rateLimit?: boolean; corsOrigins?: string[]; billingEnvironment?: NodeJS.ProcessEnv;
  assetDirectory?: string; maxOrganizationAssetBytes?: number;
  assemblyProcessor?: AssemblyProcessor;
}

const managers: Role[] = ['owner', 'admin', 'manager'];
const featureWriters: Role[] = ['owner', 'admin', 'manager', 'surveyor'];
const reviewers: Role[] = ['owner', 'admin', 'manager', 'reviewer'];
const now = () => new Date().toISOString();
const notFound = () => new ApiError(404, 'not_found', 'Resource not found');
const forbidden = () => new ApiError(403, 'forbidden', 'Your role does not permit this action');

export async function buildApp(options: AppOptions = {}): Promise<FastifyInstance> {
  const app = Fastify({
    logger: options.logger === false ? false : {
      level: 'info', redact: ['req.headers.authorization', 'req.headers.cookie', 'password', 'token', 'signedTransaction'],
    },
    bodyLimit: 1024 * 1024,
    ajv: { customOptions: { removeAdditional: false, coerceTypes: false, useDefaults: false } },
  });
  const store = new Store(options.databasePath ?? './data/atlas.sqlite');
  const billing = new AppleBilling(store, options.billingEnvironment ?? process.env);
  if (billing.commercialMode && !billing.configured) app.log.warn('Apple billing configuration is invalid; paid services remain unavailable');
  await app.register(cors, { origin: options.corsOrigins?.length ? options.corsOrigins : false });
  if (options.rateLimit !== false) await app.register(rateLimit, { max: 240, timeWindow: '1 minute' });
  app.addHook('onClose', async () => { store.close(); });
  app.addHook('onRequest', async (request, reply) => {
    reply.header('Cache-Control', 'no-store');
    const path = request.url.split('?')[0];
    if (path === '/health' || path === '/v1/auth/register' || path === '/v1/auth/login' || path === '/v1/billing/apple/notifications') return;
    const authorization = request.headers.authorization;
    if (typeof authorization !== 'string' || !/^Bearer [A-Za-z0-9_-]{43}$/.test(authorization)) {
      throw new ApiError(401, 'unauthorized', 'A valid bearer session is required');
    }
    const hash = tokenHash(authorization.slice(7));
    const session = store.get<{ user_id: string }>('SELECT user_id FROM sessions WHERE token_hash = ? AND expires_at > ?', hash, Date.now());
    const user = session && store.get<UserRow>('SELECT * FROM users WHERE id = ?', session.user_id);
    if (!user) throw new ApiError(401, 'unauthorized', 'A valid bearer session is required');
    request.atlasPrincipal = { user, tokenHash: hash };
  });
  app.addHook('preValidation', async request => {
    // UUIDs have no case semantics; Swift's uppercase encoding must address the same record.
    const uuidKeys = new Set(['id', 'organizationID', 'projectID', 'recordID', 'userID', 'operationID',
      'targetID', 'frameID', 'featureID', 'assigneeID', 'targetFeatureID']);
    const pattern = new RegExp(uuidPattern);
    const pending: { value: unknown; depth: number; normalize: boolean }[] = [request.body, request.params, request.query].map(value => ({ value, depth: 0, normalize: true }));
    while (pending.length) {
      const { value, depth, normalize } = pending.pop()!;
      if (!value || typeof value !== 'object' || Buffer.isBuffer(value)) continue;
      if (depth > 64) throw new ApiError(400, 'invalid_input', 'JSON nesting exceeds the limit');
      for (const [key, item] of Object.entries(value)) {
        if (normalize && uuidKeys.has(key) && typeof item === 'string' && pattern.test(item)) (value as Record<string, unknown>)[key] = item.toLowerCase();
        else if (item && typeof item === 'object') pending.push({ value: item, depth: depth + 1, normalize: normalize && key !== 'attributes' });
      }
    }
  });
  app.setErrorHandler((error, request, reply) => {
    const known = error as Error & { validation?: unknown; statusCode?: number };
    if (error instanceof ApiError) return reply.code(error.status).send({ error: { code: error.code, message: error.message } });
    if (known.validation || known.statusCode === 400) return reply.code(400).send({ error: { code: 'invalid_input', message: 'Request does not match the API schema' } });
    if (known.statusCode === 429) {
      return reply.code(429).send({ error: { code: 'rate_limited', message: 'Too many requests; retry later' } });
    }
    if (known.statusCode === 413) return reply.code(413).send({ error: { code: 'payload_too_large', message: 'Request exceeds the size limit' } });
    if (/database is locked|SQLITE_BUSY/.test(known.message)) {
      return reply.header('Retry-After', '1').code(503).send({ error: { code: 'temporarily_unavailable', message: 'Retry this operation with the same operationID' } });
    }
    request.log.error({ err: error }, 'Request failed');
    return reply.code(500).send({ error: { code: 'internal_error', message: 'The request could not be completed' } });
  });

  function user(request: FastifyRequest) {
    if (!request.atlasPrincipal) throw new ApiError(401, 'unauthorized', 'A valid bearer session is required');
    return request.atlasPrincipal.user;
  }
  function role(organizationID: string, request: FastifyRequest): Role {
    const membership = store.get<{ role: Role }>('SELECT role FROM memberships WHERE organization_id = ? AND user_id = ?', organizationID, user(request).id);
    if (!membership) throw notFound();
    return membership.role;
  }
  function requireRole(actual: Role, allowed: Role[]) { if (!allowed.includes(actual)) throw forbidden(); }
  function project(projectID: string, request: FastifyRequest) {
    id(projectID, 'projectID');
    const row = store.get<ProjectRow>('SELECT * FROM projects WHERE id = ?', projectID);
    if (!row) throw notFound();
    return { row, role: role(row.organization_id, request) };
  }
  function publicUser(row: UserRow) { return { id: row.id, email: row.email, displayName: row.display_name, createdAt: row.created_at }; }
  function publicOrg(row: OrgRow) { return { id: row.id, name: row.name, plan: billing.snapshot(row.id).plan, createdAt: row.created_at }; }
  function publicProject(row: ProjectRow) {
    return { id: row.id, organizationID: row.organization_id, name: row.name, kind: row.kind,
      coordinateReference: JSON.parse(row.coordinate_reference), notes: row.notes,
      requiresIndependentReview: Boolean(row.requires_independent_review), revision: row.revision,
      createdAt: row.created_at, updatedAt: row.updated_at };
  }
  function publicReview(row: ReviewRow) {
    return { id: row.id, projectID: row.project_id, featureID: row.record_id, revision: row.version,
      verdict: row.verdict, note: row.note, reviewerID: row.author_id, createdAt: row.created_at };
  }
  function record(row: RecordRow): Record<string, unknown> {
    const data = JSON.parse(row.data_json) as Record<string, unknown>;
    if (row.entity === 'feature') {
      const review = store.get<ReviewRow>('SELECT * FROM reviews WHERE record_id = ? AND version = ? ORDER BY created_at DESC, rowid DESC LIMIT 1', row.id, row.version);
      if (review) data.reviewStatus = review.verdict === 'accepted' ? 'reviewed' : 'draft';
      const accepted = store.get<{ version: number }>("SELECT version FROM reviews WHERE record_id = ? AND verdict = 'accepted' ORDER BY version DESC LIMIT 1", row.id);
      data.acceptedRevision = accepted?.version ?? null;
    }
    return { ...data, id: row.id, projectID: row.project_id, organizationID: row.organization_id,
      revision: row.version, deleted: Boolean(row.deleted), createdAt: row.created_at, updatedAt: row.updated_at };
  }
  function scopedRecord(recordID: string, projectID: string, entity?: string): RecordRow {
    const row = store.get<RecordRow>('SELECT * FROM records WHERE id = ? AND project_id = ?', recordID, projectID);
    if (!row || (entity && row.entity !== entity)) throw notFound();
    return row;
  }
  function audit(organizationID: string, actorID: string, action: string, subjectID: string) {
    store.run('INSERT INTO audit (organization_id, actor_id, action, subject_id, created_at) VALUES (?, ?, ?, ?, ?)', organizationID, actorID, action, subjectID, now());
  }
  function session(userID: string) {
    const token = newToken(); const expiresAt = Date.now() + 30 * 24 * 3600 * 1000;
    store.run('DELETE FROM sessions WHERE expires_at <= ?', Date.now());
    store.run('INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)', tokenHash(token), userID, now(), expiresAt);
    return { token, expiresAt: new Date(expiresAt).toISOString() };
  }
  function cursor(projectID: string) { return store.get<{ value: number }>('SELECT COALESCE(MAX(sequence), 0) AS value FROM changes WHERE project_id = ?', projectID)!.value; }
  function change(row: ProjectRow, entity: string, recordID: string, revision: number, kind: string, payload: Record<string, unknown>) {
    return Number(store.run('INSERT INTO changes (organization_id, project_id, entity, record_id, version, kind, payload_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      row.organization_id, row.id, entity, recordID, revision, kind, JSON.stringify(payload), now()).lastInsertRowid);
  }

  await registerMaterialRoutes(app, store, {
    assetDirectory: options.assetDirectory ?? join(dirname(options.databasePath ?? './data/atlas.sqlite'), 'assets'),
    maxOrganizationBytes: options.maxOrganizationAssetBytes,
    scope: project, user, audit,
  });
  await registerCollaborationRoutes(app, store, { scope: project, user, audit, processor: options.assemblyProcessor,
    assetDirectory: options.assetDirectory ?? join(dirname(options.databasePath ?? './data/atlas.sqlite'), 'assets') });

  app.get('/health', async () => ({ status: 'ok', storage: 'sqlite', version: '0.1.0' }));
  const authConfig: FastifyContextConfig = options.rateLimit === false ? {} : { rateLimit: { max: 12, timeWindow: '1 minute' } };
  const emailSchema = { type: 'string', format: 'email', maxLength: 254 };
  app.post('/v1/auth/register', {
    config: authConfig,
    schema: { body: bodySchema({ email: emailSchema, password: stringSchema(128, 12), displayName: stringSchema(160, 1), organizationName: stringSchema(160, 1) }, ['email', 'password', 'displayName', 'organizationName']) },
  }, async (request, reply) => {
    const data = request.body as { email: string; password: string; displayName: string; organizationName: string };
    text(data.displayName, 'displayName', 160, 1); text(data.organizationName, 'organizationName', 160, 1);
    const email = data.email.trim().toLowerCase();
    if (store.get('SELECT id FROM users WHERE email = ?', email)) throw new ApiError(409, 'account_exists', 'An account with this email already exists');
    const passwordHash = await hashPassword(data.password);
    const userID = randomUUID(); const organizationID = randomUUID(); const timestamp = now();
    const result = store.transaction(() => {
      if (store.get('SELECT id FROM users WHERE email = ?', email)) throw new ApiError(409, 'account_exists', 'An account with this email already exists');
      store.run('INSERT INTO users VALUES (?, ?, ?, ?, ?)', userID, email, data.displayName.trim(), passwordHash, timestamp);
      store.run('INSERT INTO organizations VALUES (?, ?, ?, ?)', organizationID, data.organizationName.trim(), 'free', timestamp);
      store.run('INSERT INTO memberships VALUES (?, ?, ?, ?)', organizationID, userID, 'owner', timestamp);
      return { ...session(userID), user: publicUser(store.get<UserRow>('SELECT * FROM users WHERE id = ?', userID)!),
        organization: publicOrg(store.get<OrgRow>('SELECT * FROM organizations WHERE id = ?', organizationID)!) };
    });
    return reply.code(201).send(result);
  });
  app.post('/v1/auth/login', {
    config: authConfig, schema: { body: bodySchema({ email: emailSchema, password: stringSchema(128, 1) }, ['email', 'password']) },
  }, async request => {
    const data = request.body as { email: string; password: string };
    const row = store.get<UserRow>('SELECT * FROM users WHERE email = ?', data.email.trim().toLowerCase());
    if (!await verifyPassword(data.password, row?.password_hash) || !row) throw new ApiError(401, 'invalid_credentials', 'Email or password is incorrect');
    return { ...session(row.id), user: publicUser(row) };
  });
  app.post('/v1/auth/logout', async (request, reply) => {
    store.run('DELETE FROM sessions WHERE token_hash = ?', request.atlasPrincipal!.tokenHash);
    return reply.code(204).send();
  });
  app.get('/v1/me', async request => ({ user: publicUser(user(request)), memberships: store.all<{ organization_id: string; role: Role; name: string }>(
    'SELECT m.organization_id, m.role, o.name FROM memberships m JOIN organizations o ON o.id = m.organization_id WHERE m.user_id = ?', user(request).id)
    .map(m => ({ organizationID: m.organization_id, organizationName: m.name, role: m.role })) }));

  app.get('/v1/organizations', async request => ({ organizations: store.all<OrgRow & { role: Role }>(
    'SELECT o.*, m.role FROM organizations o JOIN memberships m ON m.organization_id = o.id WHERE m.user_id = ?', user(request).id)
    .map(row => ({ ...publicOrg(row), role: row.role })) }));
  app.post('/v1/organizations', { schema: { body: bodySchema({ name: stringSchema(160, 1) }, ['name']) } }, async (request, reply) => {
    const organizationID = randomUUID(); const name = text((request.body as { name: string }).name, 'name', 160, 1).trim();
    store.transaction(() => {
      store.run('INSERT INTO organizations VALUES (?, ?, ?, ?)', organizationID, name, 'free', now());
      store.run('INSERT INTO memberships VALUES (?, ?, ?, ?)', organizationID, user(request).id, 'owner', now());
    });
    return reply.code(201).send(publicOrg(store.get<OrgRow>('SELECT * FROM organizations WHERE id = ?', organizationID)!));
  });
  app.get('/v1/organizations/:organizationID/members', async request => {
    const { organizationID } = request.params as { organizationID: string }; id(organizationID);
    const actual = role(organizationID, request);
    return { members: store.all<{ id: string; email: string; display_name: string; role: Role }>(
      'SELECT u.id, u.email, u.display_name, m.role FROM memberships m JOIN users u ON u.id = m.user_id WHERE m.organization_id = ?', organizationID)
      .map(row => ({ userID: row.id, displayName: row.display_name, role: row.role, ...(managers.includes(actual) ? { email: row.email } : {}) })) };
  });
  app.post('/v1/organizations/:organizationID/members', {
    schema: { body: bodySchema({ email: emailSchema, role: { type: 'string', enum: roles } }, ['email', 'role']) },
  }, async (request, reply) => {
    const { organizationID } = request.params as { organizationID: string }; id(organizationID);
    const actual = role(organizationID, request); requireRole(actual, ['owner', 'admin']);
    const data = request.body as { email: string; role: Role };
    if (data.role === 'owner' && actual !== 'owner') throw forbidden();
    const target = store.get<UserRow>('SELECT * FROM users WHERE email = ?', data.email.trim().toLowerCase());
    if (!target) throw new ApiError(404, 'account_not_found', 'The team member must first register an account');
    store.transaction(() => {
      billing.requireCapability(organizationID, 'teamManagement');
      billing.requireSeat(organizationID, data.role);
      if (store.get('SELECT user_id FROM memberships WHERE organization_id = ? AND user_id = ?', organizationID, target.id)) throw new ApiError(409, 'membership_exists', 'The user is already a member');
      store.run('INSERT INTO memberships VALUES (?, ?, ?, ?)', organizationID, target.id, data.role, now());
      audit(organizationID, user(request).id, 'member.added', target.id);
    });
    return reply.code(201).send({ userID: target.id, displayName: target.display_name, role: data.role });
  });
  function updateMembership(request: FastifyRequest, nextRole?: Role) {
    const { organizationID, userID } = request.params as { organizationID: string; userID: string }; id(organizationID); id(userID);
    const actual = role(organizationID, request); requireRole(actual, ['owner', 'admin']);
    if (nextRole === 'owner' && actual !== 'owner') throw forbidden();
    store.transaction(() => {
      const target = store.get<{ role: Role }>('SELECT role FROM memberships WHERE organization_id = ? AND user_id = ?', organizationID, userID);
      if (!target) throw notFound();
      if (target.role === 'owner') {
        if (actual !== 'owner') throw forbidden();
        if (nextRole !== 'owner' && store.get<{ n: number }>("SELECT COUNT(*) AS n FROM memberships WHERE organization_id = ? AND role = 'owner'", organizationID)!.n <= 1) {
          throw new ApiError(409, 'last_owner', 'An organization must retain an owner');
        }
      }
      if (nextRole && target.role === 'viewer' && nextRole !== 'viewer') {
        billing.requireCapability(organizationID, 'teamManagement'); billing.requireSeat(organizationID, nextRole, target.role);
      }
      if (nextRole) store.run('UPDATE memberships SET role = ? WHERE organization_id = ? AND user_id = ?', nextRole, organizationID, userID);
      else store.run('DELETE FROM memberships WHERE organization_id = ? AND user_id = ?', organizationID, userID);
      audit(organizationID, user(request).id, nextRole ? 'member.role_changed' : 'member.removed', userID);
    });
  }
  app.patch('/v1/organizations/:organizationID/members/:userID', { schema: { body: bodySchema({ role: { type: 'string', enum: roles } }, ['role']) } }, async request => {
    const nextRole = (request.body as { role: Role }).role; updateMembership(request, nextRole); return { role: nextRole };
  });
  app.delete('/v1/organizations/:organizationID/members/:userID', async (request, reply) => { updateMembership(request); return reply.code(204).send(); });

  app.get('/v1/organizations/:organizationID/billing', async request => {
    const { organizationID } = request.params as { organizationID: string }; id(organizationID); role(organizationID, request);
    return billing.snapshot(organizationID);
  });
  app.post('/v1/organizations/:organizationID/billing/apple/verify', {
    schema: { body: bodySchema({ signedTransaction: stringSchema(16384, 1) }, ['signedTransaction']) },
  }, async request => {
    const { organizationID } = request.params as { organizationID: string }; id(organizationID);
    requireRole(role(organizationID, request), ['owner', 'admin']);
    return billing.verifyPurchase(organizationID, user(request).id, (request.body as { signedTransaction: string }).signedTransaction);
  });
  app.post('/v1/billing/apple/notifications', {
    config: options.rateLimit === false ? {} : { rateLimit: { max: 60, timeWindow: '1 minute' } },
    schema: { body: bodySchema({ signedPayload: stringSchema(65536, 1) }, ['signedPayload']) },
  }, async request => billing.notification((request.body as { signedPayload: string }).signedPayload));

  app.get('/v1/projects', async request => {
    const query = request.query as { organizationID?: string };
    if (query.organizationID) { id(query.organizationID); role(query.organizationID, request); }
    const rows = query.organizationID
      ? store.all<ProjectRow>('SELECT * FROM projects WHERE organization_id = ? ORDER BY created_at DESC, id DESC', query.organizationID)
      : store.all<ProjectRow>('SELECT p.* FROM projects p JOIN memberships m ON m.organization_id = p.organization_id WHERE m.user_id = ? ORDER BY p.created_at DESC, p.id DESC', user(request).id);
    return { projects: rows.map(publicProject) };
  });
  app.post('/v1/projects', { schema: { body: bodySchema({ id: uuidSchema, organizationID: uuidSchema,
    name: stringSchema(160, 1), kind: { type: 'string', enum: ['cemetery', 'building', 'objectScan', 'site'] },
    coordinateReference: { type: 'object' }, notes: stringSchema(4096), requiresIndependentReview: { type: 'boolean' },
  }, ['organizationID', 'name', 'kind', 'coordinateReference']) } }, async (request, reply) => {
    const data = request.body as { id?: string; organizationID: string; name: string; kind: string; coordinateReference: unknown; notes?: string; requiresIndependentReview?: boolean };
    text(data.name, 'name', 160, 1);
    requireRole(role(data.organizationID, request), featureWriters); coordinateReference(data.coordinateReference);
    const projectID = data.id ?? randomUUID(); const timestamp = now();
    const outcome = store.transaction(() => {
      billing.requireEditorSeat(data.organizationID, user(request).id);
      const existing = store.get<ProjectRow>('SELECT * FROM projects WHERE id = ?', projectID);
      if (existing) {
        if (existing.organization_id === data.organizationID && existing.revision === 1 && existing.name === data.name.trim()
          && existing.kind === data.kind && canonical(JSON.parse(existing.coordinate_reference)) === canonical(data.coordinateReference)
          && existing.notes === (data.notes ?? '') && Boolean(existing.requires_independent_review) === Boolean(data.requiresIndependentReview)) {
          return { created: false, row: existing };
        }
        throw new ApiError(409, 'identifier_unavailable', 'Use a new project identifier or load the existing project');
      }
      store.run('INSERT INTO projects VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', projectID, data.organizationID,
        data.name.trim(), data.kind, JSON.stringify(data.coordinateReference), data.notes ?? '', data.requiresIndependentReview ? 1 : 0,
        1, user(request).id, timestamp, timestamp);
      audit(data.organizationID, user(request).id, 'project.created', projectID);
      return { created: true, row: store.get<ProjectRow>('SELECT * FROM projects WHERE id = ?', projectID)! };
    });
    return reply.code(outcome.created ? 201 : 200).send(publicProject(outcome.row));
  });
  app.get('/v1/projects/:projectID', async request => publicProject(project((request.params as { projectID: string }).projectID, request).row));
  app.patch('/v1/projects/:projectID', { schema: { body: bodySchema({ baseRevision: { type: 'integer', minimum: 1 }, name: stringSchema(160, 1), notes: stringSchema(4096), requiresIndependentReview: { type: 'boolean' } }, ['baseRevision']) } }, async request => {
    const scope = project((request.params as { projectID: string }).projectID, request); requireRole(scope.role, managers);
    const data = request.body as { baseRevision: number; name?: string; notes?: string; requiresIndependentReview?: boolean };
    if (data.name !== undefined) text(data.name, 'name', 160, 1);
    store.transaction(() => {
      billing.requireEditorSeat(scope.row.organization_id, user(request).id);
      const current = store.get<ProjectRow>('SELECT * FROM projects WHERE id = ?', scope.row.id)!;
      if (current.revision !== data.baseRevision) throw new ApiError(409, 'revision_conflict', 'Reload the project before applying this change');
      store.run('UPDATE projects SET name = ?, notes = ?, requires_independent_review = ?, revision = revision + 1, updated_at = ? WHERE id = ?',
        data.name?.trim() ?? current.name, data.notes ?? current.notes,
        data.requiresIndependentReview === undefined ? current.requires_independent_review : Number(data.requiresIndependentReview), now(), current.id);
      audit(current.organization_id, user(request).id, 'project.updated', current.id);
    });
    return publicProject(store.get<ProjectRow>('SELECT * FROM projects WHERE id = ?', scope.row.id)!);
  });

  function authorizeOperation(op: Operation, actual: Role) {
    if (op.entity === 'review') { if (op.action !== 'review') throw new ApiError(400, 'invalid_input', 'Reviews require the review action'); requireRole(actual, reviewers); }
    else {
      if (op.action === 'review') throw new ApiError(400, 'invalid_input', 'Invalid operation action');
      requireRole(actual, op.entity === 'workorder' ? managers : op.entity === 'task' ? [...featureWriters, 'reviewer'] : featureWriters);
    }
  }
  function validateLinks(data: Record<string, unknown>, scope: ProjectRow) {
    for (const item of data.links as { targetID: string }[] ?? []) {
      const target = scopedRecord(item.targetID, scope.id, 'feature');
      if (target.deleted) throw new ApiError(400, 'invalid_reference', 'A link target is unavailable');
    }
  }
  function validateTask(data: Record<string, unknown>, existing: RecordRow | undefined, scope: ProjectRow, actual: Role, actorID: string, action: string) {
    const previous = existing ? JSON.parse(existing.data_json) as Record<string, unknown> : undefined;
    if (data.assigneeID) {
      const member = store.get<{ role: Role }>('SELECT role FROM memberships WHERE organization_id = ? AND user_id = ?', scope.organization_id, String(data.assigneeID));
      if (!member || member.role === 'viewer') throw new ApiError(400, 'invalid_assignee', 'Assignee must be an active working member of this organization');
    }
    if (data.targetFeatureID) {
      const target = scopedRecord(String(data.targetFeatureID), scope.id, 'feature');
      if (target.deleted) throw new ApiError(400, 'invalid_reference', 'Target feature is unavailable');
    }
    if (actual === 'surveyor') {
      if (action === 'delete' || (previous?.assigneeID && previous.assigneeID !== actorID) || (data.assigneeID && data.assigneeID !== actorID)) throw forbidden();
      if (['accepted', 'needs_revision', 'cancelled'].includes(String(data.status))) throw forbidden();
    }
    if (actual === 'reviewer') {
      if (!previous || action === 'delete' || !['accepted', 'needs_revision'].includes(String(data.status))) throw forbidden();
      const { status: _before, ...before } = previous; const { status: _after, ...after } = data;
      if (canonical(before) !== canonical(after)) throw forbidden();
    }
    if (data.status === 'accepted' && data.targetFeatureID && !store.get(
      "SELECT 1 FROM reviews r JOIN records f ON f.id = r.record_id AND f.version = r.version WHERE f.id = ? AND f.project_id = ? AND r.verdict = 'accepted' AND f.deleted = 0", String(data.targetFeatureID), scope.id)) {
      throw new ApiError(400, 'feature_not_accepted', 'Accept the current target feature before accepting its task');
    }
  }

  function mutate(op: Operation, scope: ProjectRow, actual: Role, actorID: string): OperationResult {
    const existing = store.get<RecordRow>('SELECT * FROM records WHERE id = ?', op.id);
    if (existing && (existing.project_id !== scope.id || existing.organization_id !== scope.organization_id || existing.entity !== (op.entity === 'review' ? 'feature' : op.entity))) throw notFound();
    if (op.entity === 'review') {
      if (!existing || existing.deleted) throw notFound();
      if (existing.version !== op.baseRevision) return { operationID: op.operationID, status: 'conflict', code: 'revision_conflict', current: record(existing) };
      const data = object(op.data); keys(data, ['verdict', 'note']);
      const verdict = enumeration(data.verdict, ['accepted', 'changes_requested'], 'verdict'); const note = text(data.note ?? '', 'note');
      const revision = store.get<{ author_id: string }>('SELECT author_id FROM revisions WHERE record_id = ? AND version = ?', existing.id, existing.version)!;
      if (scope.requires_independent_review && revision.author_id === actorID) throw new ApiError(403, 'independent_review_required', 'Another team member must review this revision');
      const accepted = store.get<ReviewRow>("SELECT * FROM reviews WHERE record_id = ? AND version = ? AND verdict = 'accepted'", existing.id, existing.version);
      if (accepted) throw new ApiError(409, 'already_accepted', 'This accepted revision is immutable; create a new revision for changes');
      const reviewID = randomUUID(); const timestamp = now();
      store.run('INSERT INTO reviews VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)', reviewID, scope.organization_id, scope.id, existing.id, existing.version, verdict, note, actorID, timestamp);
      const payload = publicReview(store.get<ReviewRow>('SELECT * FROM reviews WHERE id = ?', reviewID)!);
      const sequence = change(scope, 'review', existing.id, existing.version, verdict, payload);
      audit(scope.organization_id, actorID, `feature.${verdict}`, existing.id);
      return { operationID: op.operationID, status: 'applied', record: payload, revision: existing.version, cursor: sequence };
    }
    if (op.baseRevision !== (existing?.version ?? 0)) {
      return { operationID: op.operationID, status: 'conflict', code: 'revision_conflict', ...(existing ? { current: record(existing) } : {}), revision: existing?.version ?? 0 };
    }
    if (op.action === 'delete' && !existing) throw notFound();
    if (existing?.deleted) throw new ApiError(409, 'record_deleted', 'Deleted records cannot be edited; create a new object');
    let data: Record<string, unknown>;
    if (op.action === 'delete') data = JSON.parse(existing!.data_json) as Record<string, unknown>;
    else if (op.entity === 'feature') { data = featureData(op.data, coordinateReference(JSON.parse(scope.coordinate_reference))); validateLinks(data, scope); }
    else if (op.entity === 'task') data = taskData(op.data);
    else data = workorderData(op.data);
    if (op.entity === 'task') validateTask(data, existing, scope, actual, actorID, op.action);
    if (op.action === 'delete' && op.entity === 'feature') {
      if (store.get("SELECT id FROM records WHERE project_id = ? AND entity = 'task' AND deleted = 0 AND json_extract(data_json, '$.targetFeatureID') = ?", scope.id, op.id)) {
        throw new ApiError(409, 'feature_in_use', 'Remove the feature from tasks before deleting it');
      }
      if (store.get("SELECT f.id FROM records f, json_each(f.data_json, '$.links') link WHERE f.project_id = ? AND f.entity = 'feature' AND f.deleted = 0 AND f.id <> ? AND json_extract(link.value, '$.targetID') = ? LIMIT 1", scope.id, op.id, op.id)) {
        throw new ApiError(409, 'feature_in_use', 'Remove references from other features before deleting it');
      }
    }
    const version = op.baseRevision + 1; const timestamp = now(); const json = JSON.stringify(data); const deleted = op.action === 'delete' ? 1 : 0;
    if (!existing) store.run('INSERT INTO records VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', op.id, scope.organization_id, scope.id, op.entity, version, json, deleted, actorID, timestamp, timestamp);
    else store.run('UPDATE records SET version = ?, data_json = ?, deleted = ?, updated_at = ? WHERE id = ?', version, json, deleted, timestamp, op.id);
    store.run('INSERT INTO revisions VALUES (?, ?, ?, ?, ?, ?, ?)', op.id, version, json, deleted, contentHash({ data, deleted: Boolean(deleted) }), actorID, timestamp);
    const payload = record(store.get<RecordRow>('SELECT * FROM records WHERE id = ?', op.id)!);
    const sequence = change(scope, op.entity, op.id, version, op.action, payload);
    audit(scope.organization_id, actorID, `${op.entity}.${op.action}`, op.id);
    return { operationID: op.operationID, status: 'applied', record: payload, revision: version, cursor: sequence };
  }
  function apply(op: Operation, scope: ProjectRow, actual: Role, actorID: string): OperationResult {
    return store.transaction(() => {
      const membership = store.get<{ role: Role }>('SELECT role FROM memberships WHERE organization_id = ? AND user_id = ?', scope.organization_id, actorID);
      if (!membership) throw notFound();
      actual = membership.role;
      authorizeOperation(op, actual);
      billing.requireEditorSeat(scope.organization_id, actorID);
      if (op.entity === 'workorder') billing.requireCapability(scope.organization_id, 'businessWorkflow');
      const requestHash = contentHash(op);
      const prior = store.get<{ request_hash: string; result_json: string }>('SELECT request_hash, result_json FROM operations WHERE user_id = ? AND project_id = ? AND operation_id = ?', actorID, scope.id, op.operationID);
      if (prior) {
        if (prior.request_hash !== requestHash) return { operationID: op.operationID, status: 'rejected', code: 'idempotency_mismatch', message: 'Use a new operationID for a changed payload' };
        return JSON.parse(prior.result_json) as OperationResult;
      }
      let result: OperationResult;
      try { result = mutate(op, scope, actual, actorID); }
      catch (error) {
        if (!(error instanceof ApiError)) throw error;
        result = { operationID: op.operationID, status: 'rejected', code: error.code, message: error.message };
      }
      store.run('INSERT INTO operations VALUES (?, ?, ?, ?, ?, ?)', actorID, scope.id, op.operationID, requestHash, JSON.stringify(result), now());
      return result;
    });
  }
  function sendOperation(result: OperationResult, reply: FastifyReply, created: boolean) {
    if (result.status === 'conflict') return reply.code(409).send({ error: { code: 'revision_conflict', message: 'Reload and rebase this change' }, current: result.current });
    if (result.status === 'rejected') {
      const status = result.code === 'not_found' ? 404 : ['subscription_required', 'seat_quota_exceeded', 'editor_seat_required'].includes(result.code ?? '') ? 402 : ['forbidden', 'independent_review_required'].includes(result.code ?? '') ? 403
        : ['idempotency_mismatch', 'already_accepted', 'record_deleted', 'feature_in_use'].includes(result.code ?? '') ? 409 : 400;
      return reply.code(status).send({ error: { code: result.code, message: result.message } });
    }
    return reply.code(created ? 201 : 200).send(result.record);
  }

  for (const [route, entity] of [['features', 'feature'], ['tasks', 'task'], ['workorders', 'workorder']] as const) {
    app.get(`/v1/projects/:projectID/${route}`, async request => {
      const scope = project((request.params as { projectID: string }).projectID, request);
      if (entity === 'workorder') requireRole(scope.role, managers);
      const query = request.query as { limit?: string; offset?: string };
      const limit = integer(query.limit === undefined ? 100 : Number(query.limit), 'limit', 1, 200);
      const offset = integer(query.offset === undefined ? 0 : Number(query.offset), 'offset', 0, 1e8);
      const rows = store.all<RecordRow>('SELECT * FROM records WHERE project_id = ? AND entity = ? AND deleted = 0 ORDER BY created_at, id LIMIT ? OFFSET ?', scope.row.id, entity, limit + 1, offset);
      return { [route]: rows.slice(0, limit).map(record), hasMore: rows.length > limit, nextOffset: offset + Math.min(rows.length, limit) };
    });
    app.get(`/v1/projects/:projectID/${route}/:recordID`, async request => {
      const params = request.params as { projectID: string; recordID: string }; id(params.recordID);
      const scope = project(params.projectID, request); if (entity === 'workorder') requireRole(scope.role, managers);
      const row = scopedRecord(params.recordID, scope.row.id, entity); if (row.deleted) throw notFound(); return record(row);
    });
    app.get(`/v1/projects/:projectID/${route}/:recordID/revisions/:revision`, async request => {
      const params = request.params as { projectID: string; recordID: string; revision: string }; id(params.recordID);
      const scope = project(params.projectID, request); if (entity === 'workorder') requireRole(scope.role, managers);
      const current = scopedRecord(params.recordID, scope.row.id, entity);
      const revision = integer(Number(params.revision), 'revision', 1);
      const snapshot = store.get<{ data_json: string; deleted: number; content_hash: string; author_id: string; created_at: string }>('SELECT * FROM revisions WHERE record_id = ? AND version = ?', current.id, revision);
      if (!snapshot) throw notFound();
      return { id: current.id, projectID: scope.row.id, revision, snapshot: JSON.parse(snapshot.data_json), deleted: Boolean(snapshot.deleted),
        contentHash: snapshot.content_hash, authorID: snapshot.author_id, createdAt: snapshot.created_at,
        reviews: store.all<ReviewRow>('SELECT * FROM reviews WHERE record_id = ? AND version = ? ORDER BY created_at, rowid', current.id, revision).map(publicReview) };
    });
    app.post(`/v1/projects/:projectID/${route}`, { schema: { body: bodySchema({ id: uuidSchema, operationID: uuidSchema, data: { type: 'object' } }, ['operationID', 'data']) } }, async (request, reply) => {
      const scope = project((request.params as { projectID: string }).projectID, request);
      const body = request.body as { id?: string; operationID: string; data: Record<string, unknown> };
      const recordID = body.id ?? body.operationID; // Stable when a creation is retried after a lost response.
      return sendOperation(apply({ operationID: body.operationID, entity, action: 'upsert', id: recordID, baseRevision: 0, data: body.data }, scope.row, scope.role, user(request).id), reply, true);
    });
    app.put(`/v1/projects/:projectID/${route}/:recordID`, { schema: { body: bodySchema({ operationID: uuidSchema, baseRevision: { type: 'integer', minimum: 0 }, data: { type: 'object' } }, ['operationID', 'baseRevision', 'data']) } }, async (request, reply) => {
      const params = request.params as { projectID: string; recordID: string }; id(params.recordID);
      const scope = project(params.projectID, request); const body = request.body as { operationID: string; baseRevision: number; data: Record<string, unknown> };
      return sendOperation(apply({ ...body, entity, action: 'upsert', id: params.recordID }, scope.row, scope.role, user(request).id), reply, body.baseRevision === 0);
    });
    app.delete(`/v1/projects/:projectID/${route}/:recordID`, { schema: { body: bodySchema({ operationID: uuidSchema, baseRevision: { type: 'integer', minimum: 1 } }, ['operationID', 'baseRevision']) } }, async (request, reply) => {
      const params = request.params as { projectID: string; recordID: string }; id(params.recordID);
      const scope = project(params.projectID, request); const body = request.body as { operationID: string; baseRevision: number };
      return sendOperation(apply({ ...body, entity, action: 'delete', id: params.recordID }, scope.row, scope.role, user(request).id), reply, false);
    });
  }

  app.get('/v1/projects/:projectID/reviews', async request => {
    const scope = project((request.params as { projectID: string }).projectID, request);
    const query = request.query as { limit?: string; offset?: string };
    const limit = integer(query.limit === undefined ? 100 : Number(query.limit), 'limit', 1, 200);
    const offset = integer(query.offset === undefined ? 0 : Number(query.offset), 'offset', 0, 1e8);
    const rows = store.all<ReviewRow>('SELECT * FROM reviews WHERE project_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ? OFFSET ?', scope.row.id, limit + 1, offset);
    return { reviews: rows.slice(0, limit).map(publicReview), hasMore: rows.length > limit, nextOffset: offset + Math.min(rows.length, limit) };
  });
  app.post('/v1/projects/:projectID/reviews', { schema: { body: bodySchema({ operationID: uuidSchema, featureID: uuidSchema,
    revision: { type: 'integer', minimum: 1 }, verdict: { type: 'string', enum: ['accepted', 'changes_requested'] }, note: stringSchema(4096),
  }, ['operationID', 'featureID', 'revision', 'verdict']) } }, async (request, reply) => {
    const scope = project((request.params as { projectID: string }).projectID, request);
    const data = request.body as { operationID: string; featureID: string; revision: number; verdict: string; note?: string };
    return sendOperation(apply({ operationID: data.operationID, entity: 'review', action: 'review', id: data.featureID,
      baseRevision: data.revision, data: { verdict: data.verdict, note: data.note ?? '' } }, scope.row, scope.role, user(request).id), reply, true);
  });
  app.post('/v1/projects/:projectID/sync/push', { schema: { body: bodySchema({ operations: { type: 'array', minItems: 1, maxItems: 50, items: operationSchema } }, ['operations']) } }, async request => {
    const scope = project((request.params as { projectID: string }).projectID, request);
    const data = request.body as { operations: Operation[] };
    const results = data.operations.map(op => {
      try { return apply(op, scope.row, scope.role, user(request).id); }
      catch (error) {
        if (!(error instanceof ApiError)) throw error;
        return { operationID: op.operationID, status: 'rejected' as const, code: error.code, message: error.message };
      }
    });
    return { results, cursor: cursor(scope.row.id) };
  });
  app.get('/v1/projects/:projectID/sync/pull', async request => {
    const scope = project((request.params as { projectID: string }).projectID, request);
    const query = request.query as { cursor?: string; limit?: string };
    const after = integer(query.cursor === undefined ? 0 : Number(query.cursor), 'cursor');
    const highWatermark = cursor(scope.row.id);
    if (after > highWatermark) throw new ApiError(400, 'invalid_cursor', 'Reset the cursor for this project before pulling changes');
    const limit = integer(query.limit === undefined ? 100 : Number(query.limit), 'limit', 1, 200);
    const finance = managers.includes(scope.role);
    const rows = store.all<{ sequence: number; entity: string; record_id: string; version: number; kind: string; payload_json: string; created_at: string }>(
      `SELECT * FROM changes WHERE project_id = ? AND sequence > ? ${finance ? '' : "AND entity <> 'workorder'"} ORDER BY sequence LIMIT ?`, scope.row.id, after, limit + 1);
    const changes = rows.slice(0, limit).map(row => ({ sequence: row.sequence, entity: row.entity, id: row.record_id, revision: row.version, action: row.kind, data: JSON.parse(row.payload_json), createdAt: row.created_at }));
    const hasMore = rows.length > limit;
    return { changes, cursor: hasMore ? changes.at(-1)!.sequence : highWatermark, hasMore };
  });

  await app.ready();
  return app;
}
