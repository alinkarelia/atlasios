'use strict';
const ICONS = {
 mail:'M4 6h16v12H4z M4 7l8 6 8-6', inbox:'M4 4h16v16H4z M4 14h5l2 3h2l2-3h5',
 send:'M22 2L9 15 M22 2l-7 20-6-7-7-6z', edit:'M16 3l5 5-12 12H4v-5z M14 5l5 5',
 archive:'M3 4h18v4H3z M5 8v12h14V8 M10 12h4', trash:'M3 6h18 M9 6V3h6v3 M6 6l1 15h10l1-15 M10 10v7 M14 10v7',
 star:'M12 3l2.8 5.7 6.2.9-4.5 4.4 1.1 6.2L12 17.3l-5.6 2.9 1.1-6.2L3 9.6l6.2-.9z',
 search:'M21 21l-5-5 M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0', plus:'M12 5v14 M5 12h14',
 chevron:'M9 5l7 7-7 7', 'chevron-right':'M9 5l7 7-7 7', 'chevron-down':'M6 9l6 6 6-6', 'arrow-right':'M4 12h16 M14 6l6 6-6 6',
 users:'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2 M13 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0 M17 3a4 4 0 0 1 0 8 M22 21v-2a4 4 0 0 0-3-3.9',
 settings:'M12 8a4 4 0 1 1 0 8 4 4 0 0 1 0-8 M9 3h6l1 3 3 1 2 5-2 5-3 1-1 3H9l-1-3-3-1-2-5 2-5 3-1z',
 lock:'M5 10h14v11H5z M8 10V6a4 4 0 0 1 8 0v4 M12 14v3', shield:'M12 2l9 4v6c0 5-9 10-9 10S3 17 3 12V6z M8 12l3 3 5-6',
 check:'M5 12l4 4L19 6', bell:'M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9 M10 21h4',
 sun:'M12 8a4 4 0 1 1 0 8 4 4 0 0 1 0-8 M12 2v2 M12 20v2 M2 12h2 M20 12h2 M4.9 4.9l1.4 1.4 M17.7 17.7l1.4 1.4 M4.9 19.1l1.4-1.4 M17.7 6.3l1.4-1.4',
 moon:'M21 12.8A9 9 0 0 1 11.2 3 9 9 0 1 0 21 12.8', logout:'M9 3H4v18h5 M10 12h12 M18 8l4 4-4 4',
 heart:'M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1.1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8z',
 globe:'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0 M3 12h18 M12 3c5 5 5 13 0 18-5-5-5-13 0-18',
 smartphone:'M6 2h12v20H6z M10 18h4', user:'M20 21v-2a7 7 0 0 0-14 0v2 M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0',
 eye:'M2 12s4-7 10-7 10 7 10 7-4 7-10 7-10-7-10-7 M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0',
 'arrow-up-right':'M7 17L17 7 M7 7h10v10', close:'M6 6l12 12 M6 18L18 6', menu:'M4 6h16 M4 12h16 M4 18h16',
 more:'M5 12h.01 M12 12h.01 M19 12h.01', paperclip:'M21 11l-9 9a6 6 0 0 1-8-8L14 2a4 4 0 0 1 6 6L10 18a2 2 0 0 1-3-3L17 5',
 reply:'M9 4L3 10l6 6 M3 10h10a8 8 0 0 1 8 8', clock:'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0 M12 6v6l4 2',
 chat:'M21 11a9 9 0 0 1-9 9H3l2-5a9 9 0 1 1 16-4', sparkles:'M12 3l2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5z M20 2v4 M18 4h4',
 label:'M3 3h8l10 10-8 8L3 11z M7 7h.01', download:'M12 3v12 M7 10l5 5 5-5 M4 16v5h16v-5',
 copy:'M9 9h12v12H9z M15 9V3H3v12h6', file:'M5 2h9l5 5v15H5z M14 2v6h5 M9 13h6 M9 17h6', filter:'M4 7h16 M7 12h10 M10 17h4', back:'M15 5l-7 7 7 7',
 refresh:'M20 7v5h-5 M4 17v-5h5 M5 8a8 8 0 0 1 13-3l2 2 M4 17l2 2a8 8 0 0 0 13-3',
 alert:'M12 3l10 18H2z M12 9v5 M12 17h.01', folder:'M3 5h7l2 3h9v12H3z', hash:'M5 9h14 M4 15h14 M10 3L6 21 M18 3l-4 18'
};
const escapeHTML = value => String(value ?? '').replace(/[&<>"']/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const icon = (name,size=20) => `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${ICONS[name]||ICONS.mail}"/></svg>`;
const initials = name=>String(name).split(' ').filter(Boolean).slice(0,2).map(s=>s[0]).join('').toUpperCase();
const avatar = (name,color='sage',avatarUrl='') => {const src=window.MailSecurity.safeAvatarUrl(avatarUrl);const safeColor=['sage','peach','blue','lavender'].includes(color)?color:'sage';return `<span class="avatar avatar-${safeColor}">${src?`<img src="${escapeHTML(src)}" alt="${escapeHTML(name)}" width="36" height="36">`:escapeHTML(initials(name))}</span>`;};
const STORE='living-memory-mail-v1';
const seedUsers = [
 {id:'u1',name:'Елена Орлова',email:'elena@memory.example',role:'admin',active:true,color:'sage'},
 {id:'u2',name:'Анна Белова',email:'anna@memory.example',role:'member',active:true,color:'peach'},
 {id:'u3',name:'Михаил Соколов',email:'mikhail@memory.example',role:'member',active:true,color:'blue'},
 {id:'u4',name:'Дарья Волкова',email:'darya@memory.example',role:'member',active:true,color:'lavender'}
];
const seedMails = [
 {id:'m1',owner:'u1',sender:'Александр Ковалёв',email:'alexander@example.com',subject:'Семейный архив Ковалёвых — материалы готовы',body:'Елена, добрый день!\n\nМы собрали фотографии и документы для семейного архива. Очень хочется сохранить историю нашей семьи и передать её детям.\n\nВ приложении — список материалов и наши пожелания. В архиве около 120 фотографий, несколько писем дедушки и дневник бабушки за 1964–1982 годы.\n\nПодскажите, пожалуйста, когда можно передать оригиналы и сколько займёт оцифровка? Будем рады созвониться на этой неделе.\n\nСпасибо за то, что делаете.\nАлександр Ковалёв',time:'11:42',unread:true,starred:true,label:'Клиенты',attachment:{name:'Материалы семейного архива.txt',size:'2 КБ',content:'Семейный архив Ковалёвых\n120 фотографий, 1964–1982\nПисьма и дневник\nПожелания: сохранить оригиналы, подписать даты и имена, создать семейную хронику.'}},
 {id:'m2',owner:'u1',sender:'Анна Белова',email:'anna@memory.example',subject:'Макет семейной хроники: посмотри первую версию',body:'Елена, привет!\n\nПодготовила структуру хроники для Ковалёвых. Предлагаю начать с истории знакомства бабушки и дедушки, затем перейти к семейным путешествиям.\n\nНужно согласовать порядок глав. Давай обсудим в канале «Семейные архивы».\n\nАнна',time:'11:15',unread:true,starred:false,label:'Команда'},
 {id:'m3',owner:'u1',sender:'Мария Никитина',email:'maria@example.com',subject:'Фотографии из архива, 1964–1982',body:'Здравствуйте!\n\nНашла ещё коробку старых фотографий. На обороте некоторых подписаны даты и места. Можно ли добавить их в наш проект?\n\nОсобенно важно сохранить подписи моей мамы. Спасибо!\n\nМария',time:'10:38',unread:true,starred:false,label:'Архивы'},
 {id:'m4',owner:'u1',sender:'Михаил Соколов',email:'mikhail@memory.example',subject:'Оцифровка: 48 снимков уже в архиве',body:'Привет, команда!\n\nЗакончил первую партию: 48 снимков отсканированы и подписаны. На шести нужно восстановить контраст.\n\nОригиналы упакованы и готовы к возврату. Подробности обсудим в чате.\n\nМихаил',time:'09:56',unread:false,starred:false,label:'Команда'},
 {id:'m5',owner:'u1',sender:'Светлана Петрова',email:'svetlana@example.com',subject:'Хочу сохранить голос своей бабушки',body:'Добрый день!\n\nУ нас есть кассетные записи с голосом бабушки. Подскажите, вы помогаете перевести такие записи в цифровой формат?\n\nДля нашей семьи это очень ценные воспоминания.\n\nСветлана',time:'09:21',unread:false,starred:true,label:'Клиенты'},
 {id:'m6',owner:'u1',sender:'Дарья Волкова',email:'darya@memory.example',subject:'План встреч с семьями на неделю',body:'Елена, привет!\n\nНа эту неделю запланированы три встречи: Ковалёвы, Никитины и Петровы. Подготовила вопросы для интервью.\n\nНужны ваши комментарии к плану.\n\nДарья',time:'Вчера',unread:false,starred:false,label:'Команда'},
 {id:'m7',owner:'u1',sender:'Игорь Морозов',email:'igor@example.com',subject:'Спасибо за семейную книгу',body:'Команда «Живой памяти», спасибо!\n\nВчера подарили книгу родителям. Мы весь вечер рассматривали фотографии и читали истории. Это получилось очень тепло.\n\nСпасибо каждому из вас.\nИгорь',time:'Вчера',unread:false,starred:false,label:'Клиенты'},
 {id:'m8',owner:'team',sender:'Наталья Смирнова',email:'natalia@example.com',subject:'Новая заявка: архив семьи Смирновых',body:'Здравствуйте!\n\nХочу заказать оцифровку семейных фотографий и собрать историю семьи. В архиве примерно 80 снимков и два альбома.\n\nРасскажите, пожалуйста, как начать работу.\n\nНаталья',time:'12:05',unread:true,starred:false,label:'Клиенты',assignee:'u2',notes:[{user:'u1',text:'Анна, возьми, пожалуйста, первое знакомство с семьёй.'}]},
 {id:'m9',owner:'team',sender:'Сервис оцифровки',email:'studio@example.com',subject:'Записи для проекта Никитиных готовы',body:'Добрый день!\n\nАудиозаписи оцифрованы. Передадим материалы после согласования. Для старой кассеты провели дополнительную очистку шума.\n\nС уважением, студия',time:'10:10',unread:false,starred:false,label:'Архивы',assignee:'u3'},
 {id:'m10',owner:'u2',sender:'Елена Орлова',email:'elena@memory.example',subject:'Встреча с Ковалёвыми',body:'Анна, привет!\n\nПодготовь, пожалуйста, вопросы для семейного интервью. Важно поговорить про детство бабушки, её путешествия и любимые традиции.\n\nСпасибо!\nЕлена',time:'11:30',unread:true,starred:false,label:'Команда'}
].map(m=>({...m,folder:'inbox',createdAt:Date.now()}));
const defaults={users:seedUsers,mails:seedMails,settings:{theme:'dark',signature:'С теплом,\nКоманда «Живая память»',notifications:true},scheduled:[]};
let stored={};
try {const raw=localStorage.getItem(STORE)||'{}';if(raw.length<=6000000)stored=JSON.parse(raw);} catch(e) { /* use demo fixtures */ }
const clean=window.MailSecurity.normalizeState(stored,defaults);
const state={...clean,currentUser:sessionStorage.getItem('memory-user')||'u1',activeMailboxId:sessionStorage.getItem('memory-mailbox')||null,view:'inbox',filter:'all',query:'',selectedId:'m1',checked:[],sidebarOpen:false,reading:false};
if(sessionStorage.getItem('memory-user')==='logged-out')state.currentUser=null;
let composeDraft=null;
let pendingScheduled=null;
const M=window.M={state,icon,escape:escapeHTML,avatar,scrollSettingsCard,getUser:()=>state.users.find(u=>u.id===state.currentUser),persist,render,toast,openModal,closeModal,openCompose,safeAttachmentUrl:window.MailSecurity.safeAttachmentUrl,hostedSession:null,allowedMailboxes,activeMailbox,displayEmail:address=>String(address||'').replace(/@memory\.example$/,'@archiverf.ru'),normalizeEmail,formatBytes,accessibleMails:()=>M.getUser()?.active?state.mails.filter(m=>allowedMailboxes().includes(m.owner)):[]};
M.attachmentBlob=attachment=>{
 const safe=M.safeAttachmentUrl(attachment);
 if(safe){const parts=safe.split(','),mime=parts[0].slice(5).split(';')[0];return new Blob([Uint8Array.from(atob(parts[1]),character=>character.charCodeAt(0))],{type:mime});}
 return !attachment?.dataUrl&&typeof attachment?.content==='string'?new Blob([attachment.content],{type:'text/plain;charset=utf-8'}):null;
};
M.downloadSmallAttachment=attachment=>{
 const blob=M.attachmentBlob(attachment);if(!blob){toast('Небезопасное вложение заблокировано');return false;}
 const url=URL.createObjectURL(blob),anchor=document.createElement('a');anchor.href=url;
 const name=window.MailSecurity.sanitizeFilename(attachment.name);
 anchor.download=!attachment.dataUrl&&!/\.txt$/i.test(name)?name+'.txt':name;
 anchor.click();setTimeout(()=>URL.revokeObjectURL(url),1000);return true;
};
function allowedMailboxes(){const user=M.getUser();return user?.active?[user.id,'team',...state.users.filter(u=>u.active&&u.id!==user.id&&u.sharedWith?.includes(user.id)).map(u=>u.id)]:[];}
function activeMailbox(){const allowed=allowedMailboxes();if(!allowed.includes(state.activeMailboxId))state.activeMailboxId=M.getUser()?.id||null;return state.activeMailboxId==='team'?{id:'team',name:'Команда «Живая память»',email:'archive@memory.example'}:state.users.find(u=>u.id===state.activeMailboxId);}
function normalizeEmail(value){const address=String(value||'').trim().toLowerCase();if(address==='archive@archiverf.ru')return 'archive@memory.example';if(address.endsWith('@archiverf.ru')){const local=address.split('@')[0];const user=state.users.find(u=>u.email===local+'@memory.example');if(user)return user.email;}return address;}
function formatBytes(value){const n=Math.max(0,Number(value)||0);return n>=1e9?(n/1e9).toLocaleString('ru-RU',{maximumFractionDigits:1})+' ГБ':n>=1e6?(n/1e6).toLocaleString('ru-RU',{maximumFractionDigits:1})+' МБ':n>=1e3?Math.ceil(n/1e3)+' КБ':n+' Б';}
function persist(){
 try {localStorage.setItem(STORE,JSON.stringify(window.MailSecurity.normalizeState(state,defaults)));sessionStorage.setItem('memory-user',state.currentUser||'logged-out');sessionStorage.setItem('memory-mailbox',activeMailbox()?.id||'');return true;}catch(e){toast('Хранилище браузера заполнено. Удалите крупные вложения.');return false;}
}
function toast(message){const el=document.createElement('div');el.className='toast';el.innerHTML=icon('check',20)+`<span>${escapeHTML(message)}</span>`;document.getElementById('toast-root').append(el);setTimeout(()=>el.remove(),4200);}
let lastFocus=null;
function openModal(title,html,footer=''){
 lastFocus=document.activeElement;
 document.getElementById('modal-root').innerHTML=`<div class="modal-backdrop"><section class="modal" role="dialog" aria-modal="true" aria-labelledby="modal-title"><div class="modal-header"><h2 id="modal-title">${escapeHTML(title)}</h2><button type="button" class="icon-button" data-action="close-modal" aria-label="Закрыть">${icon('close')}</button></div><div class="modal-body">${html}</div>${footer?`<div class="modal-footer">${footer}</div>`:''}</section></div>`;
 setTimeout(()=>{const field=document.querySelector('.modal input:not([type="hidden"]),.modal textarea,.modal select');(field||document.querySelector('.modal button'))?.focus();},20);
}
function closeModal(){if(document.getElementById('schedule-form')&&pendingScheduled){state.mails=state.mails.filter(m=>m.id!==pendingScheduled.id);state.mails.unshift({...pendingScheduled,folder:'drafts'});pendingScheduled=null;persist();toast('Письмо сохранено в черновиках');}document.getElementById('modal-root').innerHTML='';lastFocus?.focus();}
const mailCount=(view)=>state.mails.filter(m=>m.owner===activeMailbox()?.id && (m.folder===view) && m.unread).length;
function nav(view,name,ic,count){return `<button type="button" class="nav-item ${state.view===view?'active':''}" data-action="navigate" data-view="${view}" ${state.view===view?'aria-current="page"':''}><span class="nav-icon">${icon(ic)}</span><span>${name}</span>${count?`<span class="nav-count">${count}</span>`:''}</button>`;}
function renderTopbar(user){
 const mailbox=activeMailbox();
 return `<header class="topbar">
  <button type="button" class="icon-button mobile-menu-button" data-action="mobile-menu" aria-label="Открыть меню" title="Меню" aria-expanded="${state.sidebarOpen}" aria-controls="workspace-sidebar">${icon('menu',22)}</button>
  <a class="topbar-mobile-brand" href="#" data-action="navigate" data-view="inbox" aria-label="AVELI — входящие"><img src="logo.png" alt="" width="36" height="36"><span><strong>AVELI</strong><small>Mail · Chat · Cloud · AI</small></span></a>
  <form class="search-box topbar-search" id="search-form" role="search">${icon('search',22)}<input id="global-search" type="search" aria-label="Поиск писем" placeholder="Найти письмо" value="${escapeHTML(state.query)}"><kbd>⌘ K</kbd><button type="submit" class="icon-button search-submit" aria-label="Найти" title="Найти">${icon('arrow-right',20)}</button></form>
  <div class="topbar-actions"><span class="pill demo-pill" title="Данные сохраняются на этом устройстве">Демо</span><div class="topbar-desktop-actions"><button type="button" class="icon-button" data-action="navigate" data-view="assistant" aria-label="Открыть ИИ-помощника" title="ИИ-помощник">${icon('sparkles',22)}</button><button type="button" class="icon-button" data-action="navigate" data-view="chat" aria-label="Открыть чат команды" title="Чат команды">${icon('chat',22)}</button><span class="topbar-divider"></span></div><button type="button" class="icon-button topbar-mailbox-button" data-action="mailbox-switch" aria-haspopup="dialog" aria-label="Переключить ящик. Выбран ${escapeHTML(M.displayEmail(mailbox?.email))}" title="Переключить ящик">${icon('mail',22)}</button><button type="button" class="topbar-profile-button" data-action="profile" aria-label="Профиль и настройки: ${escapeHTML(user.name)}" aria-haspopup="dialog" title="Профиль и настройки">${avatar(user.name,user.color,user.avatarUrl)}</button></div>
 </header>`;
}
function renderMobileSections(){const mailActive=!['chat','cloud','assistant','settings','team','integrations'].includes(state.view);return `<nav class="aveli-mobile-sections" aria-label="Разделы AVELI">${[['inbox','Mail','mail',mailActive],['chat','Chat','chat',state.view==='chat'],['cloud','Cloud','folder',state.view==='cloud'],['assistant','AI','sparkles',state.view==='assistant']].map(([view,title,name,selected])=>`<button type="button" data-action="navigate" data-view="${view}" class="${selected?'active':''}" ${selected?'aria-current="page"':''}>${icon(name,21)}<span>${title}</span></button>`).join('')}</nav>`;}
function render(){
 const user=M.getUser();
 document.body.classList.toggle('light',state.settings.theme==='light');
 document.documentElement.dataset.theme=state.settings.theme;
 if(!user||!user.active){M.translation?.cleanup?.();M.media?.cleanup?.();state.currentUser=null;document.getElementById('app').innerHTML=M.renderLogin?.()||'<p>Вход</p>';return;}
 activeMailbox();
 if(state.view==='login'){document.getElementById('app').innerHTML=M.renderLogin?.()||'';M.media?.sync?.();M.translation?.sync?.();return;}
 if(['team','integrations'].includes(state.view)&&user.role!=='admin')state.view='inbox';
 document.getElementById('app').innerHTML=`<div class="app-shell ${state.sidebarOpen?'sidebar-open':''}"><button type="button" class="mobile-scrim" data-action="mobile-menu" aria-label="Закрыть меню"></button><aside class="sidebar" id="workspace-sidebar"><a class="brand" href="#" data-action="navigate" data-view="inbox"><span class="brand-icon aveli-brand-mark"><img src="logo.png" alt="" width="48" height="48"></span><span><strong>AVELI</strong><small class="aveli-workspace-descriptor">Workspace by<br>Семейный архив: Живая память</small></span></a>${M.renderMailboxSwitch?.()||''}<button type="button" class="compose-button" data-action="compose">${icon('plus',20)}<span>Написать письмо</span><kbd>N</kbd></button><div class="nav-section"><div class="nav-label">MAIL · ПОЧТА</div>${nav('inbox','Входящие','inbox',mailCount('inbox'))}${nav('starred','Важное','star')}${nav('sent','Отправленные','send')}${nav('drafts','Черновики','edit',state.mails.filter(m=>m.owner===activeMailbox()?.id&&m.folder==='drafts').length)}${nav('scheduled','Отложенные','clock',state.scheduled.filter(m=>m.owner===activeMailbox()?.id).length)}${nav('archive','Архив','archive')}${nav('trash','Корзина','trash')}</div><div class="nav-section"><div class="nav-label">ВМЕСТЕ С КОМАНДОЙ</div>${nav('shared','Общий ящик','users',state.mails.filter(m=>m.owner==='team'&&m.folder==='inbox'&&m.unread).length)}${nav('chat','Chat · Команда','chat')}${nav('cloud','Cloud · 15 ГБ','folder')}${nav('assistant','AI · Помощник','sparkles')}</div><div class="nav-section labels-nav"><div class="nav-label">МЕТКИ <button type="button" class="icon-button" data-action="labels" aria-label="О метках">${icon('plus',20)}</button></div>${['Клиенты','Архивы','Команда'].map((n,i)=>`<button type="button" class="nav-item ${state.view==='label:'+n?'active':''}" data-action="navigate" data-view="label:${n}"><span class="label-dot label-${i}"></span>${n}</button>`).join('')}</div><div class="sidebar-bottom">${user.role==='admin'?nav('team','Управление командой','shield')+nav('integrations','Интеграции','globe'):''}${nav('settings','Настройки','settings')}${M.renderInstallAction?.()||''}<a class="nav-item" href="screens.html" target="_top">${icon('eye',20)}<span>Обзор всех экранов</span></a><button type="button" class="storage-card cloud-sidebar-meter" data-action="navigate" data-view="cloud"><span>${icon('folder',13)} <b>Облако ящика · 15 ГБ</b></span><small>${formatBytes(M.cloud?.snapshot?.().quota?.used||0)} занято · локальное демо</small></button><button type="button" class="profile-button" data-action="profile" aria-haspopup="dialog" aria-label="Профиль и настройки">${avatar(user.name,user.color,user.avatarUrl)}<span><strong>${escapeHTML(user.name)}</strong><small>${user.role==='admin'?'Администратор':'Участник команды'}</small></span>${icon('chevron-down',20)}</button></div></aside><main class="workspace">${renderTopbar(user)}<div class="content-area">${state.view==='cloud'?M.renderCloud?.():state.view==='team'?M.renderAdmin?.():state.view==='integrations'?M.renderIntegrations?.():state.view==='settings'?M.renderSettings?.():state.view==='chat'?M.renderChat?.():state.view==='assistant'?M.renderAssistant?.():renderMailView()}</div>${renderMobileSections()}</main></div>`;
 M.media?.sync?.();M.translation?.sync?.();
}
function scrollSettingsCard(selector){return scrollWorkspaceCard(selector,'.settings-view');}
function scrollWorkspaceCard(selector,containerSelector){
 const card=document.querySelector(selector);
 const scroller=card?.closest(containerSelector);
 if(!scroller)return false;
 const top=card.getBoundingClientRect().top-scroller.getBoundingClientRect().top+scroller.scrollTop;
 scroller.scrollTop=Math.max(0,top);
 return true;
}
function visibleMails(){
 let items=M.accessibleMails().filter(m=>state.view==='shared'?m.owner==='team':m.owner===activeMailbox()?.id);
 if(state.query){const q=state.query.toLowerCase();items=items.filter(m=>`${m.sender} ${m.email} ${m.subject} ${m.body} ${m.attachment?.name||''}`.toLowerCase().includes(q));}
 else if(state.view==='shared')items=items.filter(m=>m.owner==='team'&&m.folder==='inbox');
 else if(state.view==='starred')items=items.filter(m=>m.starred&&!['trash','spam'].includes(m.folder));
 else if(state.view.startsWith('label:'))items=items.filter(m=>m.label===state.view.slice(6)&&!['trash','spam'].includes(m.folder));
 else items=items.filter(m=>m.owner===activeMailbox()?.id&&m.folder===state.view);
 if(state.filter==='unread')items=items.filter(m=>m.unread);
 if(state.filter==='attachments')items=items.filter(m=>m.attachment);
 return items;
}
function renderMailView(){
 const titles={inbox:'Входящие',starred:'Важное',sent:'Отправленные',drafts:'Черновики',archive:'Архив',trash:'Корзина',shared:'Общий ящик',scheduled:'Отложенные письма',spam:'Спам'};
 const items=state.view==='scheduled'?state.scheduled.filter(m=>m.owner===activeMailbox()?.id):visibleMails();
 const title=state.query?'Результаты поиска':(titles[state.view]||state.view.slice(6));
 let selected=items.find(m=>m.id===state.selectedId)||(state.reading?M.accessibleMails().find(m=>m.id===state.selectedId):null);
 if(!selected&&items.length&&!state.query&&state.view!=='scheduled'){selected=items[0];state.selectedId=selected.id;}
 return `<div class="page-header"><div><div class="page-eyebrow">ВАШЕ ПРОСТРАНСТВО ДЛЯ ВАЖНОГО</div><h1>${escapeHTML(title)} <span class="heading-count">${items.length}</span></h1><p class="page-subtitle">${state.view==='shared'?'archive@archiverf.ru · общий ящик':state.view==='scheduled'?'Будут отправлены в демоящики, когда приложение открыто':escapeHTML(M.displayEmail(activeMailbox()?.email))}</p></div><div class="header-actions"><span class="today-label">${new Date().toLocaleDateString('ru-RU',{day:'numeric',month:'long'})}</span><button type="button" class="button primary mail-compose-action" data-action="compose">${icon('edit',20)}<span>Написать</span></button></div></div>${state.view==='scheduled'?renderScheduled(items):`<div class="mail-layout ${state.reading?'reading':''}"><section class="mail-list-panel" aria-label="Список писем"><div class="list-toolbar"><div class="list-tabs"><button type="button" class="tab ${state.filter==='all'?'active':''}" data-action="filter" data-filter="all" aria-pressed="${state.filter==='all'}">Все письма</button><button type="button" class="tab ${state.filter==='unread'?'active':''}" data-action="filter" data-filter="unread" aria-pressed="${state.filter==='unread'}">Непрочитанные</button></div><button type="button" class="icon-button ${state.filter==='attachments'?'active':''}" data-action="filter" data-filter="attachments" aria-label="С вложениями" aria-pressed="${state.filter==='attachments'}">${icon('paperclip',20)}</button></div><div class="list-actions"><label class="select-all"><input type="checkbox" aria-label="Выбрать все письма" id="select-all" ${items.length&&items.every(m=>state.checked.includes(m.id))?'checked':''}><span>${state.checked.length?`Выбрано: ${state.checked.length}`:`${items.length} писем`}</span></label><div>${state.checked.length?`<button type="button" class="icon-button" data-action="bulk-archive" aria-label="Архивировать выбранные">${icon('archive',20)}</button><button type="button" class="icon-button" data-action="bulk-trash" aria-label="Удалить выбранные">${icon('trash',20)}</button>`:`<button type="button" class="icon-button" data-action="refresh" aria-label="Обновить">${icon('refresh',20)}</button>`}</div></div><div class="mail-items">${items.length?items.map(renderMailRow).join(''):`<div class="empty-state">${icon('inbox',38)}<h3>${state.query?'Ничего не найдено':'Здесь пока тихо'}</h3><p>${state.query?'Попробуйте другое имя или слово.':'Новые письма появятся здесь.'}</p><button type="button" class="button secondary small" data-action="compose">Написать письмо</button></div>`}</div><div class="list-footer">${icon('shield',13)} Только ваша почта и общий ящик</div></section><section class="reader-panel" aria-label="Письмо">${selected?renderReader(selected):`<div class="empty-state reader-empty"><div class="reader-empty-logo"><img src="logo.png" alt="Логотип AVELI" width="54" height="54"></div><h3>Всё важное — рядом</h3><p>Выберите письмо, чтобы прочитать<br>историю и продолжить разговор.</p></div>`}</section></div>`}`;
}
function mailAvatar(m){const u=state.users.find(u=>u.email===m.email);return avatar(m.sender,u?.color||'peach',u?.avatarUrl||'');}
function renderMailRow(m){return `<div class="mail-row ${m.id===state.selectedId?'selected':''} ${m.unread?'unread':''}" data-action="open-mail" data-id="${escapeHTML(m.id)}" role="button" tabindex="0" aria-label="${escapeHTML(m.sender+': '+m.subject)}"><label class="row-select-target"><input class="row-select" type="checkbox" data-check="${escapeHTML(m.id)}" aria-label="Выбрать письмо ${escapeHTML(m.subject)}" ${state.checked.includes(m.id)?'checked':''}></label><div class="mail-avatar">${mailAvatar(m)}</div><div class="mail-main"><div class="mail-row-top"><span class="sender">${escapeHTML(m.sender)}</span><time class="mail-time">${escapeHTML(m.time)}</time></div><div class="mail-subject">${escapeHTML(m.subject||'Без темы')}</div><div class="mail-preview">${escapeHTML(m.body.replace(/\n/g,' '))}</div><div class="mail-meta"><span class="tag tag-${labelClass(m.label)}">${escapeHTML(m.label||'Письмо')}</span>${m.attachment?icon('paperclip',13):''}${m.unread?'<span class="unread-dot"></span>':''}</div></div><button type="button" class="star-button ${m.starred?'starred':''}" data-action="star" data-id="${escapeHTML(m.id)}" aria-label="${m.starred?'Убрать из важного':'Добавить в важное'}" aria-pressed="${m.starred}">${icon('star',20)}</button></div>`;}
function labelClass(label){return {'Клиенты':'clients','Архивы':'archive','Команда':'team'}[label]||'team';}
function canDownloadAttachment(m){return Boolean(m.attachment&&(m.attachment.cloudFileId||M.safeAttachmentUrl(m.attachment)||typeof m.attachment.content==='string'));}
function renderAttachment(m){const a=m.attachment;if(!a)return '';return `<div class="mail-cloud-attachment"><button type="button" class="attachment-card" data-action="download-attachment" data-id="${escapeHTML(m.id)}" ${canDownloadAttachment(m)?'':'disabled'}><span class="attachment-icon">${icon('file',24)}</span><span><strong>${escapeHTML(a.name)}</strong><small>${escapeHTML(a.size)} · ${a.cloudFileId?'Файл в облаке':'Вложение письма'}</small></span>${icon('download',20)}</button><div class="mail-attachment-actions"><button type="button" class="button secondary small" data-action="save-attachment-cloud" data-id="${escapeHTML(m.id)}">${icon('folder',20)} ${a.cloudFileId?'Открыть облако':'В облако'}</button><button type="button" class="button secondary small" data-action="attachment-to-archive" data-id="${escapeHTML(m.id)}">${icon('archive',20)} В семейный архив</button></div><p class="mail-file-note">Файл в облаке можно связать с архивом без скачивания и повторной загрузки.</p></div>`;}
async function ensureCloudAttachment(mail){
 if(!M.cloud)throw new Error('Облако ещё загружается');
 if(mail.attachment?.cloudFileId)return mail.attachment.cloudFileId;
 if(!M.accessibleMails().some(m=>m.id===mail.id))throw new Error('Нет доступа к письму');
 const a=mail.attachment;if(!a)throw new Error('В письме нет вложения');
 const actor=state.currentUser,mailbox=mail.owner;
 const safe=M.safeAttachmentUrl(a);let blob=null;
 if(safe){const parts=safe.split(','),mime=parts[0].slice(5).split(';')[0],bytes=Uint8Array.from(atob(parts[1]),character=>character.charCodeAt(0));blob=new Blob([bytes],{type:mime});}
 else if(typeof a.content==='string')blob=new Blob([a.content],{type:'text/plain'});
 if(!blob)throw new Error('Этот тип вложения заблокирован');
 const file=new File([blob],window.MailSecurity.sanitizeFilename(a.name),{type:blob.type||'text/plain'});
 const upload=await M.cloud.upload(file,{mailbox,source:'email'});const id=typeof upload==='string'?upload:upload.id;
 await M.cloud.waitForFile(id);
 if(state.currentUser!==actor||!M.accessibleMails().some(m=>m.id===mail.id))throw new Error('Доступ к письму изменился');
 mail.attachment={name:file.name,size:formatBytes(file.size),cloudFileId:id};persist();render();return id;
}
async function chooseAttachmentArchive(mail){const id=await ensureCloudAttachment(mail);const families=M.cloud.snapshot().families||M.cloud.snapshot().archiveFamilies||[];openModal('Связать файл с семейным архивом',`<p class="muted">Локальное демо: будет добавлена ссылка на тот же файл, без второй копии.</p><div class="action-menu">${families.map(f=>`<button type="button" class="button secondary" data-action="link-attachment-archive" data-file-id="${escapeHTML(id)}" data-family-id="${escapeHTML(f.id)}">${icon('archive',20)} ${escapeHTML(f.name)}</button>`).join('')}</div>`);}
async function composeCloudPicker(){
 const draft=composeDraft,form=document.getElementById('compose-form');if(!draft||!form||draft.uploading)return;
 await M.cloud.refresh();if(composeDraft!==draft||document.getElementById('compose-form')!==form||draft.actorId!==state.currentUser)return;
 const files=M.cloud.snapshot().files.filter(file=>file.mailboxId===draft.mailboxId);
 const target=document.getElementById('compose-attachment');
 target.innerHTML=`<div class="compose-cloud-picker"><strong>Файлы текущего ящика</strong>${files.length?files.map(file=>`<button type="button" class="button secondary small" data-action="compose-pick-cloud" data-file-id="${escapeHTML(file.id)}">${icon('file',20)} ${escapeHTML(file.name)} <small>${formatBytes(file.size)}</small></button>`).join(''):'<p class="muted">Облако пока пустое. Добавьте файл через «Вложение».</p>'}<button type="button" class="button subtle small" data-action="compose-picker-cancel">Закрыть выбор</button></div>`;
}
async function uploadComposeFile(file,input){
 const draft=composeDraft,form=document.getElementById('compose-form');if(!draft||!form||draft.uploading)return;
 const actor=state.currentUser,mailbox=draft.mailboxId;draft.uploading=true;
 const current=()=>composeDraft===draft&&document.getElementById('compose-form')===form&&state.currentUser===actor&&allowedMailboxes().includes(mailbox);
 const panel=document.getElementById('compose-attachment');let unsubscribe=()=>{};
 try{
  panel.textContent='Подготовка файла…';const upload=await M.cloud.upload(file,{mailbox,source:'email'});const id=typeof upload==='string'?upload:upload.id;
  if(!current())return;
  const progress=()=>{if(!current())return;const item=M.cloud.snapshot().uploads.find(item=>item.id===id);if(item)panel.textContent=`${file.name} · ${formatBytes(item.uploadedBytes||0)} / ${formatBytes(file.size)}${item.status==='paused'?' · пауза, продолжите в облаке':''}${item.status==='offline'?' · ожидание соединения':''}`;};
  unsubscribe=M.cloud.subscribe(progress);progress();await M.cloud.waitForFile(id);
  if(!current())return;
  draft.attachment={name:window.MailSecurity.sanitizeFilename(file.name),size:formatBytes(file.size),cloudFileId:id};panel.textContent=`${draft.attachment.name} · ${formatBytes(file.size)} · в облаке`;
 }catch(error){if(current()){panel.textContent=draft.attachment?.name||'';toast(error.message||'Не удалось загрузить файл');}}
 finally{draft.uploading=false;unsubscribe();if(input)input.value='';}
}
function renderReader(m){
 return `<div class="reader-toolbar"><div class="reader-toolbar-primary"><button type="button" class="icon-button mobile-back" data-action="back-to-list" aria-label="Назад к списку писем" title="Назад">${icon('back',22)}</button><button type="button" class="button primary reader-quick-reply" data-action="reply" data-id="${escapeHTML(m.id)}">${icon('reply',20)}<span>Ответить</span></button></div><div class="reader-toolbar-secondary reader-desktop-actions"><button type="button" class="icon-button" data-action="archive-mail" data-id="${escapeHTML(m.id)}" aria-label="Архивировать письмо" title="В архив">${icon('archive',22)}</button><button type="button" class="icon-button" data-action="trash-mail" data-id="${escapeHTML(m.id)}" aria-label="Переместить письмо в корзину" title="В корзину">${icon('trash',22)}</button><span class="toolbar-separator"></span><button type="button" class="icon-button" data-action="read-toggle" data-id="${escapeHTML(m.id)}" aria-label="${m.unread?'Пометить прочитанным':'Пометить непрочитанным'}" title="${m.unread?'Пометить прочитанным':'Пометить непрочитанным'}">${icon('mail',22)}</button><button type="button" class="icon-button" data-action="snooze" data-id="${escapeHTML(m.id)}" aria-label="Напомнить о письме" title="Напомнить">${icon('clock',22)}</button>${M.renderTranslationActions?.({type:'mail',id:m.id,text:m.body})||''}<button type="button" class="button secondary ai-mail-button" data-action="ai-summary" data-id="${escapeHTML(m.id)}" aria-label="Краткое содержание письма">${icon('sparkles',20)}<span>Кратко</span></button></div><button type="button" class="icon-button reader-more-button" data-action="mail-more" data-id="${escapeHTML(m.id)}" aria-label="Все действия с письмом" title="Все действия" aria-haspopup="dialog">${icon('more',22)}</button></div><div class="reader-scroll"><div class="reader-header"><div class="reader-tags"><span class="tag tag-${labelClass(m.label)}">${escapeHTML(m.label||'Письмо')}</span>${m.owner==='team'?'<span class="pill">Общий ящик</span>':''}<button type="button" class="star-button ${m.starred?'starred':''}" data-action="star" data-id="${escapeHTML(m.id)}" aria-label="${m.starred?'Убрать из важного':'Добавить в важное'}" aria-pressed="${m.starred}">${icon('star',20)}</button></div><h2>${escapeHTML(m.subject||'Без темы')}</h2><div class="sender-line">${mailAvatar(m)}<div class="sender-details"><strong>${escapeHTML(m.sender)} <span>&lt;${escapeHTML(M.displayEmail(m.email))}&gt;</span></strong><small>кому: ${m.folder==='sent'?escapeHTML(M.displayEmail(m.to)):m.owner==='team'?'archive@archiverf.ru':escapeHTML(M.displayEmail(state.users.find(u=>u.id===m.owner)?.email))}</small></div><time>${escapeHTML(m.time)}</time></div></div><div class="message-body">${escapeHTML(m.body).replace(/\n/g,'<br>')}</div>${renderAttachment(m)}${m.replies?.map(r=>`<div class="thread-reply"><div class="sender-line">${avatar(r.sender,'sage')}<div class="sender-details"><strong>${escapeHTML(r.sender)}</strong><small>${escapeHTML(r.time)}</small></div></div><div class="message-body">${escapeHTML(r.body).replace(/\n/g,'<br>')}</div></div>`).join('')||''}${m.owner==='team'?renderTeamNote(m):''}${M.renderCrmContext?.(m)||''}<div class="reply-box"><div class="reply-caption">${icon('reply',20)} Продолжите эту историю</div><p>Ответьте письмом или обсудите с командой.</p><div class="reply-actions"><button type="button" class="button primary" data-action="reply" data-id="${escapeHTML(m.id)}">${icon('reply',20)} Ответить</button><button type="button" class="button secondary" data-action="forward" data-id="${escapeHTML(m.id)}">Переслать</button>${m.folder==='drafts'?`<button type="button" class="button secondary" data-action="edit-draft" data-id="${escapeHTML(m.id)}">Открыть черновик</button>`:''}</div></div><div class="reader-footer">${icon('heart',13)} Сохраняем истории. Остаёмся на связи.</div></div>`;
}
function renderMailActions(m){
 const id=escapeHTML(m.id);
 return `<div class="action-menu mail-action-menu">
  <button type="button" class="button secondary" data-action="reply" data-id="${id}">${icon('reply',22)} Ответить</button><button type="button" class="button secondary" data-action="forward" data-id="${id}">${icon('send',22)} Переслать</button>
  ${M.renderTranslationActions?.({type:'mail',id:m.id,text:m.body})||''}<button type="button" class="button secondary" data-action="ai-summary" data-id="${id}">${icon('sparkles',22)} Краткое содержание</button>
  <button type="button" class="button secondary" data-action="archive-mail" data-id="${id}">${icon('archive',22)} В архив</button><button type="button" class="button secondary" data-action="read-toggle" data-id="${id}">${icon('mail',22)} ${m.unread?'Пометить прочитанным':'Пометить непрочитанным'}</button><button type="button" class="button secondary" data-action="snooze" data-id="${id}">${icon('clock',22)} Напомнить о письме</button>
  <button type="button" class="button secondary" data-action="set-label" data-id="${id}">${icon('label',22)} Изменить метку</button><button type="button" class="button secondary" data-action="restore-mail" data-id="${id}">${icon('inbox',22)} Вернуть во входящие</button><button type="button" class="button secondary" data-action="mark-spam" data-id="${id}">${icon('alert',22)} Пометить как спам</button><button type="button" class="button secondary" data-action="navigate-spam">${icon('folder',22)} Открыть спам</button><button type="button" class="button secondary" data-action="trash-mail" data-id="${id}">${icon('trash',22)} В корзину</button>
 </div>`;
}
function renderTeamNote(m){return `<div class="conversation-note"><div class="note-heading">${icon('users',20)}<strong>Работа с командой</strong><span>Клиент этого не видит</span></div><div class="assignment-line"><label>Ответственный <select data-assign="${escapeHTML(m.id)}"><option value="">Не назначен</option>${state.users.filter(u=>u.active).map(u=>`<option value="${escapeHTML(u.id)}" ${m.assignee===u.id?'selected':''}>${escapeHTML(u.name)}</option>`).join('')}</select></label></div>${(m.notes||[]).map(n=>`<div class="note-item"><strong>${escapeHTML(state.users.find(u=>u.id===n.user)?.name||'Участник')}</strong><p>${escapeHTML(n.text)}</p></div>`).join('')}<form id="note-form" data-id="${escapeHTML(m.id)}"><input name="note" placeholder="Оставить внутреннюю заметку…" aria-label="Внутренняя заметка" required maxlength="2000"><button type="submit" class="icon-button" aria-label="Добавить заметку">${icon('send',20)}</button></form></div>`;}
function renderScheduled(items){return `<div class="team-panel">${items.length?items.map(m=>`<div class="scheduled-row"><div>${icon('clock',24)}</div><div><strong>${escapeHTML(m.subject)}</strong><p>${escapeHTML(m.to)} · ${new Date(m.sendAt).toLocaleString('ru-RU')}</p></div><button type="button" class="button secondary small" data-action="cancel-schedule" data-id="${escapeHTML(m.id)}">Вернуть в черновики</button></div>`).join(''):`<div class="empty-state">${icon('clock',38)}<h3>Письма в нужный момент</h3><p>При написании выберите «Отложить».</p><button type="button" class="button primary" data-action="compose">Написать письмо</button></div>`}<div class="team-panel-note">Отложенная отправка в демоверсии работает, пока эта страница открыта.</div></div>`;}
function openCompose(options={}){
 const mailbox=options.mailboxId||options.owner||activeMailbox()?.id;
 if(!allowedMailboxes().includes(mailbox)){toast('Нет доступа к этому почтовому ящику');return;}
 const box=mailbox==='team'?{email:'archive@memory.example',name:'Команда «Живая память»'}:state.users.find(u=>u.id===mailbox);
 const signature=box.signature??M.getUser().signature??state.settings.signature;
 composeDraft={...options,mailboxId:mailbox,actorId:state.currentUser,attachment:options.attachment||null};
 openModal(options.draftId?'Черновик':options.replyId?'Ответить на письмо':'Новое письмо',`<form id="compose-form"><div class="compose-from">От: <strong>${escapeHTML(M.displayEmail(box.email))}</strong><span class="pill">Демо</span></div><div class="form-field"><label for="compose-to">Кому</label><input id="compose-to" name="to" type="email" autocapitalize="none" spellcheck="false" placeholder="name@example.com" value="${escapeHTML(M.displayEmail(options.to||''))}" required></div><div class="form-field"><label for="compose-subject">Тема</label><input id="compose-subject" name="subject" value="${escapeHTML(options.subject||'')}" placeholder="О чём ваше письмо?" required maxlength="250"></div><div class="compose-tools">${M.renderComposerTranslation?.({type:'mail'})||''}<button type="button" class="button secondary small" data-action="compose-from-cloud">${icon('folder',20)} Из облака</button><button type="button" class="button secondary small" data-action="template">${icon('file',20)} Шаблон</button><label class="button secondary small attachment-upload">${icon('paperclip',20)} Вложение<input id="compose-file" type="file" accept=".pdf,.txt,.png,.jpg,.jpeg,.webp,.docx,.xlsx,.zip,.mp4,.webm,.mp3,.wav,.ogg,.m4a" hidden></label></div><textarea id="compose-body" class="compose-body" name="body" aria-label="Текст письма" placeholder="Текст письма…" required>${escapeHTML(options.body??'\n\n'+signature)}</textarea><div id="compose-attachment" class="compose-attachment">${composeDraft.attachment?escapeHTML(composeDraft.attachment.name):''}</div><div class="compose-hint">Локальное демо: письма доставляются между демоящиками на этом устройстве. Внешняя отправка пока не подключена.</div><div class="modal-form-footer"><button type="button" class="button secondary" data-action="save-draft">Сохранить</button><button type="button" class="button secondary" data-action="schedule">${icon('clock',20)} Отложить</button><button type="submit" class="button primary">${icon('send',20)} Отправить</button></div></form>`);
 document.querySelector('.modal').classList.add('compose-modal');
}
function composeData(){const f=document.getElementById('compose-form');if(!f||!composeDraft||composeDraft.actorId!==state.currentUser||!allowedMailboxes().includes(composeDraft.mailboxId))return null;const box=composeDraft.mailboxId==='team'?{id:'team',name:'Команда «Живая память»',email:'archive@memory.example'}:state.users.find(u=>u.id===composeDraft.mailboxId);const form=new FormData(f);return {id:composeDraft?.draftId||crypto.randomUUID(),owner:box.id,actorId:state.currentUser,sender:box.name,email:box.email,to:normalizeEmail(form.get('to')),subject:String(form.get('subject')).trim(),body:String(form.get('body')),attachment:composeDraft?.attachment||null,replyId:composeDraft?.replyId,createdAt:Date.now(),time:new Date().toLocaleTimeString('ru-RU',{hour:'2-digit',minute:'2-digit'}),label:'Команда',unread:false,starred:false};}
function saveDraft(){const m=composeData();if(!m)return;state.mails=state.mails.filter(x=>x.id!==m.id);state.mails.unshift({...m,folder:'drafts'});persist();closeModal();render();toast('Черновик сохранён');}
async function deliverMail(m){
 const actor=state.currentUser;
 if(!M.getUser()?.active||(m.actorId||m.owner)!==actor||!allowedMailboxes().includes(m.owner))throw new Error('Доступ к ящику изменился');
 const receiver=state.users.find(u=>u.active&&u.email.toLowerCase()===m.to);
 const shared=m.to==='archive@memory.example';
 const copy=receiver||shared?{...m,id:crypto.randomUUID(),owner:shared?'team':receiver.id,folder:'inbox',unread:true}:null;
 if(m.attachment?.cloudFileId){
  await M.cloud.refresh();if(!M.cloud.get(m.attachment.cloudFileId))throw new Error('Вложение недоступно');
  if(state.currentUser!==actor||!M.getUser()?.active||!allowedMailboxes().includes(m.owner))throw new Error('Доступ к ящику изменился во время отправки');
  if(copy)await M.cloud.registerMailReference(m.attachment.cloudFileId,{mailboxId:copy.owner,mailId:copy.id});
 }
 state.mails=state.mails.filter(x=>x.id!==m.id);state.mails.unshift({...m,folder:'sent'});
 if(copy){if(receiver?.smartSort)copy.label=classify(copy);state.mails.unshift(copy);
  if(receiver?.autoReply?.enabled && receiver.id!==m.owner && Date.now()-(receiver.autoReply.lastReplies?.[m.email]||0)>86400000){receiver.autoReply.lastReplies??={};receiver.autoReply.lastReplies[m.email]=Date.now();const auto={id:crypto.randomUUID(),owner:receiver.id,sender:receiver.name,email:receiver.email,to:m.email,subject:'Автоответ: '+m.subject,body:receiver.autoReply.message,folder:'sent',createdAt:Date.now(),time:m.time,label:'Команда',unread:false,starred:false};state.mails.unshift(auto,{...auto,id:crypto.randomUUID(),owner:m.owner,folder:'inbox',unread:true});}
 }
 if(m.replyId){const original=state.mails.find(x=>x.id===m.replyId&&(x.owner===m.owner||x.owner==='team'));if(original){original.replies??=[];original.replies.push({sender:m.sender,body:m.body,time:m.time});}}
 persist();M.cloud?.refresh?.().catch(()=>{});return Boolean(receiver||shared);
}
function classify(m){return /архив|фото|оцифров|дневник|снимк/i.test(m.subject+' '+m.body)?'Архивы':m.email.endsWith('@memory.example')?'Команда':'Клиенты';}
M.classify=classify;
function mutateMail(id,operation){const m=M.accessibleMails().find(x=>x.id===id);if(!m)return;operation(m);persist();render();}
document.addEventListener('click',async e=>{
 const button=e.target.closest('[data-action]');if(!button||e.target.matches('input[type=checkbox]')||e.target.closest('.row-select-target'))return;
 const action=button.dataset.action,id=button.dataset.id;
 if(button.tagName==='A')e.preventDefault();
 if(!M.getUser()?.active&&!['open-demo','fill-demo','toggle-password','close-modal'].includes(action))return;
 if(button.closest('.mail-action-menu'))closeModal();
 if(M.onManagementAction?.(action,button)||M.onChatAction?.(action,button)||M.onAiAction?.(action,button)||M.onIntegrationAction?.(action,button)||M.onMailboxAction?.(action,button)||M.onCloudAction?.(action,button)||M.onMediaAction?.(action,button)||M.onTranslationAction?.(action,button)||M.onPwaAction?.(action,button))return;
 switch(action){
 case 'navigate':if(button.dataset.view==='shared')state.activeMailboxId='team';state.view=button.dataset.view;if(state.view==='cloud')M.cloud?.refresh?.().catch(error=>toast(error.message));state.query='';state.filter='all';state.checked=[];state.selectedId=null;state.sidebarOpen=false;state.reading=false;render();break;
 case 'mobile-menu':state.sidebarOpen=!state.sidebarOpen;render();break;
 case 'compose':openCompose();break;
 case 'close-modal':if(document.getElementById('compose-form')){saveDraft();}else closeModal();break;
 case 'open-mail':{const mail=M.accessibleMails().find(m=>m.id===id);if(!mail)return;state.activeMailboxId=mail.owner;state.selectedId=id;state.reading=true;mutateMail(id,m=>m.unread=false);if(allowedMailboxes().includes(mail.owner)&&mail.folder==='drafts')openCompose({...mail,draftId:id});break;}
 case 'back-to-list':state.reading=false;render();break;
 case 'filter':state.filter=button.dataset.filter;state.selectedId=null;state.checked=[];render();break;
 case 'star':e.stopPropagation();mutateMail(id,m=>m.starred=!m.starred);break;
 case 'read-toggle':mutateMail(id,m=>m.unread=!m.unread);break;
 case 'archive-mail':moveMail(id,'archive');break;
 case 'trash-mail':moveMail(id,'trash');break;
 case 'bulk-archive':state.checked.forEach(id=>{const m=M.accessibleMails().find(x=>x.id===id);if(m)m.folder='archive';});state.checked=[];state.selectedId=null;persist();render();toast('Выбранные письма в архиве');break;
 case 'bulk-trash':state.checked.forEach(id=>{const m=M.accessibleMails().find(x=>x.id===id);if(m)m.folder='trash';});state.checked=[];state.selectedId=null;persist();render();toast('Выбранные письма в корзине');break;
 case 'reply':{const m=M.accessibleMails().find(x=>x.id===id);if(m)openCompose({to:m.folder==='sent'?m.to:m.email,subject:'Re: '+m.subject,replyId:id});break;}
 case 'forward':{const m=M.accessibleMails().find(x=>x.id===id);if(m)openCompose({subject:'Fwd: '+m.subject,body:`\n\n—— Пересланное письмо ——\nОт: ${m.sender} <${m.email}>\nТема: ${m.subject}\n\n${m.body}`,attachment:m.attachment});break;}
 case 'edit-draft':{const m=state.mails.find(x=>x.id===id&&allowedMailboxes().includes(x.owner));if(m)openCompose({...m,draftId:id});break;}
 case 'save-draft':saveDraft();break;
 case 'schedule':{const form=document.getElementById('compose-form');if(!form.reportValidity())return;pendingScheduled=composeData();if(!pendingScheduled||composeDraft.uploading){toast('Дождитесь загрузки файла');return;}const later=new Date(Date.now()+3600000);const localTime=new Date(later.getTime()-later.getTimezoneOffset()*60000).toISOString().slice(0,16);openModal('Когда отправить письмо?',`<form id="schedule-form"><div class="form-field"><label for="send-at">Дата и время</label><input id="send-at" name="sendAt" type="datetime-local" value="${localTime}" required></div><p class="muted">В демоверсии письмо будет доставлено в локальный ящик, пока страница открыта.</p><div class="modal-form-footer"><button type="button" class="button secondary" data-action="back-compose">Назад к письму</button><button type="submit" class="button primary">Запланировать</button></div></form>`);break;}
 case 'back-compose':if(pendingScheduled){openCompose({...pendingScheduled,draftId:pendingScheduled.id});pendingScheduled=null;}break;
 case 'cancel-schedule':{const m=state.scheduled.find(x=>x.id===id&&allowedMailboxes().includes(x.owner));if(m){state.scheduled=state.scheduled.filter(x=>x.id!==id);state.mails.unshift({...m,folder:'drafts'});persist();render();toast('Письмо возвращено в черновики');}break;}
 case 'template':{const body=document.getElementById('compose-body');body.value=`Здравствуйте!\n\nСпасибо, что обратились в «Живую память». Мы поможем бережно сохранить историю вашей семьи.\n\nРасскажите, пожалуйста, какие материалы у вас есть: фотографии, письма, документы или аудиозаписи. После этого предложим удобный план работы.\n\n${M.getUser().signature??state.settings.signature}`;toast('Добавлен шаблон первого ответа');break;}
 case 'download-attachment':{const m=M.accessibleMails().find(x=>x.id===id);if(!m?.attachment)return;if(m.attachment.cloudFileId){try{await M.cloud.download(m.attachment.cloudFileId);}catch(error){toast(error.message);}break;}M.downloadSmallAttachment(m.attachment);break;}
 case 'save-attachment-cloud':{const mail=M.accessibleMails().find(item=>item.id===id);if(!mail)return;try{await ensureCloudAttachment(mail);state.activeMailboxId=mail.owner;state.view='cloud';state.selectedId=null;render();toast('Файл доступен в облаке ящика');}catch(error){toast(error.message);}break;}
 case 'attachment-to-archive':{const mail=M.accessibleMails().find(item=>item.id===id);if(mail)try{await chooseAttachmentArchive(mail);}catch(error){toast(error.message);}break;}
 case 'link-attachment-archive':try{await M.cloud.toArchive(button.dataset.fileId,{familyId:button.dataset.familyId});closeModal();toast('Файл связан с архивом · без повторной загрузки');}catch(error){toast(error.message);}break;
 case 'compose-from-cloud':try{await composeCloudPicker();}catch(error){toast(error.message);}break;
 case 'compose-pick-cloud':{const file=M.cloud?.snapshot().files.find(item=>item.id===button.dataset.fileId);if(!file||!M.cloud.get(file.id)||!composeDraft||composeDraft.actorId!==state.currentUser||file.mailboxId!==composeDraft.mailboxId){toast('Файл недоступен в выбранном ящике');break;}composeDraft.attachment={name:file.name,size:formatBytes(file.size),cloudFileId:file.id};document.getElementById('compose-attachment').textContent=`${file.name} · ${formatBytes(file.size)} · в облаке`;break;}
 case 'compose-picker-cancel':document.getElementById('compose-attachment').textContent=composeDraft?.attachment?.name||'';break;
 case 'snooze':{const m=M.accessibleMails().find(x=>x.id===id);if(!m)return;openModal('Напомнить о письме',`<p class="muted">Локальное напоминание появится, если приложение будет открыто.</p><button type="button" class="button primary" data-action="snooze-confirm" data-id="${escapeHTML(id)}">${icon('clock',20)} Через 5 минут</button>`);break;}
 case 'snooze-confirm':mutateMail(id,m=>m.remindAt=Date.now()+300000);closeModal();toast('Напомним через 5 минут, пока страница открыта');break;
 case 'mail-more':{const mail=M.accessibleMails().find(item=>item.id===id);if(mail)openModal('Действия с письмом',renderMailActions(mail));break;}
 case 'set-label':openModal('Метка письма',`<div class="action-menu">${['Клиенты','Архивы','Команда'].map(label=>`<button type="button" class="button secondary" data-action="apply-label" data-id="${escapeHTML(id)}" data-label="${label}">${label}</button>`).join('')}</div>`);break;
 case 'apply-label':mutateMail(id,m=>m.label=button.dataset.label);closeModal();toast('Метка обновлена');break;
 case 'restore-mail':moveMail(id,'inbox');closeModal();break;
 case 'mark-spam':moveMail(id,'spam');closeModal();break;
 case 'navigate-spam':state.view='spam';state.selectedId=null;closeModal();render();break;
 case 'refresh':render();toast('Демопочта обновлена');break;
 case 'labels':openModal('Метки',`<p>«Клиенты» — переписка с семьями.<br>«Архивы» — материалы и оцифровка.<br>«Команда» — рабочие договорённости.</p><p class="muted">Метки можно менять через меню письма. Умную сортировку можно включить в ИИ-помощнике.</p>`);break;
 case 'about':openModal('AVELI',`<p>Workspace by Семейный архив: Живая память. Mail · Chat · Cloud · AI.</p><p class="muted">Это интерактивная демоверсия. Локальные ящики и чат сохраняются в этом браузере. Почтовый провайдер, общий сервер, настоящая авторизация и модель ИИ подключаются на следующем этапе.</p>`);break;
 case 'profile':{const user=M.getUser();openModal('Профиль и настройки',`<div class="profile-row">${avatar(user.name,user.color,user.avatarUrl)}<div><strong>${escapeHTML(user.name)}</strong><p class="muted">${escapeHTML(M.displayEmail(user.email))}</p></div></div><div class="action-menu profile-action-menu"><button type="button" class="button secondary" data-action="profile-settings">${icon('settings',22)} Настройки и аватар</button><button type="button" class="button secondary" data-action="mailbox-switch">${icon('mail',22)} Переключить почтовый ящик</button>${user.role==='admin'?`<button type="button" class="button secondary" data-action="profile-navigate" data-view="team">${icon('users',22)} Управление командой</button><button type="button" class="button secondary" data-action="profile-navigate" data-view="integrations">${icon('globe',22)} Интеграции</button>`:''}<button type="button" class="button secondary" data-action="about">${icon('heart',22)} О приложении</button><button type="button" class="button secondary" data-action="logout">${icon('logout',22)} Выйти и сменить аккаунт</button></div><p class="profile-demo-note muted">Локальная демоверсия · данные на этом устройстве</p>`);break;}
 case 'profile-navigate':if(['team','integrations'].includes(button.dataset.view)&&M.getUser()?.role==='admin'){closeModal();state.view=button.dataset.view;state.sidebarOpen=false;state.reading=false;render();}break;
 case 'profile-settings':closeModal();state.view='settings';render();break;
 }
});
function moveMail(id,folder){const moved=M.accessibleMails().find(m=>m.id===id);if(moved)state.activeMailboxId=moved.owner;mutateMail(id,m=>m.folder=folder);state.selectedId=null;render();toast({archive:'Письмо перемещено в архив',trash:'Письмо в корзине',spam:'Письмо перемещено в спам',inbox:'Письмо возвращено во входящие'}[folder]);}
document.addEventListener('submit',async e=>{
 if(e.target.id!=='login-form'&&!M.getUser()?.active){e.preventDefault();return;}
 if(M.onMailboxSubmit?.(e))return;
 if(e.target.id==='schedule-form'){e.preventDefault();const sendAt=new Date(new FormData(e.target).get('sendAt')).getTime();if(!pendingScheduled||!Number.isFinite(sendAt)||sendAt<=Date.now()){toast('Выберите время в будущем');return;}state.mails=state.mails.filter(m=>m.id!==pendingScheduled.id);state.scheduled.push({...pendingScheduled,sendAt});pendingScheduled=null;persist();closeModal();render();toast('Отложенная отправка настроена');}
 if(e.target.id==='search-form'){e.preventDefault();state.query=document.getElementById('global-search').value.trim();state.view='inbox';state.selectedId=null;state.filter='all';render();}
 if(e.target.id==='compose-form'){e.preventDefault();const form=e.target;if(form.dataset.sending==='true'||!form.reportValidity())return;const m=composeData();if(!m||composeDraft.uploading){toast(composeDraft?.uploading?'Дождитесь загрузки файла':'Доступ к ящику изменился');return;}form.dataset.sending='true';try{const delivered=await deliverMail(m);if(document.getElementById('compose-form')===form)closeModal();render();toast(delivered?'Письмо доставлено в локальный демоящик':'Письмо сохранено в отправленных · внешняя отправка не подключена');}catch(error){toast(error.message||'Не удалось отправить письмо');}finally{delete form.dataset.sending;}}
 if(e.target.id==='note-form'){e.preventDefault();const m=M.accessibleMails().find(x=>x.id===e.target.dataset.id);const text=new FormData(e.target).get('note')?.trim();if(m&&text){m.notes??=[];m.notes.push({user:state.currentUser,text});persist();render();toast('Внутренняя заметка добавлена');}}
});
document.addEventListener('change',e=>{
 if(!M.getUser()?.active)return;
 if(e.target.id==='select-all'){state.checked=e.target.checked?visibleMails().map(m=>m.id):[];render();}
 if(e.target.dataset.check){const id=e.target.dataset.check;state.checked=e.target.checked?[...new Set([...state.checked,id])]:state.checked.filter(x=>x!==id);render();}
 if(e.target.dataset.assign){mutateMail(e.target.dataset.assign,m=>m.assignee=e.target.value);toast('Ответственный обновлён');}
 if(e.target.id==='compose-file'){
 const file=e.target.files[0];if(!file)return;
 uploadComposeFile(file,e.target);
 }
});
document.addEventListener('keydown',e=>{
 if(e.key==='Escape'){if(document.querySelector('.modal')){if(document.getElementById('compose-form'))saveDraft();else closeModal();}else{state.sidebarOpen=false;state.reading=false;render();}}
 if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='k'){e.preventDefault();document.getElementById('global-search')?.focus();}
 if(e.key==='n'&&!e.target.closest('input,textarea,select')&&!document.querySelector('.modal')&&M.getUser()){e.preventDefault();openCompose();}
 if((e.key==='Enter'||e.key===' ')&&e.target.classList.contains('mail-row')){e.preventDefault();e.target.click();}
 if(e.key==='Tab'&&document.querySelector('.modal')){const focusable=[...document.querySelector('.modal').querySelectorAll('button,input,textarea,select,a[href],[tabindex]:not([tabindex="-1"])')].filter(el=>!el.disabled&&el.offsetParent!==null);const first=focusable[0],last=focusable.at(-1);if(e.shiftKey&&document.activeElement===first){e.preventDefault();last?.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first?.focus();}}
});
function mergeStored(raw){if(typeof raw!=='string'||raw.length>6000000)return;const next=window.MailSecurity.normalizeState(JSON.parse(raw),defaults);for(const key of ['users','mails','chats','scheduled','settings','integrations'])state[key]=next[key];}
window.addEventListener('storage',e=>{if(e.key!==STORE||!e.newValue)return;try{mergeStored(e.newValue);render();}catch(error){/* ignore invalid external state */}});
async function processDue(){
 if(!M.getUser()?.active)return;
 try{const latest=localStorage.getItem(STORE);if(latest)mergeStored(latest);}catch{/* ignore corrupt local data */}
 if(!M.getUser()?.active)return;
 const due=state.scheduled.filter(m=>(m.actorId||m.owner)===state.currentUser&&allowedMailboxes().includes(m.owner)&&(m.owner==='team'||state.users.find(u=>u.id===m.owner)?.active)&&m.sendAt<=Date.now());for(const mail of due){try{await deliverMail(mail);state.scheduled=state.scheduled.filter(item=>item.id!==mail.id);persist();render();toast('Отложенное письмо отправлено в деморежиме');}catch(error){toast('Отложенное письмо осталось в очереди: '+error.message);}}
 let changed=false;for(const m of M.accessibleMails()){if(m.remindAt&&m.remindAt<=Date.now()){delete m.remindAt;m.unread=true;changed=true;toast('Напоминание: '+m.subject);}}if(changed){persist();render();}
}
let processingDue=false;
setInterval(()=>{if(processingDue)return;processingDue=true;const run=navigator.locks?.request?navigator.locks.request('living-memory-mail-scheduler',{ifAvailable:true},lock=>lock?processDue():null):processDue();Promise.resolve(run).catch(()=>{}).finally(()=>processingDue=false);},15000);
M.renderSecuritySettings=()=>`<div class="settings-card"><div class="settings-card-heading">${icon('shield',22)}<h2>Доступ и безопасность</h2></div><p class="muted">Демоверсия хранит письма, чат и профили на этом устройстве.</p><div class="settings-note">Проверка доступа к реальным ящикам, серверные сессии и синхронизация команды будут подключены вместе с сервером AVELI. Сейчас демопрофили показывают сценарии работы.</div></div>`;
async function initHostedSecurity(){if(typeof fetch!=='function')return;try{const r=await fetch('/api/session',{credentials:'same-origin',cache:'no-store',headers:{Accept:'application/json'}});if(!r.ok)return;const data=await r.json();if(data?.user&&typeof data.csrf==='string'&&/^[A-Za-z0-9_-]{32}$/.test(data.csrf)){M.hostedSession=data;}}catch{/* local preview has no hosted identity */}}
const galleryScreens=new Set(['inbox','shared','compose','cloud','uploads','chat','assistant','team','integrations','settings','avatar','access','login']);
M.showScreen=async screen=>{
 if(!galleryScreens.has(screen))return false;
 closeModal();state.query='';state.filter='all';state.checked=[];state.sidebarOpen=false;state.reading=false;state.selectedId=null;state.cloudShowUploads=screen==='uploads';
 if(screen==='shared')state.activeMailboxId='team';
 state.view=['compose'].includes(screen)?'inbox':['uploads'].includes(screen)?'cloud':['avatar','access'].includes(screen)?'settings':screen;
 render();
 if(!M.getUser()?.active)return true;
 if(screen==='compose')openCompose();
 if(['cloud','uploads'].includes(screen)){try{await M.cloud.refresh();if(state.view==='cloud'){render();if(screen==='uploads')scrollWorkspaceCard('.cloud-transfers','.cloud-screen');}}catch(error){toast(error.message);}}
 if(screen==='avatar')scrollSettingsCard('.avatar-settings');
 if(screen==='access')scrollSettingsCard('.mailbox-access-settings');
 return true;
};
window.addEventListener('message',event=>{if(event.origin!==location.origin||event.source!==window.parent||window.parent===window)return;if(event.data?.type==='memory-screen'&&galleryScreens.has(event.data.screen))M.showScreen(event.data.screen);});
document.addEventListener('DOMContentLoaded',()=>{persist();render();const screen=new URLSearchParams(location.search).get('screen');if(galleryScreens.has(screen))M.showScreen(screen);M.cloud?.refresh?.().catch(()=>{});initHostedSecurity();});
