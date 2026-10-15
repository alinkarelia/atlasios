(function () {
  'use strict';

  const M = window.M;
  if (!M) return;
  const escape = M.escape;
  const icon = (name, size = 18) => M.icon(name, size);
  const MAX_DRAFTS = 500;
  const catalog = [
    { id: 'files', name: 'Файлы и архивы', icon: 'folder', description: 'Материалы семьи рядом с перепиской', examples: 'Облачное хранилище · семейный архив' },
    { id: 'calendar', name: 'Календари', icon: 'clock', description: 'Интервью и встречи в одном расписании', examples: 'Встречи · напоминания · доступность' },
    { id: 'communications', name: 'Коммуникации', icon: 'chat', description: 'Обращения из других каналов связи', examples: 'Мессенджеры · телефония' },
    { id: 'webhooks', name: 'Свои интеграции', icon: 'settings', description: 'Связь с будущими сервисами проекта', examples: 'API · подписанные webhooks' }
  ];

  function user() {
    const current = M.getUser();
    return current?.active ? current : null;
  }

  function isAdmin() {
    return user()?.role === 'admin';
  }

  function getStore() {
    const state = M.state;
    if (!state.integrations || typeof state.integrations !== 'object' || Array.isArray(state.integrations)) {
      state.integrations = {};
    }
    const store = state.integrations;
    if (!store.amo || typeof store.amo !== 'object' || Array.isArray(store.amo)) store.amo = {};
    if (!Array.isArray(store.drafts)) store.drafts = [];
    return store;
  }

  function accessible() {
    return user() ? M.accessibleMails() : [];
  }

  function validAccountUrl(value) {
    const raw = String(value || '').trim();
    if (!raw) return '';
    if (!/^https:\/\/[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.amocrm\.ru\/?$/i.test(raw)) return null;
    try {
      const url = new URL(raw);
      if (url.username || url.password || url.port || url.search || url.hash || url.pathname !== '/') return null;
      return url.origin;
    } catch (error) {
      return null;
    }
  }

  function clientAddress(mail) {
    return String(mail.folder === 'sent' ? mail.to || '' : mail.email || '').trim().toLowerCase();
  }

  function eligibleMail(mail) {
    const email = clientAddress(mail);
    return !['trash', 'spam', 'drafts'].includes(mail.folder) && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) && !email.endsWith('@memory.example');
  }

  function ownDrafts() {
    const current = user();
    if (!current) return [];
    const ids = new Set(accessible().map(mail => mail.id));
    return getStore().drafts.filter(draft => draft && draft.userId === current.id && ids.has(draft.mailId)).slice(0, MAX_DRAFTS);
  }

  function formatDate(value) {
    const date = new Date(value);
    return Number.isFinite(date.getTime()) ? date.toLocaleDateString('ru-RU', { day: 'numeric', month: 'short' }) : 'Локальный черновик';
  }

  function badge(text, style = '') {
    return `<span class="int-status ${style}"><i></i>${escape(text)}</span>`;
  }

  function renderDrafts() {
    const drafts = ownDrafts();
    return `<section class="int-card int-history"><div class="int-card-heading"><div><h2>Мои черновики сделок <span class="int-count">${drafts.length}</span></h2><p>Подготовлены из писем. В amoCRM не отправлены.</p></div>${icon('edit', 20)}</div>${drafts.length
      ? `<div class="int-draft-list">${drafts.slice(0, 8).map(draft => `<button class="int-draft-row" data-action="crm-view-draft" data-id="${escape(draft.id)}"><span class="int-draft-icon">${icon('file', 17)}</span><span><strong>${escape(draft.title)}</strong><small>${escape(draft.contactName || draft.contactEmail)} · ${escape(formatDate(draft.createdAt))}</small></span><span class="int-local-label">Локально</span>${icon('chevron-right', 16)}</button>`).join('')}</div>${drafts.length > 8 ? '<p class="int-history-note">Показаны 8 последних черновиков.</p>' : ''}`
      : `<div class="int-draft-empty">${icon('mail', 24)}<div><strong>Письмо может стать началом сделки</strong><p>Откройте письмо клиента и выберите «Подготовить сделку» в блоке amoCRM.</p></div></div>`}</section>`;
  }

  function renderAmo() {
    const amo = getStore().amo;
    const demo = amo.demoEnabled === true;
    const accountUrl = validAccountUrl(amo.accountUrl) || '';
    const draftMail = accessible().find(mail => mail.id === M.state.selectedId && eligibleMail(mail)) || accessible().find(eligibleMail);
    return `<section class="int-card int-amo-card"><div class="int-amo-top"><span class="int-amo-logo" aria-hidden="true">a<span>mo</span></span><div class="int-amo-title"><div class="int-eyebrow">CRM · ПЕРВАЯ ИНТЕГРАЦИЯ</div><h2>amoCRM</h2><p>От первого письма до сохранённой семейной истории</p></div>${badge('Не подключено')}</div>
      <div class="int-workflow"><div>${icon('mail', 18)}<span>Письмо клиента</span></div>${icon('chevron-right', 14)}<div>${icon('user', 18)}<span>Контакт</span></div>${icon('chevron-right', 14)}<div>${icon('folder', 18)}<span>Сделка</span></div></div>
      <form id="integration-amo-form" class="int-config-form"><label class="form-field"><span>Адрес аккаунта amoCRM</span><input type="url" name="accountUrl" value="${escape(accountUrl)}" placeholder="https://yourteam.amocrm.ru" maxlength="100" autocomplete="off" spellcheck="false"><small>Только адрес аккаунта. Пароли и ключи здесь не нужны.</small></label>
        <div class="int-preference"><div><strong>Локальная демонстрация</strong><p>Пример карточки клиента и черновики сделок в этом браузере.</p></div><label class="int-check"><input name="demoEnabled" type="checkbox"${demo ? ' checked' : ''}><span class="sr-only">Включить локальную демонстрацию amoCRM</span></label></div>
        <details class="int-access-details"><summary>${icon('shield', 16)} Правила доступа к письмам ${icon('chevron-down', 15)}</summary><div class="int-access-inner"><p>Предпочтения для будущего рабочего подключения. Сейчас данные никуда не передаются.</p><label class="int-checkbox-row"><input name="syncClientMail" type="checkbox"${amo.syncClientMail === true ? ' checked' : ''}><span><strong>Переписка с внешними клиентами</strong><small>После подключения — только выбранные клиентские письма в разрешённых ящиках.</small></span></label><label class="int-checkbox-row"><input name="personalOptIn" type="checkbox"${amo.personalOptIn === true ? ' checked' : ''}><span><strong>Разрешить личные рабочие ящики</strong><small>Для реального доступа дополнительно понадобится согласие владельца каждого ящика.</small></span></label><div class="int-private-note">${icon('lock', 14)} Внутренние чаты, заметки команды и вложения не входят в эту настройку.</div></div></details>
        <div id="integration-amo-error" class="form-error" role="alert"></div><div class="int-config-actions"><button class="button primary" type="submit">${icon('check', 16)} Сохранить настройки</button><button class="button secondary" type="button" data-action="integration-oauth-info">Как подключить OAuth ${icon('arrow-up-right', 15)}</button></div>
      </form>
      ${demo ? `<div class="int-demo-active">${icon('edit', 18)}<div><strong>Локальная демонстрация включена</strong><p>Это пример данных, без подключения к аккаунту amoCRM.</p></div>${draftMail ? `<button class="button secondary small" data-action="crm-create-draft" data-id="${escape(draftMail.id)}">Попробовать ${icon('chevron-right', 15)}</button>` : ''}</div>` : ''}
    </section>`;
  }

  M.renderIntegrations = function () {
    if (!isAdmin()) return `<section class="int-view"><div class="int-card int-denied">${icon('lock', 28)}<h1>Интеграции команды</h1><p>Подключениями управляет администратор проекта.</p></div></section>`;
    return `<section class="int-view"><div class="page-heading"><div><div class="eyebrow">СЕРВИСЫ В ОДНОМ ПРОСТРАНСТВЕ</div><h1>Интеграции</h1><p class="muted">Почта, клиенты и инструменты команды — рядом.</p></div><span class="int-admin-label">${icon('shield', 16)} Доступ администратора</span></div>
      <div class="int-demo-banner">${icon('alert', 18)}<div><strong>Реальные API пока не настроены</strong><span>Настройки и черновики остаются в этом браузере. Автоматической отправки данных нет.</span></div><span class="int-banner-tag">ПРОТОТИП</span></div>
      <div class="int-main-grid"><div class="int-main-column">${renderAmo()}${renderDrafts()}</div><aside class="int-side-column"><section class="int-card int-security-card"><span class="int-security-symbol">${icon('shield', 26)}</span><div class="int-eyebrow">БЕРЕЖНО К ДАННЫМ</div><h2>Доступ под контролем</h2><p>Для рабочего подключения ключи и OAuth-токены должны храниться только на сервере.</p><ul><li>${icon('check', 15)} Подключение разрешает администратор</li><li>${icon('check', 15)} Минимальный доступ к CRM</li><li>${icon('check', 15)} Доступ только к разрешённым письмам</li><li>${icon('check', 15)} Отключение и отзыв токенов на сервере</li></ul><button class="button secondary small" data-action="integration-oauth-info">Что потребуется ${icon('chevron-right', 15)}</button></section>
      <section class="int-card int-mapping-card"><h2>Письмо → сделка</h2><p>Поля локального черновика</p><dl><div><dt>Отправитель</dt><dd>Контакт ${icon('chevron-right', 12)}</dd></div><div><dt>Email</dt><dd>Адрес клиента ${icon('chevron-right', 12)}</dd></div><div><dt>Тема письма</dt><dd>Название сделки ${icon('chevron-right', 12)}</dd></div><div><dt>Первое обращение</dt><dd>Новая заявка ${icon('chevron-right', 12)}</dd></div></dl><small>Текст письма и семейные материалы автоматически не копируются.</small></section></aside></div>
      <div class="int-catalog-heading"><div><h2>Следующие подключения</h2><p>Категории для развития проекта. Коннекторы ещё предстоит реализовать.</p></div><span class="int-count">${catalog.length}</span></div><div class="int-catalog">${catalog.map(item => `<button class="int-card int-catalog-card" data-action="integration-planned-info" data-integration="${item.id}"><div class="int-catalog-top"><span class="int-service-icon">${icon(item.icon, 22)}</span>${badge('Планируется', 'int-status-planned')}</div><h3>${item.name}</h3><p>${item.description}</p><div class="int-catalog-bottom"><span>${item.examples}</span>${icon('arrow-up-right', 15)}</div></button>`).join('')}</div><div class="int-page-footer">${icon('lock', 14)} Никаких ключей в браузере. Рабочие подключения — через сервер проекта.</div></section>`;
  };

  M.renderCrmContext = function (mail) {
    const current = user();
    const safeMail = current && accessible().find(item => item.id === mail?.id);
    if (!safeMail || !eligibleMail(safeMail)) return '';
    const demo = getStore().amo.demoEnabled === true;
    if (!demo) return `<section class="int-mail-context"><div class="int-context-heading"><span class="int-amo-mini">amo</span><strong>Клиент и сделка</strong>${badge('Не подключено')}</div><p>Свяжите клиентскую переписку с amoCRM.</p>${isAdmin() ? '<button class="button secondary small" data-action="integration-open">Настроить интеграцию</button>' : '<p class="int-context-note">Подключение настраивает администратор команды.</p>'}</section>`;
    const existing = ownDrafts().find(draft => draft.mailId === safeMail.id);
    const fixture = safeMail.id === 'm1' && clientAddress(safeMail) === 'alexander@example.com';
    return `<section class="int-mail-context"><div class="int-context-heading"><span class="int-amo-mini">amo</span><strong>Клиент и сделка</strong><span class="int-local-label">Локальное демо</span></div>${fixture ? `<div class="int-context-client">${M.avatar('Александр Ковалёв', 'blue')}<div><strong>Александр Ковалёв</strong><small>alexander@example.com · пример контакта</small></div></div><div class="int-context-deal"><span>ДЕМО СДЕЛКИ</span><strong>Семейный архив Ковалёвых</strong><small><i></i>Знакомство с семьёй</small></div>` : `<p>Подготовьте контакт и сделку из этого письма. Данные реальной CRM не загружены.</p>`}<div class="int-context-actions"><button class="button secondary small" data-action="${existing ? 'crm-view-draft' : 'crm-create-draft'}" data-id="${escape(existing?.id || safeMail.id)}">${icon(existing ? 'file' : 'plus', 15)} ${existing ? 'Открыть мой черновик' : 'Подготовить сделку'}</button>${isAdmin() ? '<button class="int-text-button" data-action="integration-open">Настройки</button>' : ''}</div><p class="int-context-note">Черновик сохраняется только здесь. В amoCRM ничего не отправляется.</p></section>`;
  };

  function showOAuthInfo() {
    if (!isAdmin()) return;
    M.openModal('Подключение amoCRM через OAuth', `<div class="int-oauth-intro"><span class="int-amo-logo" aria-hidden="true">a<span>mo</span></span><div><strong>Аккаунт ещё не подключён</strong><p>Нужны backend проекта и OAuth-интеграция в amoCRM.</p></div></div><ol class="int-oauth-steps"><li><strong>Зарегистрировать интеграцию в amoCRM</strong><span>Указать серверный адрес callback проекта. Client secret хранить в секретах сервера.</span></li><li><strong>Разрешить доступ администратором</strong><span>Сервер создаёт одноразовый OAuth state и проверяет его при возврате. Токены браузеру не передаются.</span></li><li><strong>Выбрать правила работы</strong><span>Приложение использует контакты, сделки и примечания. Фактические права amoCRM нужно проверить при подключении и дополнительно ограничить на сервере.</span></li></ol><div class="int-private-note">${icon('lock', 16)} Чаты команды и семейные вложения автоматически не передаются. Сейчас внешнего подключения нет.</div><div class="modal-form-footer"><button class="button primary" data-action="close-modal">Понятно</button></div>`);
  }

  function createDraftModal(mailId) {
    const mail = accessible().find(item => item.id === mailId);
    if (!mail || !eligibleMail(mail)) { M.toast('Это письмо недоступно для подготовки сделки.'); return; }
    if (getStore().amo.demoEnabled !== true) { M.toast('Администратор должен включить локальную демонстрацию.'); return; }
    const existing = ownDrafts().find(draft => draft.mailId === mail.id);
    if (existing) { showDraft(existing.id); return; }
    const name = mail.folder === 'sent' ? clientAddress(mail) : String(mail.sender || '').slice(0, 120);
    M.openModal('Черновик сделки из письма', `<form id="integration-draft-form" data-mail-id="${escape(mail.id)}" data-user-id="${escape(user().id)}"><div class="int-draft-source">${icon('mail', 19)}<div><strong>${escape(mail.subject || 'Без темы')}</strong><small>Источник — доступное вам письмо</small></div></div><label class="form-field"><span>Название сделки</span><input name="title" required maxlength="250" value="${escape(String(mail.subject || 'Новое обращение').slice(0, 250))}"></label><div class="int-draft-preview"><div><span>Контакт</span><strong>${escape(name)}</strong></div><div><span>Email</span><strong>${escape(clientAddress(mail))}</strong></div><div><span>Этап</span><strong>Новая заявка</strong></div></div><div class="int-private-note">${icon('lock', 15)} Сохраним только название, имя и email. Текст письма, вложения и заметки команды не копируются. В CRM ничего не отправится.</div><div class="form-error" id="integration-draft-error" role="alert"></div><div class="modal-form-footer"><button type="button" class="button secondary" data-action="close-modal">Отмена</button><button type="submit" class="button primary">${icon('edit', 16)} Сохранить локально</button></div></form>`);
  }

  function showDraft(id) {
    const draft = ownDrafts().find(item => item.id === id);
    if (!draft) { M.toast('Черновик недоступен.'); return; }
    M.openModal('Локальный черновик сделки', `<div class="int-draft-source">${icon('file', 21)}<div><strong>${escape(draft.title)}</strong><small>amoCRM не подключена · ${escape(formatDate(draft.createdAt))}</small></div></div><div class="int-draft-preview"><div><span>Контакт</span><strong>${escape(draft.contactName)}</strong></div><div><span>Email</span><strong>${escape(draft.contactEmail)}</strong></div><div><span>Этап</span><strong>Новая заявка</strong></div></div><div class="int-private-note">${icon('lock', 16)} Черновик доступен вашему демоаккаунту и не отправлен во внешнюю CRM. Локальное хранилище не заменяет серверную защиту.</div><div class="modal-form-footer"><button class="button secondary" data-action="crm-delete-draft" data-id="${escape(draft.id)}">Удалить черновик</button><button class="button primary" data-action="close-modal">Готово</button></div>`);
  }

  M.onIntegrationAction = function (action, element) {
    if (!action.startsWith('integration-') && !action.startsWith('crm-')) return false;
    if (!user()) { M.toast('Войдите в активный аккаунт.'); return true; }
    if (action === 'integration-open') {
      if (!isAdmin()) { M.toast('Настройки доступны администратору.'); return true; }
      M.state.view = 'integrations'; M.state.sidebarOpen = false; M.render(); return true;
    }
    if (action === 'integration-oauth-info') {
      if (!isAdmin()) { M.toast('Подключением управляет администратор.'); return true; }
      showOAuthInfo(); return true;
    }
    if (action === 'integration-planned-info') {
      if (!isAdmin()) { M.toast('Настройки доступны администратору.'); return true; }
      const service = catalog.find(item => item.id === element.dataset.integration);
      if (service) M.openModal(service.name, `<div class="int-planned-modal">${icon(service.icon, 30)}<h3>Планируется</h3><p>${escape(service.description)}.</p><p class="muted">Для этого подключения ещё нужно реализовать серверный коннектор, согласовать права доступа и правила передачи данных.</p></div><div class="modal-form-footer"><button class="button primary" data-action="close-modal">Понятно</button></div>`);
      return true;
    }
    if (action === 'crm-create-draft') { createDraftModal(element.dataset.id); return true; }
    if (action === 'crm-view-draft') { showDraft(element.dataset.id); return true; }
    if (action === 'crm-delete-draft') {
      const draft = ownDrafts().find(item => item.id === element.dataset.id);
      if (!draft) { M.toast('Черновик недоступен.'); return true; }
      getStore().drafts = getStore().drafts.filter(item => item.id !== draft.id || item.userId !== user().id);
      M.persist(); M.closeModal(); M.render(); M.toast('Локальный черновик удалён.'); return true;
    }
    return false;
  };

  document.addEventListener('submit', event => {
    const form = event.target;
    if (form.id !== 'integration-amo-form' && form.id !== 'integration-draft-form') return;
    event.preventDefault();
    if (!user()) { M.toast('Войдите в активный аккаунт.'); return; }
    if (form.id === 'integration-amo-form') {
      if (!isAdmin()) { M.toast('Настройки доступны администратору.'); return; }
      if (!form.reportValidity()) return;
      const data = new FormData(form);
      const accountUrl = validAccountUrl(data.get('accountUrl'));
      if (accountUrl === null) {
        const error = document.getElementById('integration-amo-error');
        if (error) error.textContent = 'Укажите адрес вида https://yourteam.amocrm.ru без дополнительных путей и параметров.';
        return;
      }
      getStore().amo = { accountUrl, demoEnabled: data.get('demoEnabled') === 'on', syncClientMail: data.get('syncClientMail') === 'on', personalOptIn: data.get('personalOptIn') === 'on' };
      M.persist(); M.render(); M.toast('Настройки сохранены локально. amoCRM не подключена.'); return;
    }
    const current = user();
    const mail = accessible().find(item => item.id === form.dataset.mailId);
    if (form.dataset.userId !== current.id || !mail || !eligibleMail(mail) || getStore().amo.demoEnabled !== true) { M.toast('Письмо или режим демонстрации больше недоступны.'); return; }
    if (!form.reportValidity()) return;
    const title = String(new FormData(form).get('title') || '').trim().slice(0, 250);
    if (!title) { M.toast('Добавьте название сделки.'); return; }
    if (ownDrafts().some(draft => draft.mailId === mail.id)) { M.toast('Для этого письма уже есть ваш черновик.'); return; }
    if (getStore().drafts.length >= MAX_DRAFTS) { M.toast('Достигнут лимит локальных черновиков. Удалите ненужные.'); return; }
    getStore().drafts.unshift({ id: crypto.randomUUID(), userId: current.id, mailId: mail.id, createdAt: Date.now(), title, contactName: String(mail.folder === 'sent' ? clientAddress(mail) : mail.sender || '').slice(0, 120), contactEmail: clientAddress(mail).slice(0, 254), stage: 'new' });
    M.persist(); M.closeModal(); M.render(); M.toast('Черновик сохранён в этом браузере. В amoCRM ничего не отправлено.');
  });
})();
