import { DatabaseSync } from 'node:sqlite';
import { dirname } from 'node:path';
import { mkdirSync, chmodSync } from 'node:fs';

type Value = string | number | null;

export class Store {
  readonly db: DatabaseSync;

  constructor(path: string) {
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(path);
    if (path !== ':memory:') chmodSync(path, 0o600);
    const schemaVersion = this.db.prepare('PRAGMA user_version').get() as { user_version: number };
    if (schemaVersion.user_version > 3) { this.db.close(); throw new Error('Database schema is newer than this server'); }
    this.db.exec(`
      PRAGMA foreign_keys = ON;
      PRAGMA busy_timeout = 5000;
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = NORMAL;
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE COLLATE NOCASE,
        display_name TEXT NOT NULL, password_hash TEXT NOT NULL, created_at TEXT NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS organizations (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, plan TEXT NOT NULL DEFAULT 'free', created_at TEXT NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS memberships (
        organization_id TEXT NOT NULL REFERENCES organizations(id),
        user_id TEXT NOT NULL REFERENCES users(id),
        role TEXT NOT NULL CHECK(role IN ('owner','admin','manager','surveyor','reviewer','viewer')),
        created_at TEXT NOT NULL, PRIMARY KEY (organization_id, user_id)
      ) STRICT;
      CREATE TABLE IF NOT EXISTS sessions (
        token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
        created_at TEXT NOT NULL, expires_at INTEGER NOT NULL
      ) STRICT;
      CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);
      CREATE TABLE IF NOT EXISTS projects (
        id TEXT PRIMARY KEY, organization_id TEXT NOT NULL REFERENCES organizations(id),
        name TEXT NOT NULL, kind TEXT NOT NULL, coordinate_reference TEXT NOT NULL,
        notes TEXT NOT NULL, requires_independent_review INTEGER NOT NULL DEFAULT 0,
        revision INTEGER NOT NULL DEFAULT 1, created_by TEXT NOT NULL REFERENCES users(id),
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL, UNIQUE(id, organization_id)
      ) STRICT;
      CREATE INDEX IF NOT EXISTS projects_org ON projects(organization_id);
      CREATE TABLE IF NOT EXISTS records (
        id TEXT PRIMARY KEY, organization_id TEXT NOT NULL REFERENCES organizations(id),
        project_id TEXT NOT NULL REFERENCES projects(id), entity TEXT NOT NULL CHECK(entity IN ('feature','task','workorder')),
        version INTEGER NOT NULL, data_json TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
        created_by TEXT NOT NULL REFERENCES users(id), created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        UNIQUE(id, project_id, organization_id),
        FOREIGN KEY (project_id, organization_id) REFERENCES projects(id, organization_id)
      ) STRICT;
      CREATE INDEX IF NOT EXISTS records_project ON records(project_id, entity, deleted);
      CREATE TABLE IF NOT EXISTS revisions (
        record_id TEXT NOT NULL REFERENCES records(id), version INTEGER NOT NULL,
        data_json TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, content_hash TEXT NOT NULL,
        author_id TEXT NOT NULL REFERENCES users(id), created_at TEXT NOT NULL,
        PRIMARY KEY (record_id, version)
      ) STRICT;
      CREATE TABLE IF NOT EXISTS reviews (
        id TEXT PRIMARY KEY, organization_id TEXT NOT NULL REFERENCES organizations(id),
        project_id TEXT NOT NULL REFERENCES projects(id), record_id TEXT NOT NULL,
        version INTEGER NOT NULL, verdict TEXT NOT NULL CHECK(verdict IN ('accepted','changes_requested')),
        note TEXT NOT NULL, author_id TEXT NOT NULL REFERENCES users(id), created_at TEXT NOT NULL,
        FOREIGN KEY (record_id, version) REFERENCES revisions(record_id, version),
        FOREIGN KEY (record_id, project_id, organization_id) REFERENCES records(id, project_id, organization_id)
      ) STRICT;
      CREATE UNIQUE INDEX IF NOT EXISTS one_acceptance_per_revision
        ON reviews(record_id, version) WHERE verdict = 'accepted';
      CREATE TABLE IF NOT EXISTS operations (
        user_id TEXT NOT NULL REFERENCES users(id), project_id TEXT NOT NULL REFERENCES projects(id),
        operation_id TEXT NOT NULL, request_hash TEXT NOT NULL, result_json TEXT NOT NULL,
        created_at TEXT NOT NULL, PRIMARY KEY (user_id, project_id, operation_id)
      ) STRICT;
      CREATE TABLE IF NOT EXISTS changes (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT, organization_id TEXT NOT NULL,
        project_id TEXT NOT NULL REFERENCES projects(id), entity TEXT NOT NULL,
        record_id TEXT NOT NULL, version INTEGER NOT NULL, kind TEXT NOT NULL,
        payload_json TEXT NOT NULL, created_at TEXT NOT NULL,
        FOREIGN KEY (project_id, organization_id) REFERENCES projects(id, organization_id)
      ) STRICT;
      CREATE INDEX IF NOT EXISTS changes_project ON changes(project_id, sequence);
      CREATE TABLE IF NOT EXISTS audit (
        id INTEGER PRIMARY KEY AUTOINCREMENT, organization_id TEXT NOT NULL,
        actor_id TEXT NOT NULL REFERENCES users(id), action TEXT NOT NULL,
        subject_id TEXT NOT NULL, created_at TEXT NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS apple_bindings (
        original_id TEXT NOT NULL, environment TEXT NOT NULL,
        organization_id TEXT NOT NULL REFERENCES organizations(id), purchaser_id TEXT NOT NULL REFERENCES users(id),
        created_at TEXT NOT NULL, PRIMARY KEY (original_id, environment)
      ) STRICT;
      CREATE TABLE IF NOT EXISTS apple_transactions (
        transaction_id TEXT NOT NULL, environment TEXT NOT NULL, original_id TEXT NOT NULL,
        product_id TEXT NOT NULL, account_token TEXT NOT NULL, purchased_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL, revoked_at INTEGER, upgraded INTEGER NOT NULL,
        signed_at INTEGER NOT NULL, jws_hash TEXT NOT NULL, updated_at TEXT NOT NULL,
        PRIMARY KEY (transaction_id, environment)
      ) STRICT;
      CREATE INDEX IF NOT EXISTS apple_transactions_original ON apple_transactions(original_id, environment, purchased_at);
      CREATE TABLE IF NOT EXISTS apple_renewals (
        original_id TEXT NOT NULL, environment TEXT NOT NULL, product_id TEXT NOT NULL,
        grace_expires_at INTEGER, signed_at INTEGER NOT NULL, jws_hash TEXT NOT NULL,
        PRIMARY KEY (original_id, environment)
      ) STRICT;
      CREATE TABLE IF NOT EXISTS apple_notifications (
        notification_id TEXT PRIMARY KEY, environment TEXT NOT NULL, signed_at INTEGER NOT NULL,
        jws_hash TEXT NOT NULL, status TEXT NOT NULL, original_id TEXT, created_at TEXT NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS billing_state (
        organization_id TEXT PRIMARY KEY REFERENCES organizations(id), revision INTEGER NOT NULL,
        updated_at TEXT NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS material_packages (
        id TEXT PRIMARY KEY, organization_id TEXT NOT NULL REFERENCES organizations(id),
        project_id TEXT NOT NULL, author_id TEXT NOT NULL REFERENCES users(id),
        author_name TEXT NOT NULL, manifest_json TEXT NOT NULL, manifest_hash TEXT NOT NULL,
        total_bytes INTEGER NOT NULL, state TEXT NOT NULL CHECK(state IN ('incomplete','complete')),
        received_at TEXT NOT NULL, completed_at TEXT,
        FOREIGN KEY (project_id, organization_id) REFERENCES projects(id, organization_id)
      ) STRICT;
      CREATE INDEX IF NOT EXISTS material_packages_project ON material_packages(project_id, state, received_at, id);
      CREATE TABLE IF NOT EXISTS material_assets (
        package_id TEXT NOT NULL REFERENCES material_packages(id), id TEXT NOT NULL,
        byte_count INTEGER NOT NULL, sha256 TEXT NOT NULL, uploaded_bytes INTEGER NOT NULL DEFAULT 0,
        verified INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (package_id, id),
        CHECK(byte_count >= 0 AND uploaded_bytes >= 0 AND uploaded_bytes <= byte_count)
      ) STRICT;
      CREATE TRIGGER IF NOT EXISTS immutable_material_manifest BEFORE UPDATE ON material_packages
        WHEN NEW.id <> OLD.id OR NEW.organization_id <> OLD.organization_id OR NEW.project_id <> OLD.project_id
          OR NEW.author_id <> OLD.author_id OR NEW.author_name <> OLD.author_name
          OR NEW.manifest_json <> OLD.manifest_json OR NEW.manifest_hash <> OLD.manifest_hash
          OR NEW.total_bytes <> OLD.total_bytes OR NEW.received_at <> OLD.received_at OR OLD.state = 'complete'
        BEGIN SELECT RAISE(ABORT, 'material manifests are immutable'); END;
      CREATE TRIGGER IF NOT EXISTS immutable_material_asset_identity BEFORE UPDATE ON material_assets
        WHEN NEW.package_id <> OLD.package_id OR NEW.id <> OLD.id OR NEW.byte_count <> OLD.byte_count OR NEW.sha256 <> OLD.sha256
        BEGIN SELECT RAISE(ABORT, 'material asset identities are immutable'); END;
      CREATE TRIGGER IF NOT EXISTS immutable_revision_update BEFORE UPDATE ON revisions
        BEGIN SELECT RAISE(ABORT, 'revisions are immutable'); END;
      CREATE TRIGGER IF NOT EXISTS immutable_revision_delete BEFORE DELETE ON revisions
        BEGIN SELECT RAISE(ABORT, 'revisions are immutable'); END;
      CREATE TRIGGER IF NOT EXISTS immutable_review_update BEFORE UPDATE ON reviews
        BEGIN SELECT RAISE(ABORT, 'reviews are immutable'); END;
      CREATE TRIGGER IF NOT EXISTS immutable_review_delete BEFORE DELETE ON reviews
        BEGIN SELECT RAISE(ABORT, 'reviews are immutable'); END;
      PRAGMA user_version = 3;
    `);
  }

  get<T>(sql: string, ...params: Value[]): T | undefined {
    return this.db.prepare(sql).get(...params) as T | undefined;
  }

  all<T>(sql: string, ...params: Value[]): T[] {
    return this.db.prepare(sql).all(...params) as T[];
  }

  run(sql: string, ...params: Value[]) {
    return this.db.prepare(sql).run(...params);
  }

  transaction<T>(work: () => T): T {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const result = work();
      this.db.exec('COMMIT');
      return result;
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }

  close() { this.db.close(); }
}
