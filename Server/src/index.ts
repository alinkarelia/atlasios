import { buildApp } from './app.js';

const port = Number(process.env.PORT ?? 3000);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be a valid port');
const app = await buildApp({
  databasePath: process.env.DATABASE_PATH ?? './data/atlas.sqlite',
  corsOrigins: (process.env.CORS_ORIGINS ?? '').split(',').map(value => value.trim()).filter(Boolean),
});
async function shutdown() { await app.close(); }
process.once('SIGINT', () => { void shutdown(); });
process.once('SIGTERM', () => { void shutdown(); });
try { await app.listen({ host: process.env.HOST ?? '127.0.0.1', port }); }
catch (error) { app.log.error(error); await app.close(); process.exitCode = 1; }
