(function () {
  'use strict';

  const M = window.M;
  if (!M) return;
  const escape = M.escape;
  const icon = (name, size = 20) => M.icon(name, size);
  const seedAddresses = {
    u1: 'elena@memory.example',
    u2: 'anna@memory.example',
    u3: 'mikhail@memory.example',
    u4: 'darya@memory.example'
  };
  const PBKDF_ITERATIONS = 210000;
  let teamSearch = '';
  let loginError = '';
  let loginBusy = false;
  let createBusy = false;
  let avatarBusy = false;
  let avatarBusyUser = null;
  let avatarRequest = 0;
  const AVATAR_MAX_SOURCE_BYTES = 2 * 1024 * 1024;
  const AVATAR_MAX_OUTPUT_LENGTH = 150 * 1024;
  const AVATAR_COLORS = { sage: 'Шалфей', blue: 'Небо', peach: 'Персик', lavender: 'Лаванда' };

  function userInitials(user) {
    return M.avatar(user.name, user.color || 'sage', user.avatarUrl || '');
  }

  function avatarError(message) {
    const error = document.getElementById('avatar-error');
    if (!error) return;
    error.textContent = message;
    error.classList.toggle('visible', Boolean(message));
  }

  function readImageBytes(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(new Uint8Array(reader.result));
      reader.onerror = () => reject(new Error('Не удалось прочитать изображение. Выберите файл ещё раз.'));
      reader.onabort = () => reject(new Error('Загрузка изображения прервана.'));
      reader.readAsArrayBuffer(file);
    });
  }

  function sourceImageSize(bytes, mime) {
    const matches = (offset, values) => values.every((value, index) => bytes[offset + index] === value);
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let size = null;
    if (mime === 'image/png' && bytes.length >= 24 && matches(0, [137, 80, 78, 71, 13, 10, 26, 10]) && matches(12, [73, 72, 68, 82])) {
      size = [view.getUint32(16), view.getUint32(20)];
    } else if (mime === 'image/jpeg' && bytes.length >= 4 && matches(0, [255, 216, 255])) {
      // Inspect the SOF header before decoding, so oversized compressed images are rejected early.
      const frames = [192, 193, 194, 195, 197, 198, 199, 201, 202, 203, 205, 206, 207];
      let offset = 2;
      while (offset < bytes.length) {
        if (bytes[offset++] !== 255) break;
        while (bytes[offset] === 255) offset++;
        const marker = bytes[offset++];
        if (marker === 217 || marker === 218) break;
        if (marker === 1 || (marker >= 208 && marker <= 215)) continue;
        if (offset + 2 > bytes.length) break;
        const length = view.getUint16(offset);
        if (length < 2 || offset + length > bytes.length) break;
        if (frames.includes(marker) && length >= 8) {
          size = [view.getUint16(offset + 5), view.getUint16(offset + 3)];
          break;
        }
        offset += length;
      }
    } else if (mime === 'image/webp' && bytes.length >= 20 && matches(0, [82, 73, 70, 70]) && matches(8, [87, 69, 66, 80])) {
      let offset = 12;
      while (offset + 8 <= bytes.length) {
        const length = view.getUint32(offset + 4, true);
        const start = offset + 8;
        if (start + length > bytes.length) break;
        if (matches(offset, [86, 80, 56, 88]) && length >= 10) {
          size = [1 + bytes[start + 4] + (bytes[start + 5] << 8) + (bytes[start + 6] << 16), 1 + bytes[start + 7] + (bytes[start + 8] << 8) + (bytes[start + 9] << 16)];
          break;
        }
        if (matches(offset, [86, 80, 56, 32]) && length >= 10 && matches(start + 3, [157, 1, 42])) {
          size = [view.getUint16(start + 6, true) & 16383, view.getUint16(start + 8, true) & 16383];
          break;
        }
        if (matches(offset, [86, 80, 56, 76]) && length >= 5 && bytes[start] === 47) {
          size = [1 + bytes[start + 1] + ((bytes[start + 2] & 63) << 8), 1 + (bytes[start + 2] >> 6) + (bytes[start + 3] << 2) + ((bytes[start + 4] & 15) << 10)];
          break;
        }
        offset = start + length + (length % 2);
      }
    }
    if (!size || !size[0] || !size[1]) throw new Error('Выберите корректное изображение PNG, JPEG или WebP.');
    if (size[0] > 8192 || size[1] > 8192 || size[0] * size[1] > 40000000) {
      throw new Error('Изображение слишком большое. Уменьшите его до 8192 пикселей по стороне и 40 мегапикселей.');
    }
    return size;
  }

  async function prepareAvatar(file) {
    if (!['image/png', 'image/jpeg', 'image/webp'].includes(file.type)) {
      throw new Error('Поддерживаются PNG, JPEG и WebP.');
    }
    if (!file.size || file.size > AVATAR_MAX_SOURCE_BYTES) throw new Error('Выберите изображение размером до 2 МБ.');
    const bytes = await readImageBytes(file);
    sourceImageSize(bytes, file.type);
    const url = URL.createObjectURL(file);
    try {
      const image = await new Promise((resolve, reject) => {
        const candidate = new Image();
        const timeout = setTimeout(() => {
          candidate.onload = null;
          candidate.onerror = null;
          candidate.src = '';
          reject(new Error('Не удалось открыть изображение. Попробуйте другой файл.'));
        }, 15000);
        candidate.onload = () => { clearTimeout(timeout); resolve(candidate); };
        candidate.onerror = () => { clearTimeout(timeout); reject(new Error('Не удалось открыть изображение. Попробуйте другой файл.')); };
        candidate.decoding = 'async';
        candidate.src = url;
      });
      if (!image.naturalWidth || !image.naturalHeight || image.naturalWidth > 8192 || image.naturalHeight > 8192 || image.naturalWidth * image.naturalHeight > 40000000) {
        throw new Error('Размер изображения не подходит. Выберите фото меньшего размера.');
      }
      const canvas = document.createElement('canvas');
      canvas.width = canvas.height = 256;
      const context = canvas.getContext('2d');
      if (!context) throw new Error('Этот браузер не смог подготовить фото. Можно выбрать цвет инициалов.');
      context.fillStyle = '#e7ece3';
      context.fillRect(0, 0, 256, 256);
      const side = Math.min(image.naturalWidth, image.naturalHeight);
      context.drawImage(image, (image.naturalWidth - side) / 2, (image.naturalHeight - side) / 2, side, side, 0, 0, 256, 256);
      const result = canvas.toDataURL('image/jpeg', 0.82);
      if (!/^data:image\/jpeg;base64,[A-Za-z0-9+/]+=*$/.test(result) || result.length > AVATAR_MAX_OUTPUT_LENGTH) {
        throw new Error('Не удалось подготовить компактный аватар. Попробуйте другое фото.');
      }
      return result;
    } finally {
      URL.revokeObjectURL(url);
    }
  }

  function persistAvatar(user, avatarUrl, color = user.color) {
    const previousAvatar = user.avatarUrl;
    const previousColor = user.color;
    if (avatarUrl) user.avatarUrl = avatarUrl;
    else delete user.avatarUrl;
    user.color = color;
    if (M.persist() === false) {
      if (previousAvatar) user.avatarUrl = previousAvatar;
      else delete user.avatarUrl;
      user.color = previousColor;
      throw new Error('В браузере не осталось места. Освободите хранилище и повторите попытку.');
    }
  }

  function b64(bytes) {
    let binary = '';
    bytes.forEach(byte => { binary += String.fromCharCode(byte); });
    return btoa(binary);
  }

  function unb64(value) {
    return Uint8Array.from(atob(value), char => char.charCodeAt(0));
  }

  async function passwordHash(password, salt, iterations = PBKDF_ITERATIONS) {
    if (!window.crypto || !window.crypto.subtle) {
      throw new Error('Вход доступен при открытии прототипа через HTTPS или localhost.');
    }
    const key = await crypto.subtle.importKey(
      'raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveBits']
    );
    const bits = await crypto.subtle.deriveBits({
      name: 'PBKDF2', salt: unb64(salt), iterations, hash: 'SHA-256'
    }, key, 256);
    return b64(new Uint8Array(bits));
  }

  async function setPassword(user, password) {
    const salt = b64(crypto.getRandomValues(new Uint8Array(16)));
    const hash = await passwordHash(password, salt);
    user.salt = salt;
    user.passwordHash = hash;
    user.passwordIterations = PBKDF_ITERATIONS;
  }

  async function verifyPassword(user, password) {
    if (!user.passwordHash || !user.salt) {
      if (seedAddresses[user.id] !== user.email) return false;
      await setPassword(user, 'memory2026');
      M.persist();
    }
    const candidate = await passwordHash(password, user.salt, user.passwordIterations || PBKDF_ITERATIONS);
    const expected = user.passwordHash;
    let difference = candidate.length ^ expected.length;
    for (let index = 0; index < Math.max(candidate.length, expected.length); index++) {
      difference |= (candidate.charCodeAt(index) || 0) ^ (expected.charCodeAt(index) || 0);
    }
    return difference === 0;
  }

  function isAdmin() {
    const user = M.getUser();
    return Boolean(user && user.active && user.role === 'admin');
  }

  function renderTeamRows() {
    const query = teamSearch.toLocaleLowerCase('ru');
    const users = M.state.users.filter(user =>
      `${user.name} ${user.email}`.toLocaleLowerCase('ru').includes(query)
    );
    if (!users.length) {
      return '<div class="team-empty">Никого не нашли. Попробуйте другое имя или адрес.</div>';
    }
    return users.map(user => {
      const current = user.id === M.state.currentUser;
      return `<div class="team-row">
        <div class="team-cell team-person">${userInitials(user)}<div><strong>${escape(user.name)}${current ? ' <span class="you-label">это вы</span>' : ''}</strong><span class="team-mobile-email">${escape(M.displayEmail?M.displayEmail(user.email):user.email)}</span></div></div>
        <div class="team-cell team-email">${escape(M.displayEmail?M.displayEmail(user.email):user.email)}</div>
        <div class="team-cell"><span class="role-badge${user.role === 'admin' ? ' admin' : ''}">${user.role === 'admin' ? 'Администратор' : 'Участник'}</span></div>
        <div class="team-cell"><span class="status-pill${user.active ? ' active' : ' paused'}"><i></i>${user.active ? 'Активен' : 'Приостановлен'}</span></div>
        <div class="team-cell team-actions">${current
          ? '<span class="muted">Ваша учётная запись</span>'
          : `<button type="button" class="button subtle small" data-action="toggle-user" data-user-id="${escape(user.id)}" aria-label="${user.active ? 'Приостановить доступ' : 'Возобновить доступ'}: ${escape(user.name)}">${user.active ? 'Приостановить' : 'Возобновить'}</button>`}</div>
      </div>`;
    }).join('');
  }

  M.renderAdmin = function () {
    if (!isAdmin()) {
      return `<section class="admin-view"><div class="settings-card"><h2>Управление командой</h2><p class="muted">Доступ к этому разделу есть у администратора проекта.</p></div></section>`;
    }
    const users = M.state.users;
    const stats = [
      { label: 'Участников команды', value: users.length, name: 'users', note: 'Вместе сохраняем истории' },
      { label: 'Активных ящиков', value: users.filter(user => user.active).length, name: 'mail', note: 'Готовы к работе' },
      { label: 'Администраторов', value: users.filter(user => user.active && user.role === 'admin').length, name: 'shield', note: 'Управляют доступом' },
      { label: 'Писем в прототипе', value: M.state.mails.length, name: 'archive', note: 'Личные и общие переписки' }
    ];
    return `<section class="admin-view">
      <div class="page-heading"><div><div class="eyebrow">ПРОЕКТ «ЖИВАЯ ПАМЯТЬ»</div><h1>Команда и доступ</h1><p class="muted">У каждого своя почта. У всех — общее дело.</p></div><button type="button" class="button primary" data-action="create-user">${icon('plus')} Создать ящик</button></div>
      <div class="admin-stats">${stats.map(stat => `<div class="stat-card"><div class="stat-top"><span>${stat.label}</span><span class="stat-icon">${icon(stat.name, 19)}</span></div><strong>${stat.value}</strong><small>${stat.note}</small></div>`).join('')}</div>
      <div class="team-panel"><div class="panel-heading"><div><h2>Участники проекта <span class="count-badge">${users.length}</span></h2><p class="muted">Личные ящики и роли в команде</p></div><label class="team-search">${icon('search',20)}<input id="team-search" type="search" value="${escape(teamSearch)}" placeholder="Найти участника" aria-label="Найти участника команды"></label></div>
        <div class="team-table"><div class="team-row team-table-head"><span>Участник</span><span>Почтовый ящик</span><span>Роль</span><span>Статус</span><span>Доступ</span></div><div id="team-results">${renderTeamRows()}</div></div>
        <div class="team-panel-note">${icon('lock',20)} Демо-режим: ящики и доступ сохраняются только в этом браузере.</div>
      </div>
      <div class="admin-bottom"><div class="admin-bottom-icon">${icon('heart', 22)}</div><div><strong>Работа команды — часть большой истории</strong><p class="muted">Подключайте архивистов, редакторов и близких к проекту.</p></div></div>
    </section>`;
  };

  M.renderSettings = function () {
    const user = M.getUser();
    if (!user) return M.renderLogin();
    const settings = M.state.settings;
    const signature = user.signature ?? settings.signature ?? '';
    const autoReply = user.autoReply || { enabled: false, message: '' };
    const uploadingAvatar = avatarBusy && avatarBusyUser === user.id;
    return `<section class="settings-view">
      <div class="page-heading"><div><div class="eyebrow">ВАШЕ ПРОСТРАНСТВО</div><h1>Настройки</h1><p class="muted">Пусть почта работает в вашем ритме.</p></div></div>
      <div class="settings-grid">
        <div class="settings-card settings-profile"><div class="settings-card-heading">${icon('user',20)}<h2>Мой профиль</h2></div><div class="profile-row">${userInitials(user)}<div><strong>${escape(user.name)}</strong><p class="muted">${escape(M.displayEmail?M.displayEmail(user.email):user.email)}</p><span class="role-badge${user.role === 'admin' ? ' admin' : ''}">${user.role === 'admin' ? 'Администратор' : 'Участник команды'}</span></div></div><div class="settings-note">${icon('lock',20)} Личный вход в пространство команды</div></div>
        <div class="settings-card avatar-settings" aria-busy="${uploadingAvatar}"><div class="settings-card-heading">${icon('user',20)}<h2>Аватар почтового ящика</h2></div><p class="muted">Ваше фото помогает команде узнавать вас в почте и чате.</p><div class="avatar-settings-stage"><div class="avatar-settings-preview">${userInitials(user)}</div><div class="avatar-settings-controls"><button type="button" class="button primary" data-action="choose-avatar"${uploadingAvatar ? ' disabled' : ''}>${icon('plus',20)} ${uploadingAvatar ? 'Готовим фото…' : 'Загрузить фото'}</button><button type="button" class="button subtle" data-action="remove-avatar"${uploadingAvatar || !user.avatarUrl ? ' disabled' : ''}>Удалить фото</button><input id="avatar-upload" type="file" accept="image/png,image/jpeg,image/webp" hidden aria-label="Выбрать фото для аватара"><span class="avatar-settings-hint">PNG, JPEG или WebP · до 2 МБ<br>Фото будет обрезано по центру.</span></div></div><div class="avatar-settings-palette"><span>Или использовать инициалы</span><div class="avatar-color-options" role="group" aria-label="Цвет аватара с инициалами">${Object.entries(AVATAR_COLORS).map(([color, title]) => `<button type="button" class="avatar-color avatar-color-${color}${!user.avatarUrl && user.color === color ? ' selected' : ''}" data-action="set-avatar-color" data-color="${color}" aria-label="${title}" aria-pressed="${!user.avatarUrl && user.color === color}"${uploadingAvatar ? ' disabled' : ''}>${!user.avatarUrl && user.color === color ? icon('check', 14) : ''}</button>`).join('')}</div></div><div id="avatar-error" class="form-error" role="alert"></div><p id="avatar-status" class="avatar-settings-status" role="status" aria-live="polite">${uploadingAvatar ? 'Подготавливаем аватар…' : ''}</p><div class="settings-note">${icon('lock',20)} Аватар сохраняется в этом браузере.</div></div>
        <div class="settings-card"><div class="settings-card-heading">${icon('moon',20)}<h2>Оформление</h2></div><p class="muted">Выберите комфортную тему интерфейса.</p><div class="theme-options"><button type="button" class="theme-option${settings.theme === 'dark' ? ' selected' : ''}" data-action="set-theme" data-theme="dark" aria-pressed="${settings.theme === 'dark'}"><span class="theme-preview dark"><i></i><b></b><em></em></span><span>${icon('moon',20)} Тёмная${settings.theme === 'dark' ? icon('check',20) : ''}</span></button><button type="button" class="theme-option${settings.theme === 'light' ? ' selected' : ''}" data-action="set-theme" data-theme="light" aria-pressed="${settings.theme === 'light'}"><span class="theme-preview light"><i></i><b></b><em></em></span><span>${icon('sun',20)} Светлая${settings.theme === 'light' ? icon('check',20) : ''}</span></button></div></div>
        <div class="settings-card"><div class="settings-card-heading">${icon('edit',20)}<h2>Подпись в письмах</h2></div><p class="muted">Ваша личная подпись для новых писем.</p><form id="settings-signature-form"><label class="form-field"><span class="sr-only">Подпись в письмах</span><textarea name="signature" maxlength="1000" rows="4" placeholder="С уважением, команда проекта «Живая память»">${escape(signature)}</textarea></label><div class="form-actions"><button type="submit" class="button primary">Сохранить подпись</button></div></form></div>
        <div class="settings-card"><div class="settings-card-heading">${icon('reply',20)}<h2>Автоответчик</h2></div><div class="notification-row"><div><strong>Ответить, пока вы заняты</strong><p class="muted">Отправитель получит ваше сообщение автоматически.</p></div><button type="button" class="switch${autoReply.enabled ? ' enabled' : ''}" role="switch" aria-checked="${Boolean(autoReply.enabled)}" aria-label="Включить автоответчик" data-action="toggle-autoreply"><span></span></button></div><form id="settings-autoreply-form"><label class="form-field"><span>Текст автоответа</span><textarea name="message" id="autoreply-message" maxlength="2000" rows="4" placeholder="Спасибо за письмо! Сейчас я вне офиса. Отвечу, как только вернусь."${autoReply.enabled ? ' required' : ''}>${escape(autoReply.message || '')}</textarea></label><div class="form-error" id="autoreply-error" role="alert"></div><div class="form-actions"><button type="submit" class="button primary">Сохранить автоответ</button></div></form><div class="settings-note">В демоверсии автоответ отправляется только на письма между локальными демоящиками. Не чаще одного раза в сутки каждому отправителю.</div></div>
        <div class="settings-card"><div class="settings-card-heading">${icon('bell',20)}<h2>Уведомления</h2></div><div class="notification-row"><div><strong>Новые письма</strong><p class="muted">Предпочтение для уведомлений о входящих.</p></div><button type="button" class="switch${settings.notifications ? ' enabled' : ''}" role="switch" aria-checked="${Boolean(settings.notifications)}" aria-label="Уведомления о новых письмах" data-action="toggle-notifications"><span></span></button></div><div class="settings-note">В прототипе настройка сохраняется. Push-уведомления появятся после подключения почтового сервера.</div></div>
        <div class="settings-card settings-about"><div class="settings-card-heading">${icon('heart',20)}<h2>AVELI</h2></div><p class="aveli-workspace-descriptor">Workspace by Семейный архив: Живая память</p><p>Место, где команда собирает истории, отвечает семьям и сохраняет важное.</p><div class="aveli-section-chips"><span>Mail</span><span>Chat</span><span>Cloud</span><span>AI</span></div><div class="platform-tags"><span>${icon('globe',20)} Браузер</span><span>${icon('smartphone',20)} iPhone и Android</span></div><div class="settings-note">AVELI устанавливается из браузера как веб-приложение и работает на компьютере и телефоне. Общая синхронизация, внешняя почта и ИИ требуют подключения серверных сервисов.</div></div>
        ${M.renderInstallCard?.()||''}${M.renderMailboxAccessSettings?.()||''}${M.renderSecuritySettings?.()||''}<div class="settings-card settings-session"><div class="settings-card-heading">${icon('lock',20)}<h2>Текущая сессия</h2></div><p class="muted">Вы вошли как ${escape(user.name)}.</p><button type="button" class="button secondary" data-action="management-logout">${icon('logout',20)} Выйти из аккаунта</button><div class="settings-note">Данные прототипа останутся в этом браузере.</div></div>
      </div>
    </section>`;
  };

  M.renderLogin = function () {
    return `<div class="login-layout login">
      <section class="login-brand">
        <div class="login-logo"><span class="brand-mark aveli-brand-mark"><img src="logo.png" alt="" width="56" height="56"></span><div><strong>AVELI</strong><span class="aveli-workspace-descriptor">Workspace by Семейный архив: Живая память</span></div></div>
        <div class="login-brand-content"><div class="eyebrow"><span class="live-dot"></span> РАБОТАЕМ ВМЕСТЕ</div><h1>Всё важное — рядом.<br><span>Команда на связи.</span></h1><p>Почта, разговоры, файлы и помощник в одном пространстве проекта «Живая память».</p><div class="login-brand-features"><span>${icon('mail',22)} Mail</span><span>${icon('chat',22)} Chat</span><span>${icon('folder',22)} Cloud</span><span>${icon('sparkles',22)} AI</span></div></div>
        <div class="login-brand-footer"><span>СЕМЕЙНЫЙ АРХИВ «ЖИВАЯ ПАМЯТЬ»</span><span>Каждая история имеет значение.</span></div><div class="login-orbit" aria-hidden="true"><i></i><b></b><em></em></div>
      </section>
      <section class="login-main"><div class="login-card">
        <span class="login-welcome-icon aveli-brand-mark"><img src="logo.png" alt="Логотип AVELI" width="64" height="64"></span>
        <div class="eyebrow">AVELI WORKSPACE</div><h2>Добро пожаловать.</h2><p class="muted aveli-login-descriptor">Почта и команда в одном месте.</p>
        <button type="button" class="button primary login-demo-open" data-action="open-demo">Открыть демоверсию AVELI ${icon('arrow-right',22)}</button>
        <p class="login-note login-demo-status">Локальная демоверсия: данные хранятся на этом устройстве. Серверная почта и синхронизация команды пока не подключены.</p>
        <div class="login-divider"><span>Локальный вход в демоящик</span></div>
        <form id="login-form" aria-label="Локальный вход в демоящик">
          <label class="form-field"><span>Почтовый адрес</span><div class="input-with-icon">${icon('mail',20)}<input id="login-email" name="email" type="email" required autocomplete="username" autocapitalize="none" spellcheck="false" placeholder="name@archiverf.ru" value="elena@archiverf.ru"></div></label>
          <label class="form-field"><span>Пароль</span><div class="input-with-icon">${icon('lock',20)}<input id="login-password" name="password" type="password" required autocomplete="current-password" placeholder="Введите пароль" value="memory2026"><button type="button" class="password-eye" data-action="toggle-password" aria-label="Показать пароль" aria-pressed="false">${icon('eye',22)}</button></div></label>
          <div class="form-error${loginError?' visible':''}" id="login-error" role="alert">${escape(loginError)}</div><button type="submit" class="button secondary login-submit">Войти в демоящик ${icon('arrow-right',22)}</button>
        </form>
        <div class="login-demo"><span class="login-demo-caption">ВЫБРАТЬ ДЕМОПРОФИЛЬ</span><div class="login-demo-buttons"><button type="button" class="login-demo-button" data-action="fill-demo" data-demo="admin">${icon('shield',22)}<span><strong>Администратор</strong><small>Управление командой</small></span>${icon('arrow-up-right',20)}</button><button type="button" class="login-demo-button" data-action="fill-demo" data-demo="member">${icon('user',22)}<span><strong>Участник</strong><small>Личная почта</small></span>${icon('arrow-up-right',20)}</button></div><p class="demo-credentials">Демопароль: memory2026</p></div>
      </div><div class="login-bottom">AVELI · Workspace by Живая память</div></section>
    </div>`;
  };

  function createMailboxModal() {
    if (!isAdmin()) return;
    M.openModal('Новый почтовый ящик', `<form id="create-mailbox-form"><p class="muted modal-description">Добавьте участника в рабочее пространство AVELI.</p><label class="form-field"><span>Имя и фамилия</span><input name="name" autocomplete="name" maxlength="80" required placeholder="Например, Анна Соколова" autofocus></label><label class="form-field"><span>Адрес ящика</span><div class="email-input-group"><input name="emailLocal" required maxlength="40" pattern="[A-Za-z0-9]+([._-][A-Za-z0-9]+)*" autocapitalize="none" autocomplete="off" placeholder="anna"><span>@archiverf.ru</span></div><small>Латинские буквы, цифры, точки, дефис и подчёркивание.</small></label><label class="form-field"><span>Роль в команде</span><select name="role"><option value="member">Участник — работа с письмами</option><option value="admin">Администратор — письма и управление командой</option></select></label><label class="form-field"><span>Пароль для первого входа</span><input name="password" type="password" required minlength="8" maxlength="128" autocomplete="new-password" placeholder="Не менее 8 символов"><small>Передайте пароль участнику самостоятельно.</small></label><div class="form-error" id="create-error" role="alert"></div><div class="settings-note">Это демо-ящик в этом браузере. Реальная почта и отправка приглашений пока не подключены.</div><div class="modal-form-footer"><button type="button" class="button secondary" data-action="close-modal">Отмена</button><button type="submit" class="button primary">${icon('plus',20)} Создать ящик</button></div></form>`);
    setTimeout(() => document.querySelector('#create-mailbox-form input[name="name"]')?.focus(), 60);
  }

  function logout() {
    avatarRequest++;
    avatarBusy = false;
    avatarBusyUser = null;
    M.translation?.cleanup?.();
    M.media?.cleanup?.();
    M.state.currentUser = null;
    M.state.activeMailboxId = null;
    M.state.selectedId = null;
    M.state.view = 'inbox';
    M.state.checked = [];
    M.state.query = '';
    M.state.filter = 'all';
    M.state.reading = false;
    M.state.sidebarOpen = false;
    if (M.state.selectedIds instanceof Set) M.state.selectedIds.clear();
    M.closeModal();
    M.persist();
    loginError = '';
    M.render();
  }

  function enterLocalWorkspace(user) {
    M.state.currentUser = user.id;
    M.state.activeMailboxId = user.id;
    M.state.selectedId = null;
    if (M.state.selectedIds instanceof Set) M.state.selectedIds.clear();
    M.state.view = 'inbox';
    M.state.checked = [];
    M.state.query = '';
    M.state.filter = 'all';
    M.state.reading = false;
    M.state.sidebarOpen = false;
    loginError = '';
    teamSearch = '';
    M.persist();
    M.render();
  }

  M.onManagementAction = function (action, element) {
    if (action === 'open-demo') {
      // This opens a local prototype, not an authenticated server account.
      const user = M.state.users.find(item => item.id === 'u1' && item.active)
        || M.state.users.find(item => item.active);
      if (user) {
        enterLocalWorkspace(user);
        M.toast('Открыта демоверсия · данные на этом устройстве');
      } else {
        M.toast('Нет активных демоящиков для просмотра');
      }
      return true;
    }
    if (action === 'choose-avatar') {
      const user = M.getUser();
      if (!user?.active || (avatarBusy && avatarBusyUser === user.id)) return true;
      document.getElementById('avatar-upload')?.click();
      return true;
    }
    if (action === 'remove-avatar' || action === 'set-avatar-color') {
      const user = M.getUser();
      if (!user?.active || (avatarBusy && avatarBusyUser === user.id)) return true;
      if (action === 'set-avatar-color' && !Object.prototype.hasOwnProperty.call(AVATAR_COLORS, element.dataset.color)) return true;
      try {
        persistAvatar(user, '', action === 'set-avatar-color' ? element.dataset.color : user.color);
        M.render();
        M.toast(action === 'set-avatar-color' ? 'Для аватара выбраны инициалы' : 'Фото удалено. Показываем ваши инициалы');
      } catch (error) {
        avatarError(error.message || 'Не удалось сохранить аватар.');
      }
      return true;
    }
    if (action === 'create-user') {
      createMailboxModal();
      return true;
    }
    if (action === 'toggle-user') {
      if (!isAdmin()) return true;
      const user = M.state.users.find(item => item.id === element.dataset.userId);
      if (!user || user.id === M.state.currentUser) return true;
      user.active = !user.active;
      M.persist();
      M.render();
      M.toast(user.active ? `Доступ ${user.name} возобновлён` : `Доступ ${user.name} приостановлен`);
      return true;
    }
    if (action === 'set-theme') {
      if (!M.getUser()) return true;
      if (!['dark', 'light'].includes(element.dataset.theme)) return true;
      M.state.settings.theme = element.dataset.theme;
      document.documentElement.dataset.theme = element.dataset.theme;
      M.persist();
      M.render();
      return true;
    }
    if (action === 'toggle-notifications') {
      if (!M.getUser()) return true;
      M.state.settings.notifications = !M.state.settings.notifications;
      M.persist();
      M.render();
      M.toast(M.state.settings.notifications ? 'Предпочтение уведомлений включено' : 'Предпочтение уведомлений выключено');
      return true;
    }
    if (action === 'toggle-autoreply') {
      const user = M.getUser();
      if (!user) return true;
      const autoReply = user.autoReply || { enabled: false, message: '' };
      const textarea = document.getElementById('autoreply-message');
      const message = (textarea ? textarea.value : autoReply.message || '').trim();
      if (!autoReply.enabled && !message) {
        const error = document.getElementById('autoreply-error');
        if (error) { error.textContent = 'Добавьте текст, который получит отправитель.'; error.classList.add('visible'); }
        if (textarea) textarea.focus();
        return true;
      }
      user.autoReply = { ...autoReply, enabled: !autoReply.enabled, message };
      M.persist();
      M.render();
      M.toast(user.autoReply.enabled ? 'Автоответчик включён для демоящиков' : 'Автоответчик выключен');
      return true;
    }
    if (action === 'management-logout' || action === 'logout') {
      logout();
      return true;
    }
    if (action === 'fill-demo') {
      const emailInput = document.getElementById('login-email');
      const passwordInput = document.getElementById('login-password');
      if (!emailInput || !passwordInput) return true;
      emailInput.value = element.dataset.demo === 'member' ? 'anna@archiverf.ru' : 'elena@archiverf.ru';
      passwordInput.value = 'memory2026';
      loginError = '';
      const error = document.getElementById('login-error');
      if (error) { error.textContent = ''; error.classList.remove('visible'); }
      emailInput.focus();
      return true;
    }
    if (action === 'toggle-password') {
      const input = document.getElementById('login-password');
      if (!input) return true;
      const show = input.type === 'password';
      input.type = show ? 'text' : 'password';
      element.setAttribute('aria-label', show ? 'Скрыть пароль' : 'Показать пароль');
      element.setAttribute('aria-pressed', String(show));
      return true;
    }
    return false;
  };

  document.addEventListener('input', event => {
    if (event.target.id === 'team-search') {
      teamSearch = event.target.value;
      const results = document.getElementById('team-results');
      if (results) results.innerHTML = renderTeamRows();
    }
    if (event.target.closest('#login-form')) {
      loginError = '';
      const error = document.getElementById('login-error');
      if (error) { error.textContent = ''; error.classList.remove('visible'); }
    }
    if (event.target.id === 'autoreply-message') {
      const error = document.getElementById('autoreply-error');
      if (error) { error.textContent = ''; error.classList.remove('visible'); }
    }
  });

  document.addEventListener('change', async event => {
    if (event.target.id !== 'avatar-upload') return;
    const input = event.target;
    const user = M.getUser();
    const file = input.files?.[0];
    input.value = '';
    if (!file || !user?.active || avatarBusy) return;
    const userId = user.id;
    const request = ++avatarRequest;
    avatarBusy = true;
    avatarBusyUser = userId;
    avatarError('');
    const updateControls = busy => {
      if (M.getUser()?.id !== userId) return;
      const card = document.querySelector('.avatar-settings');
      if (!card) return;
      card.setAttribute('aria-busy', String(busy));
      card.querySelectorAll('[data-action="choose-avatar"], [data-action="set-avatar-color"]').forEach(button => { button.disabled = busy; });
      const remove = card.querySelector('[data-action="remove-avatar"]');
      if (remove) remove.disabled = busy || !M.getUser()?.avatarUrl;
      const upload = card.querySelector('[data-action="choose-avatar"]');
      if (upload) upload.innerHTML = `${icon('plus',20)} ${busy ? 'Готовим фото…' : 'Загрузить фото'}`;
      const status = document.getElementById('avatar-status');
      if (status) status.textContent = busy ? 'Подготавливаем аватар…' : '';
    };
    updateControls(true);
    try {
      const avatarUrl = await prepareAvatar(file);
      const currentUser = M.getUser();
      if (request !== avatarRequest || currentUser?.id !== userId || !currentUser.active) return;
      persistAvatar(currentUser, avatarUrl);
      avatarBusy = false;
      avatarBusyUser = null;
      M.render();
      M.toast('Аватар почтового ящика сохранён');
    } catch (error) {
      if (request === avatarRequest && M.getUser()?.id === userId) {
        avatarError(error.message || 'Не удалось сохранить аватар. Попробуйте другое фото.');
      }
    } finally {
      if (request === avatarRequest) {
        avatarBusy = false;
        avatarBusyUser = null;
        updateControls(false);
      }
    }
  });

  document.addEventListener('submit', async event => {
    const form = event.target;
    if (form.id === 'settings-signature-form') {
      event.preventDefault();
      if (!M.getUser()) return;
      M.getUser().signature = new FormData(form).get('signature').toString().trim();
      M.persist();
      M.toast('Подпись сохранена');
      return;
    }
    if (form.id === 'settings-autoreply-form') {
      event.preventDefault();
      const user = M.getUser();
      if (!user) return;
      const message = new FormData(form).get('message').toString().trim();
      const enabled = Boolean(user.autoReply?.enabled);
      if (enabled && !message) {
        const error = document.getElementById('autoreply-error');
        if (error) { error.textContent = 'Для включённого автоответчика нужен текст сообщения.'; error.classList.add('visible'); }
        document.getElementById('autoreply-message')?.focus();
        return;
      }
      user.autoReply = { ...user.autoReply, enabled, message };
      M.persist();
      M.toast('Текст автоответа сохранён');
      return;
    }
    if (form.id === 'login-form') {
      event.preventDefault();
      if (loginBusy) return;
      loginBusy = true;
      const submit = form.querySelector('[type="submit"]');
      const data = new FormData(form);
      const email = M.normalizeEmail ? M.normalizeEmail(data.get('email').toString()) : data.get('email').toString().trim().toLowerCase();
      const password = data.get('password').toString();
      const user = M.state.users.find(item => item.email.toLowerCase() === email);
      submit.disabled = true;
      submit.textContent = 'Входим…';
      try {
        if (!user || !(await verifyPassword(user, password))) {
          throw new Error('Проверьте почтовый адрес и пароль.');
        }
        if (!user.active) {
          throw new Error('Доступ к этому ящику приостановлен. Обратитесь к администратору.');
        }
        enterLocalWorkspace(user);
        M.toast(`Добро пожаловать, ${user.name.split(' ')[0]}!`);
      } catch (error) {
        loginError = error.message || 'Не удалось войти. Попробуйте ещё раз.';
        const errorElement = document.getElementById('login-error');
        if (errorElement) { errorElement.textContent = loginError; errorElement.classList.add('visible'); }
        submit.disabled = false;
        submit.innerHTML = `Войти в демоящик ${icon('arrow-right', 22)}`;
      } finally {
        loginBusy = false;
      }
      return;
    }
    if (form.id === 'create-mailbox-form') {
      event.preventDefault();
      if (createBusy || !isAdmin()) return;
      const data = new FormData(form);
      const name = data.get('name').toString().trim();
      const emailLocal = data.get('emailLocal').toString().trim().toLowerCase();
      const password = data.get('password').toString();
      const role = data.get('role') === 'admin' ? 'admin' : 'member';
      const email = `${emailLocal}@memory.example`;
      const errorElement = document.getElementById('create-error');
      const showError = message => { errorElement.textContent = message; errorElement.classList.add('visible'); };
      if (!name) { showError('Укажите имя участника.'); return; }
      if (!/^[a-z0-9]+(?:[._-][a-z0-9]+)*$/.test(emailLocal)) { showError('Проверьте адрес: используйте латинские буквы и цифры.'); return; }
      if (password.length < 8) { showError('В пароле должно быть не менее 8 символов.'); return; }
      if (M.state.users.some(user => user.email.toLowerCase() === email)) { showError('Такой адрес уже есть в команде. Выберите другой.'); return; }
      createBusy = true;
      const submit = form.querySelector('[type="submit"]');
      submit.disabled = true;
      submit.textContent = 'Создаём…';
      try {
        const colors = ['sage', 'blue', 'peach', 'lavender'];
        const user = {
          id: `u-${crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`}`,
          name, email, role, active: true, color: colors[M.state.users.length % colors.length],
          autoReply: { enabled: false, message: '' }
        };
        await setPassword(user, password);
        if (!isAdmin()) throw new Error('Сессия администратора завершена. Войдите снова.');
        if (M.state.users.some(item => item.email.toLowerCase() === email)) throw new Error('Такой адрес уже есть в команде.');
        M.state.users.push(user);
        M.persist();
        teamSearch = '';
        M.closeModal();
        M.render();
        M.toast(`Ящик ${email} создан в этом браузере`);
      } catch (error) {
        showError(error.message || 'Не удалось создать ящик. Попробуйте ещё раз.');
        submit.disabled = false;
        submit.innerHTML = `${icon('plus',20)} Создать ящик`;
      } finally {
        createBusy = false;
      }
    }
  });
})();
