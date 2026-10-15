(function () {
  'use strict';

  const ID = /^[A-Za-z0-9_-]{1,100}$/;
  const EMAIL = /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}$/;
  const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
  const COLORS = new Set(['sage', 'peach', 'blue', 'lavender']);
  const FOLDERS = new Set(['inbox', 'sent', 'drafts', 'archive', 'trash', 'spam']);
  const LABELS = new Set(['Клиенты', 'Архивы', 'Команда']);
  const CHANNELS = new Set(['general', 'archives', 'digitize']);
  const RASTER = new Set(['image/png', 'image/jpeg', 'image/webp']);
  const ATTACHMENT_TYPES = new Set([
    ...RASTER, 'application/pdf', 'text/plain',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  ]);
  const ATTACHMENT_EXTENSIONS = new Map([
    ['image/png', ['png']], ['image/jpeg', ['jpg', 'jpeg']], ['image/webp', ['webp']],
    ['application/pdf', ['pdf']], ['text/plain', ['txt']],
    ['application/vnd.openxmlformats-officedocument.wordprocessingml.document', ['docx']],
    ['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', ['xlsx']]
  ]);
  const MIN_DATE = 946684800000;
  const MAX_DATE = 4102444800000;
  const owns = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

  function record(value) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
    const prototype = Object.getPrototypeOf(value);
    return prototype === null || Object.getPrototypeOf(prototype) === null;
  }
  function text(value, maximum, fallback = '') {
    return typeof value === 'string'
      ? value.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '').slice(0, maximum)
      : fallback;
  }
  function id(value) { return typeof value === 'string' && ID.test(value) ? value : null; }
  function email(value) {
    if (typeof value !== 'string' || value.length > 254 || !EMAIL.test(value)) return null;
    return value.toLowerCase();
  }
  function date(value) {
    return typeof value === 'number' && Number.isFinite(value) && value >= MIN_DATE && value <= MAX_DATE
      ? Math.trunc(value) : null;
  }
  function list(source, key, fallback, maximum) {
    const value = Array.isArray(source[key]) ? source[key] : Array.isArray(fallback[key]) ? fallback[key] : [];
    return value.slice(0, maximum);
  }
  function base64(value, maximum, expectedBytes) {
    if (typeof value !== 'string' || !value.length || value.length > maximum || !BASE64.test(value)) return null;
    try {
      const bytes = atob(value);
      if (btoa(bytes) !== value || (expectedBytes !== undefined && bytes.length !== expectedBytes)) return null;
      return bytes;
    } catch (_) { return null; }
  }
  function matchesMagic(bytes, mime) {
    const byte = index => bytes.charCodeAt(index);
    if (mime === 'image/png') return bytes.length >= 8 && bytes.slice(0, 8) === '\x89PNG\r\n\x1a\n';
    if (mime === 'image/jpeg') return bytes.length >= 4 && byte(0) === 255 && byte(1) === 216 && byte(2) === 255;
    if (mime === 'image/webp') return bytes.length >= 12 && bytes.slice(0, 4) === 'RIFF' && bytes.slice(8, 12) === 'WEBP';
    if (mime === 'application/pdf') return bytes.length >= 5 && bytes.slice(0, 5) === '%PDF-';
    if (mime.startsWith('application/vnd.openxmlformats-officedocument.')) {
      return bytes.length >= 4 && bytes.slice(0, 4) === 'PK\x03\x04';
    }
    return mime === 'text/plain';
  }
  function boundedAvatarDimensions(bytes, mime) {
    const byte = index => bytes.charCodeAt(index);
    const be16 = index => (byte(index) << 8) | byte(index + 1);
    const be32 = index => byte(index) * 16777216 + byte(index + 1) * 65536 + byte(index + 2) * 256 + byte(index + 3);
    const le16 = index => byte(index) | (byte(index + 1) << 8);
    const le32 = index => byte(index) + byte(index + 1) * 256 + byte(index + 2) * 65536 + byte(index + 3) * 16777216;
    const bounded = (width, height) => Number.isInteger(width) && Number.isInteger(height) && width > 0 && height > 0 && width <= 512 && height <= 512 && width * height <= 262144;
    if (mime === 'image/png') {
      return bytes.length >= 33 && be32(8) === 13 && bytes.slice(12, 16) === 'IHDR' && bounded(be32(16), be32(20));
    }
    if (mime === 'image/jpeg') {
      const frames = new Set([192, 193, 194, 195, 197, 198, 199, 201, 202, 203, 205, 206, 207]);
      let offset = 2, dimensions = null;
      while (offset < bytes.length) {
        if (byte(offset++) !== 255) return false;
        while (offset < bytes.length && byte(offset) === 255) offset++;
        if (offset >= bytes.length) return false;
        const marker = byte(offset++);
        if (marker === 217 || marker === 218) return dimensions !== null;
        if (marker === 1 || (marker >= 208 && marker <= 215)) continue;
        if (offset + 2 > bytes.length) return false;
        const length = be16(offset);
        if (length < 2 || offset + length > bytes.length) return false;
        if (frames.has(marker)) {
          if (length < 11) return false;
          const components = byte(offset + 7), width = be16(offset + 5), height = be16(offset + 3);
          if (components < 1 || components > 4 || length < 8 + 3 * components || !bounded(width, height)) return false;
          if (dimensions && (dimensions[0] !== width || dimensions[1] !== height)) return false;
          dimensions = [width, height];
        }
        offset += length;
      }
      return false;
    }
    if (mime === 'image/webp') {
      if (bytes.length < 20 || le32(4) !== bytes.length - 8) return false;
      let offset = 12, dimensions = null;
      while (offset + 8 <= bytes.length) {
        const kind = bytes.slice(offset, offset + 4), length = le32(offset + 4), start = offset + 8;
        if (start + length + (length % 2) > bytes.length) return false;
        let width, height;
        if (kind === 'VP8X') {
          if (length !== 10 || (byte(start) & 2)) return false;
          width = 1 + byte(start + 4) + (byte(start + 5) << 8) + (byte(start + 6) << 16);
          height = 1 + byte(start + 7) + (byte(start + 8) << 8) + (byte(start + 9) << 16);
        } else if (kind === 'VP8 ') {
          if (length < 10 || (byte(start) & 1) || bytes.slice(start + 3, start + 6) !== '\x9d\x01\x2a') return false;
          width = le16(start + 6) & 16383;
          height = le16(start + 8) & 16383;
        } else if (kind === 'VP8L') {
          if (length < 5 || byte(start) !== 47 || (byte(start + 4) >> 5)) return false;
          width = 1 + byte(start + 1) + ((byte(start + 2) & 63) << 8);
          height = 1 + (byte(start + 2) >> 6) + (byte(start + 3) << 2) + ((byte(start + 4) & 15) << 10);
        } else if (kind === 'ANIM' || kind === 'ANMF') return false;
        if (width !== undefined) {
          if (!bounded(width, height) || (dimensions && (dimensions[0] !== width || dimensions[1] !== height))) return false;
          dimensions = [width, height];
        }
        offset = start + length + (length % 2);
      }
      return offset === bytes.length && dimensions !== null;
    }
    return false;
  }
  function safeDataUrl(value, allowedTypes, maximum, avatarDimensions = false) {
    if (typeof value !== 'string' || value.length > maximum) return null;
    const match = /^data:([a-z0-9.+/-]+);base64,([A-Za-z0-9+/=]+)$/.exec(value);
    if (!match || !allowedTypes.has(match[1])) return null;
    const bytes = base64(match[2], maximum);
    return bytes !== null && matchesMagic(bytes, match[1]) && (!avatarDimensions || boundedAvatarDimensions(bytes, match[1])) ? value : null;
  }
  function safeAttachmentUrl(attachment) {
    if (!record(attachment)) return null;
    const match = typeof attachment.dataUrl === 'string' ? /^data:([a-z0-9.+/-]+);base64,/.exec(attachment.dataUrl) : null;
    if (!match || !ATTACHMENT_EXTENSIONS.has(match[1])) return null;
    if (owns(attachment, 'name')) {
      if (typeof attachment.name !== 'string') return null;
      const extension = /\.([a-z0-9]+)$/i.exec(sanitizeFilename(attachment.name));
      if (!extension || !ATTACHMENT_EXTENSIONS.get(match[1]).includes(extension[1].toLowerCase())) return null;
    }
    return safeDataUrl(attachment.dataUrl, ATTACHMENT_TYPES, 1600000);
  }
  function safeAvatarUrl(value) { return safeDataUrl(value, RASTER, 200 * 1024, true); }
  function sanitizeFilename(value) {
    let name = text(value, 240, 'Вложение').replace(/[\\/<>:"|?*\u0000-\u001F\u007F\u200E\u200F\u2028\u2029\u202A-\u202E\u2066-\u2069\uFEFF]/g, '')
      .replace(/\.{2,}/g, '.').replace(/^\.+|[. ]+$/g, '').trim().slice(0, 120);
    if (!name || /^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)/i.test(name)) name = 'Вложение';
    return name;
  }
  function attachment(value, numericSize) {
    if (!record(value)) return null;
    const result = { name: sanitizeFilename(value.name), size: numericSize ? 0 : '' };
    const cloudId = id(value.cloudFileId);
    if (cloudId) result.cloudFileId = cloudId;
    if (numericSize) {
      if (typeof value.size === 'number' && Number.isFinite(value.size)) result.size = Math.max(0, Math.min(cloudId ? 15000000000 : 1200000, Math.trunc(value.size)));
    } else if (typeof value.size === 'string') result.size = text(value.size, 30);
    else if (typeof value.size === 'number' && Number.isFinite(value.size)) result.size = `${Math.ceil(Math.max(0, Math.min(value.size, 1200000)) / 1024)} КБ`;
    const url = safeAttachmentUrl(value);
    if (url) {
      result.dataUrl = url;
      if (!owns(value, 'name')) {
        const mime = /^data:([^;]+);/.exec(url)[1];
        result.name = 'Вложение.' + ATTACHMENT_EXTENSIONS.get(mime)[0];
      }
    }
    // A rejected URL cannot become a downloadable text fallback.
    else if (!owns(value, 'dataUrl') && typeof value.content === 'string') {
      result.content = text(value.content, 800000);
      if (!/\.txt$/i.test(result.name)) result.name = result.name.slice(0, 116) + '.txt';
    }
    return result;
  }
  function normalizeUser(value) {
    if (!record(value)) return null;
    const userId = id(value.id), address = email(value.email), name = text(value.name, 120).trim();
    if (!userId || !address || !name) return null;
    const result = { id: userId, name, email: address, role: value.role === 'admin' ? 'admin' : 'member', active: value.active === true, color: COLORS.has(value.color) ? value.color : 'sage', smartSort: value.smartSort === true };
    if (typeof value.signature === 'string') result.signature = text(value.signature, 1000);
    result.sharedWith = Array.isArray(value.sharedWith) ? [...new Set(value.sharedWith.filter(v=>id(v)&&v!==userId))].slice(0,100) : [];
    const avatar = safeAvatarUrl(value.avatarUrl);
    if (avatar) result.avatarUrl = avatar;
    if (value.passwordIterations === 210000 && base64(value.passwordHash, 44, 32) !== null && base64(value.salt, 24, 16) !== null) {
      result.passwordHash = value.passwordHash;
      result.salt = value.salt;
      result.passwordIterations = 210000;
    }
    const auto = record(value.autoReply) ? value.autoReply : {};
    const lastReplies = Object.create(null);
    if (record(auto.lastReplies)) {
      for (const key of Object.keys(auto.lastReplies).slice(0, 250)) {
        const addressKey = email(key), sentAt = date(auto.lastReplies[key]);
        if (addressKey && sentAt !== null) lastReplies[addressKey] = sentAt;
      }
    }
    result.autoReply = { enabled: auto.enabled === true, message: text(auto.message, 2000), lastReplies };
    return result;
  }
  function normalizeMail(value, users, scheduled) {
    if (!record(value)) return null;
    const mailId = id(value.id), owner = value.owner === 'team' ? 'team' : id(value.owner);
    if (!mailId || !owner || (owner !== 'team' && !users.has(owner))) return null;
    const actorId = users.has(value.actorId) ? value.actorId : owner === 'team' ? null : owner;
    if (scheduled && (!actorId || (owner !== 'team' && actorId!==owner && !users.get(owner).sharedWith?.includes(actorId)))) return null;
    const sender = scheduled ? users.get(owner) : null;
    const address = sender ? sender.email : email(value.email);
    if (!address) return null;
    const result = {
      id: mailId, owner, sender: sender ? sender.name : text(value.sender, 120, 'Отправитель'), email: address,
      to: email(value.to) || '', subject: text(value.subject, 250), body: text(value.body, 20000),
      folder: scheduled ? 'drafts' : FOLDERS.has(value.folder) ? value.folder : 'inbox',
      label: LABELS.has(value.label) ? value.label : 'Команда', unread: value.unread === true, starred: value.starred === true,
      createdAt: date(value.createdAt) ?? Date.now(), time: text(value.time, 40)
    };
    const file = attachment(value.attachment, false);
    if(actorId)result.actorId=actorId;
    if (file) result.attachment = file;
    if (id(value.replyId)) result.replyId = value.replyId;
    const reminder = date(value.remindAt);
    if (reminder !== null) result.remindAt = reminder;
    if (owner === 'team') {
      if (users.has(value.assignee)) result.assignee = value.assignee;
      result.notes = Array.isArray(value.notes) ? value.notes.slice(0, 100).flatMap(note => {
        if (!record(note) || !users.has(note.user) || typeof note.text !== 'string') return [];
        return [{ user: note.user, text: text(note.text, 2000) }];
      }) : [];
    }
    result.replies = Array.isArray(value.replies) ? value.replies.slice(0, 100).flatMap(reply => {
      if (!record(reply) || typeof reply.body !== 'string') return [];
      return [{ sender: text(reply.sender, 120), body: text(reply.body, 20000), time: text(reply.time, 40) }];
    }) : [];
    if (scheduled) {
      const sendAt = date(value.sendAt);
      if (sendAt === null || !result.to) return null;
      result.sendAt = sendAt;
    }
    return result;
  }
  function chatRoom(value, users) {
    if (CHANNELS.has(value)) return value;
    if (typeof value !== 'string' || !value.startsWith('dm:')) return null;
    const ids = value.slice(3).split(':');
    if (ids.length !== 2 || ids[0] === ids[1] || !ids.every(userId => id(userId) && users.has(userId))) return null;
    return 'dm:' + ids.sort().join(':');
  }
  function normalizeMessage(value, users) {
    if (!record(value)) return null;
    const messageId = id(value.id), room = chatRoom(value.room, users), createdAt = date(value.createdAt);
    if (!messageId || !room || !users.has(value.user) || createdAt === null) return null;
    if (room.startsWith('dm:') && !room.slice(3).split(':').includes(value.user)) return null;
    const result = { id: messageId, room, user: value.user, text: text(value.text, 6000), createdAt, pinned: value.pinned === true };
    result.attachments = Array.isArray(value.attachments) ? value.attachments.slice(0, 3).map(file => attachment(file, true)).filter(Boolean) : [];
    if(record(value.media)&&id(value.media.fileId)&&['voice','circle'].includes(value.media.kind)){
      const max=value.media.kind==='circle'?60:300;
      const duration=typeof value.media.duration==='number'&&Number.isFinite(value.media.duration)?Math.max(0,Math.min(max,value.media.duration)):0;
      result.media={fileId:value.media.fileId,kind:value.media.kind,duration,mime:text(value.media.mime,60),transcript:typeof value.media.transcript==='string'?text(value.media.transcript,20000):null};
    }
    if (id(value.replyTo)) result.replyTo = value.replyTo;
    return result;
  }
  function unique(values, field) {
    const seen = new Set();
    return values.filter(value => { if (!value || seen.has(value[field])) return false; seen.add(value[field]); return true; });
  }
  function accountUrl(value) {
    if (typeof value !== 'string' || value.length > 254) return '';
    try {
      const url = new URL(value);
      if (url.protocol !== 'https:' || url.username || url.password || url.port || url.search || url.hash || url.pathname !== '/') return '';
      if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.(?:amocrm\.ru|kommo\.com)$/.test(url.hostname)) return '';
      return url.origin;
    } catch (_) { return ''; }
  }
  function normalizeIntegrations(value, users, mails) {
    const source = record(value) ? value : {}, amo = record(source.amo) ? source.amo : {};
    const drafts = unique((Array.isArray(source.drafts) ? source.drafts.slice(0, 500) : []).flatMap(value => {
      if (!record(value) || !id(value.id) || !users.has(value.userId) || !mails.has(value.mailId) || date(value.createdAt) === null || (value.stage !== undefined && value.stage !== 'new')) return [];
      const mail = mails.get(value.mailId);
      if (mail.owner !== value.userId && mail.owner !== 'team' && !users.get(mail.owner)?.sharedWith?.includes(value.userId)) return [];
      return [{ id: value.id, userId: value.userId, mailId: value.mailId, createdAt: date(value.createdAt), contactName: text(value.contactName, 120), contactEmail: email(value.contactEmail) || '', title: text(value.title, 250), stage: 'new' }];
    }), 'id');
    return { amo: { demoEnabled: amo.demoEnabled === true, accountUrl: accountUrl(amo.accountUrl), syncClientMail: amo.syncClientMail === true, personalOptIn: amo.personalOptIn === true }, drafts };
  }
  function normalizeState(value, seeds) {
    const source = record(value) ? value : {}, fallback = record(seeds) ? seeds : {};
    const users = unique(unique(list(source, 'users', fallback, 250).map(normalizeUser), 'id'), 'email');
    const userMap = new Map(users.map(user => [user.id, user]));
    for(const user of users)user.sharedWith=user.sharedWith.filter(userId=>userMap.get(userId)?.active===true);
    const mails = unique(list(source, 'mails', fallback, 1500).map(mail => normalizeMail(mail, userMap, false)), 'id');
    const mailMap = new Map(mails.map(mail => [mail.id, mail]));
    const scheduled = unique(list(source, 'scheduled', fallback, 100).map(mail => normalizeMail(mail, userMap, true)), 'id');
    for (const mail of [...mails, ...scheduled]) {
      const original = mailMap.get(mail.replyId);
      if (!original || (original.owner !== mail.owner && original.owner !== 'team')) delete mail.replyId;
    }
    const settingSource = record(source.settings) ? source.settings : record(fallback.settings) ? fallback.settings : {};
    const settings = { theme: settingSource.theme === 'light' ? 'light' : 'dark', signature: text(settingSource.signature, 1000), notifications: settingSource.notifications === true };
    const chatSource = record(source.chats) ? source.chats : record(fallback.chats) ? fallback.chats : null;
    let chats;
    if (chatSource) {
      const messages = unique((Array.isArray(chatSource.messages) ? chatSource.messages.slice(0, 3000) : []).map(message => normalizeMessage(message, userMap)), 'id');
      const messageMap = new Map(messages.map(message => [message.id, message]));
      for (const message of messages) if (message.replyTo && messageMap.get(message.replyTo)?.room !== message.room) delete message.replyTo;
      chats = { version: 1, messages };
    }
    return { users, mails, chats, settings, scheduled, integrations: normalizeIntegrations(source.integrations, userMap, mailMap) };
  }

  window.MailSecurity = Object.freeze({ normalizeState, safeAvatarUrl, safeAttachmentUrl, sanitizeFilename });
})();
