import { randomBytes, createHash, scrypt, timingSafeEqual } from 'node:crypto';
const parameters = { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };
const derive = (password: string, salt: Buffer): Promise<Buffer> => new Promise((resolve, reject) => {
  scrypt(password, salt, 32, parameters, (error, key) => error ? reject(error) : resolve(key));
});
const dummySalt = Buffer.alloc(16, 1);
const dummyKey = Buffer.alloc(32, 2);

export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(16);
  const key = await derive(password, salt);
  return `scrypt$16384$8$1$${salt.toString('hex')}$${key.toString('hex')}`;
}

export async function verifyPassword(password: string, encoded?: string): Promise<boolean> {
  const parts = encoded?.split('$');
  const valid = parts?.length === 6 && parts[0] === 'scrypt' && parts[1] === '16384'
    && parts[2] === '8' && parts[3] === '1' && /^[a-f0-9]{32}$/.test(parts[4] ?? '')
    && /^[a-f0-9]{64}$/.test(parts[5] ?? '');
  const salt = valid ? Buffer.from(parts![4]!, 'hex') : dummySalt;
  const expected = valid ? Buffer.from(parts![5]!, 'hex') : dummyKey;
  const actual = await derive(password, salt);
  return timingSafeEqual(actual, expected) && Boolean(valid);
}

export function tokenHash(token: string) { return createHash('sha256').update(token).digest('hex'); }
export function newToken() { return randomBytes(32).toString('base64url'); }
export function canonical(value: unknown): string {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  const source = value as Record<string, unknown>;
  return `{${Object.keys(source).sort().map(key => `${JSON.stringify(key)}:${canonical(source[key])}`).join(',')}}`;
}
export function contentHash(value: unknown) { return tokenHash(canonical(value)); }
