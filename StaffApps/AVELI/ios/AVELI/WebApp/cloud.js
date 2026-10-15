(function () {
  'use strict';

  const M = window.M;
  if (!M) return;
  const e = M.escape;
  const QUOTA = 15000000000;
  const localIcons = {
    cloud: 'M7 18H6a4 4 0 0 1-.7-7.9A7 7 0 0 1 19 8a5 5 0 0 1 0 10h-2',
    upload: 'M12 16V3 M7 8l5-5 5 5 M4 16v5h16v-5',
    image: 'M3 3h18v18H3z M3 16l6-6 6 6 3-3 3 3 M15 7h.01',
    video: 'M3 5h18v14H3z M10 9l5 3-5 3z',
    audio: 'M9 18V5l11-2v13 M9 5l11-2 M9 18a3 3 0 1 1-3-3c1.7 0 3 1.3 3 3 M20 16a3 3 0 1 1-3-3c1.7 0 3 1.3 3 3',
    pause: 'M7 4h3v16H7z M14 4h3v16h-3z',
    play: 'M8 4l12 8-12 8z',
    offline: 'M2 2l20 20 M8 8a9 9 0 0 1 11 3 M5 5a16 16 0 0 1 17 3 M2 8l3-2 M5 12l2-1 M9 16l3-1 3 1 M12 20h.01'
  };
  function ic(name, size = 18) {
    if (!localIcons[name]) return M.icon(name, size);
    return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${localIcons[name]}"/></svg>`;
  }
  let category = 'all';
  let query = '';
  let sort = 'newest';
  let subscribed = null;
  let resumeId = null;
  const busy = new Set();
  const sources = { upload: 'Загрузка', email: 'Из письма', mail: 'Из письма', chat: 'Из чата' };
  const categories = [
    ['all', 'Все файлы', 'folder'], ['images', 'Фото', 'image'],
    ['docs', 'Документы', 'file'], ['audio', 'Аудио', 'audio'], ['video', 'Видео', 'video']
  ];

  const mailbox = () => M.state.activeMailboxId || M.getUser()?.id;
  const sizeOf = file => Math.max(0, Number(file?.size ?? file?.bytes ?? 0) || 0);
  const ownerOf = file => file?.mailboxId ?? file?.mailbox ?? file?.owner;
  const recordId = file => String(file?.id ?? file?.fileId ?? '');
  const isCurrent = file => !ownerOf(file) || ownerOf(file) === mailbox();
  function formatBytes(value) {
    const number = Math.max(0, Number(value) || 0);
    if (number === 0) return '0 МБ';
    if (number < 1000) return `${number.toLocaleString('ru-RU')} Б`;
    if (number < 1000000) return `${(number / 1000).toLocaleString('ru-RU', { maximumFractionDigits: 1 })} КБ`;
    if (number < 1000000000) return `${(number / 1000000).toLocaleString('ru-RU', { maximumFractionDigits: 1 })} МБ`;
    return `${(number / 1000000000).toLocaleString('ru-RU', { maximumFractionDigits: 2 })} ГБ`;
  }
  function fileCategory(file) {
    const type = String(file.type ?? file.mime ?? file.mimeType ?? '').toLowerCase();
    const name = String(file.name || '').toLowerCase();
    if (type.startsWith('image/') || /\.(jpe?g|png|webp|gif|heic|heif|avif|tiff?|bmp|svg)$/.test(name)) return 'images';
    if (type.startsWith('video/') || /\.(mp4|mov|webm|mkv|avi|m4v)$/.test(name)) return 'video';
    if (type.startsWith('audio/') || /\.(mp3|wav|m4a|ogg|flac|aac)$/.test(name)) return 'audio';
    return 'docs';
  }
  function dateLabel(value) {
    const d = new Date(value);
    return Number.isFinite(d.getTime()) ? d.toLocaleDateString('ru-RU', { day: 'numeric', month: 'short' }) : 'Сегодня';
  }
  function snapshot() {
    let data = {};
    try { data = M.cloud?.snapshot?.() || {}; } catch (_) { /* Engine may still be opening its storage. */ }
    const files = Array.isArray(data.files) ? data.files.filter(isCurrent) : [];
    const uploads = Array.isArray(data.uploads) ? data.uploads.filter(isCurrent) : [];
    return { ...data, files, uploads, mode: data.mode || 'local-demo' };
  }
  function quotaFor(data) {
    const quota = data.quotas?.[mailbox()] || data.quota?.[mailbox()] || data.quota || {};
    const used = Math.max(0, Number(quota.used) || data.files.reduce((total, file) => total + sizeOf(file), 0));
    const reserved = Math.max(0, Number(quota.reserved) || 0);
    return { limit: Number(quota.limit) || QUOTA, used, reserved };
  }
  function linksFor(file) {
    if (Array.isArray(file.archiveLinks)) return file.archiveLinks;
    if (Array.isArray(file.archiveRefs)) return file.archiveRefs;
    if (file.archiveFamilyId || file.archivedFamilyId) return [{ familyId: file.archiveFamilyId || file.archivedFamilyId }];
    return [];
  }
  function familiesFor(data) {
    const families = data.families || data.archiveFamilies || M.state.archiveFamilies;
    return Array.isArray(families) && families.length ? families : [
      { id: 'kovalev', name: 'Семья Ковалёвых' },
      { id: 'nikitina', name: 'Семья Никитиных' },
      { id: 'petrova', name: 'Семья Петровых' }
    ];
  }
  function mailboxLabel() {
    if (mailbox() === 'team') return 'archive@archiverf.ru';
    return M.state.users?.find(user => user.id === mailbox())?.email || M.getUser()?.email || 'Текущий ящик';
  }
  function fileBadge(file) {
    const kind = fileCategory(file);
    return `<span class="cloud-file-symbol cloud-kind-${kind}">${ic(kind === 'images' ? 'image' : kind === 'docs' ? 'file' : kind)}</span>`;
  }
  function archiveStatus(file, data) {
    const links = linksFor(file);
    if (!links.length) return `<span class="cloud-status-empty">Ещё не в архиве</span>`;
    const family = familiesFor(data).find(item => item.id === (links[0].familyId || links[0].id));
    return `<span class="cloud-status-linked" title="${e(family?.name || 'Семейный архив')}">${ic('check', 12)} ${data.mode === 'server' ? 'В семейном архиве' : 'Демоархив'}${links.length > 1 ? ` · ${links.length}` : ''}</span>`;
  }
  function fileRow(file, data) {
    const id = e(recordId(file));
    return `<div class="cloud-file-row" role="row">
      <button class="cloud-file-main" data-action="cloud-details" data-id="${id}" role="cell">${fileBadge(file)}<span><strong>${e(file.name || 'Без названия')}</strong><small>${e(String(file.type || file.mime || 'Файл'))}</small></span></button>
      <span class="cloud-row-source" role="cell">${ic(['email', 'mail'].includes(file.source) ? 'mail' : file.source === 'chat' ? 'chat' : 'upload', 13)} ${e(sources[file.source] || 'Загрузка')}</span>
      <span class="cloud-row-size" role="cell">${formatBytes(sizeOf(file))}</span>
      <time class="cloud-row-date" role="cell">${e(dateLabel(file.createdAt || file.updatedAt))}</time>
      <span class="cloud-row-archive" role="cell">${archiveStatus(file, data)}</span>
      <span class="cloud-row-actions" role="cell"><button class="icon-button" data-action="cloud-download" data-id="${id}" aria-label="Скачать ${e(file.name)}" title="Скачать">${ic('download', 17)}</button><button class="icon-button" data-action="cloud-archive" data-id="${id}" aria-label="В семейный архив: ${e(file.name)}" title="В семейный архив">${ic('archive', 17)}</button><button class="icon-button cloud-delete" data-action="cloud-remove" data-id="${id}" aria-label="Удалить ${e(file.name)}" title="Удалить из облака">${ic('trash', 16)}</button></span>
    </div>`;
  }
  function renderFiles(data) {
    let files = data.files.filter(file => (category === 'all' || fileCategory(file) === category) && String(file.name || '').toLowerCase().includes(query.toLowerCase()));
    files = [...files].sort((a, b) => sort === 'name' ? String(a.name).localeCompare(String(b.name), 'ru') : sort === 'size' ? sizeOf(b) - sizeOf(a) : new Date(b.createdAt || 0) - new Date(a.createdAt || 0));
    if (!files.length) return `<div class="cloud-empty">${ic(query || category !== 'all' ? 'search' : 'cloud', 36)}<h3>${query || category !== 'all' ? 'Ничего не найдено' : 'Место для ваших воспоминаний'}</h3><p>${query || category !== 'all' ? 'Попробуйте другое название или выберите все файлы.' : 'Добавьте фотографии, документы, аудио и видео. Файлы из писем и чата тоже можно сохранить сюда.'}</p>${query || category !== 'all' ? `<button class="button secondary small" data-action="cloud-reset-filter">Показать все файлы</button>` : `<button class="button secondary" data-action="cloud-upload">${ic('plus', 15)} Добавить первый файл</button>`}</div>`;
    return `<div class="cloud-files-table" role="table" aria-label="Файлы текущего почтового ящика"><div class="cloud-file-row cloud-table-heading" role="row"><span role="columnheader">Название</span><span role="columnheader">Источник</span><span role="columnheader">Размер</span><span role="columnheader">Добавлен</span><span role="columnheader">Семейный архив</span><span role="columnheader" class="cloud-sr-only">Действия</span></div>${files.map(file => fileRow(file, data)).join('')}</div>`;
  }
  function uploadStatus(upload) {
    return ({ uploading: 'Загружается', queued: 'В очереди', pending: 'В очереди', paused: 'На паузе', offline: 'Нет соединения', 'needs-file': 'Выберите исходный файл', waiting: 'Выберите исходный файл', error: 'Загрузка остановлена', failed: 'Загрузка остановлена', complete: 'Загружено', completed: 'Загружено', done: 'Загружено', cancelled: 'Отменено' })[upload.status] || 'Подготовка';
  }
  function queueRow(upload) {
    const id = e(recordId(upload));
    const uploaded = Math.min(sizeOf(upload), Math.max(0, Number(upload.uploadedBytes ?? upload.completedBytes ?? upload.offset ?? 0) || 0));
    const pct = sizeOf(upload) ? Math.min(100, Math.floor(uploaded / sizeOf(upload) * 100)) : 0;
    const completed = ['complete', 'completed', 'done'].includes(upload.status);
    const active = ['uploading', 'queued', 'pending'].includes(upload.status);
    return `<div class="cloud-transfer ${completed ? 'cloud-transfer-complete' : ''}">${fileBadge(upload)}<div class="cloud-transfer-body"><div class="cloud-transfer-title"><strong>${e(upload.name || 'Файл')}</strong><span>${completed ? ic('check', 13) : `${pct}%`}</span></div><progress class="cloud-progress" aria-label="${e(upload.name)}" value="${completed ? 100 : pct}" max="100"></progress><div class="cloud-transfer-meta"><span>${e(uploadStatus(upload))}${upload.error ? ` · ${e(String(upload.error).slice(0, 160))}` : ''}</span><span>${formatBytes(uploaded)} / ${formatBytes(sizeOf(upload))}</span></div></div><div class="cloud-transfer-actions">${!completed ? `<button class="icon-button" data-action="${active ? 'cloud-pause' : 'cloud-resume'}" data-id="${id}" aria-label="${active ? 'Приостановить' : 'Продолжить'} ${e(upload.name)}" title="${active ? 'Приостановить' : 'Продолжить'}">${ic(active ? 'pause' : 'play', 14)}</button><button class="icon-button" data-action="cloud-cancel" data-id="${id}" aria-label="Отменить загрузку ${e(upload.name)}" title="Отменить">${ic('close', 15)}</button>` : ''}</div></div>`;
  }
  function renderQueue(data) {
    const items = data.uploads.filter(upload => !['cancelled', 'complete', 'completed', 'done'].includes(upload.status));
    if (!items.length) return M.state.cloudShowUploads ? `<section class="cloud-transfers" aria-label="Загрузки"><div class="cloud-section-heading"><h2>${ic('upload', 16)} Загрузки</h2></div><div class="cloud-empty"><h3>Очередь пока пуста</h3><p>Добавьте файл. Здесь появятся сохранённый прогресс, пауза и продолжение.</p><button class="button secondary" data-action="cloud-upload">Выбрать файл</button></div></section>` : '';
    return `<section class="cloud-transfers" aria-label="Загрузки"><div class="cloud-section-heading"><h2>${ic('upload', 16)} Загрузки <span>${items.length}</span></h2><small>Продолжение с последней сохранённой части</small></div>${items.map(queueRow).join('')}</section>`;
  }

  M.renderCloud = function () {
    ensureSubscription();
    const data = snapshot();
    const quota = quotaFor(data);
    const pct = Math.min(100, Math.max(0, quota.used / quota.limit * 100));
    const local = data.mode !== 'server';
    return `<section id="cloud-screen" class="cloud-screen"><div class="page-heading cloud-heading"><div><div class="eyebrow">ФАЙЛЫ ВАШЕГО ПОЧТОВОГО ЯЩИКА</div><h1>Облако <span class="cloud-title-count">${data.files.length}</span></h1><p>Всё для семейных историй. Рядом с почтой и командой.</p></div><button class="button primary" data-action="cloud-upload">${ic('upload', 17)} <span>Загрузить файлы</span></button></div>
    <div class="cloud-mode-note">${ic(local ? 'smartphone' : 'shield', 15)}<span>${local ? 'Демо · файлы в этом браузере; сервер архива пока не подключён' : 'Общее хранилище почты, чата и семейного архива'}</span><span class="cloud-mode-tag">${local ? 'ЛОКАЛЬНО' : 'СЕРВЕР'}</span></div>
    ${data.storageError ? `<div class="cloud-offline-banner cloud-storage-error" role="alert">${ic('alert', 18)}<div><strong>Хранилище недоступно</strong><span>${e(data.storageError)}</span></div><button class="button secondary small" data-action="cloud-refresh">Повторить</button></div>` : ''}
    <div class="cloud-offline-banner" ${navigator.onLine !== false ? 'hidden' : ''}>${ic('offline', 18)}<div><strong>Соединение прервано</strong><span>Незавершённые загрузки на паузе. После восстановления продолжим с сохранённого места.</span></div></div>
    <div class="cloud-overview"><section class="cloud-quota-card"><div class="cloud-quota-top"><span class="cloud-quota-symbol">${ic('cloud', 24)}</span><div><span class="cloud-overline">ЛИЧНОЕ ОБЛАКО ЯЩИКА</span><strong>${e(mailboxLabel())}</strong></div><span class="cloud-quota-limit">15 <small>ГБ</small></span></div><div class="cloud-quota-summary"><span><strong>${formatBytes(quota.used)}</strong> из 15 ГБ</span><small>${data.files.length} ${data.files.length === 1 ? 'файл' : data.files.length > 1 && data.files.length < 5 ? 'файла' : 'файлов'}</small></div><progress class="cloud-quota-meter" aria-label="Использовано облака" value="${pct}" max="100"></progress><div class="cloud-quota-foot"><span>Свободно ${formatBytes(Math.max(0, quota.limit - quota.used - quota.reserved))}</span><small>${local ? 'Лимит демоящика; доступное место зависит от браузера' : '15 ГБ для каждого ящика'}</small></div></section>
    <section class="cloud-archive-card"><span class="cloud-archive-symbol">${ic('archive', 22)}</span><div><span class="cloud-overline">В СЕМЕЙНЫЙ АРХИВ</span><h2>Один файл. Вся история.</h2><p>Письмо → облако → архив семьи.<br>Без скачивания и повторной загрузки.</p><button class="cloud-text-action" data-action="cloud-how-archive">Как это работает ${ic('arrow-up-right', 13)}</button></div><span class="cloud-archive-mark">ЖП</span></section></div>
    <div class="cloud-grid"><div class="cloud-main"><div class="cloud-file-panel"><div class="cloud-file-toolbar"><div class="cloud-filter-tabs" role="tablist" aria-label="Тип файлов">${categories.map(([id, label, name]) => `<button class="cloud-filter ${category === id ? 'active' : ''}" data-action="cloud-filter" data-filter="${id}" role="tab" aria-selected="${category === id}">${ic(name, 14)} ${label}</button>`).join('')}</div><button class="icon-button" data-action="cloud-refresh" aria-label="Обновить список файлов" title="Обновить">${ic('refresh', 16)}</button></div><div class="cloud-search-row"><label class="cloud-search">${ic('search', 16)}<input id="cloud-search" type="search" placeholder="Найти файл…" aria-label="Поиск в облаке" value="${e(query)}" maxlength="200"></label><label class="cloud-sort-label"><span class="cloud-sr-only">Сортировка файлов</span><select id="cloud-sort"><option value="newest" ${sort === 'newest' ? 'selected' : ''}>Сначала новые</option><option value="name" ${sort === 'name' ? 'selected' : ''}>По названию</option><option value="size" ${sort === 'size' ? 'selected' : ''}>По размеру</option></select></label></div><div id="cloud-file-results">${renderFiles(data)}</div><div class="cloud-file-footer">${ic('lock', 12)} Файлы текущего ящика · ${e(mailboxLabel())}</div></div>${renderQueue(data)}</div>
    <aside class="cloud-side"><button class="cloud-dropzone" data-action="cloud-upload" aria-label="Выбрать или перетащить файлы для загрузки"><span class="cloud-drop-icon">${ic('upload', 23)}</span><strong>Перетащите файлы сюда</strong><span>или нажмите, чтобы выбрать</span><small>Большие файлы · загрузка частями</small></button><section class="cloud-resume-card"><span class="cloud-resume-icon">${ic('refresh', 19)}</span><h2>Продолжим с того же места</h2><p>Сохранённые части остаются. Если вкладку закрыли, выберите тот же файл — загрузка продолжится.</p><div class="cloud-resume-points"><span>${ic('check', 12)} Пауза и продолжение</span><span>${ic('check', 12)} Сохранение прогресса загрузки</span></div></section><div class="cloud-linked-note">${ic('chat', 17)}<div><strong>Делитесь в командном чате</strong><p>Загрузите файл один раз. В чат отправится ссылка на файл облака.</p></div></div></aside></div><input type="file" id="cloud-upload-input" multiple hidden><input type="file" id="cloud-resume-input" hidden></section>`;
  };

  function redraw() {
    if (M.state.view !== 'cloud') return;
    const current = document.getElementById('cloud-screen');
    if (!current) return;
    const active = document.activeElement;
    const searchFocused = active?.id === 'cloud-search';
    const caret = searchFocused ? active.selectionStart : null;
    const scroll = current.scrollTop;
    current.outerHTML = M.renderCloud();
    if (searchFocused) {
      const input = document.getElementById('cloud-search');
      input?.focus({ preventScroll: true });
      try { input?.setSelectionRange(caret, caret); } catch (_) { /* Search inputs may not expose a selection API. */ }
    }
    const replacement = document.getElementById('cloud-screen');
    if (replacement && Number.isFinite(scroll)) replacement.scrollTop = scroll;
  }
  function ensureSubscription() {
    if (!M.cloud || subscribed === M.cloud) return;
    subscribed = M.cloud;
    M.cloud.subscribe?.(redraw);
  }
  async function perform(key, work) {
    if (!M.getUser()?.active || busy.has(key)) return;
    busy.add(key);
    try { return await work(); }
    catch (error) { M.toast(error?.message || 'Не удалось выполнить действие с файлом.'); }
    finally { busy.delete(key); redraw(); }
  }
  function fileFor(id) { return snapshot().files.find(file => recordId(file) === id); }
  function showDetails(file) {
    const data = snapshot();
    const links = linksFor(file);
    M.openModal('Файл в облаке', `<div class="cloud-modal-file">${fileBadge(file)}<div><strong>${e(file.name)}</strong><span>${formatBytes(sizeOf(file))} · ${e(sources[file.source] || 'Загрузка')}</span></div></div><dl class="cloud-detail-list"><div><dt>Почтовый ящик</dt><dd>${e(mailboxLabel())}</dd></div><div><dt>Добавлен</dt><dd>${e(dateLabel(file.createdAt))}</dd></div><div><dt>Тип</dt><dd>${e(file.type || file.mime || 'Файл')}</dd></div><div><dt>Семейный архив</dt><dd>${links.length ? links.map(link => e(familiesFor(data).find(family => family.id === (link.familyId || link.id))?.name || 'Архив семьи')).join(', ') : 'Не связан'}</dd></div></dl>${data.mode !== 'server' ? '<p class="cloud-modal-note">Файл хранится в этом браузере. Сервер семейного архива ещё не подключён.</p>' : ''}<div class="modal-form-footer"><button class="button secondary" data-action="cloud-download" data-id="${e(recordId(file))}">${ic('download', 16)} Скачать</button><button class="button primary" data-action="cloud-archive" data-id="${e(recordId(file))}">${ic('archive', 16)} В семейный архив</button></div>`);
  }
  function showArchive(file) {
    const data = snapshot();
    const local = data.mode !== 'server';
    M.openModal('Добавить в семейный архив', `<form id="cloud-archive-form" data-id="${e(recordId(file))}"><div class="cloud-modal-file">${fileBadge(file)}<div><strong>${e(file.name)}</strong><span>${formatBytes(sizeOf(file))} · ${e(sources[file.source] || 'Загрузка')}</span></div></div><label class="form-field"><span>Архив семьи</span><select name="familyId" required>${familiesFor(data).map(family => `<option value="${e(family.id)}">${e(family.name || family.title || family.id)}</option>`).join('')}</select></label><div class="cloud-archive-explanation">${ic('refresh', 20)}<div><strong>Без повторной передачи файла</strong><p>${local ? 'В демоархиве сохранится ссылка на те же части файла в этом браузере. Это не отправка на сервер.' : 'Архив получит ссылку на уже сохранённый объект общего хранилища.'}</p></div></div><div class="modal-form-footer"><button type="button" class="button secondary" data-action="close-modal">Отмена</button><button class="button primary" type="submit">${ic('archive', 16)} ${local ? 'Связать с демоархивом' : 'Добавить в архив'}</button></div></form>`);
  }
  function chooseUpload() { document.getElementById('cloud-upload-input')?.click(); }
  function chooseResume(id) { resumeId = id; document.getElementById('cloud-resume-input')?.click(); }
  async function uploadFiles(files) {
    if (!M.cloud?.upload) return M.toast('Хранилище ещё открывается. Попробуйте через несколько секунд.');
    const currentMailbox = mailbox();
    const valid = Array.from(files || []).filter(file => file && typeof file.slice === 'function');
    const results = await Promise.allSettled(valid.map(file => perform(`upload:${currentMailbox}:${file.name}:${file.size}:${file.lastModified}`, () => M.cloud.upload(file, { mailbox: currentMailbox }))));
    results.forEach(result => { if (result.status === 'rejected') M.toast(result.reason?.message || 'Не удалось загрузить файл.'); });
  }
  M.onCloudAction = function (action, element) {
    if (!action.startsWith('cloud-')) return false;
    if (!M.getUser()?.active) return true;
    const id = String(element?.dataset?.id || '');
    const file = fileFor(id);
    switch (action) {
      case 'cloud-upload': chooseUpload(); break;
      case 'cloud-filter': category = categories.some(([key]) => key === element.dataset.filter) ? element.dataset.filter : 'all'; redraw(); break;
      case 'cloud-reset-filter': category = 'all'; query = ''; redraw(); break;
      case 'cloud-refresh': perform('refresh', async () => { await M.cloud?.refresh?.(); }); break;
      case 'cloud-details': if (file) showDetails(file); break;
      case 'cloud-download': if (file) perform(`download:${id}`, () => M.cloud.download(id)); break;
      case 'cloud-archive': if (file) showArchive(file); break;
      case 'cloud-pause': perform(`pause:${id}`, () => M.cloud.pause(id)); break;
      case 'cloud-resume': {
        const upload = snapshot().uploads.find(item => recordId(item) === id);
        if (!upload) break;
        if (['needs-file', 'waiting'].includes(upload.status) || upload.needsFile || upload.requiresFile) chooseResume(id);
        else perform(`resume:${id}`, async () => {
          const result = await M.cloud.resume(id);
          if (result?.needsFile || result?.requiresFile) chooseResume(id);
        });
        break;
      }
      case 'cloud-cancel': perform(`cancel:${id}`, () => M.cloud.cancel(id)); break;
      case 'cloud-remove': if (file) M.openModal('Удалить из облака?', `<div class="cloud-modal-file">${fileBadge(file)}<div><strong>${e(file.name)}</strong><span>${formatBytes(sizeOf(file))}</span></div></div><p class="cloud-modal-note">Ссылка в этом облаке будет удалена. Если файл уже связан с семейным архивом, архивная ссылка сохранится.</p><div class="modal-form-footer"><button class="button secondary" data-action="close-modal">Отмена</button><button class="button danger" data-action="cloud-confirm-remove" data-id="${e(id)}">Удалить из облака</button></div>`); break;
      case 'cloud-confirm-remove': if (file) perform(`remove:${id}`, async () => { await M.cloud.remove(id); M.closeModal(); M.toast('Файл удалён из облака'); }); break;
      case 'cloud-how-archive': M.openModal('Облако и семейный архив', `<div class="cloud-explainer-flow"><span>${ic('mail', 23)} Почта / чат</span>${ic('chevron-right', 16)}<span>${ic('cloud', 23)} Облако ящика</span>${ic('chevron-right', 16)}<span>${ic('archive', 23)} Архив семьи</span></div><p class="cloud-modal-note">Файл загружается один раз. Для письма, чата и архива создаются ссылки на один объект. Для архива выберите семью в меню файла — скачивать его на устройство не требуется.</p><div class="cloud-archive-explanation">${ic('smartphone', 20)}<div><strong>${snapshot().mode === 'server' ? 'Общее серверное хранилище' : 'Сейчас — демонстрация в браузере'}</strong><p>${snapshot().mode === 'server' ? 'Права доступа проверяются сервером для каждой операции.' : 'Файлы и связи сохраняются локально. Чтобы команда работала с разных устройств, нужно подключить общее серверное хранилище.'}</p></div></div>`); break;
      default: return false;
    }
    return true;
  };

  document.addEventListener('input', event => {
    if (event.target.id !== 'cloud-search') return;
    query = event.target.value.slice(0, 200);
    const results = document.getElementById('cloud-file-results');
    if (results) results.innerHTML = renderFiles(snapshot());
  });
  document.addEventListener('change', event => {
    if (event.target.id === 'cloud-sort') {
      sort = ['newest', 'name', 'size'].includes(event.target.value) ? event.target.value : 'newest';
      const results = document.getElementById('cloud-file-results');
      if (results) results.innerHTML = renderFiles(snapshot());
    }
    if (event.target.id === 'cloud-upload-input') { const files = Array.from(event.target.files || []); event.target.value = ''; uploadFiles(files); }
    if (event.target.id === 'cloud-resume-input') {
      const file = event.target.files?.[0];
      const id = resumeId;
      resumeId = null;
      event.target.value = '';
      if (file && id) perform(`resume:${id}`, () => M.cloud.resume(id, file));
    }
  });
  document.addEventListener('submit', event => {
    if (event.target.id !== 'cloud-archive-form') return;
    event.preventDefault();
    const form = event.target;
    if (!form.reportValidity()) return;
    const id = form.dataset.id;
    const familyId = new FormData(form).get('familyId');
    if (!fileFor(id) || !familiesFor(snapshot()).some(family => family.id === familyId)) return;
    const button = form.querySelector('button[type="submit"]');
    if (button) button.disabled = true;
    perform(`archive:${id}`, async () => {
      await M.cloud.toArchive(id, { familyId });
      M.closeModal();
      M.toast(snapshot().mode === 'server' ? 'Файл добавлен в семейный архив' : 'Связано с демоархивом · без повторной загрузки');
    }).finally(() => { if (button?.isConnected) button.disabled = false; });
  });
  let dragDepth = 0;
  function cloudDrag(event) {
    const screen = document.getElementById('cloud-screen');
    const hasFiles = Array.from(event.dataTransfer?.types || []).includes('Files');
    if (!screen || M.state.view !== 'cloud' || !hasFiles) return;
    event.preventDefault();
    if (event.type === 'dragenter') { dragDepth++; screen.classList.add('cloud-is-dragging'); }
    if (event.type === 'dragover' && event.dataTransfer) event.dataTransfer.dropEffect = 'copy';
    if (event.type === 'dragleave') { dragDepth = Math.max(0, dragDepth - 1); if (!dragDepth) screen.classList.remove('cloud-is-dragging'); }
    if (event.type === 'drop') { dragDepth = 0; screen.classList.remove('cloud-is-dragging'); uploadFiles(event.dataTransfer.files); }
  }
  ['dragenter', 'dragover', 'dragleave', 'drop'].forEach(type => document.addEventListener(type, cloudDrag));
  window.addEventListener('online', redraw);
  window.addEventListener('offline', redraw);
})();
