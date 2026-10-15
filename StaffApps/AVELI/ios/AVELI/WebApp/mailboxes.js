(function () {
  'use strict';

  const M = window.M;
  if (!M) return;
  const escape = M.escape;
  const icon = (name, size = 18) => M.icon(name, size);
  const sharedMailbox = { id: 'team', name: 'Команда «Живая память»', email: 'archive@memory.example', color: 'sage' };

  function allowedIds() {
    const user = M.getUser();
    if (!user?.active) return [];
    if (typeof M.allowedMailboxes === 'function') return M.allowedMailboxes();
    return [user.id, 'team', ...M.state.users.filter(item => item.active && Array.isArray(item.sharedWith) && item.sharedWith.includes(user.id)).map(item => item.id)];
  }

  function address(mailbox) {
    return M.displayEmail ? M.displayEmail(mailbox.email) : mailbox.email.replace(/@memory\.example$/, '@archiverf.ru');
  }

  function mailboxById(mailboxId) {
    return mailboxId === 'team' ? sharedMailbox : M.state.users.find(user => user.id === mailboxId && user.active);
  }

  function currentMailbox() {
    const ids = allowedIds();
    const active = ids.includes(M.state.activeMailboxId) ? M.state.activeMailboxId : M.state.currentUser;
    return mailboxById(active);
  }

  function mailboxAvatar(mailbox) {
    return mailbox.id === 'team'
      ? `<span class="mailbox-team-avatar">${icon('users', 18)}</span>`
      : M.avatar(mailbox.name, mailbox.color || 'sage', mailbox.avatarUrl || '');
  }

  function typeLabel(mailbox) {
    return mailbox.id === 'team' ? 'Общий ящик' : mailbox.id === M.state.currentUser ? 'Мой ящик' : 'Делегированный доступ';
  }

  M.renderMailboxSwitch = function () {
    const mailbox = currentMailbox();
    if (!mailbox) return '';
    return `<button class="workspace-switch mailbox-switcher" type="button" data-action="mailbox-switch" aria-haspopup="dialog" aria-label="Переключить почтовый ящик. Выбран ${escape(address(mailbox))}">${mailboxAvatar(mailbox)}<span class="mailbox-switch-copy"><strong>${escape(typeLabel(mailbox))}</strong><small>${escape(address(mailbox))}</small></span>${icon('chevron-down', 16)}</button>`;
  };

  function openMailboxSwitcher() {
    const user = M.getUser();
    if (!user?.active) return;
    const active = currentMailbox()?.id;
    const mailboxes = [...new Set(allowedIds())].map(mailboxById).filter(Boolean);
    M.openModal('Почтовые ящики', `<div class="mailbox-picker"><p class="mailbox-picker-description">Выберите ящик для работы с письмами и облаком.</p><div class="mailbox-picker-list">${mailboxes.map(mailbox => `<button class="mailbox-choice ${active === mailbox.id ? 'selected' : ''}" type="button" data-action="select-mailbox" data-mailbox-id="${escape(mailbox.id)}" aria-pressed="${active === mailbox.id}">${mailboxAvatar(mailbox)}<span class="mailbox-choice-copy"><strong>${escape(mailbox.id === 'team' ? 'Общий ящик команды' : mailbox.name)}</strong><span>${escape(address(mailbox))}</span><small>${escape(typeLabel(mailbox))} · 15 ГБ облака</small></span><span class="mailbox-choice-status">${active === mailbox.id ? icon('check', 19) : icon('chevron-right', 17)}</span></button>`).join('')}</div><div class="mailbox-picker-domain">${icon('globe', 15)}<span>Рабочий домен: <strong>archiverf.ru</strong> · демоящики</span></div><p class="mailbox-picker-identity">Вход: ${escape(user.name)}. Переключение ящика сохраняет ваш профиль, личный чат и роль.</p><button class="button secondary mailbox-manage-access" type="button" data-action="mailbox-access-settings">${icon('lock', 16)} Настроить доступ к моему ящику</button></div>`);
  }

  function eligibleMembers() {
    return M.state.users.filter(user => user.active && user.id !== M.state.currentUser);
  }

  M.renderMailboxAccessSettings = function () {
    const user = M.getUser();
    if (!user?.active) return '';
    const sharedWith = Array.isArray(user.sharedWith) ? user.sharedWith : [];
    const members = eligibleMembers();
    return `<div class="settings-card mailbox-access-settings"><div class="settings-card-heading">${icon('users', 19)}<h2>Доступ к моему ящику</h2></div><p class="muted">Разрешите коллеге работать с вашим ящиком ${escape(address(user))}.</p><form id="settings-mailbox-access-form" data-mailbox-owner="${escape(user.id)}"><fieldset class="mailbox-access-members"><legend class="sr-only">Сотрудники с доступом к вашему почтовому ящику</legend>${members.length ? members.map(member => `<label class="mailbox-access-member"><input type="checkbox" name="memberId" value="${escape(member.id)}"${sharedWith.includes(member.id) ? ' checked' : ''}>${M.avatar(member.name, member.color || 'sage', member.avatarUrl || '')}<span><strong>${escape(member.name)}</strong><small>${escape(address(member))}</small></span></label>`).join('') : '<p class="muted">Других активных участников пока нет.</p>'}</fieldset><p class="mailbox-access-description">Коллега сможет читать письма, отвечать от имени этого ящика и работать с его файлами. Ваш личный профиль и чат останутся отдельными.</p><div class="form-error" id="mailbox-access-error" role="alert"></div><div class="form-actions"><button class="button primary" type="submit">Сохранить доступ</button>${sharedWith.length ? '<button class="button subtle" type="button" data-action="revoke-mailbox-access">Отозвать весь доступ</button>' : ''}</div></form><div class="settings-note">${icon('lock', 15)} Доступ выдаёт владелец ящика. Администратор не получает личные письма автоматически. Изменения сохраняются в этом браузере.</div></div>`;
  };

  function accessError(message) {
    const element = document.getElementById('mailbox-access-error');
    if (element) {
      element.textContent = message;
      element.classList.add('visible');
    } else M.toast(message);
  }

  function saveDelegation(user, next) {
    const before = user.sharedWith;
    user.sharedWith = next;
    if (M.persist() === false) {
      if (before === undefined) delete user.sharedWith;
      else user.sharedWith = before;
      accessError('Не удалось сохранить доступ. Освободите хранилище браузера и повторите попытку.');
      return false;
    }
    return true;
  }

  M.onMailboxSubmit = function (event) {
    const form = event.target;
    if (form?.id !== 'settings-mailbox-access-form') return false;
    event.preventDefault();
    const user = M.getUser();
    if (!user?.active || form.dataset.mailboxOwner !== user.id) {
      accessError('Изменить доступ может только владелец ящика.');
      return true;
    }
    const requested = [...new Set(new FormData(form).getAll('memberId'))];
    const eligible = new Set(eligibleMembers().map(member => member.id));
    if (requested.length > 250 || requested.some(memberId => typeof memberId !== 'string' || !eligible.has(memberId))) {
      accessError('Список сотрудников изменился. Откройте настройки и выберите активных участников.');
      return true;
    }
    if (saveDelegation(user, requested)) {
      M.render();
      M.toast(requested.length ? 'Доступ к вашему ящику обновлён' : 'Ваш ящик доступен только вам');
    }
    return true;
  };

  M.onMailboxAction = function (action, element) {
    if (!['mailbox-switch', 'select-mailbox', 'mailbox-access-settings', 'revoke-mailbox-access'].includes(action)) return false;
    const user = M.getUser();
    if (!user?.active) return true;
    if (action === 'mailbox-switch') {
      openMailboxSwitcher();
      return true;
    }
    if (action === 'select-mailbox') {
      const mailboxId = element?.dataset?.mailboxId;
      const mailbox = mailboxById(mailboxId);
      if (!mailbox || !allowedIds().includes(mailboxId)) {
        M.toast('У вас нет доступа к этому ящику');
        return true;
      }
      M.closeModal();
      M.state.activeMailboxId = mailboxId;
      M.state.view = mailboxId === 'team' ? 'shared' : 'inbox';
      M.state.query = '';
      M.state.filter = 'all';
      M.state.checked = [];
      M.state.selectedId = null;
      M.state.reading = false;
      M.state.sidebarOpen = false;
      M.persist();
      M.render();
      M.toast(`Открыт ящик ${address(mailbox)}`);
      return true;
    }
    if (action === 'mailbox-access-settings') {
      M.closeModal();
      M.state.view = 'settings';
      M.state.sidebarOpen = false;
      M.render();
      M.scrollSettingsCard?.('.mailbox-access-settings');
      return true;
    }
    if (action === 'revoke-mailbox-access') {
      if (saveDelegation(user, [])) {
        M.render();
        M.toast('Делегированный доступ к вашему ящику отозван');
      }
      return true;
    }
    return false;
  };
})();
