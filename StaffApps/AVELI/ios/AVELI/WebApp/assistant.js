(function () {
  'use strict';

  const M = window.M;
  if (!M) return;
  const escape = M.escape;
  const histories = Object.create(null);
  const sourceChoices = Object.create(null);
  const undoSort = Object.create(null);
  const commands = Object.create(null);
  const sparkle = '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="m12 3 2.6 6.4L21 12l-6.4 2.6L12 21l-2.6-6.4L3 12l6.4-2.6L12 3Z" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/><path d="m20 2 .8 1.9L23 5l-2.2.9L20 8l-.8-2.1L17 5l2.2-1.1L20 2Z" fill="currentColor"/></svg>';
  const icon = name => M.icon(name, 18);
  const currentId = () => M.getUser()?.id || 'anonymous';
  const getHistory = () => histories[currentId()] || (histories[currentId()] = []);
  const accessible = () => typeof M.accessibleMails === 'function' ? M.accessibleMails() : [];

  function selectedMail() {
    const id = sourceChoices[currentId()] || M.state.selectedId;
    const mails = accessible();
    return mails.find(mail => mail.id === id) || mails.find(mail => mail.unread) || mails[0];
  }

  function appendResult(result) {
    result.id = `assistant-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
    result.time = new Date().toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
    getHistory().unshift(result);
    histories[currentId()] = getHistory().slice(0, 20);
    M.state.view = 'assistant';
    M.render();
  }

  function extractSentences(body) {
    const text = String(body || '').trim();
    if (!text) return [];
    const sentences = text.match(/[^.!?\n]+[.!?]+(?=\s|$)|[^.!?\n]+$/gm) || text.split(/\n+/);
    return sentences.map(sentence => sentence.trim()).filter(Boolean).slice(0, 3);
  }

  function summarise() {
    const mail = selectedMail();
    if (!mail) {
      M.toast('Пока нет доступных писем для разбора.');
      return;
    }
    appendResult({ type: 'summary', title: 'Главное в выбранном письме', mailId: mail.id,
      subject: mail.subject, sender: mail.sender, email: mail.email,
      sentences: extractSentences(mail.body), query: 'Покажи главное в письме' });
  }

  function draftFor(mail) {
    const user = M.getUser();
    return {
      to: (mail.folder === 'sent' ? mail.to : mail.email) || '',
      subject: /^re:/i.test(mail.subject || '') ? mail.subject : `Re: ${mail.subject || 'Ваше письмо'}`,
      body: `Здравствуйте!\n\nСпасибо за ваше письмо${mail.subject ? ` «${mail.subject}»` : ''}. Мы получили его и внимательно ознакомимся с деталями.\n\n[Добавьте ответ на вопрос, информацию об архиве и следующий шаг.]\n\nС уважением,\n${user?.name || 'Команда проекта'}\nЖивая память`
    };
  }

  function prepareDraft() {
    const mail = selectedMail();
    if (!mail) {
      M.toast('Выберите письмо, чтобы подготовить ответ.');
      return;
    }
    appendResult({ type: 'draft', title: 'Основа ответа готова', subject: mail.subject,
      mailId: mail.id, draft: draftFor(mail), query: 'Подготовь черновик ответа' });
  }

  function keywordsFor(query) {
    const stopwords = new Set(['найди', 'найдите', 'покажи', 'покажите', 'поиск', 'ищи', 'пожалуйста', 'письма', 'письмо', 'письмах', 'почта', 'все', 'всю', 'мне', 'про', 'для', 'где', 'есть', 'теме', 'по', 'на', 'об', 'от', 'и', 'с', 'в']);
    return String(query).toLocaleLowerCase('ru').replace(/ё/g, 'е').split(/[^a-zа-я0-9@.]+/i)
      .filter(token => token.length > 1 && !stopwords.has(token))
      .map(token => token.startsWith('фотограф') ? 'фото' : token.startsWith('архив') ? 'архив' : token.startsWith('семейн') ? 'семейн' : token);
  }

  function search(query) {
    const keywords = keywordsFor(query);
    if (!keywords.length) {
      appendResult({ type: 'help', title: 'Уточните, что найти', query,
        text: 'Добавьте имя, адрес или тему: например, «Найди письма про фотографии». Поиск проверяет отправителя, тему и текст доступных вам писем.' });
      return;
    }
    const mails = accessible().filter(mail => {
      const text = `${mail.sender} ${mail.email} ${mail.subject} ${mail.body}`.toLocaleLowerCase('ru').replace(/ё/g, 'е');
      return keywords.every(keyword => text.includes(keyword));
    });
    appendResult({ type: 'search', title: mails.length ? `Найдено писем: ${mails.length}` : 'Писем не нашлось',
      query, keywords, mailIds: mails.slice(0, 8).map(mail => mail.id), total: mails.length });
  }

  function runCommand(value) {
    const query = String(value || '').trim();
    if (!query) {
      document.getElementById('ai-command-input')?.focus();
      return;
    }
    commands[currentId()] = '';
    if (/(?:кратко|главное|разбери|суммар|резюме|суть)/i.test(query)) summarise();
    else if (/(?:черновик|подготовь ответ|составь ответ|напиши ответ)/i.test(query)) prepareDraft();
    else if (/(?:разложи|рассортируй|сортируй|сортиров)/i.test(query)) classifyInbox();
    else search(query);
  }

  function labelFor(mail) {
    if (typeof M.classify === 'function') return M.classify(mail);
    const text = `${mail.subject} ${mail.body}`.toLocaleLowerCase('ru');
    if (/(?:архив|фото|оцифров|дневник|снимк)/.test(text)) return 'Архивы';
    if (String(mail.email || '').endsWith('@memory.example')) return 'Команда';
    return 'Клиенты';
  }

  function classifyInbox() {
    const user = M.getUser();
    if (!user) return;
    const mails = accessible().filter(mail => mail.owner === user.id && mail.folder === 'inbox');
    const changes = [];
    mails.forEach(mail => {
      const label = labelFor(mail);
      if (mail.label !== label) {
        changes.push({ id: mail.id, before: mail.label, after: label });
        mail.label = label;
      }
    });
    if (changes.length) {
      getHistory().forEach(entry => { if (entry.type === 'sort') entry.canUndo = false; });
      undoSort[user.id] = changes;
    }
    M.persist();
    appendResult({ type: 'sort', title: changes.length ? 'Письма распределены по меткам' : 'Метки уже в порядке',
      query: 'Разложи мои входящие', count: changes.length,
      counts: { 'Архивы': mails.filter(mail => mail.label === 'Архивы').length,
        'Команда': mails.filter(mail => mail.label === 'Команда').length,
        'Клиенты': mails.filter(mail => mail.label === 'Клиенты').length },
      canUndo: Boolean(changes.length) });
  }

  function undoClassification() {
    const id = currentId();
    const changes = undoSort[id];
    if (!changes?.length) {
      M.toast('Эта сортировка уже отменена.');
      return;
    }
    const mails = accessible();
    changes.forEach(change => {
      const mail = mails.find(item => item.id === change.id && item.owner === id);
      if (mail && mail.label === change.after) mail.label = change.before;
    });
    delete undoSort[id];
    getHistory().forEach(entry => { if (entry.type === 'sort') entry.canUndo = false; });
    M.persist();
    M.render();
    M.toast('Предыдущие метки восстановлены.');
  }

  function renderResult(result) {
    let body = '';
    if (result.type === 'summary') {
      const stillAccessible = accessible().some(mail => mail.id === result.mailId);
      if (!stillAccessible) return '';
      body = `<div class="ai-result-source">${icon('mail')}<span>${escape(result.sender || result.email)}<strong>${escape(result.subject)}</strong></span><button class="button small" data-action="ai-result-mail" data-mail-id="${escape(result.mailId)}">Открыть</button></div>
        ${result.sentences.length ? `<ul class="ai-extracts">${result.sentences.map(sentence => `<li>${escape(sentence)}</li>`).join('')}</ul>` : '<p>В этом письме нет текста.</p>'}
        <p class="ai-result-note">Это первые фразы письма. Смысловой анализ станет доступен после подключения вашей модели.</p>
        <button class="ai-text-button" data-action="ai-draft" data-mail-id="${escape(result.mailId)}">${icon('edit')} Подготовить ответ</button>`;
    } else if (result.type === 'draft') {
      if (!accessible().some(mail => mail.id === result.mailId)) return '';
      body = `<div class="ai-draft-head"><span>Кому: ${escape(result.draft.to)}</span><strong>${escape(result.draft.subject)}</strong></div>
        <div class="ai-draft-preview">${escape(result.draft.body)}</div>
        <div class="ai-result-actions"><button class="button primary" data-action="ai-open-draft" data-result-id="${escape(result.id)}">${icon('edit')} Открыть редактор</button><span>Шаблон. Дополните перед отправкой.</span></div>`;
    } else if (result.type === 'search') {
      const mails = accessible().filter(mail => result.mailIds.includes(mail.id));
      body = mails.length ? `<div class="ai-found-mails">${mails.map(mail => `<button class="ai-found-mail" data-action="ai-result-mail" data-mail-id="${escape(mail.id)}"><span class="ai-found-icon">${icon('mail')}</span><span><strong>${escape(mail.subject)}</strong><small>${escape(mail.sender || mail.email)} · ${escape(mail.time || '')}</small></span>${icon('arrow-right')}</button>`).join('')}</div>${result.total > 8 ? '<p class="ai-result-note">Показаны первые 8 совпадений.</p>' : ''}` : '<p>Попробуйте другое слово или имя. Поиск доступен по вашим письмам и общему ящику.</p>';
      body += '<p class="ai-result-note">Поиск по словам, без обращения к ИИ.</p>';
    } else if (result.type === 'sort') {
      body = `<p>${result.count ? `Обновлены метки у ${result.count} писем в ваших входящих.` : 'Все личные входящие уже распределены по этим правилам.'}</p>
        <div class="ai-label-counts">${Object.entries(result.counts).map(([label, count]) => `<span><i></i>${escape(label)}<b>${count}</b></span>`).join('')}</div>
        <p class="ai-result-note">Слова об архиве и фотографиях → «Архивы», внутренние отправители → «Команда», остальные → «Клиенты». Письма остаются во входящих.</p>
        ${result.canUndo && undoSort[currentId()] ? '<button class="ai-text-button" data-action="ai-undo-sort">Отменить сортировку</button>' : ''}`;
    } else {
      body = `<p>${escape(result.text)}</p>`;
    }
    return `<article class="ai-result"><div class="ai-result-question"><span>${escape(result.query)}</span><time>${escape(result.time)}</time></div><div class="ai-result-response"><div class="ai-response-icon">${sparkle}</div><div class="ai-response-content"><h3>${escape(result.title)}</h3>${body}</div></div></article>`;
  }

  M.renderAssistant = function () {
    const user = M.getUser();
    const mail = selectedMail();
    const mails = accessible();
    const history = getHistory();
    return `<section class="assistant-view" aria-label="Помощник памяти">
      <div class="ai-hero"><div class="ai-orb" aria-hidden="true"><div>${sparkle}</div><i></i><i></i></div><span class="ai-kicker">ПОМОЩНИК ПАМЯТИ</span><h2>Меньше рутины.<br><span>Больше памяти.</span></h2><p>Находите нужное, разбирайте письма<br class="ai-desktop-break"> и готовьте ответы в одном месте.</p><span class="ai-demo-badge"><i></i>Демо помощника · модель пока не подключена</span></div>
      <div class="ai-workbench"><form id="ai-command-form" class="ai-command-form"><label for="ai-command-input" class="sr-only">Команда помощнику</label><span>${sparkle}</span><input id="ai-command-input" name="command" type="text" maxlength="500" autocomplete="off" placeholder="Например, найди письма про фотографии" value="${escape(commands[currentId()] || '')}"><button type="submit" class="ai-command-send" aria-label="Выполнить команду">${icon('arrow-up-right')}</button></form><p class="ai-command-note">В демо работают поиск, выдержки из письма, шаблон ответа и правила сортировки.</p>
      <div class="ai-task-grid"><button class="ai-task-card" data-action="ai-selected-summary"><span class="ai-task-icon">${icon('mail')}</span><strong>Главное из письма</strong><small>Быстро прочитать первые фразы</small><span class="ai-task-arrow">${icon('arrow-up-right')}</span></button><button class="ai-task-card" data-action="ai-draft"><span class="ai-task-icon">${icon('edit')}</span><strong>Подготовить ответ</strong><small>Черновик, который можно дополнить</small><span class="ai-task-arrow">${icon('arrow-up-right')}</span></button><button class="ai-task-card" data-action="ai-search-photos"><span class="ai-task-icon">${icon('search')}</span><strong>Найти важное</strong><small>Письма о семейных фотографиях</small><span class="ai-task-arrow">${icon('arrow-up-right')}</span></button><button class="ai-task-card" data-action="ai-sort-now"><span class="ai-task-icon">${icon('archive')}</span><strong>Разложить входящие</strong><small>Назначить метки по правилам</small><span class="ai-task-arrow">${icon('arrow-up-right')}</span></button></div>
      <div class="ai-source-selector"><label for="ai-mail-source">Письмо для разбора и ответа</label><select id="ai-mail-source" ${!mails.length ? 'disabled' : ''}>${mails.length ? mails.map(item => `<option value="${escape(item.id)}" ${item.id === mail?.id ? 'selected' : ''}>${escape(item.sender || item.email)} — ${escape(item.subject)}</option>`).join('') : '<option>Нет доступных писем</option>'}</select></div>
      <div class="ai-automation"><div class="ai-automation-icon">${sparkle}</div><div><h3>Порядок без лишних действий</h3><p>Автоматически назначать метки новым личным входящим по тем же правилам.</p><span>В пределах этого демо · можно отключить</span></div><button class="ai-switch${user?.smartSort ? ' enabled' : ''}" data-action="ai-toggle-sort" role="switch" aria-checked="${Boolean(user?.smartSort)}" aria-label="Автоматическая сортировка новых писем"><span></span></button></div>
      ${history.length ? `<div class="ai-results-heading"><h3>Последние действия</h3><button class="ai-text-button" data-action="ai-clear-history">Очистить</button></div><div class="ai-results" aria-live="polite">${history.map(renderResult).join('')}</div>` : '<div class="ai-empty-history"><span>Начните с письма или короткой команды.</span><small>Письма отправляются только из редактора после вашего действия.</small></div>'}
      <div class="ai-connection-note">${icon('lock')}<p>Подключение вашей ИИ модели — следующий этап. В демо тексты обрабатываются в браузере и не отправляются в сторонние сервисы.</p></div></div>
    </section>`;
  };

  M.onAiAction = function (action, element) {
    if (!action.startsWith('ai-')) return false;
    switch (action) {
      case 'ai-summary':
        if (element?.dataset.id && accessible().some(mail => mail.id === element.dataset.id)) sourceChoices[currentId()] = element.dataset.id;
        else if (accessible().some(mail => mail.id === M.state.selectedId)) sourceChoices[currentId()] = M.state.selectedId;
        summarise();
        break;
      case 'ai-selected-summary':
        summarise();
        break;
      case 'ai-draft':
        if (element?.dataset.mailId) sourceChoices[currentId()] = element.dataset.mailId;
        prepareDraft();
        break;
      case 'ai-search-photos':
        search('Найди письма про фото');
        break;
      case 'ai-command':
        runCommand(document.getElementById('ai-command-input')?.value || element?.dataset.command);
        break;
      case 'ai-sort-now':
        classifyInbox();
        break;
      case 'ai-undo-sort':
        undoClassification();
        break;
      case 'ai-toggle-sort': {
        const user = M.getUser();
        if (!user) break;
        user.smartSort = !user.smartSort;
        M.persist();
        M.render();
        M.toast(user.smartSort ? 'Правила для новых личных входящих включены.' : 'Автоматическая сортировка отключена.');
        break;
      }
      case 'ai-open-draft': {
        const result = getHistory().find(item => item.id === element?.dataset.resultId && item.type === 'draft');
        if (result && accessible().some(mail => mail.id === result.mailId)) M.openCompose(result.draft);
        else M.toast('Исходное письмо больше недоступно.');
        break;
      }
      case 'ai-result-mail': {
        const mail = accessible().find(item => item.id === element?.dataset.mailId);
        if (!mail) {
          M.toast('Письмо больше недоступно.');
          break;
        }
        if (typeof M.openMail === 'function') M.openMail(mail.id);
        else {
          M.state.activeMailboxId = mail.owner;
        M.state.selectedId = mail.id;
          M.state.view = mail.owner === 'team' ? 'shared' : mail.folder === 'inbox' ? 'inbox' : mail.folder;
          M.state.query = '';
          M.state.filter = 'all';
          M.state.reading = true;
          mail.unread = false;
          M.persist();
          M.render();
        }
        break;
      }
      case 'ai-clear-history':
        histories[currentId()] = [];
        M.render();
        break;
      default:
        return false;
    }
    return true;
  };

  M.aiLabelFor = labelFor;
  document.addEventListener('submit', function (event) {
    if (event.target.id !== 'ai-command-form') return;
    event.preventDefault();
    runCommand(new FormData(event.target).get('command'));
  });
  document.addEventListener('change', function (event) {
    if (event.target.id === 'ai-mail-source') sourceChoices[currentId()] = event.target.value;
  });
  document.addEventListener('input', function (event) {
    if (event.target.id === 'ai-command-input') commands[currentId()] = event.target.value;
  });
})();
