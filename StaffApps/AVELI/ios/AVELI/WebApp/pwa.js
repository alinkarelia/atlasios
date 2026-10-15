/* AVELI installation UI. Private messages and files are never put in a PWA cache. */
(() => {
  'use strict';
  const M = window.M;
  if (!M) return;
  let pendingPrompt = null;
  let installing = false;
  let registration = null;
  let registrationFailed = false;
  let initialized = false;
  const standalone = window.matchMedia?.('(display-mode: standalone)');
  // This changes installation UI only; it never grants roles or server access.
  const native = /\bAVELI-iOS\b/.test(navigator.userAgent || '');
  let installed = Boolean(standalone?.matches || navigator.standalone || native);
  const ios = /iPhone|iPad|iPod/i.test(navigator.userAgent || '') || navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1;
  const android = /Android/i.test(navigator.userAgent || '');
  const embedded = window.top !== window.self;
  const ic = (name, size = 18) => M.icon?.(name, size) || '';
  const snapshot = () => ({installed, installing, canPrompt:Boolean(pendingPrompt), native, ios, android, embedded, registered:Boolean(registration), registrationFailed});
  function redraw() { if (document.getElementById('app')) M.render?.(); }
  function instructions() {
    if (embedded) return '<p>Откройте AVELI в отдельной вкладке, чтобы установить приложение на устройство.</p><a class="button primary" href="/" target="_top">Открыть AVELI</a>';
    if (installed) return '<p>Вы уже открыли AVELI как приложение. Запускайте его с иконки на устройстве.</p><p class="muted">Для почты, звонков и синхронизации требуется интернет.</p>';
    if (ios) return '<p>На iPhone и iPad установите AVELI через Safari:</p><ol class="pwa-install-steps"><li>Откройте эту страницу в <strong>Safari</strong>.</li><li>Нажмите <strong>«Поделиться»</strong> в панели браузера.</li><li>Выберите <strong>«На экран “Домой”»</strong>. Если пункт скрыт, прокрутите список действий.</li><li>Нажмите <strong>«Добавить»</strong>.</li></ol><p class="muted">На домашнем экране появится иконка AVELI. Приложение откроется в отдельном окне.</p>';
    if (android) return '<p>В Chrome откройте меню <strong>⋮</strong> и выберите <strong>«Установить приложение»</strong> или <strong>«Добавить на главный экран»</strong>, затем подтвердите установку.</p><p class="muted">Названия пунктов зависят от браузера. Если их нет, откройте AVELI в Chrome.</p>';
    return '<p>Откройте AVELI в <strong>Chrome или Edge</strong>. Нажмите значок установки в адресной строке или выберите <strong>«Установить AVELI»</strong> в меню браузера.</p><p class="muted">После установки AVELI откроется в отдельном окне. Если установка ещё не появилась, обновите страницу после первой загрузки.</p>';
  }
  function showInstructions() {
    M.openModal(installed ? 'AVELI на устройстве' : 'Установить AVELI', `<div class="pwa-install-dialog"><img class="pwa-install-logo" src="/app-icon-192.png" width="72" height="72" alt="Логотип AVELI"><div class="pwa-install-intro"><strong>AVELI</strong><span>Mail · Chat · Cloud · AI</span></div>${instructions()}${registrationFailed && !installed ? '<p class="pwa-install-warning" role="status">Браузер пока не подготовил установку. Проверьте соединение и обновите страницу.</p>' : ''}</div>`);
  }
  async function requestInstall() {
    if (installing) return;
    if (!pendingPrompt || installed || embedded) { showInstructions(); return; }
    const prompt = pendingPrompt;
    pendingPrompt = null;
    installing = true;
    // Call prompt synchronously in the click handler, before any asynchronous work.
    try {
      await prompt.prompt();
      const choice = await prompt.userChoice;
      if (choice?.outcome === 'accepted') M.toast?.('Установка запущена · AVELI появится на устройстве');
    } catch { showInstructions(); }
    finally { installing = false; redraw(); }
  }
  M.renderInstallAction = () => `<button type="button" class="pwa-install-action" data-action="pwa-install"${installing ? ' disabled' : ''}>${ic(installed ? 'check' : 'smartphone', 17)}<span>${installing ? 'Установка…' : installed ? 'AVELI на устройстве' : 'Установить AVELI'}</span></button>`;
  M.renderInstallCard = () => `<section class="settings-card pwa-install-card"><div class="pwa-install-card-title">${ic('smartphone', 22)}<div><h3>AVELI на ваших устройствах</h3><p>Компьютер, iPhone, iPad и Android</p></div></div><p>Добавьте AVELI на устройство и открывайте почту, чат и облако из одного приложения.</p>${M.renderInstallAction()}<small>${installed ? 'Открыто как приложение' : 'Установка из браузера · без App Store'}</small></section>`;
  M.onPwaAction = action => {
    if (action !== 'pwa-install' && action !== 'pwa-install-help') return false;
    if (action === 'pwa-install-help') showInstructions(); else void requestInstall();
    return true;
  };
  async function initialize() {
    if (initialized || embedded || native || !window.isSecureContext || !navigator.serviceWorker) return;
    initialized = true;
    try {
      registration = await navigator.serviceWorker.register('/service-worker.js', {scope:'/', updateViaCache:'none'});
      registrationFailed = false;
    } catch { registrationFailed = true; }
    redraw();
  }
  M.pwa = {snapshot, initialize};
  window.addEventListener('beforeinstallprompt', event => {
    if (embedded || installed) return;
    event.preventDefault();
    pendingPrompt = event;
    redraw();
  });
  window.addEventListener('appinstalled', () => {
    installed = true; pendingPrompt = null; installing = false;
    M.toast?.('AVELI установлен'); redraw();
  });
  standalone?.addEventListener?.('change', event => { installed = Boolean(event.matches || navigator.standalone || native); redraw(); });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize, {once:true});
  else void initialize();
})();
