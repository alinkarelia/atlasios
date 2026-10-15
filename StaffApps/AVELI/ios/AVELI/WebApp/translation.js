(function () {
  'use strict';
  const M = window.M;
  const languages = [
    ['ru','Русский'],['en','English'],['de','Deutsch'],['fr','Français'],['es','Español'],['it','Italiano'],
    ['pt','Português'],['uk','Українська'],['tr','Türkçe'],['ar','العربية'],['zh','中文'],['ja','日本語']
  ];
  const languageIds = new Set(languages.map(([id])=>id));
  const esc = M.escape;
  let active = null, lastLanguages = {source:'ru',target:'en'}, sequence = 0;
  const root = document.createElement('div');
  root.id = 'translation-root';
  document.body.append(root);
  const actor = () => M.getUser?.()?.active ? M.state.currentUser : null;
  const mailbox = () => M.state.activeMailboxId || M.state.currentUser;
  function roomAllowed(room) {
    if (!actor()) return false;
    if (['general','archives','digitize'].includes(room)) return true;
    if (typeof room !== 'string') return false;
    const ids = room.split(':');
    return ids.length === 3 && ids[0] === 'dm' && ids[1] !== ids[2] && ids.slice(1).includes(actor())
      && ids.slice(1).every(id=>M.state.users.some(user=>user.id===id && user.active))
      && room === 'dm:'+ids.slice(1).sort().join(':');
  }
  function incoming(type,id) {
    if (type === 'mail') {
      if (M.state.view === 'chat' || M.state.selectedId !== id) return null;
      const mail = M.accessibleMails?.().find(item=>item.id===id);
      return mail && {text:String(mail.body || ''),id:mail.id,mailboxId:mail.owner};
    }
    if (type === 'chat' && M.state.view === 'chat' && roomAllowed(M.state.chatRoom)) {
      const message = M.state.chats?.messages?.find(item=>item.id===id && item.room===M.state.chatRoom);
      return message && {text:String(message.text || message.media?.transcript || ''),id:message.id,room:message.room};
    }
    return null;
  }
  function contextValid(context) {
    if (!context || actor() !== context.actor || mailbox() !== context.mailbox) return false;
    if (context.composer) {
      const current = document.getElementById(context.type === 'mail' ? 'compose-body' : 'chat-text');
      if (current !== context.input || !current?.isConnected || current.form !== context.form || current.value !== context.original) return false;
      if (context.type === 'chat' && (M.state.view !== 'chat' || M.state.chatRoom !== context.room || !roomAllowed(context.room))) return false;
      return !M.allowedMailboxes || M.allowedMailboxes().includes(context.mailbox);
    }
    const item = incoming(context.type,context.id);
    return Boolean(item && item.text === context.original && (context.type !== 'chat' || item.room === context.room));
  }
  function current(operation) {
    return active === operation && contextValid(operation.context) && root.querySelector('#translation-panel')?.isConnected;
  }
  function close(restoreFocus = true) {
    const operation = active;
    active = null; sequence++;
    operation?.controller?.abort();
    root.innerHTML = '';
    if (restoreFocus && operation?.focus?.isConnected) operation.focus.focus({preventScroll:true});
  }
  function setStatus(text,error = false) {
    const el = root.querySelector('#translation-status');
    if (!el) return;
    el.textContent = text; el.classList.toggle('translation-error',error);
  }
  function counts() {
    const input = root.querySelector('#translation-source-text');
    const label = root.querySelector('#translation-count');
    if (input && label) label.textContent = `${[...input.value].length.toLocaleString('ru-RU')} / 6 000`;
  }
  function invalidateResult() {
    if (!active) return;
    active.controller?.abort(); active.requestId = ++sequence; active.result = null;
    const output = root.querySelector('#translation-result');
    if (output) output.value = '';
    const button = root.querySelector('[data-action="translation-run"]');
    if (button) {button.disabled = false;button.textContent = 'Перевести';}
    for (const element of root.querySelectorAll('[data-translation-result-action]')) element.disabled = true;
    setStatus('Выберите языки и нажмите «Перевести».');
    counts();
  }
  function open(type,id,composer,focus) {
    if (!actor() || !['mail','chat'].includes(type)) return;
    let context;
    if (composer) {
      const input = document.getElementById(type === 'mail' ? 'compose-body' : 'chat-text');
      if (!input?.form) { M.toast('Откройте письмо или чат для перевода'); return; }
      context = {type,composer:true,input,form:input.form,original:input.value,actor:actor(),mailbox:mailbox(),room:M.state.chatRoom};
    } else {
      const item = incoming(type,id);
      if (!item?.text.trim()) {M.toast('Сообщение недоступно для перевода');return;}
      context = {type,id,original:item.text,actor:actor(),mailbox:mailbox(),room:item.room};
    }
    if (!contextValid(context)) return;
    close(false);
    active = {context,focus,result:null,controller:null,requestId:++sequence};
    const options = selected=>languages.map(([id,label])=>`<option value="${id}" ${id===selected?'selected':''}>${esc(label)}</option>`).join('');
    root.innerHTML = `<div class="translation-backdrop"><section class="translation-panel" id="translation-panel" role="dialog" aria-modal="true" aria-labelledby="translation-title"><header><div><span class="translation-eyebrow">AVELI · TRANSLATE</span><h2 id="translation-title">${composer?'Написать на другом языке':'Перевести '+(type==='mail'?'письмо':'сообщение')}</h2></div><button type="button" class="icon-button" data-action="translation-close" aria-label="Закрыть переводчик">${M.icon('close',18)}</button></header><div class="translation-languages"><label for="translation-source-language">Язык оригинала<select id="translation-source-language">${options(lastLanguages.source)}</select></label><button type="button" class="icon-button translation-swap" data-action="translation-swap" aria-label="Поменять языки местами">⇄</button><label for="translation-target-language">Язык перевода<select id="translation-target-language">${options(lastLanguages.target)}</select></label></div><div class="translation-texts"><label for="translation-source-text"><span>Оригинал <small id="translation-count"></small></span><textarea id="translation-source-text" maxlength="6000" dir="auto" spellcheck="false" placeholder="Напишите текст для перевода…">${esc(context.original)}</textarea></label><label for="translation-result"><span>Перевод <small>MyMemory</small></span><textarea id="translation-result" readonly dir="auto" placeholder="Здесь появится перевод после вашего запроса"></textarea></label></div><p class="translation-status" id="translation-status" role="status" aria-live="polite">${[...context.original].length>6000?'Выберите фрагмент до 6 000 символов в поле оригинала.':'Выберите языки и нажмите «Перевести».'}</p><p class="translation-provider-note">По кнопке «Перевести» только текст из поля оригинала передаётся сервису MyMemory. Бесплатный сервис имеет лимиты. Оригинал ${composer?'в черновике':'сообщения'} сохраняется.</p><footer><button type="button" class="button secondary small" data-action="translation-copy" data-translation-result-action disabled>${M.icon('copy',15)} Копировать</button>${composer?'<button type="button" class="button secondary small" data-action="translation-insert" data-translation-result-action disabled>Вставить в черновик</button>':''}<button type="button" class="button primary small" data-action="translation-run">Перевести</button></footer></section></div>`;
    counts();
    root.querySelector('#translation-source-language')?.focus({preventScroll:true});
  }
  async function csrf(operation,force = false) {
    if (!force && M.hostedSession?.csrf) return M.hostedSession.csrf;
    const response = await fetch('/api/session',{credentials:'same-origin',cache:'no-store',headers:{Accept:'application/json'},signal:operation.controller.signal});
    if (!response.ok) throw new Error(location.hostname === '127.0.0.1'
      ? 'Переводчик станет доступен после подключения сервера AVELI. Ваш текст остаётся в черновике.'
      : 'Сессия AVELI недоступна. Войдите в приложение повторно.');
    const data = await response.json();
    if (data?.mode === 'local-demo' && data.remoteConfigured === false) {
      throw new Error('Переводчик станет доступен после подключения сервера AVELI. Ваш текст остаётся в черновике.');
    }
    if (!data?.user || typeof data.csrf !== 'string' || !/^[A-Za-z0-9_-]{32}$/.test(data.csrf)) throw new Error('Не удалось подтвердить сессию. Обновите страницу.');
    if (!current(operation)) throw new DOMException('Context changed','AbortError');
    M.hostedSession = data;
    return data.csrf;
  }
  async function run() {
    const operation = active;
    if (!current(operation)) {close();return;}
    const input = root.querySelector('#translation-source-text');
    const text = input.value, source = root.querySelector('#translation-source-language').value, target = root.querySelector('#translation-target-language').value;
    if (!text.trim() || [...text].length>6000) {setStatus('Выберите текст от 1 до 6 000 символов.',true);return;}
    if (!languageIds.has(source) || !languageIds.has(target) || source===target) {setStatus('Выберите два разных языка.',true);return;}
    operation.controller?.abort(); operation.controller = new AbortController(); operation.requestId = ++sequence; operation.result = null;
    const controller = operation.controller;
    const requestId = operation.requestId;
    const button = root.querySelector('[data-action="translation-run"]'); button.disabled = true;button.textContent = 'Переводим…';
    root.querySelector('#translation-result').value = '';
    for (const el of root.querySelectorAll('[data-translation-result-action]')) el.disabled = true;
    setStatus('Отправляем выбранный текст в MyMemory…');
    const timeout = setTimeout(()=>controller.abort(),55000);
    try {
      let token = await csrf(operation), response, data;
      for (let attempt = 0; attempt < 2; attempt++) {
        if (!current(operation) || operation.requestId!==requestId) return;
        response = await fetch('/api/translate',{method:'POST',credentials:'same-origin',cache:'no-store',headers:{'Content-Type':'application/json','X-CSRF-Token':token,Accept:'application/json'},body:JSON.stringify({text,source,target}),signal:controller.signal});
        try {data = await response.json();} catch {throw new Error('Сервис перевода вернул некорректный ответ.');}
        if (!current(operation) || operation.requestId!==requestId) return;
        // Another tab can refresh the shared HttpOnly cookie. Retry once only
        // when the Worker confirms CSRF failed before contacting the provider.
        if (attempt === 0 && response.status === 403 && data?.error?.code === 'csrf') {
          setStatus('Обновляем сессию и повторяем запрос…');
          token = await csrf(operation,true);
          continue;
        }
        break;
      }
      if (!response.ok) throw new Error(typeof data?.error?.message==='string'?data.error.message.slice(0,300):'Не удалось выполнить перевод. Повторите попытку.');
      if (!current(operation) || operation.requestId!==requestId) return;
      if (typeof data?.translatedText!=='string' || !data.translatedText.trim() || [...data.translatedText].length>24000 || data.source!==source || data.target!==target || data.provider!=='MyMemory') throw new Error('Сервис перевода вернул некорректный результат.');
      if (data.translatedText===text && /\p{L}/u.test(text)) throw new Error('Сервис вернул исходный текст. Проверьте язык оригинала.');
      operation.result = data.translatedText;
      root.querySelector('#translation-result').value = data.translatedText;
      for (const el of root.querySelectorAll('[data-translation-result-action]')) el.disabled = false;
      lastLanguages = {source,target};
      setStatus(data.unchangedChunks?'Перевод готов. Некоторые фрагменты остались без изменений — проверьте их перед отправкой.':operation.context.composer?'Перевод готов. Проверьте текст и вставьте его в черновик.':'Перевод готов. Оригинальное сообщение сохранено.');
    } catch (error) {
      if (current(operation) && operation.requestId===requestId) setStatus(error?.name==='AbortError'?'Перевод прерван. Повторите попытку.':error.message || 'Не удалось выполнить перевод.',true);
    } finally {
      clearTimeout(timeout);
      if (current(operation) && operation.requestId===requestId) {button.disabled = false;button.textContent = 'Перевести';}
    }
  }
  async function copy() {
    const operation = active;
    if (!current(operation) || !operation.result) return;
    try {
      if (navigator.clipboard?.writeText) await navigator.clipboard.writeText(operation.result);
      else {const result = root.querySelector('#translation-result');result.focus();result.select();if (!document.execCommand?.('copy')) throw new Error('copy_unavailable');}
      if (current(operation)) setStatus('Перевод скопирован.');
    } catch {if (current(operation)) setStatus('Выделите перевод и скопируйте его вручную.',true);}
  }
  function insert() {
    const operation = active;
    if (!current(operation) || !operation.context.composer || !operation.result) {setStatus('Черновик изменился. Откройте перевод заново.',true);return;}
    const input = operation.context.input;
    if (input.maxLength>0 && operation.result.length>input.maxLength) {setStatus('Перевод превышает лимит сообщения. Скопируйте его и сократите текст.',true);return;}
    input.value = operation.result;
    input.dispatchEvent(new Event('input',{bubbles:true}));
    close(false);input.focus({preventScroll:true});
    M.toast('Перевод вставлен в черновик. Проверьте его перед отправкой');
  }
  M.renderTranslationActions = function ({type,id,text} = {}) {
    if (!['mail','chat'].includes(type) || typeof id!=='string' || !String(text||'').trim()) return '';
    return `<button type="button" class="translation-inline" data-action="translation-open" data-translation-type="${type}" data-translation-id="${esc(id)}" title="Перевести ${type==='mail'?'письмо':'сообщение'}">${M.icon('globe',14)}<span>Перевести</span></button>`;
  };
  M.renderComposerTranslation = function ({type} = {}) {
    if (!['mail','chat'].includes(type)) return '';
    return `<button type="button" class="${type==='mail'?'button secondary small':'icon-button'} translation-compose-button" data-action="translation-compose" data-translation-type="${type}" title="Перевести черновик перед отправкой" aria-label="Перевести черновик перед отправкой">${M.icon('globe',type==='mail'?15:19)}${type==='mail'?'<span>Переводчик</span>':''}</button>`;
  };
  M.onTranslationAction = function (action,element) {
    if (!action.startsWith('translation-')) return false;
    switch (action) {
      case 'translation-open':open(element.dataset.translationType,element.dataset.translationId,false,element);break;
      case 'translation-compose':open(element.dataset.translationType,null,true,element);break;
      case 'translation-close':close();break;
      case 'translation-run':void run();break;
      case 'translation-copy':void copy();break;
      case 'translation-insert':insert();break;
      case 'translation-swap':{const a = root.querySelector('#translation-source-language'),b = root.querySelector('#translation-target-language');if (a&&b) {[a.value,b.value] = [b.value,a.value];invalidateResult();}break;}
    }
    return true;
  };
  M.translation = {sync(){if (active && !contextValid(active.context)) close();},cleanup(){close(false);}};
  document.addEventListener('input',event=>{if (event.target.id==='translation-source-text') invalidateResult();});
  document.addEventListener('change',event=>{if (['translation-source-language','translation-target-language'].includes(event.target.id)) invalidateResult();});
  document.addEventListener('keydown',event=>{
    if (!active) return;
    // Keep global app shortcuts and the underlying compose dialog's focus trap
    // from acting while the translator is the active dialog.
    event.stopImmediatePropagation();
    if (event.key==='Escape') {event.preventDefault();event.stopImmediatePropagation();close();}
    if (event.key==='Tab') {
      const elements = [...root.querySelectorAll('button:not([disabled]),select,textarea')];
      const first = elements[0], last = elements.at(-1);
      if (event.shiftKey && (document.activeElement===first || !root.contains(document.activeElement))) {event.preventDefault();last?.focus();}
      else if (!event.shiftKey && (document.activeElement===last || !root.contains(document.activeElement))) {event.preventDefault();first?.focus();}
    }
  },true);
})();
