(function () {
  'use strict';
  const M = window.M;
  const esc = M.escape;
  const channels = [
    {id:'general', name:'Общий', description:'Рабочие планы, идеи и новости команды', icon:'hash'},
    {id:'archives', name:'Семейные архивы', description:'Истории семей, интервью и семейные хроники', icon:'folder'},
    {id:'digitize', name:'Оцифровка', description:'Фотографии, документы и голосовые воспоминания', icon:'sparkles'}
  ];
  const drafts = new Map();
  let search = '';
  let searchOpen = false;
  let emojiOpen = false;
  let replyTo = null;
  let renderedRoomKey = '';
  const today = new Date(Date.now() - 60 * 60000);
  const time = (minutes, yesterday=false) => today.getTime() + minutes * 60000 - (yesterday ? 86400000 : 0);
  const seedMessages = [
    {id:'c1',room:'general',user:'u1',text:'Всем доброе утро! На этой неделе собираем хронику Ковалёвых. Давайте сохраним не только снимки, но и истории за ними.',createdAt:time(3)},
    {id:'c2',room:'general',user:'u2',text:'Доброе! Первый макет уже отправила на почту. В «Семейных архивах» оставлю вопросы к интервью.',createdAt:time(8)},
    {id:'c3',room:'general',user:'u3',text:'Закончил первые 48 снимков. Подписи на обороте сохранил отдельными сканами — там есть даты и места.',createdAt:time(16)},
    {id:'c4',room:'general',user:'u4',text:'Ковалёвы готовы встретиться в четверг. Подготовлю вопросы про семейные традиции и историю знакомства бабушки с дедушкой.',createdAt:time(24)},
    {id:'c5',room:'general',user:'u1',text:'Отлично. Анна — структура книги, Михаил — обработка снимков, Дарья — интервью. Ответ клиенту отправим из общего ящика, чтобы вся команда видела договорённости.',createdAt:time(28),pinned:true},
    {id:'c6',room:'general',user:'u2',text:'Вместо сухой хронологии предлагаю главы «Дом», «Путешествия», «То, что нас объединяет». Так история получится живой 🌿',createdAt:time(42)},
    {id:'a1',room:'archives',user:'u2',text:'Создала рабочий план хроники Ковалёвых. В первой главе — дом детства, во второй — история семьи в письмах.',createdAt:time(35,true)},
    {id:'a2',room:'archives',user:'u4',text:'Вопросы для интервью готовы. Отдельно спрошу, как семья отмечала праздники и какие рецепты передавались от поколения к поколению.',createdAt:time(42,true)},
    {id:'a3',room:'archives',user:'u1',text:'Добавим к каждому портрету короткую историю от близких. Имена и даты перед печатью обязательно согласуем с семьёй.',createdAt:time(51,true),pinned:true},
    {id:'a4',room:'archives',user:'u2',text:'Прикрепила список того, что нужно уточнить на встрече. Дарья, посмотри, пожалуйста.',createdAt:time(18),attachments:[{name:'Вопросы к семейному интервью.txt',size:766,content:'Семейный архив Ковалёвых\n\n1. Где прошло детство бабушки?\n2. Как познакомились бабушка и дедушка?\n3. Какие традиции собирали семью вместе?\n4. Кто изображён на фотографиях 1964 года?\n5. Какие письма можно включить в семейную книгу?\n6. Какие подписи и даты нужно уточнить?'}]},
    {id:'a5',room:'archives',user:'u4',text:'Посмотрела. Добавлю вопрос о самом тёплом воспоминании. Иногда именно с него начинается лучшая история.',createdAt:time(31)},
    {id:'d1',room:'digitize',user:'u3',text:'Первая партия: 48 фотографий, 600 dpi. Оригиналы подписаны и упакованы в том же порядке.',createdAt:time(20)},
    {id:'d2',room:'digitize',user:'u1',text:'Михаил, на шести выцветших снимках восстановим контраст. Исходные сканы обязательно сохрани.',createdAt:time(26)},
    {id:'d3',room:'digitize',user:'u3',text:'Да, оригинал и обработанная версия будут рядом. Подготовлю сравнение для семьи перед окончательным выбором.',createdAt:time(30)},
    {id:'d4',room:'digitize',user:'u4',text:'Ещё есть кассета с голосом бабушки Никитиной. После оцифровки отметим фрагменты для семейной хроники.',createdAt:time(38)},
    {id:'p1',room:'dm:u1:u2',user:'u1',text:'Анна, спасибо за макет. Мне нравится, что история начинается с воспоминания о доме.',createdAt:time(4)},
    {id:'p2',room:'dm:u1:u2',user:'u2',text:'Спасибо! После интервью добавлю цитаты семьи. Хочется, чтобы в книге звучали их собственные голоса.',createdAt:time(11)}
  ];

  function ensureChats() {
    if (!M.state.chats || !Array.isArray(M.state.chats.messages)) {
      M.state.chats = {version:1, messages:seedMessages};
    }
    if (!M.state.chatRoom) M.state.chatRoom = 'general';
    if (!roomAllowed(M.state.chatRoom)) M.state.chatRoom = 'general';
    return M.state.chats;
  }
  ensureChats();

  const draftKey = () => `${M.state.currentUser}:${M.state.chatRoom}`;
  const getDraft = () => {const key=draftKey();if(!drafts.has(key))drafts.set(key,{text:'',attachments:[],uploads:[],sending:false});return drafts.get(key);};
  const getUser = id => M.state.users.find(user=>user.id===id) || {name:'Участник команды',color:'sage'};
  const dmRoom = id => 'dm:' + [M.state.currentUser,id].sort().join(':');
  const roomMessages = () => ensureChats().messages.filter(message=>message.room===M.state.chatRoom);
  const formatTime = value => new Date(value).toLocaleTimeString('ru-RU',{hour:'2-digit',minute:'2-digit'});
  function formatDay(value) {
    const date=new Date(value), now=new Date();
    const d=new Date(date.getFullYear(),date.getMonth(),date.getDate()).getTime();
    const n=new Date(now.getFullYear(),now.getMonth(),now.getDate()).getTime();
    if(d===n) return 'Сегодня';
    if(d===n-86400000) return 'Вчера';
    return date.toLocaleDateString('ru-RU',{day:'numeric',month:'long',...(date.getFullYear()!==now.getFullYear()?{year:'numeric'}:{})});
  }
  function filesize(value) {
    if (M.formatBytes) return M.formatBytes(value);
    const bytes=Math.max(0,Number(value)||0), units=['Б','КБ','МБ','ГБ'];
    const index=bytes?Math.min(3,Math.floor(Math.log(bytes)/Math.log(1000))):0;
    return `${(bytes/1000**index).toLocaleString('ru-RU',{maximumFractionDigits:index?1:0})} ${units[index]}`;
  }
  function roomAllowed(room,userId=M.state.currentUser) {
    if(!M.state.users.some(user=>user.id===userId&&user.active)||typeof room!=='string')return false;
    if(channels.some(channel=>channel.id===room))return true;
    const ids=room.split(':');
    return ids.length===3&&ids[0]==='dm'&&ids[1]!==ids[2]&&ids.slice(1).includes(userId)&&ids.slice(1).every(id=>M.state.users.some(user=>user.id===id&&user.active))&&room==='dm:'+ids.slice(1).sort().join(':');
  }
  function captureContext(room=M.state.chatRoom,userId=M.state.currentUser) {
    return {room,userId,mailbox:M.state.activeMailboxId||userId};
  }
  function contextValid(context) {
    return M.state.view==='chat'&&M.state.currentUser===context.userId&&M.state.chatRoom===context.room&&(M.state.activeMailboxId||context.userId)===context.mailbox&&roomAllowed(context.room,context.userId)&&(!M.allowedMailboxes||M.allowedMailboxes().includes(context.mailbox));
  }
  const pendingSends=new Set();
  M.sendChatMessage=async function(payload={}) {
    const context=captureContext(payload.room||M.state.chatRoom,payload.userId||M.state.currentUser);
    const key=`${context.userId}:${context.room}`;
    if(!contextValid(context)||pendingSends.has(key))return false;
    const text=typeof payload.text==='string'?payload.text.trim().slice(0,6000):'';
    const attachments=Array.isArray(payload.attachments)?payload.attachments.slice(0,3).map(file=>({...file})):[];
    const media=payload.media&&['voice','circle'].includes(payload.media.kind)&&typeof payload.media.fileId==='string'?{
      fileId:payload.media.fileId,kind:payload.media.kind,duration:Math.max(0,Math.min(payload.media.kind==='circle'?60:300,Number(payload.media.duration)||0)),mime:String(payload.media.mime||'').slice(0,60),transcript:null
    }:null;
    if(!text&&!attachments.length&&!media)return false;
    const cloudIds=[...new Set([...attachments.map(file=>file.cloudFileId).filter(Boolean),...(media?[media.fileId]:[])])];
    if(cloudIds.length&&(!M.cloud?.waitForFile||!M.cloud.registerChatReference)){M.toast('Хранилище ещё загружается. Попробуйте через несколько секунд.');return false;}
    pendingSends.add(key);
    try {
      for(const id of cloudIds){
        await M.cloud.waitForFile(id);
        if(!contextValid(context))return false;
        await M.cloud.registerChatReference(id,{room:context.room});
        if(!contextValid(context))return false;
      }
      if(!contextValid(context))return false;
      const quoted=payload.replyTo&&ensureChats().messages.some(message=>message.id===payload.replyTo&&message.room===context.room);
      const message={id:crypto.randomUUID(),room:context.room,user:context.userId,text,createdAt:Date.now(),attachments,...(media?{media}:{}),...(quoted?{replyTo:payload.replyTo}:{})};
      ensureChats().messages.push(message);M.persist();M.render();return message;
    } catch(error) {
      if(contextValid(context))M.toast(error?.message||'Не удалось отправить сообщение. Повторите отправку.');
      return false;
    } finally {pendingSends.delete(key);}
  };
  function uploadHTML(item) {
    let metadata;try{metadata=M.cloud?.snapshot?.().uploads.find(upload=>upload.id===item.id);}catch{}
    const uploaded=Number(metadata?.uploadedBytes??metadata?.uploaded??0), total=Number(metadata?.size||item.size);
    const status=metadata?.status;
    const label=status==='offline'?'Нет сети · продолжим после подключения':status==='paused'?'На паузе · продолжите в облаке':status==='needs-file'?'Выберите файл повторно в облаке':`${uploaded?Math.min(100,Math.round(uploaded/total*100))+'% · ':''}Сохраняем в облако…`;
    return `<span role="status">${M.icon('refresh',13)} ${esc(item.name)} <small>${esc(label)}</small></span>`;
  }
  function roomName() {
    const channel=channels.find(channel=>channel.id===M.state.chatRoom);
    if(channel) return channel;
    const user=getUser(M.state.chatRoom.split(':').find(id=>id!=='dm'&&id!==M.state.currentUser));
    return {name:user.name,description:'Личный разговор',icon:'user',user};
  }
  function attachmentHTML(attachment,message,index) {
    const downloadable=Boolean(attachment.cloudFileId||M.safeAttachmentUrl?.(attachment)||(!attachment.dataUrl&&typeof attachment.content==='string'));
    return `<${downloadable?'button':'div'} class="chat-file" ${downloadable?`type="button" data-action="chat-download" data-id="${esc(message.id)}" data-index="${index}"`:''}>${M.icon('file',20)}<span><strong>${esc(attachment.name)}</strong><small>${filesize(attachment.size||0)} · ${downloadable?'Скачать':'Сведения о файле'}</small></span>${downloadable?M.icon('download',15):''}</${downloadable?'button':'div'}>`;
  }
  function messageHTML(message) {
    const user=getUser(message.user), own=message.user===M.state.currentUser;
    const quoted=ensureChats().messages.find(item=>item.id===message.replyTo && item.room===message.room);
    return `<article class="chat-message ${own?'chat-message-own':''}" id="chat-message-${esc(message.id)}">${M.avatar(user.name,user.color,user.avatarUrl)}<div class="chat-message-content"><div class="chat-message-meta"><strong>${esc(user.name)}</strong>${own?'<span class="chat-you">Вы</span>':''}<time datetime="${new Date(message.createdAt).toISOString()}" title="${new Date(message.createdAt).toLocaleString('ru-RU')}">${formatTime(message.createdAt)}</time>${message.pinned?`<span class="chat-pin-label">${M.icon('label',12)} Закреплено</span>`:''}</div>${quoted?`<div class="chat-quote"><strong>${esc(getUser(quoted.user).name)}</strong><span>${esc(quoted.text || 'Вложение')}</span></div>`:''}${message.text?`<p class="chat-message-text">${esc(message.text)}</p>`:''}${M.renderMediaMessage?.(message)||''}${(message.attachments||[]).length?`<div class="chat-files">${message.attachments.map((attachment,i)=>attachmentHTML(attachment,message,i)).join('')}</div>`:''}<div class="chat-message-actions">${M.renderTranslationActions?.({type:'chat',id:message.id,text:message.text||message.media?.transcript})||''}<button type="button" class="icon-button" data-action="chat-reply" data-id="${esc(message.id)}" aria-label="Ответить ${esc(user.name)}" title="Ответить">${M.icon('reply',15)}</button><button type="button" class="icon-button ${message.pinned?'chat-pin-active':''}" data-action="chat-pin" data-id="${esc(message.id)}" aria-label="${message.pinned?'Открепить':'Закрепить'} сообщение" title="${message.pinned?'Открепить':'Закрепить'}">${M.icon('label',15)}</button></div></div></article>`;
  }
  function messagesHTML(messages) {
    let lastDay='';
    return messages.map(message=>{const day=formatDay(message.createdAt);const divider=day!==lastDay?`<div class="chat-date"><span>${day}</span></div>`:'';lastDay=day;return divider+messageHTML(message);}).join('');
  }

  M.renderChat = function () {
    ensureChats();
    const room=roomName(), current=M.getUser(), activeUsers=M.state.users.filter(user=>user.active), draft=getDraft();
    const all=roomMessages();
    const visible=search?all.filter(message=>`${message.text} ${getUser(message.user).name} ${(message.attachments||[]).map(attachment=>attachment.name).join(' ')}`.toLocaleLowerCase('ru-RU').includes(search.toLocaleLowerCase('ru-RU'))):all;
    const pinned=all.filter(message=>message.pinned).at(-1);
    const quoted=all.find(message=>message.id===replyTo);
    const previousList=document.getElementById('chat-messages');
    const previousInput=document.getElementById('chat-text');
    const sameRoom=renderedRoomKey===draftKey();
    const keepInputFocus=sameRoom && previousInput && document.activeElement===previousInput;
    const selection=keepInputFocus?[previousInput.selectionStart,previousInput.selectionEnd]:null;
    const scrollTop=sameRoom?previousList?.scrollTop||0:0;
    const wasAtBottom=!sameRoom || !previousList || previousList.scrollHeight-previousList.scrollTop-previousList.clientHeight<90;
    renderedRoomKey=draftKey();
    queueMicrotask(()=>{
      const list=document.getElementById('chat-messages');
      if(list&&!search)list.scrollTop=wasAtBottom?list.scrollHeight:scrollTop;
      if(keepInputFocus){const input=document.getElementById('chat-text');input?.focus({preventScroll:true});input?.setSelectionRange(...selection);}
    });
    return `<div class="chat-page"><div class="page-header chat-page-header"><div><div class="page-eyebrow">СВЯЗЬ, КОТОРАЯ ОБЪЕДИНЯЕТ</div><h1>Командный чат <span class="chat-title-mark">${M.icon('chat',21)}</span></h1><p class="page-subtitle">Обсуждаем внутри. Важные договорённости отправляем почтой.</p></div><button type="button" class="button secondary small chat-mail-button" data-action="navigate" data-view="shared">${M.icon('mail',16)} Общий ящик</button></div><section class="chat-layout" aria-label="Чат команды"><aside class="chat-rooms"><div class="chat-space-title"><span class="chat-space-icon">${M.icon('users',20)}</span><div><strong>Команда «Живая память»</strong><small>${activeUsers.length} участника в пространстве</small></div></div><div class="chat-section-label">КАНАЛЫ</div><div class="chat-channel-list">${channels.map(channel=>`<button type="button" class="chat-room ${M.state.chatRoom===channel.id?'active':''}" data-action="chat-room" data-room="${channel.id}" aria-pressed="${M.state.chatRoom===channel.id}">${M.icon(channel.icon,18)}<span>${channel.name}</span>${channel.id==='general'?'<span class="chat-room-mark"></span>':''}</button>`).join('')}</div><div class="chat-section-label chat-direct-label">ЛИЧНЫЕ СООБЩЕНИЯ</div><div class="chat-direct-list">${activeUsers.filter(user=>user.id!==current.id).map(user=>`<button type="button" class="chat-room chat-person ${M.state.chatRoom===dmRoom(user.id)?'active':''}" data-action="chat-room" data-room="${esc(dmRoom(user.id))}" aria-pressed="${M.state.chatRoom===dmRoom(user.id)}">${M.avatar(user.name,user.color,user.avatarUrl)}<span>${esc(user.name)}<small>${user.role==='admin'?'Администратор':'Участник команды'}</small></span></button>`).join('')||'<p class="chat-no-people">Добавьте участников в управлении командой.</p>'}</div><div class="chat-rooms-footer">${M.icon('heart',15)}<span>Истории сохраняем.<br>Идеями делимся.</span></div></aside><div class="chat-main"><header class="chat-header"><div class="chat-room-title">${room.user?M.avatar(room.user.name,room.user.color,room.user.avatarUrl):`<span class="chat-hash">${M.icon(room.icon,21)}</span>`}<div><h2>${esc(room.name)}</h2><p>${esc(room.description)}</p></div></div><div class="chat-header-actions">${M.renderChatCallActions?.(M.state.chatRoom)||''}${!room.user?`<button type="button" class="chat-members" data-action="chat-members" title="Участники канала">${activeUsers.slice(0,3).map(user=>M.avatar(user.name,user.color,user.avatarUrl)).join('')}<span>${activeUsers.length} участника</span></button>`:''}<button type="button" class="icon-button ${searchOpen?'chat-search-active':''}" data-action="chat-search-toggle" aria-label="Найти сообщение" aria-expanded="${searchOpen}">${M.icon('search',19)}</button></div></header>${searchOpen?`<form class="chat-search-form" id="chat-search-form">${M.icon('search',17)}<input id="chat-search-input" name="search" value="${esc(search)}" placeholder="Поиск в этом разговоре" aria-label="Поиск сообщений в разговоре"><button type="submit" class="button secondary small">Найти</button><button type="button" class="icon-button" data-action="chat-search-close" aria-label="Закрыть поиск">${M.icon('close',16)}</button></form>`:''}${pinned&&!search?`<button type="button" class="chat-pinned" data-action="chat-jump" data-id="${esc(pinned.id)}">${M.icon('label',15)}<span><strong>Закреплено</strong> ${esc(pinned.text||'Вложение')}</span>${M.icon('chevron-down',15)}</button>`:''}<div class="chat-messages" id="chat-messages" role="log" aria-label="Сообщения в ${esc(room.name)}" aria-live="polite">${search?`<div class="chat-search-result">Найдено сообщений: ${visible.length}</div>`:''}${visible.length?messagesHTML(visible):`<div class="chat-empty">${M.icon(search?'search':'chat',38)}<h3>${search?'Ничего не нашли':'Начните разговор'}</h3><p>${search?'Попробуйте другое слово или имя участника.':'Напишите коллеге — все договорённости будут здесь.'}</p></div>`}</div><div class="chat-compose-area">${quoted?`<div class="chat-reply-preview">${M.icon('reply',17)}<div><strong>Ответ ${esc(getUser(quoted.user).name)}</strong><span>${esc(quoted.text||'Вложение')}</span></div><button type="button" class="icon-button" data-action="chat-reply-cancel" aria-label="Отменить ответ">${M.icon('close',15)}</button></div>`:''}<form id="chat-compose-form" class="chat-compose-form"><label class="sr-only" for="chat-text">Сообщение в ${esc(room.name)}</label><textarea id="chat-text" name="message" rows="2" maxlength="6000" placeholder="Написать ${esc(room.user?room.user.name.split(' ')[0]:'в #'+room.name.toLowerCase())}…">${esc(draft.text)}</textarea>${draft.attachments.length?`<div class="chat-draft-files">${draft.attachments.map((attachment,i)=>`<span>${M.icon('file',13)} ${esc(attachment.name)} <button type="button" data-action="chat-remove-file" data-index="${i}" aria-label="Убрать ${esc(attachment.name)}">${M.icon('close',13)}</button></span>`).join('')}</div>`:''}${draft.uploads.length?`<div class="chat-draft-files chat-pending-files">${draft.uploads.map(uploadHTML).join('')}</div>`:''}<div class="chat-compose-toolbar"><div class="chat-compose-tools"><label class="icon-button chat-file-upload" title="Прикрепить файл · облако ящика 15 ГБ">${M.icon('paperclip',19)}<input id="chat-file-input" type="file" multiple class="sr-only" aria-label="Прикрепить файл в облако ящика"></label>${M.renderChatMediaTools?.(M.state.chatRoom)||''}${M.renderComposerTranslation?.({type:'chat'})||''}<button type="button" class="icon-button" data-action="chat-emoji-toggle" aria-label="Добавить эмодзи" aria-expanded="${emojiOpen}"><span class="chat-smile">☺</span></button><span class="chat-key-hint">Enter — отправить · Shift + Enter — новая строка</span></div><button type="submit" class="chat-send" ${draft.uploads.length||draft.sending?'disabled':''} aria-label="Отправить сообщение">${M.icon('send',17)}<span>${draft.sending?'Отправляем…':'Отправить'}</span></button></div>${emojiOpen?`<div class="chat-emoji-picker" aria-label="Выберите эмодзи">${['🌿','💚','👍','✨','🙏','📷','🎉','😊'].map(emoji=>`<button type="button" data-action="chat-emoji" data-emoji="${emoji}" aria-label="Добавить ${emoji}">${emoji}</button>`).join('')}</div>`:''}</form><p class="chat-demo-note">${M.icon('refresh',11)} Демо · синхронизация между вкладками этого браузера</p></div></div></section></div>`;
  };

  function refreshFocus() {M.render();requestAnimationFrame(()=>document.getElementById('chat-text')?.focus());}
  M.onChatAction = function (action, element) {
    if(!action.startsWith('chat-')) return false;
    ensureChats();
    const message=roomMessages().find(item=>item.id===element.dataset.id);
    switch(action) {
      case 'chat-room': {
        const room=element.dataset.room;
        const isChannel=channels.some(channel=>channel.id===room);
        const dmIds=room.split(':').slice(1);
        if(!isChannel && !(room.startsWith('dm:') && dmIds.length===2 && dmIds.includes(M.state.currentUser) && dmIds.every(id=>M.state.users.some(user=>user.id===id&&user.active)))) return true;
        M.state.chatRoom=room;search='';searchOpen=false;replyTo=null;emojiOpen=false;M.render();break;
      }
      case 'chat-search-toggle':searchOpen=!searchOpen;if(!searchOpen)search='';M.render();if(searchOpen)requestAnimationFrame(()=>document.getElementById('chat-search-input')?.focus());break;
      case 'chat-search-close':searchOpen=false;search='';M.render();break;
      case 'chat-reply':if(message){replyTo=message.id;refreshFocus();}break;
      case 'chat-reply-cancel':replyTo=null;refreshFocus();break;
      case 'chat-pin':if(message){message.pinned=!message.pinned;M.persist();M.render();M.toast(message.pinned?'Сообщение закреплено':'Сообщение откреплено');}break;
      case 'chat-jump':document.getElementById('chat-message-'+element.dataset.id)?.scrollIntoView({behavior:'smooth',block:'center'});break;
      case 'chat-remove-file':getDraft().attachments.splice(Number(element.dataset.index),1);refreshFocus();break;
      case 'chat-emoji-toggle':emojiOpen=!emojiOpen;refreshFocus();break;
      case 'chat-emoji': {
        const draft=getDraft(), input=document.getElementById('chat-text');
        const start=input?.selectionStart??draft.text.length, end=input?.selectionEnd??start;
        draft.text=draft.text.slice(0,start)+element.dataset.emoji+draft.text.slice(end);emojiOpen=false;refreshFocus();break;
      }
      case 'chat-download': {
        const attachment=message?.attachments?.[Number(element.dataset.index)];if(!attachment)break;
        if(attachment.cloudFileId){void M.cloud?.download(attachment.cloudFileId).catch(error=>M.toast(error?.message||'Не удалось скачать файл'));break;}
        if(M.downloadSmallAttachment){M.downloadSmallAttachment(attachment);break;}
        const dataUrl=M.safeAttachmentUrl?.(attachment);
        if(attachment.dataUrl&&!dataUrl){M.toast('Небезопасное вложение заблокировано');break;}
        if(!dataUrl&&typeof attachment.content!=='string')break;
        const objectURL=!dataUrl?URL.createObjectURL(new Blob([attachment.content],{type:'text/plain;charset=utf-8'})):null;
        const anchor=document.createElement('a');anchor.href=dataUrl||objectURL;const name=window.MailSecurity.sanitizeFilename(attachment.name);anchor.download=objectURL&&!/\.txt$/i.test(name)?name+'.txt':name;anchor.click();if(objectURL)setTimeout(()=>URL.revokeObjectURL(objectURL),1000);break;
      }
      case 'chat-members': {
        const users=M.state.users.filter(user=>user.active);
        M.openModal('Команда «Живая память»',`<div class="chat-member-list">${users.map(user=>`<div class="chat-member-row">${M.avatar(user.name,user.color,user.avatarUrl)}<div><strong>${esc(user.name)}</strong><small>${esc(M.displayEmail?.(user.email)||user.email)}</small></div><span class="pill gray">${user.role==='admin'?'Администратор':'Участник'}</span></div>`).join('')}</div><p class="muted">Каналы доступны всем активным участникам пространства.</p>`);break;
      }
    }
    return true;
  };

  document.addEventListener('input',event=>{if(event.target.id==='chat-text')getDraft().text=event.target.value;});
  document.addEventListener('keydown',event=>{
    if(event.target.id==='chat-text' && event.key==='Enter' && !event.shiftKey && !event.isComposing){event.preventDefault();event.target.form.requestSubmit();}
  });
  document.addEventListener('submit',async event=>{
    if(event.target.id==='chat-search-form'){event.preventDefault();search=String(new FormData(event.target).get('search')||'').trim();M.render();}
    if(event.target.id!=='chat-compose-form')return;
    event.preventDefault();
    const user=M.getUser();if(!user?.active)return;
    const context=captureContext(),key=draftKey(),draft=getDraft(),text=String(new FormData(event.target).get('message')||'').trim();
    if(draft.uploads.length){M.toast('Дождитесь сохранения файлов в облако. При обрыве связи загрузка продолжится с сохранённого места.');return;}
    if(draft.sending||!contextValid(context))return;
    if(!text&&!draft.attachments.length){document.getElementById('chat-text')?.focus();return;}
    draft.text=text;draft.sending=true;M.render();
    const sent=await M.sendChatMessage({text,room:context.room,userId:context.userId,attachments:draft.attachments.slice(),replyTo});
    draft.sending=false;
    if(sent&&drafts.get(key)===draft)drafts.delete(key);
    if(contextValid(context)){if(sent){replyTo=null;search='';emojiOpen=false;renderedRoomKey='';}refreshFocus();}
  });
  document.addEventListener('change',async event=>{
    if(event.target.id!=='chat-file-input')return;
    const files=[...event.target.files],key=draftKey(),context=captureContext();
    const draft=getDraft();
    event.target.value='';
    if(!contextValid(context)||draft.sending)return;
    if(!M.cloud?.upload||!M.cloud.waitForFile){M.toast('Хранилище ещё загружается. Попробуйте через несколько секунд.');return;}
    for(const file of files){
      if(!contextValid(context)||drafts.get(key)!==draft)break;
      if(draft.attachments.length+draft.uploads.length>=3){M.toast('Можно прикрепить до 3 файлов к сообщению');break;}
      const item={name:window.MailSecurity.sanitizeFilename(file.name),size:file.size,id:null};
      draft.uploads.push(item);M.render();
      try {
        const reservation=await M.cloud.upload(file,{mailbox:context.mailbox,source:'chat'});
        item.id=typeof reservation==='string'?reservation:reservation?.id;
        if(!item.id)throw new Error('Не удалось создать файл в облаке.');
        if(!contextValid(context)||drafts.get(key)!==draft){void M.cloud.pause?.(item.id).catch(()=>{});break;}
        M.render();
        const saved=await M.cloud.waitForFile(item.id);
        if(!contextValid(context)||drafts.get(key)!==draft)break;
        draft.attachments.push({name:saved?.name||item.name,size:saved?.size??file.size,cloudFileId:item.id});
      } catch(error) {
        if(contextValid(context))M.toast(error?.message||'Не удалось сохранить файл. Продолжить загрузку можно в облаке.');
      } finally {
        const index=draft.uploads.indexOf(item);if(index>=0)draft.uploads.splice(index,1);
        if(contextValid(context))M.render();
      }
    }
    if(contextValid(context))refreshFocus();
  });
  M.cloud?.subscribe?.(()=>{if(M.state.view==='chat'&&getDraft().uploads.length)M.render();});
})();
