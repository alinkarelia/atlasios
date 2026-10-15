(function () {
  'use strict';

  const M = window.M;
  if (!M) return;
  const LIMIT = 15_000_000_000;
  const CHUNK_SIZE = 1024 * 1024;
  const MAIL_REFERENCE_GRACE = 2 * 60 * 1000;
  const DB_NAME = 'memory-cloud-v1';
  const FAMILIES = [
    { id: 'kovalev', name: 'Семья Ковалёвых' },
    { id: 'nikitina', name: 'Семья Никитиных' },
    { id: 'petrova', name: 'Семья Петровых' }
  ];
  const CHANNELS = new Set(['general', 'archives', 'digitize']);
  const TYPES = {
    txt: 'text/plain', md: 'text/plain', csv: 'text/csv', json: 'application/json',
    pdf: 'application/pdf', png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg',
    webp: 'image/webp', gif: 'image/gif', avif: 'image/avif', heic: 'image/heic', heif: 'image/heif',
    tif: 'image/tiff', tiff: 'image/tiff', bmp: 'image/bmp',
    docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    odt: 'application/vnd.oasis.opendocument.text', ods: 'application/vnd.oasis.opendocument.spreadsheet',
    odp: 'application/vnd.oasis.opendocument.presentation', rtf: 'application/rtf', zip: 'application/zip',
    mp4: 'video/mp4', m4v: 'video/mp4', mov: 'video/quicktime', webm: 'video/webm', mkv: 'video/x-matroska',
    mp3: 'audio/mpeg', m4a: 'audio/mp4', aac: 'audio/aac', ogg: 'audio/ogg', opus: 'audio/ogg',
    wav: 'audio/wav', flac: 'audio/flac'
  };
  const ALTERNATE_TYPES = {
    webm: ['audio/webm'], mp4: ['audio/mp4'], ogg: ['video/ogg', 'application/ogg'],
    wav: ['audio/x-wav', 'audio/wave'], m4a: ['audio/x-m4a'], flac: ['audio/x-flac'],
    heic: ['image/heic-sequence'], heif: ['image/heif-sequence'],
    zip: ['application/x-zip-compressed'], rtf: ['text/rtf'], md: ['text/markdown'], csv: ['text/plain']
  };
  let dbPromise;
  let cache = { files: [], uploads: [] };
  let browserStorage = null;
  let storageError = '';
  let refreshGeneration = 0;
  const listeners = new Set();
  const localFiles = new Map();
  const runners = new Map();
  const localErrors = new Map();
  const waiters = new Map();
  let waiterTimer = null;
  const channel = typeof window.BroadcastChannel === 'function' ? new window.BroadcastChannel('memory-cloud-changes-v1') : null;

  function failure(code, message) {
    const error = new Error(message);
    error.code = code;
    return error;
  }

  function actor() {
    const user = M.getUser?.();
    if (!user?.active || typeof user.id !== 'string') throw failure('permission', 'Войдите под активным профилем команды.');
    return user.id;
  }

  function allowedIds() {
    const user = M.getUser?.();
    if (!user?.active) return [];
    return typeof M.allowedMailboxes === 'function'
      ? M.allowedMailboxes().filter(id => typeof id === 'string')
      : [user.id, 'team', ...(M.state.users || []).filter(item => item.active && item.sharedWith?.includes(user.id)).map(item => item.id)];
  }

  function context(mailboxId) {
    const actorId = actor();
    if (typeof mailboxId !== 'string' || !allowedIds().includes(mailboxId)) throw failure('permission', 'У вас нет доступа к этому почтовому ящику.');
    return { actorId, mailboxId };
  }

  function assertContext(ctx) {
    if (actor() !== ctx.actorId || !allowedIds().includes(ctx.mailboxId)) throw failure('permission', 'Профиль или права доступа изменились. Загрузка остановлена.');
  }

  function activeMailbox() {
    const ids = allowedIds();
    return ids.includes(M.state.activeMailboxId) ? M.state.activeMailboxId : ids.includes(M.state.currentUser) ? M.state.currentUser : ids[0] || null;
  }

  function validId(id) {
    if (typeof id !== 'string' || !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(id)) throw failure('missing', 'Файл не найден.');
    return id;
  }

  function uuid() {
    if (window.crypto?.randomUUID) return window.crypto.randomUUID();
    if (!window.crypto?.getRandomValues) throw failure('unsupported', 'Для облака нужен современный браузер и защищённое HTTPS-соединение.');
    const bytes = window.crypto.getRandomValues(new Uint8Array(16));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    const hex = Array.from(bytes, value => value.toString(16).padStart(2, '0')).join('');
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  function filename(value) {
    const name = String(value || 'Файл').replace(/[\u0000-\u001f\u007f/\\]/g, '_').trim().slice(0, 200);
    return name && name !== '.' && name !== '..' ? name : 'Файл';
  }

  function validateFile(file) {
    if (!file || typeof file.slice !== 'function' || !Number.isSafeInteger(file.size) || file.size < 0) throw failure('file', 'Выберите файл с устройства.');
    const name = filename(file.name);
    const extension = name.includes('.') ? name.split('.').pop().toLowerCase() : '';
    const expected = TYPES[extension];
    const supplied = String(file.type || '').split(';')[0].trim().toLowerCase();
    if (!expected || (supplied && supplied !== 'application/octet-stream' && supplied !== expected && !ALTERNATE_TYPES[extension]?.includes(supplied))) {
      throw failure('type', 'Разрешены фотографии, документы, ZIP-архивы, аудио и видео. Исполняемые файлы, HTML и SVG заблокированы.');
    }
    return { name, type: supplied && supplied !== 'application/octet-stream' ? supplied : expected };
  }

  function openDB() {
    if (dbPromise) return dbPromise;
    dbPromise = new Promise((resolve, reject) => {
      if (!window.indexedDB) return reject(failure('unsupported', 'Этот браузер не поддерживает локальное хранилище файлов.'));
      const request = window.indexedDB.open(DB_NAME, 1);
      request.onupgradeneeded = () => {
        const db = request.result;
        db.createObjectStore('files', { keyPath: 'id' });
        db.createObjectStore('uploads', { keyPath: 'id' });
        const chunks = db.createObjectStore('chunks', { keyPath: ['uploadId', 'index'] });
        chunks.createIndex('uploadId', 'uploadId', { unique: false });
      };
      request.onsuccess = () => {
        request.result.onversionchange = () => request.result.close();
        resolve(request.result);
      };
      request.onerror = () => reject(failure('storage', 'Не удалось открыть хранилище браузера. Проверьте свободное место и настройки приватности.'));
      request.onblocked = () => { storageError = 'Обновление хранилища ожидает закрытия другой вкладки.'; emit(); };
    });
    return dbPromise;
  }

  function transaction(db, stores, mode, operation) {
    return new Promise((resolve, reject) => {
      const tx = db.transaction(stores, mode);
      let result;
      let error;
      const setResult = value => { result = value; };
      const abort = value => { error = value; try { tx.abort(); } catch (_) {} };
      tx.oncomplete = () => resolve(result);
      tx.onabort = tx.onerror = () => reject(error || tx.error || failure('storage', 'Запись файла прервана. Сохранённые части не потеряны.'));
      try { operation(tx, setResult, abort); } catch (value) { abort(value); }
    });
  }

  function readRecords(tx, names, done, abort) {
    const values = {};
    let remaining = names.length;
    for (const name of names) {
      const request = tx.objectStore(name).getAll();
      request.onsuccess = () => {
        values[name] = request.result;
        if (--remaining === 0) { try { done(values); } catch (error) { abort(error); } }
      };
    }
  }

  async function refresh() {
    const generation = ++refreshGeneration;
    try {
      const db = await openDB();
      let pruned = false;
      const records = await transaction(db, ['files', 'uploads', 'chunks'], 'readwrite', (tx, result, abort) => {
        readRecords(tx, ['files', 'uploads'], values => {
          const now = Date.now();
          values.files = values.files.filter(file => {
            const references = file.mailReferences || [];
            const retained = references.filter(reference => mailExists(file, reference) || (Number.isFinite(reference.createdAt) && now - reference.createdAt < MAIL_REFERENCE_GRACE));
            if (retained.length === references.length) return true;
            pruned = true;
            file.mailReferences = retained;
            if (file.cloudRef !== false || file.archiveLinks?.length || file.chatReferences?.length || retained.length) {
              tx.objectStore('files').put(file);
              return true;
            }
            tx.objectStore('files').delete(file.id);
            deleteChunks(tx, file.id);
            return false;
          });
          result(values);
        }, abort);
      });
      if (pruned) channel?.postMessage({ changed: true });
      let estimate = null;
      if (navigator.storage?.estimate) {
        try {
          const value = await navigator.storage.estimate();
          if (Number.isFinite(value.quota) && Number.isFinite(value.usage)) estimate = { quota: value.quota, usage: value.usage, available: Math.max(0, value.quota - value.usage) };
        } catch (_) {}
      }
      if (generation === refreshGeneration) {
        cache = records;
        browserStorage = estimate;
        storageError = '';
        emit();
      }
      return snapshot();
    } catch (error) {
      storageError = error.message || 'Хранилище браузера недоступно.';
      emit();
      throw error;
    }
  }

  function quotaFor(mailboxId, records = cache) {
    return {
      limit: LIMIT,
      used: records.files.filter(file => (file.mailboxId === mailboxId && file.cloudRef !== false)||(file.mailReferences||[]).some(ref=>ref.mailboxId===mailboxId)).reduce((sum, file) => sum + file.size, 0),
      reserved: records.uploads.filter(upload => upload.mailboxId === mailboxId).reduce((sum, upload) => sum + upload.size, 0)
    };
  }

  function publicFile(file) {
    return { id: file.id, name: file.name, size: file.size, type: file.type, mailboxId: file.mailboxId, source: file.source, createdAt: file.createdAt, status: 'complete', cloudRef: file.cloudRef !== false, archiveLinks: (file.archiveLinks || []).map(link => ({ familyId: link.familyId, linkedAt: link.linkedAt })) };
  }

  function publicUpload(upload) {
    const localError = localErrors.get(upload.id);
    const hasFile = localFiles.get(upload.id)?.actorId === M.getUser?.()?.id;
    let status = localError ? 'error' : upload.status;
    if (status === 'uploading' && !hasFile) status = 'needs-file';
    if ((status === 'paused' || status === 'offline') && !hasFile) status = 'needs-file';
    return { id: upload.id, name: upload.name, size: upload.size, type: upload.type, mailboxId: upload.mailboxId, source: upload.source, uploadedBytes: upload.uploadedBytes, status, error: localError?.message || upload.error || '', createdAt: upload.createdAt, lastModified: upload.lastModified, needsFile: !hasFile };
  }

  function snapshot() {
    const mailboxId = activeMailbox();
    const ids = allowedIds();
    return {
      mode: 'local-demo', mailboxId,
      files: cache.files.filter(file => ids.includes(mailboxId) && ((file.cloudRef !== false && file.mailboxId === mailboxId) || hasMailReference(file, mailboxId))).map(file => ({ ...publicFile(file), mailboxId, source: file.mailboxId === mailboxId ? file.source : 'email', cloudRef: true })).sort((a, b) => b.createdAt - a.createdAt),
      uploads: cache.uploads.filter(upload => upload.mailboxId === mailboxId && ids.includes(upload.mailboxId)).map(publicUpload).sort((a, b) => b.createdAt - a.createdAt),
      quota: mailboxId ? quotaFor(mailboxId) : { limit: LIMIT, used: 0, reserved: 0 },
      quotas: Object.fromEntries(ids.map(id => [id, quotaFor(id)])),
      families: FAMILIES.map(family => ({ ...family })), archiveFamilies: FAMILIES.map(family => ({ ...family })),
      browserStorage: browserStorage ? { ...browserStorage } : null, storageError,
      chunkSize: CHUNK_SIZE
    };
  }

  function chatAccess(file) {
    const user = M.getUser?.();
    if (!user?.active) return false;
    return (file.chatReferences || []).some(reference => {
      if (CHANNELS.has(reference.room)) return true;
      if (typeof reference.room !== 'string' || !reference.room.startsWith('dm:')) return false;
      const ids = reference.room.split(':').slice(1);
      return ids.length === 2 && ids[0] !== ids[1] && ids.includes(user.id) && reference.room === 'dm:' + [...ids].sort().join(':') && reference.participants?.length === 2 && [...reference.participants].sort().join('|') === [...ids].sort().join('|') && ids.every(id => M.state.users.some(member => member.id === id && member.active));
    });
  }

  function mailExists(file, reference) {
    return Boolean(M.state.mails?.some(mail => mail.id === reference.mailId && mail.owner === reference.mailboxId && mail.attachment?.cloudFileId === file.id));
  }

  function hasMailReference(file, mailboxId) {
    return (file.mailReferences || []).some(reference => reference.mailboxId === mailboxId && mailExists(file, reference));
  }

  function mailAccess(file) { return allowedIds().some(mailboxId => hasMailReference(file, mailboxId)); }
  function canRead(file) { return Boolean(file && M.getUser?.()?.active && (allowedIds().includes(file.mailboxId) || chatAccess(file) || mailAccess(file))); }

  function get(id) {
    const file = cache.files.find(item => item.id === id);
    return canRead(file) ? publicFile(file) : null;
  }

  function settleWaiters() {
    for (const [id, items] of waiters) {
      const file = cache.files.find(item => item.id === id);
      const upload = cache.uploads.find(item => item.id === id);
      const keep = [];
      for (const item of items) {
        try {
          assertContext(item.ctx);
          if (file && canRead(file)) item.resolve(publicFile(file));
          else if (localErrors.has(id) || upload?.status === 'error') item.reject(localErrors.get(id) || failure('upload', upload.error || 'Загрузка прервана.'));
          else if (!upload) item.reject(failure('cancelled', 'Загрузка отменена или файл удалён.'));
          else keep.push(item);
        } catch (error) { item.reject(error); }
      }
      if (keep.length) waiters.set(id, keep); else waiters.delete(id);
    }
    if (!waiters.size && waiterTimer !== null) { clearTimeout(waiterTimer); waiterTimer = null; }
    if (waiters.size && waiterTimer === null) {
      // A paused upload can have no other events; still reject an abandoned actor's waiter.
      waiterTimer = setTimeout(() => { waiterTimer = null; settleWaiters(); }, 500);
    }
  }

  function emit() {
    settleWaiters();
    const value = snapshot();
    for (const listener of listeners) { try { listener(value); } catch (error) { console.error('Cloud view update failed', error); } }
  }

  async function changed() {
    await refresh();
    channel?.postMessage({ changed: true });
  }

  async function bytes(blob) {
    if (typeof blob.arrayBuffer === 'function') return blob.arrayBuffer();
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = () => reject(failure('file', 'Не удалось прочитать файл. Выберите его ещё раз.'));
      reader.readAsArrayBuffer(blob);
    });
  }

  async function fingerprint(file, ctx) {
    if (!window.crypto?.subtle) throw failure('unsupported', 'Для безопасного возобновления загрузки откройте приложение через HTTPS.');
    const hash = async blob => {
      const data = await bytes(blob);
      assertContext(ctx);
      const result = await window.crypto.subtle.digest('SHA-256', data);
      assertContext(ctx);
      return Array.from(new Uint8Array(result), value => value.toString(16).padStart(2, '0')).join('');
    };
    return { first: await hash(file.slice(0, 65536)), last: await hash(file.slice(Math.max(0, file.size - 65536), file.size)) };
  }

  async function upload(file, options = {}) {
    const mailboxId = options.mailbox || activeMailbox();
    const ctx = context(mailboxId);
    const meta = validateFile(file);
    if (file.size > LIMIT) throw failure('quota', 'Файл превышает лимит облака ящика: 15 ГБ.');
    const source = options.source || 'upload';
    if (!['upload', 'email', 'chat'].includes(source)) throw failure('source', 'Неизвестный источник файла.');
    const hashes = await fingerprint(file, ctx);
    const db = await openDB();
    assertContext(ctx);
    if (navigator.storage?.estimate) {
      const estimate = await navigator.storage.estimate().catch(() => null);
      assertContext(ctx);
      if (estimate && Number.isFinite(estimate.quota) && Number.isFinite(estimate.usage) && file.size > Math.max(0, estimate.quota - estimate.usage)) {
        throw failure('browser-quota', 'В браузере недостаточно места для этого файла. Лимит 15 ГБ относится к будущему серверному облаку; доступный объём браузера может быть меньше.');
      }
    }
    const record = {
      id: uuid(), mailboxId, actorId: ctx.actorId, ...meta, size: file.size,
      lastModified: Number.isSafeInteger(file.lastModified) ? file.lastModified : 0,
      fingerprint: hashes, source, createdAt: Date.now(), uploadedBytes: 0, chunkSize: CHUNK_SIZE,
      status: navigator.onLine === false ? 'offline' : 'uploading', error: '', token: uuid()
    };
    await transaction(db, ['files', 'uploads'], 'readwrite', (tx, result, abort) => {
      readRecords(tx, ['files', 'uploads'], records => {
        assertContext(ctx);
        const quota = quotaFor(mailboxId, records);
        if (quota.used + quota.reserved + file.size > LIMIT) throw failure('quota', 'В облаке этого ящика недостаточно места. Лимит: 15 ГБ вместе с текущими загрузками.');
        if (records.uploads.length >= 50) throw failure('too-many', 'Завершите или отмените текущие загрузки. Одновременно можно хранить до 50 незавершённых файлов.');
        tx.objectStore('uploads').add(record);
        result(record);
      }, abort);
    });
    localFiles.set(record.id, { file, actorId: ctx.actorId });
    await changed();
    assertContext(ctx);
    if (record.status === 'uploading') startRunner(record.id, ctx, record.token);
    return publicUpload(record);
  }

  async function readUpload(id) {
    const db = await openDB();
    return transaction(db, ['uploads'], 'readonly', (tx, result) => {
      const request = tx.objectStore('uploads').get(validId(id));
      request.onsuccess = () => result(request.result);
    });
  }

  async function updateUpload(id, ctx, update) {
    const db = await openDB();
    assertContext(ctx);
    return transaction(db, ['uploads'], 'readwrite', (tx, result, abort) => {
      const request = tx.objectStore('uploads').get(validId(id));
      request.onsuccess = () => {
        try {
          assertContext(ctx);
          const record = request.result;
          if (!record || record.mailboxId !== ctx.mailboxId) throw failure('missing', 'Незавершённая загрузка не найдена.');
          update(record);
          tx.objectStore('uploads').put(record);
          result(record);
        } catch (error) { abort(error); }
      };
    });
  }

  function startRunner(id, ctx, token) {
    const previous = runners.get(id);
    if (previous?.token === token) return;
    const task = { token, ctx };
    runners.set(id, task);
    // Yield between chunks so pause/offline events can stop at an acknowledged boundary.
    task.promise = runUpload(id, ctx, token).catch(async error => {
      if (runners.get(id) !== task) return;
      localErrors.set(id, error);
      try {
        await updateUpload(id, ctx, record => { if (record.token === token) { record.status = error.code === 'permission' ? 'paused' : 'error'; record.error = error.message; } });
        await changed();
      } catch (_) { emit(); }
    }).finally(() => { if (runners.get(id) === task) runners.delete(id); });
  }

  async function runUpload(id, ctx, token) {
    const db = await openDB();
    while (true) {
      assertContext(ctx);
      const record = await readUpload(id);
      assertContext(ctx);
      if (!record || record.token !== token || record.status !== 'uploading') return;
      const reference = localFiles.get(id);
      if (!reference || reference.actorId !== ctx.actorId) throw failure('file', 'Выберите исходный файл для продолжения загрузки.');
      if (navigator.onLine === false) {
        await updateUpload(id, ctx, value => { if (value.token === token) value.status = 'offline'; });
        await changed();
        return;
      }
      if (record.uploadedBytes === record.size) {
        const completed = await transaction(db, ['uploads', 'files'], 'readwrite', (tx, result, abort) => {
          const request = tx.objectStore('uploads').get(id);
          request.onsuccess = () => {
            try {
              assertContext(ctx);
              const current = request.result;
              if (!current || current.token !== token || current.status !== 'uploading') return;
              const file = { id, name: current.name, type: current.type, size: current.size, source: current.source, mailboxId: current.mailboxId, uploadedBy: current.actorId, createdAt: current.createdAt, chunkSize: current.chunkSize, status: 'complete', cloudRef: true, archiveLinks: [], chatReferences: [] };
              tx.objectStore('files').add(file);
              tx.objectStore('uploads').delete(id);
              result(file);
            } catch (error) { abort(error); }
          };
        });
        if (completed) { localFiles.delete(id); localErrors.delete(id); await changed(); }
        return;
      }
      const offset = record.uploadedBytes;
      const chunk = reference.file.slice(offset, Math.min(offset + record.chunkSize, record.size), record.type);
      assertContext(ctx);
      const committed = await transaction(db, ['uploads', 'chunks'], 'readwrite', (tx, result, abort) => {
        const request = tx.objectStore('uploads').get(id);
        request.onsuccess = () => {
          try {
            assertContext(ctx);
            const current = request.result;
            if (!current || current.token !== token || current.status !== 'uploading' || current.uploadedBytes !== offset) return;
            tx.objectStore('chunks').put({ uploadId: id, index: offset / current.chunkSize, blob: chunk });
            current.uploadedBytes = offset + chunk.size;
            tx.objectStore('uploads').put(current);
            result(true);
          } catch (error) { abort(error); }
        };
      });
      if (!committed) return;
      await changed();
      await new Promise(resolve => setTimeout(resolve, 0));
    }
  }

  async function pause(id) {
    const actorId = actor();
    const upload = await readUpload(id);
    if (actor() !== actorId) throw failure('permission', 'Профиль изменился. Повторите действие.');
    if (!upload) throw failure('missing', 'Незавершённая загрузка не найдена.');
    const ctx = context(upload.mailboxId);
    const result = await updateUpload(id, ctx, record => { record.status = 'paused'; record.error = ''; record.token = uuid(); });
    localErrors.delete(id);
    await changed();
    return publicUpload(result);
  }

  async function resume(id, file) {
    const actorId = actor();
    const record = await readUpload(id);
    if (actor() !== actorId) throw failure('permission', 'Профиль изменился. Повторите действие.');
    if (!record) throw failure('missing', 'Незавершённая загрузка не найдена.');
    const ctx = context(record.mailboxId);
    const remembered = localFiles.get(id);
    const source = file || (remembered?.actorId === ctx.actorId ? remembered.file : null);
    if (!source) throw failure('needs-file', 'После перезагрузки выберите тот же исходный файл. Уже сохранённые части будут использованы.');
    const meta = validateFile(source);
    const modified = Number.isSafeInteger(source.lastModified) ? source.lastModified : 0;
    if (meta.name !== record.name || source.size !== record.size || modified !== record.lastModified || meta.type !== record.type) throw failure('mismatch', 'Это другой файл. Выберите исходный файл с тем же именем, размером и датой изменения.');
    const hashes = await fingerprint(source, ctx);
    if (hashes.first !== record.fingerprint.first || hashes.last !== record.fingerprint.last) throw failure('mismatch', 'Содержимое файла изменилось. Выберите первоначальный файл.');
    assertContext(ctx);
    localFiles.set(id, { file: source, actorId: ctx.actorId });
    localErrors.delete(id);
    const updated = await updateUpload(id, ctx, value => { value.status = navigator.onLine === false ? 'offline' : 'uploading'; value.error = ''; value.token = uuid(); });
    await changed();
    assertContext(ctx);
    if (updated.status === 'uploading') startRunner(id, ctx, updated.token);
    return publicUpload(updated);
  }

  function deleteChunks(tx, id) {
    const index = tx.objectStore('chunks').index('uploadId');
    const cursor = index.openKeyCursor(window.IDBKeyRange.only(id));
    cursor.onsuccess = () => { if (cursor.result) { tx.objectStore('chunks').delete(cursor.result.primaryKey); cursor.result.continue(); } };
  }

  async function cancel(id) {
    const actorId = actor();
    const upload = await readUpload(id);
    if (actor() !== actorId) throw failure('permission', 'Профиль изменился. Повторите действие.');
    if (!upload) throw failure('missing', 'Незавершённая загрузка не найдена.');
    const ctx = context(upload.mailboxId);
    const db = await openDB();
    assertContext(ctx);
    await transaction(db, ['uploads', 'chunks'], 'readwrite', (tx, result, abort) => {
      const request = tx.objectStore('uploads').get(validId(id));
      request.onsuccess = () => {
        try { assertContext(ctx); if (request.result?.mailboxId !== ctx.mailboxId) throw failure('missing', 'Загрузка не найдена.'); tx.objectStore('uploads').delete(id); deleteChunks(tx, id); } catch (error) { abort(error); }
      };
    });
    localFiles.delete(id); localErrors.delete(id);
    await changed();
  }

  async function fileOperation(id, modify, readAccess = false) {
    const actorId = actor();
    const db = await openDB();
    if (actor() !== actorId) throw failure('permission', 'Профиль изменился. Повторите действие.');
    return transaction(db, ['files', 'chunks'], 'readwrite', (tx, result, abort) => {
      const request = tx.objectStore('files').get(validId(id));
      request.onsuccess = () => {
        try {
          if (actor() !== actorId) throw failure('permission', 'Профиль изменился. Повторите действие.');
          const file = request.result;
          if (!file) throw failure('missing', 'Файл не найден.');
          if(readAccess){if(!canRead(file))throw failure('permission','У вас нет доступа к этому файлу.');}else assertContext({ actorId, mailboxId: file.mailboxId });
          const keep = modify(file);
          if (keep !== false) tx.objectStore('files').put(file);
          else { tx.objectStore('files').delete(id); deleteChunks(tx, id); }
          result(publicFile(file));
        } catch (error) { abort(error); }
      };
    });
  }

  async function toArchive(id, { familyId } = {}) {
    if (!FAMILIES.some(family => family.id === familyId)) throw failure('family', 'Выберите семейный архив из списка.');
    const result = await fileOperation(id, file => {
      file.archiveLinks ||= [];
      if (!file.archiveLinks.some(link => link.familyId === familyId)) file.archiveLinks.push({ familyId, linkedAt: Date.now() });
    },true);
    await changed();
    return result;
  }

  async function remove(id) {
    const target = activeMailbox();
    const ctx = context(target);
    await fileOperation(id, file => {
      assertContext(ctx);
      if(file.mailboxId===target)file.cloudRef = false;
      file.mailReferences=(file.mailReferences||[]).filter(ref=>ref.mailboxId!==target);
      return Boolean(file.cloudRef!==false||file.archiveLinks?.length || file.chatReferences?.length || file.mailReferences.length);
    },true);
    await changed();
  }

  function roomParticipants(room) {
    const current = actor();
    const users = M.state.users.filter(user => user.active).map(user => user.id);
    if (CHANNELS.has(room)) return users;
    if (typeof room !== 'string' || !room.startsWith('dm:')) throw failure('room', 'Разговор не найден.');
    const ids = room.split(':').slice(1);
    if (ids.length !== 2 || ids[0] === ids[1] || !ids.includes(current) || !ids.every(id => users.includes(id)) || room !== 'dm:' + [...ids].sort().join(':')) throw failure('permission', 'Вы не участник этого личного разговора.');
    return ids;
  }

  async function registerChatReference(id, { room, participants } = {}) {
    const derived = roomParticipants(room);
    if (participants !== undefined && (!Array.isArray(participants) || participants.length !== derived.length || [...new Set(participants)].sort().join('|') !== [...derived].sort().join('|'))) throw failure('permission', 'Получатели файла должны совпадать с участниками разговора.');
    const result = await fileOperation(id, file => {
      const currentParticipants = roomParticipants(room);
      file.chatReferences ||= [];
      if (!file.chatReferences.some(reference => reference.room === room)) file.chatReferences.push({ room, participants: currentParticipants, createdAt: Date.now() });
    });
    await changed();
    return result;
  }

  function assertMailRecipient(mailboxId) {
    if (!mailboxId || !(mailboxId === 'team' || M.state.users.some(user => user.id === mailboxId && user.active))) throw failure('permission', 'Получатель письма не найден.');
  }

  async function registerMailReference(id,{mailboxId,mailId}={}){
    const actorId=actor();
    assertMailRecipient(mailboxId);
    validId(id);validId(mailId);const db=await openDB();
    const result=await transaction(db,['files','uploads'],'readwrite',(tx,setResult,abort)=>{
      readRecords(tx,['files','uploads'],records=>{
        try{
          if(actor()!==actorId)throw failure('permission','Профиль изменился.');
          assertMailRecipient(mailboxId);
          const file=records.files.find(f=>f.id===id);if(!file)throw failure('missing','Файл не найден.');
          // A received attachment can be forwarded only while its actual incoming
          // mail and mailbox permission still exist. Chat access alone grants no
          // permission to create mailbox references.
          if (!allowedIds().includes(file.mailboxId) && !mailAccess(file)) throw failure('permission', 'У вас нет доступа к этому вложению письма.');
          const already=file.mailboxId===mailboxId&&file.cloudRef!==false||(file.mailReferences||[]).some(ref=>ref.mailboxId===mailboxId);
          const quota=quotaFor(mailboxId,records);if(!already&&quota.used+quota.reserved+file.size>LIMIT)throw failure('quota','В облаке получателя недостаточно места: лимит 15 ГБ.');
          file.mailReferences||=[];if(!file.mailReferences.some(ref=>ref.mailId===mailId&&ref.mailboxId===mailboxId))file.mailReferences.push({mailboxId,mailId,createdAt:Date.now()});
          tx.objectStore('files').put(file);setResult(publicFile(file));
        }catch(error){abort(error);}
      },abort);
    });await changed();return result;
  }

  async function resolveBlob(id) {
    validId(id);
    const actorId = actor();
    const db = await openDB();
    const result = await transaction(db, ['files', 'chunks'], 'readonly', (tx, done, abort) => {
      const request = tx.objectStore('files').get(id);
      request.onsuccess = () => {
        try {
          if (actor() !== actorId) throw failure('permission', 'Профиль изменился. Повторите действие.');
          const file = request.result;
          if (!canRead(file)) throw failure('permission', 'У вас нет доступа к этому файлу.');
          const chunks = tx.objectStore('chunks').index('uploadId').getAll(window.IDBKeyRange.only(id));
          chunks.onsuccess = () => {
            try {
              if (actor() !== actorId || !canRead(file)) throw failure('permission', 'Доступ к файлу отозван.');
              const parts = chunks.result.sort((a, b) => a.index - b.index);
              if (parts.some((part, index) => part.index !== index || !part.blob || typeof part.blob.size !== 'number') || parts.reduce((sum, part) => sum + part.blob.size, 0) !== file.size) throw failure('incomplete', 'Файл сохранён не полностью.');
              done({ file, parts });
            } catch (error) { abort(error); }
          };
        } catch (error) { abort(error); }
      };
    });
    if (actor() !== actorId || !canRead(result.file)) throw failure('permission', 'Доступ к файлу отозван.');
    return new Blob(result.parts.map(part => part.blob), { type: result.file.type });
  }

  async function download(id) {
    const actorId = actor();
    const blob = await resolveBlob(id);
    const file = get(id);
    if (!file || actor() !== actorId) throw failure('permission', 'Доступ к файлу отозван.');
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url; link.download = filename(file.name); link.hidden = true;
    document.body.appendChild(link); link.click(); link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    return file;
  }

  async function waitForFile(id) {
    validId(id);
    const actorId = actor();
    await refresh();
    if (actor() !== actorId) throw failure('permission', 'Профиль изменился. Повторите действие.');
    const file = cache.files.find(item => item.id === id);
    if (file) {
      if (!canRead(file)) throw failure('permission', 'У вас нет доступа к этому файлу.');
      return publicFile(file);
    }
    const upload = cache.uploads.find(item => item.id === id);
    if (!upload) throw failure('cancelled', 'Загрузка отменена или файл удалён.');
    const ctx = context(upload.mailboxId);
    if (upload.status === 'error' || localErrors.has(id)) throw localErrors.get(id) || failure('upload', upload.error || 'Загрузка прервана.');
    return new Promise((resolve, reject) => { const items = waiters.get(id) || []; items.push({ ctx, resolve, reject }); waiters.set(id, items); settleWaiters(); });
  }

  async function connectionChanged(online) {
    const active = [...localFiles].filter(([, reference]) => reference.actorId === M.getUser?.()?.id);
    for (const [id] of active) {
      try {
        const record = await readUpload(id);
        if (!record) continue;
        const ctx = context(record.mailboxId);
        if (!online && record.status === 'uploading') {
          await updateUpload(id, ctx, value => { value.status = 'offline'; value.token = uuid(); });
          await changed();
        } else if (online && record.status === 'offline') await resume(id);
      } catch (_) { /* Rights can change while the browser reconnects. */ }
    }
  }

  window.addEventListener('offline', () => { void connectionChanged(false); });
  window.addEventListener('online', () => { void connectionChanged(true); });
  window.addEventListener('memory-cloud-refresh', () => { void refresh().catch(() => {}); });
  channel?.addEventListener('message', event => { if (event.data?.changed === true) void refresh().catch(() => {}); });

  M.cloud = Object.freeze({
    snapshot, refresh, upload, pause, resume, cancel, download, toArchive, remove, get, resolveBlob, waitForFile, registerChatReference, registerMailReference,
    subscribe(callback) { if (typeof callback !== 'function') throw new TypeError('Expected a callback'); listeners.add(callback); return () => listeners.delete(callback); }
  });
})();
