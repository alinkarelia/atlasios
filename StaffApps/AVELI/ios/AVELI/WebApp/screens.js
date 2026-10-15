(() => {
  'use strict';

  const groups = [
    { title: 'Mail · Cloud', screens: ['inbox', 'shared', 'compose', 'cloud', 'uploads'] },
    { title: 'Chat · AI · Команда', screens: ['chat', 'assistant', 'team'] },
    { title: 'Управление', screens: ['integrations', 'settings', 'avatar', 'access', 'login'] }
  ];

  const screens = {
    inbox: {
      label: 'Входящие', title: 'Входящие и письмо', caption: 'Mail · Входящие', icon: 'mail',
      description: 'Откройте письмо, переключите папку или подготовьте ответ. Все действия выполняются в самом приложении.',
      note: 'Почта работает на демоданных. Доставка внешних писем потребует подключения почтового сервиса.'
    },
    shared: {
      label: 'Общий ящик', title: 'Общий ящик команды', caption: 'Mail · Общий ящик', icon: 'shared',
      description: 'Посмотрите письма общего ящика и доступные действия. Переключение ящика сохраняет текущий аккаунт и его права.',
      note: 'Доступ определяется текущим аккаунтом. В обзоре нельзя открыть чужой ящик без предоставленных прав.'
    },
    compose: {
      label: 'Новое письмо', title: 'Написать письмо', caption: 'Mail · Новое письмо', icon: 'compose',
      description: 'Выберите отправителя, добавьте адресата и вложение. Попробуйте шаблон, помощь ИИ и отложенную отправку.',
      note: 'Отправка в демоверсии сохраняет письмо в приложении. Внешняя доставка появится после подключения почтового сервиса.'
    },
    cloud: {
      label: 'Облако ящика', title: 'Cloud · 15 ГБ на ящик', caption: 'Cloud · Файлы', icon: 'cloud',
      description: 'Добавьте свой файл, откройте его карточку и подготовьте передачу в семейный архив. У каждого ящика своё облако.',
      note: '15 ГБ — лимит каждого ящика. Сейчас файлы хранятся в этом браузере, и доступное место зависит от него. Общее серверное хранилище ещё не подключено.'
    },
    uploads: {
      label: 'Загрузки', title: 'Загрузки с продолжением', caption: 'Cloud · Загрузки', icon: 'upload',
      description: 'Добавьте файл, приостановите загрузку и продолжите с сохранённой части. Если вкладку закрыли, выберите тот же файл. В очереди отображаются только ваши загрузки.',
      note: 'Файлы и сохранённые части находятся в этом браузере. Загрузка на общий сервер с продолжением станет доступна после подключения серверного хранилища.'
    },
    chat: {
      label: 'Чат и звонки', title: 'Чат, звонки и сообщения', caption: 'Chat · Команда', icon: 'chat',
      description: 'Отправьте файл, запишите голосовое сообщение или видеокружок и попробуйте звонок коллеге. Качество видео подстраивается под соединение. Запись запросит доступ к микрофону и камере.',
      note: 'Чат и записи используют данные этого браузера, демозвонки работают между его вкладками. Для звонков между устройствами и расшифровки нужен общий сервер и сервис распознавания речи.'
    },
    assistant: {
      label: 'ИИ-помощник', title: 'Помощник команды', caption: 'AI · ИИ-помощник', icon: 'assistant',
      description: 'Попробуйте разбор письма, подготовку ответа и действия с подтверждением. Помощник доступен из общего пространства команды.',
      note: 'Ответы демонстрационные. API вашей ИИ-модели ещё не подключён.'
    },
    team: {
      label: 'Команда', title: 'Сотрудники и роли', caption: 'Управление · Команда', icon: 'team',
      description: 'Администратор может управлять сотрудниками, ролями и ящиками. Доступ к этому экрану зависит от текущего аккаунта.',
      note: 'Обзор сохраняет ваши права и не переключает аккаунт на администратора.'
    },
    integrations: {
      label: 'Интеграции', title: 'amoCRM и сервисы', caption: 'Управление · Интеграции', icon: 'integrations',
      description: 'Посмотрите подключение amoCRM и подготовку сделки из письма. Здесь же собраны будущие подключения к другим сервисам.',
      note: 'Серверное подключение amoCRM через OAuth ещё не настроено. Пароли и секретные ключи не нужны для просмотра экрана.'
    },
    settings: {
      label: 'Настройки', title: 'Настройки AVELI', caption: 'AVELI · Настройки', icon: 'settings',
      description: 'Настройте почту, подпись, автоответчик и уведомления. Изменения выполняются в текущем аккаунте приложения.',
      note: 'Настройки сохраняются в этом браузере. Серверная синхронизация между устройствами появится после подключения backend.'
    },
    avatar: {
      label: 'Аватар ящика', title: 'Аватар и профиль', caption: 'Настройки · Аватар', icon: 'avatar',
      description: 'Загрузите аватар почтового ящика или выберите цвет инициалов. Посмотрите, как профиль отображается в почте и чате.',
      note: 'Используйте собственное изображение. Аватар сохраняется в текущем профиле этого браузера.'
    },
    access: {
      label: 'Доступ к ящикам', title: 'Ящики и доступ', caption: 'Настройки · Ящики', icon: 'access',
      description: 'Посмотрите доступные ящики и права команды. Переключаться можно только между ящиками, к которым есть доступ.',
      note: 'Просмотр сохраняет текущего пользователя. Делегированный доступ к личному ящику выдаёт его владелец.'
    },
    login: {
      label: 'Экран входа', title: 'Вход в AVELI', caption: 'Аккаунт · Вход', icon: 'login',
      description: 'Посмотрите экран входа в приложение. Этот просмотр не завершает текущую сессию.',
      note: 'Демонстрационный экран входа не заменяет серверную авторизацию и не меняет права текущего аккаунта.'
    }
  };

  const iconPaths = {
    mail: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 6 9 7 9-7"/>',
    shared: '<path d="M3 8h18v12H3zM3 8l9 7 9-7"/><path d="M8 4h8M10 1h4"/>',
    compose: '<path d="M12 5H4v15h15v-8M16 3l5 5-9 9-5 1 1-5z"/>',
    cloud: '<path d="M7 18h11a4 4 0 0 0 .5-8 6 6 0 0 0-11.6-1.5A4.8 4.8 0 0 0 7 18z"/>',
    upload: '<path d="M12 16V3m-5 5 5-5 5 5M4 15v6h16v-6"/>',
    chat: '<path d="M3 4h18v13H9l-6 4zM7 9h10M7 13h6"/>',
    assistant: '<path d="m12 2 2.5 7.5L22 12l-7.5 2.5L12 22l-2.5-7.5L2 12l7.5-2.5z"/>',
    team: '<circle cx="9" cy="8" r="3"/><path d="M3 21v-3a6 6 0 0 1 12 0v3M16 5a3 3 0 0 1 0 6M21 21v-3a6 6 0 0 0-4-5"/>',
    integrations: '<path d="m8 3 5 5-5 5-5-5zM16 11l5 5-5 5-5-5zM12 12l-1 1M14 10l1-1"/>',
    settings: '<path d="m9 3-1 3-3 1-2 5 2 5 3 1 1 3h6l1-3 3-1 2-5-2-5-3-1-1-3z"/><circle cx="12" cy="12" r="3"/>',
    avatar: '<circle cx="12" cy="12" r="10"/><circle cx="12" cy="9" r="3"/><path d="M5 19a7 7 0 0 1 14 0"/>',
    access: '<rect x="3" y="10" width="18" height="11" rx="2"/><path d="M7 10V7a5 5 0 0 1 10 0v3M12 14v3"/>',
    login: '<path d="M13 3h8v18h-8M3 12h13m-5-5 5 5-5 5"/>'
  };

  const navigation = document.getElementById('screen-navigation');
  const select = document.getElementById('screen-select');
  const frame = document.getElementById('application-preview');
  const stage = document.getElementById('preview-stage');
  const modeButtons = Array.from(document.querySelectorAll('[data-view]')).filter(element => element.tagName === 'BUTTON');
  const buttonByScreen = new Map();
  let currentScreen = 'inbox';
  let currentView = 'desktop';
  let frameReady = false;

  const validScreen = value => typeof value === 'string' && Object.prototype.hasOwnProperty.call(screens, value);

  function makeIcon(name) {
    const span = document.createElement('span');
    span.className = 'gallery-screen-icon';
    span.setAttribute('aria-hidden', 'true');
    // Icon paths come exclusively from the fixed table above, never from route or message input.
    span.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">' + iconPaths[name] + '</svg>';
    return span;
  }

  let screenNumber = 0;
  groups.forEach(group => {
    const container = document.createElement('div');
    container.className = 'gallery-nav-group';
    const heading = document.createElement('p');
    heading.className = 'gallery-nav-label';
    heading.textContent = group.title;
    container.append(heading);
    const optionGroup = document.createElement('optgroup');
    optionGroup.label = group.title;

    group.screens.forEach(id => {
      screenNumber += 1;
      const screen = screens[id];
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'gallery-screen-button';
      button.dataset.screen = id;
      button.setAttribute('aria-label', screen.title);
      const label = document.createElement('span');
      label.className = 'gallery-screen-label';
      label.textContent = screen.label;
      const number = document.createElement('span');
      number.className = 'gallery-screen-number';
      number.textContent = String(screenNumber).padStart(2, '0');
      number.setAttribute('aria-hidden', 'true');
      button.append(makeIcon(screen.icon), label, number);
      button.addEventListener('click', () => navigate(id, currentView));
      buttonByScreen.set(id, button);
      container.append(button);

      const option = document.createElement('option');
      option.value = id;
      option.textContent = screen.title;
      optionGroup.append(option);
    });
    navigation.append(container);
    select.append(optionGroup);
  });

  function stateFromHash() {
    const parts = location.hash.slice(1).split('/');
    return { screen: validScreen(parts[0]) ? parts[0] : 'inbox', view: parts[1] === 'iphone' ? 'iphone' : 'desktop' };
  }

  function notifyApplication() {
    if (frameReady && frame.contentWindow) {
      frame.contentWindow.postMessage({ type: 'memory-screen', screen: currentScreen }, location.origin);
    }
  }

  function applyState(screenId, view, notify = true) {
    if (!validScreen(screenId)) return;
    currentScreen = screenId;
    currentView = view === 'iphone' ? 'iphone' : 'desktop';
    const screen = screens[currentScreen];
    buttonByScreen.forEach((button, id) => {
      if (id === currentScreen) button.setAttribute('aria-current', 'page');
      else button.removeAttribute('aria-current');
    });
    select.value = currentScreen;
    modeButtons.forEach(button => button.setAttribute('aria-pressed', String(button.dataset.view === currentView)));
    stage.dataset.view = currentView;
    document.getElementById('screen-title').textContent = screen.title;
    document.getElementById('screen-description').textContent = screen.description;
    document.getElementById('screen-note').textContent = screen.note;
    document.getElementById('preview-caption').textContent = screen.caption;
    document.getElementById('viewport-label').textContent = currentView === 'iphone' ? 'iPhone 12 · до 390 px' : 'Адаптивный веб-интерфейс';
    document.getElementById('open-application').href = '/?screen=' + currentScreen;
    document.getElementById('gallery-live-status').textContent = screen.title + '. ' + (currentView === 'iphone' ? 'Мобильный экран.' : 'Экран компьютера.');
    frame.title = 'AVELI: ' + screen.title.toLowerCase();
    document.title = screen.title + ' · Обзор AVELI';
    if (notify) notifyApplication();
  }

  function navigate(screenId, view) {
    if (!validScreen(screenId)) return;
    const safeView = view === 'iphone' ? 'iphone' : 'desktop';
    const hash = '#' + screenId + '/' + safeView;
    if (location.hash === hash) applyState(screenId, safeView);
    else location.hash = hash;
  }

  select.addEventListener('change', () => navigate(select.value, currentView));
  modeButtons.forEach(button => button.addEventListener('click', () => navigate(currentScreen, button.dataset.view)));
  window.addEventListener('hashchange', () => {
    const state = stateFromHash();
    applyState(state.screen, state.view);
  });
  frame.addEventListener('load', () => {
    // Ignore the empty initial document; only the same-origin application is ready.
    try {
      if (frame.contentWindow.location.origin !== location.origin) return;
    } catch {
      return;
    }
    frameReady = true;
    document.getElementById('preview-loading').hidden = true;
    notifyApplication();
  });
  window.addEventListener('message', event => {
    if (event.origin !== location.origin || event.source !== frame.contentWindow) return;
    const message = event.data;
    if (!message || message.type !== 'memory-screen-changed' || !validScreen(message.screen)) return;
    history.replaceState(null, '', '#' + message.screen + '/' + currentView);
    applyState(message.screen, currentView, false);
  });

  const initial = stateFromHash();
  applyState(initial.screen, initial.view, false);
  // Start navigation after installing the load listener, including on cached visits.
  frame.src = '/?screen=' + initial.screen;
})();
