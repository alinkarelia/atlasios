(function () {
  'use strict';
  const M = window.M;
  if (!M) return;
  const esc = M.escape;
  const channelIds = new Set(['general', 'archives', 'digitize']);
  const tabId = crypto.randomUUID();
  const recordingLimit = {voice:300, circle:60};
  const urlCache = new Map();
  const loadingMedia = new Map();
  const failedMedia = new Set();
  const transcripts = new Map();
  let recording = null;
  let call = null;
  let picker = null;
  let observerScheduled = false;
  let channel = null;
  let mediaEpoch = 0;
  const overlay = document.createElement('div');
  overlay.id = 'media-root';
  document.body.append(overlay);
  const icons = {
    mic:'<path d="M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3Z"/><path d="M5 10v2a7 7 0 0 0 14 0v-2M12 19v3M8 22h8"/>',
    video:'<rect x="3" y="5" width="13" height="14" rx="3"/><path d="m16 9 5-3v12l-5-3"/>',
    phone:'<path d="m5 3 4 4-2 3a17 17 0 0 0 7 7l3-2 4 4-2 3C9 21 3 15 2 5Z"/>',
    end:'<path d="M3 16v-5a20 20 0 0 1 18 0v5h-5v-4a13 13 0 0 0-8 0v4Z"/>',
    stop:'<rect x="6" y="6" width="12" height="12" rx="2"/>',
    circle:'<circle cx="12" cy="12" r="9"/><path d="m10 8 6 4-6 4Z"/>',
    transcript:'<path d="M7 3h10a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2ZM9 8h6M9 12h6M9 16h4"/>',
    connection:'<path d="M5 18v-3M10 18v-6M15 18V9M20 18V5"/>'
  };
  function ico(name, size = 18) { return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${icons[name] || icons.mic}</svg>`; }
  const activeUser = id => M.state.users.find(user => user.id === id && user.active);
  function roomAllowed(room, userId) {
    if (!activeUser(userId) || typeof room !== 'string') return false;
    if (channelIds.has(room)) return true;
    const ids = room.split(':');
    return ids.length === 3 && ids[0] === 'dm' && ids[1] !== ids[2] && [ids[1],ids[2]].sort().join(':') === ids.slice(1).join(':') && ids.slice(1).includes(userId) && ids.slice(1).every(id => activeUser(id));
  }
  const time = value => { const seconds = Number.isFinite(value) ? Math.max(0,value) : 0; return `${Math.floor(seconds / 60)}:${String(Math.floor(seconds) % 60).padStart(2,'0')}`; };
  const stopTracks = stream => stream?.getTracks().forEach(track => { track.onended = null; track.stop(); });
  function recordValid(item) {
    return recording === item && M.state.currentUser === item.user && activeUser(item.user) && M.state.view === 'chat' && M.state.chatRoom === item.room && (M.state.activeMailboxId || item.user) === item.mailbox && roomAllowed(item.room, item.user) && (!M.allowedMailboxes || M.allowedMailboxes().includes(item.mailbox));
  }
  function callValid(item) {
    return call === item && M.state.currentUser === item.user && roomAllowed(item.room, item.user) && roomAllowed(item.room, item.peer);
  }
  function supportedMime(kind) {
    const types = kind === 'circle'
      ? ['video/mp4;codecs=avc1.42E01E,mp4a.40.2','video/mp4','video/webm;codecs=vp8,opus','video/webm']
      : ['audio/mp4','audio/webm;codecs=opus','audio/webm','audio/ogg;codecs=opus'];
    return types.find(type => MediaRecorder.isTypeSupported?.(type)) || '';
  }
  function permissionError(error) {
    if (error?.name === 'NotAllowedError' || error?.name === 'SecurityError') return 'Разрешите доступ к микрофону и камере в настройках браузера.';
    if (error?.name === 'NotFoundError') return 'Микрофон или камера не найдены.';
    if (error?.name === 'NotReadableError') return 'Микрофон или камера заняты другим приложением.';
    return 'Не удалось подключить микрофон или камеру. Проверьте разрешения и попробуйте ещё раз.';
  }
  function browserSupportsRecording() {
    return Boolean(window.isSecureContext && navigator.mediaDevices?.getUserMedia && typeof MediaRecorder === 'function');
  }
  function releaseRecording(item) {
    if (!item) return;
    clearInterval(item.timer);
    stopTracks(item.stream);
    item.stream = null;
    if (item.url) URL.revokeObjectURL(item.url);
    item.url = null;
  }
  function pauseUpload(id) {
    try { M.cloud?.pause?.(id)?.catch?.(() => {}); } catch { /* access can be revoked during cancellation */ }
  }
  function discardRecording(reason) {
    const item = recording;
    if (!item) return;
    item.discarded = true;
    recording = null;
    if (item.recorder?.state !== 'inactive') {
      try { item.recorder?.stop(); } catch { /* already ended */ }
    }
    releaseRecording(item);
    if (item.fileId) pauseUpload(item.fileId);
    renderOverlay();
    if (reason) M.toast(reason);
  }
  async function startRecording(kind) {
    if (recording || call) { M.toast('Завершите текущую запись или звонок.'); return; }
    if (!browserSupportsRecording()) { M.toast('Запись доступна в современном браузере по HTTPS. На iPhone используйте Safari с iOS 17 или новее.'); return; }
    const user = M.getUser(), room = M.state.chatRoom;
    if (!user?.active || !roomAllowed(room, user.id)) return;
    const item = recording = {id:crypto.randomUUID(), user:user.id, room, mailbox:M.state.activeMailboxId || user.id, kind, phase:'requesting', elapsed:0, chunks:[], total:0};
    picker = null;
    renderOverlay();
    try {
      const stream = await navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true, noiseSuppression:true, channelCount:1}, video:kind === 'circle' ? {facingMode:'user', width:{ideal:480,max:640}, height:{ideal:480,max:640}, frameRate:{ideal:24,max:30}} : false});
      if (!recordValid(item)) { stopTracks(stream); return; }
      item.stream = stream;
      const mime = supportedMime(kind);
      item.recorder = new MediaRecorder(stream, {...(mime ? {mimeType:mime} : {}), ...(kind === 'circle' ? {videoBitsPerSecond:600000,audioBitsPerSecond:32000} : {audioBitsPerSecond:32000})});
      item.recorder.ondataavailable = event => {
        if (recording === item && !item.discarded && event.data.size) {
          item.total += event.data.size;
          item.chunks.push(event.data);
          if (item.total > 75 * 1024 * 1024) stopRecording();
        }
      };
      item.recorder.onerror = () => { if (recording === item) discardRecording('Браузер прервал запись. Попробуйте ещё раз.'); };
      item.recorder.onstop = () => {
        clearInterval(item.timer);
        item.elapsed = Math.min(recordingLimit[kind], (Date.now() - item.startedAt) / 1000);
        stopTracks(item.stream);
        item.stream = null;
        if (item.discarded || !recordValid(item)) { releaseRecording(item); return; }
        const blob = new Blob(item.chunks, {type:item.recorder.mimeType || item.chunks[0]?.type || (kind === 'circle' ? 'video/webm' : 'audio/webm')});
        item.chunks = [];
        if (!blob.size || item.elapsed < .3) { discardRecording('Запись слишком короткая. Запишите сообщение ещё раз.'); return; }
        item.blob = blob;
        item.mime = blob.type;
        item.url = URL.createObjectURL(blob);
        item.phase = 'preview';
        renderOverlay();
      };
      stream.getTracks().forEach(track => { track.onended = () => { if (recording === item && item.phase === 'recording') discardRecording('Доступ к микрофону или камере прекращён.'); }; });
      item.recorder.start(1000);
      item.startedAt = Date.now();
      item.phase = 'recording';
      item.timer = setInterval(() => {
        if (!recordValid(item)) { discardRecording(); return; }
        item.elapsed = (Date.now() - item.startedAt) / 1000;
        const counter = overlay.querySelector('[data-record-counter]');
        if (counter) counter.textContent = time(item.elapsed);
        if (item.elapsed >= recordingLimit[kind]) stopRecording();
      },250);
      renderOverlay();
    } catch (error) {
      if (recording !== item) return;
      discardRecording(permissionError(error));
    }
  }
  function stopRecording() {
    const item = recording;
    if (!item || item.phase !== 'recording') return;
    item.phase = 'finishing';
    clearInterval(item.timer);
    try { item.recorder.stop(); } catch { discardRecording('Не удалось завершить запись.'); }
    renderOverlay();
  }
  function uploadMetadata(id) {
    try { return M.cloud.get?.(id) || M.cloud.snapshot?.()?.uploads?.find(upload => upload.id === id); }
    catch { return null; }
  }
  async function sendRecording() {
    const item = recording;
    if (!item || !['preview','error'].includes(item.phase) || !recordValid(item)) return;
    if (!M.cloud?.upload || !M.cloud.waitForFile || !M.cloud.registerChatReference || !M.sendChatMessage) { M.toast('Хранилище файлов ещё загружается. Попробуйте через несколько секунд.'); return; }
    const retrying = item.phase === 'error';
    item.phase = 'uploading';
    item.error = '';
    renderOverlay();
    try {
      if (!item.fileId) {
        const ext = item.mime.includes('mp4') ? (item.kind === 'circle' ? 'mp4' : 'm4a') : item.mime.includes('ogg') ? 'ogg' : 'webm';
        const filename = `${item.kind === 'circle' ? 'Видеокружок' : 'Голосовое'}-${new Date(item.startedAt).toISOString().replace(/[:.]/g,'-')}.${ext}`;
        item.file = new File([item.blob], filename, {type:item.mime});
        const result = await M.cloud.upload(item.file, {mailbox:item.mailbox, source:'chat'});
        item.fileId = typeof result === 'string' ? result : result?.id;
        if (!item.fileId) throw new Error('Не удалось создать файл в облаке.');
        if (!recordValid(item)) { pauseUpload(item.fileId); return; }
      }
      if (retrying && M.cloud.resume && ['paused','error','offline','needs-file'].includes(uploadMetadata(item.fileId)?.status)) {
        await M.cloud.resume(item.fileId,item.file);
        if (!recordValid(item)) { pauseUpload(item.fileId); return; }
      }
      const progressTimer = setInterval(() => {
        if (!recordValid(item)) return;
        const metadata = uploadMetadata(item.fileId);
        const output = overlay.querySelector('[data-record-upload]');
        if (output && metadata) {
          const uploaded = Number(metadata.uploadedBytes ?? metadata.uploaded ?? 0);
          const total = Number(metadata.size || item.blob.size);
          output.textContent = metadata.status === 'paused' ? 'Загрузка приостановлена. Продолжите её в облаке.' : metadata.status === 'offline' ? 'Нет сети. Продолжим с сохранённого места после подключения.' : `Сохраняем в облако${uploaded ? ` · ${Math.min(100, Math.round(uploaded / total * 100))}%` : '…'}`;
        }
      },500);
      try { await M.cloud.waitForFile(item.fileId); } finally { clearInterval(progressTimer); }
      if (!recordValid(item)) return;
      await M.cloud.registerChatReference(item.fileId, {room:item.room});
      if (!recordValid(item)) return;
      const sent = await M.sendChatMessage({text:'', room:item.room, userId:item.user, media:{fileId:item.fileId, kind:item.kind, duration:Math.round(item.elapsed * 10) / 10, mime:item.mime, transcript:null}});
      if (sent === false) throw new Error('Сообщение не отправлено. Проверьте доступ к разговору.');
      if (!recordValid(item)) return;
      recording = null;
      releaseRecording(item);
      renderOverlay();
      M.toast(item.kind === 'circle' ? 'Видеокружок отправлен' : 'Голосовое сообщение отправлено');
    } catch (error) {
      if (!recordValid(item)) return;
      item.phase = 'error';
      item.error = error?.message || 'Не удалось сохранить сообщение. Можно повторить отправку.';
      renderOverlay();
    }
  }
  function recordingHTML(item) {
    const title = item.kind === 'circle' ? 'Видеокружок' : 'Голосовое сообщение';
    const live = item.phase === 'recording';
    const preview = ['preview','error'].includes(item.phase);
    return `<div class="media-backdrop"><section class="media-recorder" role="dialog" aria-modal="true" aria-labelledby="media-record-title"><header><div><span class="media-eyebrow">СООБЩЕНИЕ КОМАНДЕ</span><h2 id="media-record-title">${title}</h2></div><button type="button" class="icon-button" data-action="media-record-cancel" aria-label="Отменить запись">${M.icon('close',18)}</button></header><div class="media-record-body">${item.kind === 'circle' ? `<video class="media-circle media-record-video" playsinline ${preview || item.phase === 'uploading' ? 'controls preload="metadata"' : 'autoplay muted'} aria-label="${preview ? 'Предпросмотр видеокружка' : 'Камера для записи видеокружка'}"></video>` : `<div class="media-wave ${live ? 'is-recording' : ''}" aria-hidden="true">${Array.from({length:25},()=>'<i></i>').join('')}</div>`}${item.kind === 'voice' && item.url ? '<audio class="media-record-audio" controls preload="metadata" aria-label="Предпросмотр голосового сообщения"></audio>' : ''}<div class="media-record-clock"><span class="${live ? 'media-live-dot' : ''}"></span><strong data-record-counter>${time(item.elapsed)}</strong><span>/ ${time(recordingLimit[item.kind])}</span></div><p class="media-record-status" role="status" data-record-upload>${item.phase === 'requesting' ? 'Ожидаем разрешение на микрофон' + (item.kind === 'circle' ? ' и камеру…' : '…') : live ? 'Запись идёт. Можно остановить и прослушать.' : item.phase === 'finishing' ? 'Завершаем запись…' : item.phase === 'uploading' ? 'Сохраняем в облако…' : 'Посмотрите или прослушайте запись перед отправкой.'}</p>${item.error ? `<p class="media-error" role="alert">${esc(item.error)}</p>` : ''}</div><footer><button class="button secondary" type="button" data-action="media-record-cancel">Отменить</button>${live ? `<button class="button primary" type="button" data-action="media-record-stop">${ico('stop',16)} Завершить запись</button>` : preview ? `<button class="button primary" type="button" data-action="media-record-send">${M.icon('send',16)} Отправить</button>` : '<button class="button primary" type="button" disabled>Подождите…</button>'}</footer><p class="media-local-note">Демо · запись хранится в облаке этого браузера. Кнопка «Отправить» добавит её в текущий разговор.</p></section></div>`;
  }
  function messageAllowed(message, user = M.state.currentUser) {
    return Boolean(message && activeUser(user) && roomAllowed(message.room, user) && M.state.view === 'chat' && M.state.chatRoom === message.room);
  }
  function findMediaMessage(id) {
    return M.state.chats?.messages?.find(message => message.id === id && messageAllowed(message) && message.media && ['voice','circle'].includes(message.media.kind));
  }
  M.renderChatMediaTools = function () {
    return `<button class="icon-button media-record-button" type="button" data-action="media-record-voice" aria-label="Записать голосовое сообщение" title="Голосовое сообщение">${ico('mic',19)}</button><button class="icon-button media-record-button" type="button" data-action="media-record-circle" aria-label="Записать видеокружок" title="Видеокружок до 1 минуты">${ico('circle',19)}</button>`;
  };
  M.renderMediaMessage = function (message) {
    const media = message.media;
    if (!media || !messageAllowed(message) || !['voice','circle'].includes(media.kind) || typeof media.fileId !== 'string') return '';
    const text = typeof media.transcript === 'string' ? media.transcript.slice(0,20000) : '';
    const status = transcripts.get(`${M.state.currentUser}:${message.id}`);
    queueMicrotask(syncMediaElements);
    return `<div class="chat-media-message ${media.kind === 'circle' ? 'chat-media-circle' : 'chat-media-voice'}" data-media-message="${esc(message.id)}">${media.kind === 'circle' ? `<video class="media-circle" controls playsinline preload="metadata" data-media-file="${esc(media.fileId)}" data-media-id="${esc(message.id)}" aria-label="Видеокружок"></video>` : `<div class="media-voice-heading">${ico('mic',15)}<strong>Голосовое сообщение</strong><span>${time(Number(media.duration)||0)}</span></div><audio controls preload="metadata" data-media-file="${esc(media.fileId)}" data-media-id="${esc(message.id)}" aria-label="Голосовое сообщение"></audio>`}<span class="media-file-status" data-media-file-status>Загружаем запись из облака…</span>${media.kind === 'voice' ? `${text ? `<div class="media-transcript"><span>${ico('transcript',14)} Расшифровка</span><p>${esc(text)}</p></div>` : `<button class="media-transcribe" type="button" data-action="media-transcribe" data-message-id="${esc(message.id)}" ${status?.pending ? 'disabled' : ''}>${ico('transcript',15)} ${status?.pending ? 'Распознаём…' : 'Расшифровать голосовое'}</button>`}${status?.error ? `<p class="media-transcript-note" role="status">${esc(status.error)}</p>` : ''}` : `<span class="media-circle-caption">Видеокружок · ${time(Number(media.duration)||0)}</span>`}</div>`;
  };
  async function syncMediaElements() {
    const ids = new Set();
    for (const element of document.querySelectorAll('[data-media-file][data-media-id]')) {
      const id = element.dataset.mediaId;
      const message = findMediaMessage(id);
      if (!message || message.media.fileId !== element.dataset.mediaFile) {
        if (element.hasAttribute('src')) { element.pause(); element.removeAttribute('src'); element.load(); }
        continue;
      }
      const key = `${M.state.currentUser}:${id}:${message.media.fileId}`;
      ids.add(key);
      const cached = urlCache.get(key);
      if (cached) {
        if (element.getAttribute('src') !== cached) element.src = cached;
        const status = element.parentElement.querySelector('[data-media-file-status]');
        if (status) status.hidden = true;
        continue;
      }
      if (failedMedia.has(key)) {
        const status = element.parentElement.querySelector('[data-media-file-status]');
        if (status && !status.querySelector('button')) status.innerHTML = `Запись недоступна. Проверьте файл и права в облаке. <button type="button" class="media-file-retry" data-action="media-file-retry" data-message-id="${esc(id)}">Повторить</button>`;
        continue;
      }
      if (loadingMedia.has(key) || !M.cloud?.resolveBlob) continue;
      const user = M.state.currentUser, epoch = mediaEpoch;
      const task = Promise.resolve().then(() => M.cloud.resolveBlob(message.media.fileId)).then(blob => {
        if (!(blob instanceof Blob) || !blob.size) throw new Error('Запись недоступна');
        const current = findMediaMessage(id);
        if (mediaEpoch !== epoch || M.state.currentUser !== user || current?.media.fileId !== message.media.fileId) return;
        const url = URL.createObjectURL(blob);
        urlCache.set(key,url);
        document.querySelectorAll('[data-media-file][data-media-id]').forEach(node => {
          if (node.dataset.mediaId === id && node.dataset.mediaFile === message.media.fileId) {
            node.src = url;
            const status = node.parentElement.querySelector('[data-media-file-status]');
            if (status) status.hidden = true;
          }
        });
      }).catch(() => {
        if (mediaEpoch !== epoch || M.state.currentUser !== user || !findMediaMessage(id)) return;
        failedMedia.add(key);
        const status = element.parentElement?.querySelector('[data-media-file-status]');
        if (status?.isConnected) status.innerHTML = `Запись недоступна. Проверьте файл и права в облаке. <button type="button" class="media-file-retry" data-action="media-file-retry" data-message-id="${esc(id)}">Повторить</button>`;
      }).finally(() => { if (loadingMedia.get(key) === task) loadingMedia.delete(key); });
      loadingMedia.set(key,task);
    }
    for (const [key,url] of urlCache) if (!ids.has(key)) { URL.revokeObjectURL(url); urlCache.delete(key); }
  }
  async function transcribeMessage(id) {
    const message = findMediaMessage(id);
    if (message?.media.kind !== 'voice') return;
    const user = M.state.currentUser, room = message.room, fileId = message.media.fileId, epoch = mediaEpoch;
    const key = `${user}:${id}`;
    if (transcripts.get(key)?.pending) return;
    const request = {pending:true};
    transcripts.set(key,request);
    M.render();
    try {
      let result;
      if (M.transcribeVoice) result = await M.transcribeVoice(fileId);
      else {
        if (!M.hostedSession?.csrf) throw new Error('Модель распознавания речи не подключена. Для расшифровки нужен сервер с вашим ИИ.');
        const response = await fetch('/api/media/transcribe', {method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json','X-CSRF-Token':M.hostedSession.csrf},body:JSON.stringify({fileId})});
        if (!response.ok) throw new Error(response.status === 503 || response.status === 404 ? 'Модель распознавания речи не подключена. Для расшифровки нужен сервер с вашим ИИ.' : 'Не удалось распознать запись. Попробуйте позже.');
        result = await response.json();
      }
      const current = findMediaMessage(id);
      if (mediaEpoch !== epoch || M.state.currentUser !== user || M.state.chatRoom !== room || current?.media.fileId !== fileId) return;
      const text = typeof result === 'string' ? result : result?.text;
      if (typeof text !== 'string' || !text.trim()) throw new Error('В записи не удалось распознать речь.');
      current.media.transcript = text.trim().slice(0,20000);
      transcripts.delete(key);
      M.persist();
      M.render();
    } catch (error) {
      if (mediaEpoch !== epoch || M.state.currentUser !== user || M.state.chatRoom !== room || !findMediaMessage(id)) return;
      transcripts.set(key,{pending:false,error:error.message || 'Не удалось распознать запись.'});
      M.render();
    } finally {
      if (transcripts.get(key) === request) transcripts.delete(key);
    }
  }

  // The demo transports signaling only between same-origin browser tabs. No public relay is used.
  function openSignaling() {
    try { if (typeof BroadcastChannel === 'function') { channel = new BroadcastChannel('living-memory-media-v1'); channel.onmessage = onSignal; } } catch { /* unsupported private browsing mode */ }
  }
  openSignaling();
  function signal(type, item, data = {}, toTab = item.remoteTab) {
    try { channel?.postMessage({version:1,type,id:item.id,from:item.user,to:item.peer,room:item.room,tab:tabId,...(toTab ? {toTab} : {}),...data}); } catch { /* pagehide can close signaling before pending ICE fires */ }
  }
  function signalValid(data) {
    return Boolean(data && data.version === 1 && typeof data.id === 'string' && /^[a-zA-Z0-9_-]{1,80}$/.test(data.id) && typeof data.tab === 'string' && /^[a-zA-Z0-9_-]{1,80}$/.test(data.tab) && data.tab !== tabId && (!data.toTab || data.toTab === tabId) && data.to === M.state.currentUser && data.from !== data.to && roomAllowed(data.room,data.to) && roomAllowed(data.room,data.from));
  }
  function validDescription(description, type) { return description && description.type === type && typeof description.sdp === 'string' && description.sdp.length > 0 && description.sdp.length < 100000; }
  function otherUsers(room) {
    return M.state.users.filter(user => user.active && user.id !== M.state.currentUser && roomAllowed(room,user.id));
  }
  M.renderChatCallActions = function () {
    return `<div class="chat-call-actions"><button class="icon-button" type="button" data-action="media-call-audio" aria-label="Позвонить участнику" title="Аудиозвонок">${ico('phone',18)}</button><button class="icon-button" type="button" data-action="media-call-video" aria-label="Видеозвонок участнику" title="Видеозвонок">${ico('video',20)}</button></div>`;
  };
  function openCallPicker(video) {
    if (call || recording) { M.toast('Завершите текущую запись или звонок.'); return; }
    if (!channel || typeof RTCPeerConnection !== 'function' || !navigator.mediaDevices?.getUserMedia || !window.isSecureContext) { M.toast('Звонки доступны в современном браузере по HTTPS.'); return; }
    if (!roomAllowed(M.state.chatRoom,M.state.currentUser)) return;
    picker = {room:M.state.chatRoom, user:M.state.currentUser, video};
    renderOverlay();
  }
  function pickerHTML(item) {
    return `<div class="media-backdrop"><section class="media-recorder media-call-picker" role="dialog" aria-modal="true" aria-labelledby="media-picker-title"><header><div><span class="media-eyebrow">НА СВЯЗИ С КОМАНДОЙ</span><h2 id="media-picker-title">${item.video ? 'Видеозвонок' : 'Аудиозвонок'}</h2></div><button class="icon-button" type="button" data-action="media-picker-close" aria-label="Закрыть">${M.icon('close',18)}</button></header><div class="media-picker-body"><p>Выберите одного коллегу для звонка.</p><div class="media-call-people">${otherUsers(item.room).map(user => `<button type="button" class="media-call-person" data-action="media-call-start" data-peer="${esc(user.id)}">${M.avatar(user.name,user.color,user.avatarUrl)}<span><strong>${esc(user.name)}</strong><small>${esc(user.email)}</small></span>${ico(item.video ? 'video' : 'phone',19)}</button>`).join('') || '<p class="muted">Других участников пока нет.</p>'}</div><div class="media-network-info">${ico('connection',17)}<span>Качество видео подстраивается под соединение. При сильных потерях включается только звук.</span></div><p class="media-local-note">Демо: звонки между вкладками этого браузера. Откройте вторую вкладку и войдите коллегой. Между устройствами нужен сервер сигнализации и TURN.</p></div></section></div>`;
  }
  function createCall(user,peer,room,video,incoming = false,id = crypto.randomUUID()) {
    return {id,user,peer,room,video,incoming,phase:incoming ? 'incoming' : 'requesting',status:incoming ? 'Входящий звонок' : 'Подключаем микрофон…',pendingCandidates:[],localCandidates:[],signaled:false,muted:false,cameraOff:false,tier:0,bad:0,good:0,statsPrevious:null};
  }
  function closeCall(reason = '', notify = true) {
    const item = call;
    if (!item) return;
    call = null;
    item.closed = true;
    if (notify) signal(item.phase === 'incoming' ? 'reject' : 'end',item);
    clearTimeout(item.timeout);
    clearTimeout(item.disconnectTimer);
    clearInterval(item.statsTimer);
    clearInterval(item.clockTimer);
    stopTracks(item.localStream);
    stopTracks(item.remoteStream);
    if (item.pc) { item.pc.ontrack = null; item.pc.onicecandidate = null; item.pc.onconnectionstatechange = null; item.pc.close(); }
    overlay.querySelectorAll('video').forEach(node => { node.srcObject = null; });
    renderOverlay();
    if (reason) M.toast(reason);
  }
  async function initializePeer(item) {
    const stream = await navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true,noiseSuppression:true,channelCount:1},video:item.video ? {facingMode:'user',width:{ideal:640,max:640},height:{ideal:480,max:480},frameRate:{ideal:24,max:30}} : false});
    if (!callValid(item)) { stopTracks(stream); return false; }
    item.localStream = stream;
    stream.getTracks().forEach(track => {
      track.enabled = track.kind === 'audio' ? !item.muted : !item.cameraOff && item.tier < 2;
      track.onended = () => { if (call === item) closeCall('Доступ к микрофону или камере прекращён.'); };
    });
    const pc = item.pc = new RTCPeerConnection({iceServers:[]});
    for (const track of stream.getTracks()) pc.addTrack(track,stream);
    for (const transceiver of pc.getTransceivers()) {
      if (transceiver.sender.track?.kind === 'audio' && transceiver.setCodecPreferences && typeof RTCRtpReceiver !== 'undefined') {
        try { const codecs = RTCRtpReceiver.getCapabilities('audio')?.codecs || []; transceiver.setCodecPreferences([...codecs].sort((a,b) => Number(b.mimeType.toLowerCase().includes('opus')) - Number(a.mimeType.toLowerCase().includes('opus')))); } catch { /* Safari may omit codec preference support */ }
      }
    }
    pc.onicecandidate = event => {
      if (!event.candidate || !callValid(item)) return;
      const candidate = event.candidate.toJSON();
      if (item.signaled) signal('candidate',item,{candidate});
      else if (item.localCandidates.length < 64) item.localCandidates.push(candidate);
    };
    pc.ontrack = event => {
      if (!callValid(item)) return;
      item.remoteStream = event.streams[0] || item.remoteStream || new MediaStream();
      if (!event.streams.length) item.remoteStream.addTrack(event.track);
      attachCallStreams();
    };
    pc.onconnectionstatechange = () => {
      if (!callValid(item)) { if (call === item) closeCall('',false); return; }
      if (pc.connectionState === 'connected') {
        clearTimeout(item.timeout);
        clearTimeout(item.disconnectTimer);
        item.disconnectTimer = null;
        item.connectedAt ||= Date.now();
        item.phase = 'connected';
        item.status = 'Вы на связи';
        if (!item.statsTimer) item.statsTimer = setInterval(() => collectStats(item),3000);
        if (!item.clockTimer) item.clockTimer = setInterval(() => {
          const timer = overlay.querySelector('[data-call-duration]');
          if (timer) timer.textContent = time((Date.now() - item.connectedAt) / 1000);
          if (!callValid(item)) closeCall('',false);
        },1000);
        renderOverlay();
      } else if (['disconnected','failed'].includes(pc.connectionState)) {
        item.phase = 'reconnecting'; item.status = 'Связь прервалась. Пробуем восстановить…';
        renderOverlay();
        startReconnect(item);
      }
    };
    await applyQuality(item);
    if (!callValid(item)) return false;
    attachCallStreams();
    return true;
  }
  async function startCall(peer) {
    const source = picker;
    if (!source || source.user !== M.state.currentUser || source.room !== M.state.chatRoom || !roomAllowed(source.room,source.user) || !otherUsers(source.room).some(user => user.id === peer)) return;
    picker = null;
    const item = call = createCall(source.user,peer,source.room,source.video);
    renderOverlay();
    try {
      if (!await initializePeer(item) || !callValid(item)) return;
      const offer = await item.pc.createOffer();
      if (!callValid(item)) return;
      await item.pc.setLocalDescription(offer);
      if (!callValid(item)) return;
      item.phase = 'ringing'; item.status = 'Ожидаем ответа коллеги…';
      signal('invite',item,{description:item.pc.localDescription.toJSON(),video:item.video},null);
      flushLocalCandidates(item);
      item.timeout = setTimeout(() => { if (call === item) closeCall('Коллега не ответил. В демо он должен открыть вторую вкладку.'); },45000);
      renderOverlay();
    } catch (error) { if (call === item) closeCall(permissionError(error)); }
  }
  async function acceptCall() {
    const item = call;
    if (!item || item.phase !== 'incoming' || !callValid(item)) return;
    clearTimeout(item.timeout);
    item.phase = 'requesting'; item.status = 'Подключаем микрофон…';
    item.timeout = setTimeout(() => { if (call === item) closeCall('Не удалось подключить микрофон. Проверьте разрешение и позвоните ещё раз.'); },45000);
    renderOverlay();
    try {
      if (!await initializePeer(item) || !callValid(item)) return;
      if (!await setRemoteDescription(item,item.offer)) return;
      const answer = await item.pc.createAnswer();
      if (!callValid(item)) return;
      await item.pc.setLocalDescription(answer);
      if (!callValid(item)) return;
      item.phase = 'connecting'; item.status = 'Соединяем…';
      signal('answer',item,{description:item.pc.localDescription.toJSON()});
      flushLocalCandidates(item);
      clearTimeout(item.timeout);
      item.timeout = setTimeout(() => { if (call === item) closeCall('Не удалось установить связь между вкладками.'); },30000);
      renderOverlay();
    } catch (error) { if (call === item) closeCall(permissionError(error)); }
  }
  function flushLocalCandidates(item) {
    item.signaled = true;
    while (item.localCandidates.length && callValid(item)) signal('candidate',item,{candidate:item.localCandidates.shift()});
  }
  async function flushCandidates(item) {
    while (item.pendingCandidates.length && callValid(item) && item.pc.remoteDescription) {
      try { await item.pc.addIceCandidate(item.pendingCandidates.shift()); } catch { /* candidate can expire during reconnect */ }
    }
  }
  async function setRemoteDescription(item,description) {
    item.applyingDescription = true;
    try { await item.pc.setRemoteDescription(description); }
    finally { item.applyingDescription = false; }
    if (!callValid(item)) return false;
    await flushCandidates(item);
    return callValid(item);
  }
  async function onSignal(event) {
    const data = event.data;
    if (!channel || !signalValid(data)) return;
    if (data.type === 'invite') {
      if (!validDescription(data.description,'offer') || typeof data.video !== 'boolean') return;
      if (call || recording) {
        channel.postMessage({version:1,type:'busy',id:data.id,from:M.state.currentUser,to:data.from,room:data.room,tab:tabId,toTab:data.tab});
        return;
      }
      const item = call = createCall(data.to,data.from,data.room,data.video,true,data.id);
      item.remoteTab = data.tab;
      item.offer = data.description;
      item.timeout = setTimeout(() => { if (call === item) closeCall('Пропущенный звонок'); },45000);
      picker = null;
      renderOverlay();
      return;
    }
    const item = call;
    if (!item || item.id !== data.id || item.peer !== data.from || item.room !== data.room || (item.remoteTab && item.remoteTab !== data.tab) || !callValid(item)) return;
    if (data.type === 'claimed' && item.incoming && typeof data.selectedTab === 'string' && data.selectedTab !== tabId) {
      closeCall('Звонок принят в другой вкладке.',false);
      return;
    }
    if (['reject','busy','end'].includes(data.type)) {
      closeCall(data.type === 'busy' ? 'Коллега сейчас занят.' : data.type === 'reject' ? 'Коллега отклонил звонок.' : 'Звонок завершён',false);
      return;
    }
    try {
      if (data.type === 'answer' && !item.incoming && item.pc && item.phase === 'ringing' && validDescription(data.description,'answer')) {
        item.remoteTab = data.tab;
        signal('claimed',item,{selectedTab:data.tab},null);
        clearTimeout(item.timeout);
        item.phase = 'connecting'; item.status = 'Соединяем…';
        if (!await setRemoteDescription(item,data.description)) return;
        item.timeout = setTimeout(() => { if (call === item) closeCall('Не удалось установить связь между вкладками.'); },30000);
        renderOverlay();
      } else if (data.type === 'candidate') {
        const candidate = data.candidate;
        if (!candidate || typeof candidate.candidate !== 'string' || candidate.candidate.length > 4000 || item.pendingCandidates.length >= 64) return;
        if (item.pc?.remoteDescription && !item.applyingDescription) { try { await item.pc.addIceCandidate(candidate); } catch { /* stale ICE */ } }
        else item.pendingCandidates.push(candidate);
      } else if (data.type === 'reoffer' && item.incoming && item.pc && validDescription(data.description,'offer')) {
        if (!await setRemoteDescription(item,data.description)) return;
        const answer = await item.pc.createAnswer();
        if (!callValid(item)) return;
        item.signaled = false;
        await item.pc.setLocalDescription(answer);
        if (callValid(item)) { signal('reanswer',item,{description:item.pc.localDescription.toJSON()}); flushLocalCandidates(item); }
      } else if (data.type === 'reanswer' && !item.incoming && item.pc && validDescription(data.description,'answer')) {
        await setRemoteDescription(item,data.description);
      }
    } catch { if (call === item) closeCall('Соединение не удалось. Попробуйте позвонить ещё раз.'); }
  }
  function startReconnect(item) {
    if (!callValid(item) || item.disconnectTimer) return;
    item.disconnectTimer = setTimeout(() => { if (call === item) closeCall('Соединение не восстановилось. Позвоните снова, когда сеть появится.'); },30000);
    if (!item.incoming && navigator.onLine !== false) restartIce(item);
  }
  async function restartIce(item) {
    if (!callValid(item) || !item.pc || !item.remoteTab || item.restarting || item.pc.signalingState !== 'stable') return;
    item.restarting = true;
    try {
      const offer = await item.pc.createOffer({iceRestart:true});
      if (!callValid(item)) return;
      item.signaled = false;
      await item.pc.setLocalDescription(offer);
      if (callValid(item)) { signal('reoffer',item,{description:item.pc.localDescription.toJSON()}); flushLocalCandidates(item); }
    } catch { /* disconnect timer will end an unrecoverable session */ }
    finally { item.restarting = false; }
  }
  function adaptivePolicy(metrics, previous = {tier:0,bad:0,good:0}) {
    const lossKnown = Number.isFinite(metrics.loss) && metrics.loss >= 0;
    const rttKnown = Number.isFinite(metrics.rtt) && metrics.rtt >= 0;
    const loss = lossKnown ? metrics.loss : 0;
    const rtt = rttKnown ? metrics.rtt : 0;
    const severe = loss > .20 || rtt > 1.2;
    const weak = severe || loss > .08 || rtt > .65;
    const good = (lossKnown || rttKnown) && (!lossKnown || loss < .03) && (!rttKnown || rtt < .35);
    let {tier,bad,good:goodCount} = previous;
    tier = Math.max(0,Math.min(2,tier || 0));
    if (!lossKnown && !rttKnown) return {tier,bad:bad || 0,good:goodCount || 0};
    if (weak) {
      bad = (bad || 0) + 1; goodCount = 0;
      if (bad >= 2) { tier = severe ? Math.min(2,tier + 1) : Math.max(1,tier); bad = 0; }
    } else if (good) {
      goodCount = (goodCount || 0) + 1; bad = 0;
      if (goodCount >= 4) { tier = Math.max(0,tier - 1); goodCount = 0; }
    } else { bad = 0; goodCount = 0; }
    return {tier,bad,good:goodCount};
  }
  async function collectStats(item) {
    if (!callValid(item) || !item.pc || item.collectingStats) return;
    item.collectingStats = true;
    try {
      const report = await item.pc.getStats();
      if (!callValid(item)) return;
      let lost = 0, received = 0, rtt = null, outboundLoss = null, observed = false;
      report.forEach(entry => {
        if (entry.type === 'inbound-rtp' && !entry.isRemote && Number.isFinite(entry.packetsReceived)) { lost += Math.max(0,entry.packetsLost || 0); received += entry.packetsReceived; observed = true; }
        if (entry.type === 'candidate-pair' && entry.state === 'succeeded' && (entry.nominated || entry.selected) && Number.isFinite(entry.currentRoundTripTime)) rtt = entry.currentRoundTripTime;
        if (entry.type === 'remote-inbound-rtp') {
          if (Number.isFinite(entry.roundTripTime)) rtt = Math.max(rtt || 0,entry.roundTripTime);
          if (Number.isFinite(entry.fractionLost) && entry.fractionLost >= 0) outboundLoss = Math.max(outboundLoss || 0,Math.min(1,entry.fractionLost));
        }
      });
      const previous = item.statsPrevious;
      item.statsPrevious = {lost,received};
      if (!observed && rtt === null && outboundLoss === null) return;
      const total = previous ? Math.max(0,lost - previous.lost) + Math.max(0,received - previous.received) : 0;
      const loss = outboundLoss ?? (total ? Math.max(0,lost - previous.lost) / total : null);
      const next = adaptivePolicy({loss,rtt},item);
      const changed = next.tier !== item.tier;
      Object.assign(item,next);
      if (changed) { await applyQuality(item); if (callValid(item)) renderOverlay(); }
    } catch { /* getStats isn't complete on every iOS release */ }
    finally { item.collectingStats = false; }
  }
  async function applyQuality(item) {
    if (!callValid(item) || !item.pc) return;
    item.localStream?.getVideoTracks().forEach(track => { track.enabled = !item.cameraOff && item.tier < 2; });
    for (const sender of item.pc.getSenders()) {
      if (!sender.track || !sender.setParameters) continue;
      try {
        const params = sender.getParameters();
        params.encodings ||= [{}];
        for (const encoding of params.encodings) {
          if (sender.track.kind === 'video') { encoding.active = !item.cameraOff && item.tier < 2; encoding.maxBitrate = item.tier === 0 ? 600000 : 180000; encoding.scaleResolutionDownBy = item.tier === 0 ? 1 : 2; encoding.maxFramerate = item.tier === 0 ? 24 : 15; }
          else encoding.maxBitrate = item.tier === 0 ? 32000 : item.tier === 1 ? 24000 : 16000;
        }
        await sender.setParameters(params);
      } catch { /* built-in WebRTC congestion control still runs */ }
    }
  }
  function callHTML(item) {
    const peer = activeUser(item.peer);
    if (!peer) return '';
    const incoming = item.phase === 'incoming';
    const quality = !item.video ? 'Аудиозвонок' : item.tier === 2 ? 'Только звук · сеть слабая' : item.tier === 1 ? 'Экономия · видео 240p' : 'Адаптивное видео · до 480p';
    return `<div class="media-backdrop media-call-backdrop"><section class="media-call-panel" role="dialog" aria-modal="true" aria-labelledby="media-call-title"><header><span class="media-call-brand">ЖИВАЯ ПАМЯТЬ <i>·</i> КОМАНДА</span><span class="media-call-demo">Демо между вкладками</span></header><div class="media-call-stage ${item.video && !incoming ? 'has-video' : ''}">${item.video && !incoming ? '<video class="media-call-remote" autoplay playsinline aria-label="Видео коллеги"></video><video class="media-call-local" autoplay muted playsinline aria-label="Ваше видео"></video>' : ''}<div class="media-call-persona">${M.avatar(peer.name,peer.color,peer.avatarUrl)}<h2 id="media-call-title">${esc(peer.name)}</h2><p class="media-call-status" role="status">${esc(item.status)}</p><span class="media-call-duration" data-call-duration>${item.connectedAt ? time((Date.now() - item.connectedAt) / 1000) : incoming ? (item.video ? 'Видеозвонок' : 'Аудиозвонок') : 'Звонок коллеге'}</span></div>${!item.video && !incoming ? '<video class="media-call-remote media-audio-only" autoplay playsinline aria-label="Аудио коллеги"></video>' : ''}<button class="media-call-listen" type="button" data-action="media-call-listen" hidden>${ico('phone',15)} Включить звук коллеги</button></div><div class="media-call-quality">${ico('connection',15)}<span>${quality}</span>${item.phase === 'reconnecting' ? '<strong>Восстанавливаем связь</strong>' : ''}</div><div class="media-call-controls">${incoming ? `<button type="button" class="media-control media-control-end" data-action="media-call-reject">${ico('end',23)}<span>Отклонить</span></button><button type="button" class="media-control media-control-accept" data-action="media-call-accept">${ico(item.video ? 'video' : 'phone',23)}<span>Ответить</span></button>` : `<button type="button" class="media-control ${item.muted ? 'is-off' : ''}" data-action="media-call-mute" aria-pressed="${item.muted}">${ico('mic',22)}<span>${item.muted ? 'Включить микрофон' : 'Микрофон'}</span></button>${item.video ? `<button type="button" class="media-control ${item.cameraOff || item.tier === 2 ? 'is-off' : ''}" data-action="media-call-camera" aria-pressed="${item.cameraOff}">${ico('video',23)}<span>${item.cameraOff ? 'Включить камеру' : item.tier === 2 ? 'Видео на паузе' : 'Камера'}</span></button>` : ''}<button type="button" class="media-control media-control-end" data-action="media-call-end">${ico('end',23)}<span>Завершить</span></button>`}</div><p class="media-call-footnote">При полном обрыве интернета звонок прерывается. Между устройствами потребуется сервер сигнализации и TURN.</p></section></div>`;
  }
  function attachCallStreams() {
    if (!call || !callValid(call)) return;
    const local = overlay.querySelector('.media-call-local'), remote = overlay.querySelector('.media-call-remote');
    if (local && local.srcObject !== call.localStream) { local.srcObject = call.localStream || null; local.play()?.catch(() => {}); }
    if (remote && remote.srcObject !== call.remoteStream) {
      remote.srcObject = call.remoteStream || null;
      const button = overlay.querySelector('.media-call-listen');
      remote.onplaying = () => { if (button) button.hidden = true; };
      if (call.remoteStream) remote.play()?.catch(() => { if (button) button.hidden = false; });
    }
    if (remote && call.remoteStream) overlay.querySelector('.media-call-stage')?.classList.add('has-remote-stream');
  }
  function renderOverlay() {
    const focusedAction = overlay.contains(document.activeElement) ? document.activeElement.dataset.action : null;
    overlay.querySelectorAll('video,audio').forEach(element => { element.pause(); element.srcObject = null; });
    overlay.innerHTML = recording ? recordingHTML(recording) : call ? callHTML(call) : picker ? pickerHTML(picker) : '';
    if (recording) {
      const video = overlay.querySelector('.media-record-video');
      const audio = overlay.querySelector('.media-record-audio');
      if (video) {
        if (recording.url) { video.src = recording.url; video.muted = false; }
        else if (recording.stream) { video.srcObject = recording.stream; video.play()?.catch(() => {}); }
      }
      if (audio && recording.url) audio.src = recording.url;
    }
    if (call) attachCallStreams();
    if (focusedAction) [...overlay.querySelectorAll('[data-action]')].find(node => node.dataset.action === focusedAction)?.focus({preventScroll:true});
    else if (overlay.innerHTML) queueMicrotask(() => overlay.querySelector('button')?.focus({preventScroll:true}));
  }
  M.onMediaAction = function (action, element) {
    if (!action?.startsWith('media-')) return false;
    switch (action) {
      case 'media-record-voice': startRecording('voice'); break;
      case 'media-record-circle': startRecording('circle'); break;
      case 'media-record-stop': stopRecording(); break;
      case 'media-record-cancel': discardRecording(); break;
      case 'media-record-send': sendRecording(); break;
      case 'media-transcribe': transcribeMessage(element.dataset.messageId); break;
      case 'media-file-retry': {
        const message = findMediaMessage(element.dataset.messageId);
        if (message) failedMedia.delete(`${M.state.currentUser}:${message.id}:${message.media.fileId}`);
        syncMediaElements();
        break;
      }
      case 'media-call-listen': overlay.querySelector('.media-call-remote')?.play()?.catch(() => M.toast('Браузер не разрешил воспроизведение. Проверьте настройки звука.')); break;
      case 'media-call-audio': openCallPicker(false); break;
      case 'media-call-video': openCallPicker(true); break;
      case 'media-picker-close': picker = null; renderOverlay(); break;
      case 'media-call-start': startCall(element.dataset.peer); break;
      case 'media-call-accept': acceptCall(); break;
      case 'media-call-reject': case 'media-call-end': closeCall(); break;
      case 'media-call-mute':
        if (call && callValid(call)) { call.muted = !call.muted; call.localStream?.getAudioTracks().forEach(track => { track.enabled = !call.muted; }); renderOverlay(); }
        break;
      case 'media-call-camera':
        if (call && callValid(call)) { call.cameraOff = !call.cameraOff; call.localStream?.getVideoTracks().forEach(track => { track.enabled = !call.cameraOff && call.tier < 2; }); applyQuality(call); renderOverlay(); }
        break;
      default: return false;
    }
    return true;
  };
  overlay.addEventListener('click',event => {
    const element = event.target.closest('[data-action]');
    if (element) { event.stopPropagation(); M.onMediaAction(element.dataset.action,element); }
  });
  overlay.addEventListener('keydown',event => {
    if (event.key === 'Escape') { event.stopPropagation(); if (recording) discardRecording(); else if (call) closeCall(); else { picker = null; renderOverlay(); } }
    if (event.key === 'Tab') {
      const buttons = [...overlay.querySelectorAll('button:not(:disabled),audio[controls],video[controls]')];
      if (!buttons.length) return;
      const first = buttons[0], last = buttons.at(-1);
      if (event.shiftKey && document.activeElement === first) { last.focus(); event.preventDefault(); }
      else if (!event.shiftKey && document.activeElement === last) { first.focus(); event.preventDefault(); }
    }
  });
  function sync() {
    if (recording && !recordValid(recording)) discardRecording();
    if (call && !callValid(call)) closeCall('',false);
    if (picker && (picker.user !== M.state.currentUser || picker.room !== M.state.chatRoom || !roomAllowed(picker.room,picker.user))) { picker = null; renderOverlay(); }
    syncMediaElements();
  }
  function cleanup() {
    mediaEpoch++;
    discardRecording(); closeCall(); picker = null;
    document.querySelectorAll('[data-media-file][data-media-id]').forEach(element => { element.pause(); element.removeAttribute('src'); element.load(); });
    for (const url of urlCache.values()) URL.revokeObjectURL(url);
    urlCache.clear(); loadingMedia.clear(); transcripts.clear(); failedMedia.clear(); renderOverlay();
  }
  M.media = {sync,cleanup,roomAllowed,adaptivePolicy,supportedMime};
  const observer = new MutationObserver(() => {
    if (observerScheduled) return;
    observerScheduled = true;
    queueMicrotask(() => { observerScheduled = false; sync(); });
  });
  const app = document.getElementById('app');
  if (app) observer.observe(app,{childList:true,subtree:true});
  window.addEventListener('offline',() => {
    if (call) { call.phase = 'reconnecting'; call.status = 'Нет сети. Ждём восстановления соединения…'; renderOverlay(); startReconnect(call); }
  });
  window.addEventListener('online',() => { if (call?.phase === 'reconnecting') restartIce(call); });
  window.addEventListener('pagehide',() => { cleanup(); channel?.close(); channel = null; });
  window.addEventListener('pageshow',() => { if (!channel) openSignaling(); });
  setInterval(() => {
    if ((recording && !recordValid(recording)) || (call && !callValid(call))) sync();
  },1000);
})();
