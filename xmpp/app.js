(function () {
  const form = document.getElementById('connect-form');
  const wsUrlInput = document.getElementById('ws-url');
  const jidInput = document.getElementById('jid');
  const passwordInput = document.getElementById('password');
  const connectBtn = document.getElementById('connect-btn');
  const disconnectBtn = document.getElementById('disconnect-btn');
  const statusDot = document.getElementById('status-dot');
  const statusText = document.getElementById('status-text');
  const logEl = document.getElementById('log');
  const clearLogBtn = document.getElementById('clear-log-btn');
  const requestTokensBtn = document.getElementById('request-tokens-btn');
  const serverTimeBtn = document.getElementById('server-time-btn');
  const testAccountSelect = document.getElementById('test-account-select');

  const rosterJidInput = document.getElementById('roster-jid');
  const rosterNameInput = document.getElementById('roster-name');
  const addRosterBtn = document.getElementById('add-roster-btn');

  const presenceTypeSelect = document.getElementById('presence-type');
  const presenceToInput = document.getElementById('presence-to');
  const presenceStatusInput = document.getElementById('presence-status');
  const sendPresenceBtn = document.getElementById('send-presence-btn');

  const messageToInput = document.getElementById('message-to');
  const messageBodyInput = document.getElementById('message-body');
  const messageIdInput = document.getElementById('message-id');
  const requestReceiptCheckbox = document.getElementById('request-receipt-checkbox');
  const sendMessageBtn = document.getElementById('send-message-btn');
  const ackMessageIdInput = document.getElementById('ack-message-id');
  const sendDeliveryReceiptBtn = document.getElementById('send-delivery-receipt-btn');
  const sendReadReceiptBtn = document.getElementById('send-read-receipt-btn');

  const contactsDatalist = document.getElementById('contacts-datalist');

  const mucRoomSelect = document.getElementById('muc-room-select');
  const mucRefreshRoomsBtn = document.getElementById('muc-refresh-rooms-btn');

  const mucCreateNameInput = document.getElementById('muc-create-name');
  const mucCreateRoomIdInput = document.getElementById('muc-create-room-id');
  const mucCreateOccupantJidInput = document.getElementById('muc-create-occupant-jid');
  const mucCreateAddOccupantBtn = document.getElementById('muc-create-add-occupant-btn');
  const mucCreateOccupantList = document.getElementById('muc-create-occupant-list');
  const mucCreateRoomBtn = document.getElementById('muc-create-room-btn');

  const mucRenameInput = document.getElementById('muc-rename-input');
  const mucRenameBtn = document.getElementById('muc-rename-btn');

  const mucAffiliationJidInput = document.getElementById('muc-affiliation-jid');
  const mucAffiliationSelect = document.getElementById('muc-affiliation-select');
  const mucAffiliationBtn = document.getElementById('muc-affiliation-btn');

  const mucGetConfigBtn = document.getElementById('muc-get-config-btn');
  const mucGetAffiliationsBtn = document.getElementById('muc-get-affiliations-btn');

  const mucMessageBodyInput = document.getElementById('muc-message-body');
  const mucSendMessageBtn = document.getElementById('muc-send-message-btn');

  const mucBlockTargetTypeSelect = document.getElementById('muc-block-target-type');
  const mucBlockJidInput = document.getElementById('muc-block-jid');
  const mucBlockActionSelect = document.getElementById('muc-block-action');
  const mucBlockApplyBtn = document.getElementById('muc-block-apply-btn');
  const mucGetBlocklistBtn = document.getElementById('muc-get-blocklist-btn');

  const mucDestroyRoomBtn = document.getElementById('muc-destroy-room-btn');

  const liveOnlyButtons = [
    requestTokensBtn, serverTimeBtn, addRosterBtn, sendPresenceBtn, sendMessageBtn,
    sendDeliveryReceiptBtn, sendReadReceiptBtn,
    mucRefreshRoomsBtn, mucCreateRoomBtn, mucRenameBtn, mucAffiliationBtn,
    mucGetConfigBtn, mucGetAffiliationsBtn, mucSendMessageBtn,
    mucBlockApplyBtn, mucGetBlocklistBtn, mucDestroyRoomBtn,
  ];

  let connection = null;
  let keepAliveTimer = null;

  const KEEPALIVE_INTERVAL_MS = 30_000;

  // Bare JIDs known to this session, merged from the saved test accounts and
  // the live roster — feeds every `list="contacts-datalist"` input so the
  // tester can pick instead of typing.
  const knownContacts = new Set();

  function addContact(jid) {
    if (!jid || knownContacts.has(jid)) return;
    knownContacts.add(jid);
    const option = document.createElement('option');
    option.value = jid;
    contactsDatalist.appendChild(option);
  }

  function getMucDomain() {
    return `muclight.${Strophe.getDomainFromJid(connection.jid)}`;
  }

  // jid -> display name, for rooms this occupant currently belongs to.
  // Populated by disco#items (refresh) and kept live by
  // onMucAffiliationMessage below.
  const mucRooms = new Map();

  function renderMucRoomSelect() {
    const previousValue = mucRoomSelect.value;
    mucRoomSelect.innerHTML = '';
    const noneOption = document.createElement('option');
    noneOption.value = '';
    noneOption.textContent = '— none —';
    mucRoomSelect.appendChild(noneOption);
    mucRooms.forEach((name, jid) => {
      const option = document.createElement('option');
      option.value = jid;
      option.textContent = `${name} (${jid})`;
      mucRoomSelect.appendChild(option);
    });
    if (mucRooms.has(previousValue)) mucRoomSelect.value = previousValue;
  }

  function addOrUpdateMucRoom(jid, name) {
    mucRooms.set(jid, name || mucRooms.get(jid) || jid);
    renderMucRoomSelect();
  }

  function removeMucRoom(jid) {
    mucRooms.delete(jid);
    renderMucRoomSelect();
  }

  function refreshMucRooms() {
    if (!connection) return;
    const iq = $iq({ type: 'get', to: getMucDomain() })
      .c('query', { xmlns: 'http://jabber.org/protocol/disco#items' });

    connection.sendIQ(iq, (resultStanza) => {
      mucRooms.clear();
      Array.prototype.forEach.call(resultStanza.getElementsByTagName('item'), (item) => {
        const jid = item.getAttribute('jid');
        if (jid) mucRooms.set(jid, item.getAttribute('name') || jid);
      });
      renderMucRoomSelect();
    });
  }

  function refreshContactsFromRoster() {
    if (!connection) return;
    const iq = $iq({ type: 'get' }).c('query', { xmlns: 'jabber:iq:roster' });

    connection.sendIQ(iq, (resultStanza) => {
      Array.prototype.forEach.call(resultStanza.getElementsByTagName('item'), (item) => {
        addContact(item.getAttribute('jid'));
      });
    });
  }

  // Notifications MUC Light sends to every affected occupant on
  // create/invite/kick/promote/destroy — the only way to learn a
  // server-generated room JID from Create Room, and the general mechanism
  // for keeping the room dropdown in sync without manual refreshes.
  function onMucAffiliationMessage(stanza) {
    const xEl = Array.prototype.find.call(
      stanza.getElementsByTagName('x'),
      (el) => el.getAttribute('xmlns') === 'urn:xmpp:muclight:0#affiliations',
    );
    if (!xEl) return true;

    const roomJid = Strophe.getBareJidFromJid(stanza.getAttribute('from'));
    const myBareJid = Strophe.getBareJidFromJid(connection.jid).toLowerCase();

    let selfRemoved = false;
    Array.prototype.forEach.call(xEl.getElementsByTagName('user'), (userEl) => {
      const jid = (userEl.textContent || '').trim().toLowerCase();
      if (jid === myBareJid && userEl.getAttribute('affiliation') === 'none') {
        selfRemoved = true;
      }
    });

    if (selfRemoved) {
      removeMucRoom(roomJid);
    } else {
      addOrUpdateMucRoom(roomJid, mucRooms.get(roomJid));
    }

    return true;
  }

  let pendingOccupants = [];

  function renderPendingOccupants() {
    mucCreateOccupantList.innerHTML = '';
    pendingOccupants.forEach((jid) => {
      const li = document.createElement('li');
      const span = document.createElement('span');
      span.textContent = jid;
      const removeBtn = document.createElement('button');
      removeBtn.type = 'button';
      removeBtn.textContent = '×';
      removeBtn.addEventListener('click', () => {
        pendingOccupants = pendingOccupants.filter((existing) => existing !== jid);
        renderPendingOccupants();
      });
      li.append(span, removeBtn);
      mucCreateOccupantList.appendChild(li);
    });
  }

  function startKeepAlive() {
    stopKeepAlive();
    keepAliveTimer = setInterval(() => {
      if (!connection) return;
      // XEP-0199 ping to the server itself. The websocket handler's idle
      // timeout closes the socket after a period with no frames at all —
      // this keeps it alive during long pauses between manual test actions.
      connection.send($iq({ type: 'get' }).c('ping', { xmlns: 'urn:xmpp:ping' }));
    }, KEEPALIVE_INTERVAL_MS);
  }

  function stopKeepAlive() {
    if (keepAliveTimer) {
      clearInterval(keepAliveTimer);
      keepAliveTimer = null;
    }
  }

  const STATUS_INFO = {
    [Strophe.Status.ERROR]: ['error', 'Error'],
    [Strophe.Status.CONNECTING]: ['connecting', 'Connecting…'],
    [Strophe.Status.CONNFAIL]: ['error', 'Connection failed'],
    [Strophe.Status.AUTHENTICATING]: ['connecting', 'Authenticating…'],
    [Strophe.Status.AUTHFAIL]: ['error', 'Authentication failed'],
    [Strophe.Status.CONNECTED]: ['connected', 'Connected'],
    [Strophe.Status.DISCONNECTED]: ['disconnected', 'Disconnected'],
    [Strophe.Status.DISCONNECTING]: ['connecting', 'Disconnecting…'],
    [Strophe.Status.ATTACHED]: ['connected', 'Attached'],
    [Strophe.Status.REDIRECT]: ['connecting', 'Redirecting…'],
    [Strophe.Status.CONNTIMEOUT]: ['error', 'Connection timed out'],
    [Strophe.Status.BINDREQUIRED]: ['connecting', 'Bind required'],
    [Strophe.Status.ATTACHFAIL]: ['error', 'Attach failed'],
    [Strophe.Status.RECONNECTING]: ['connecting', 'Reconnecting…'],
  };

  const TERMINAL_STATUSES = new Set([
    Strophe.Status.DISCONNECTED,
    Strophe.Status.CONNFAIL,
    Strophe.Status.AUTHFAIL,
    Strophe.Status.ERROR,
    Strophe.Status.CONNTIMEOUT,
    Strophe.Status.ATTACHFAIL,
  ]);

  const LIVE_STATUSES = new Set([
    Strophe.Status.CONNECTED,
    Strophe.Status.ATTACHED,
  ]);

  function setStatus(status) {
    const [cls, text] = STATUS_INFO[status] || ['error', 'Unknown status'];
    statusDot.className = 'dot ' + cls;
    statusText.textContent = text;

    connectBtn.disabled = !TERMINAL_STATUSES.has(status) && status !== undefined;
    disconnectBtn.disabled = !LIVE_STATUSES.has(status) && !(
      status === Strophe.Status.CONNECTING || status === Strophe.Status.AUTHENTICATING
    );
    const live = LIVE_STATUSES.has(status);
    liveOnlyButtons.forEach((btn) => {
      btn.disabled = !live;
    });
  }

  // Indents a raw XML string for readability without pulling in a parser.
  function formatXml(xml) {
    const tokens = xml.match(/<[^>]+>|[^<>]+/g) || [xml];
    const pad = '  ';
    let indent = 0;
    const lines = [];

    for (const raw of tokens) {
      const token = raw.trim();
      if (!token) continue;

      if (token.startsWith('</')) {
        indent = Math.max(indent - 1, 0);
        lines.push(pad.repeat(indent) + token);
      } else if (token.startsWith('<') && (token.endsWith('/>') || token.startsWith('<?'))) {
        lines.push(pad.repeat(indent) + token);
      } else if (token.startsWith('<')) {
        lines.push(pad.repeat(indent) + token);
        indent++;
      } else {
        lines.push(pad.repeat(indent) + token);
      }
    }

    return lines.join('\n');
  }

  function logStanza(direction, xmlString) {
    if (!xmlString) return;

    const entry = document.createElement('div');
    entry.className = 'entry';

    const header = document.createElement('div');
    header.className = 'entry-header';

    const badge = document.createElement('span');
    badge.className = 'badge ' + (direction === 'sent' ? 'sent' : 'recv');
    badge.textContent = direction === 'sent' ? 'SENT' : 'RECV';

    const time = document.createElement('span');
    time.textContent = new Date().toLocaleTimeString([], { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit', fractionalSecondDigits: 3 });

    header.append(badge, time);

    const pre = document.createElement('pre');
    pre.textContent = formatXml(xmlString);

    entry.append(header, pre);
    logEl.prepend(entry);
    logEl.scrollTop = 0;
  }

  function onStatusChanged(status) {
    setStatus(status);

    if (status === Strophe.Status.CONNECTED) {
      // A session is only "online" from the server's perspective, and only
      // receives roster contacts' presence, after it sends its own initial
      // presence — real XMPP clients always do this automatically on
      // login (RFC 6121). Without it, mod_presence has no per-session
      // state to route subscription/status updates into, and they're
      // silently dropped.
      connection.send($pres());
      startKeepAlive();
      connection.addHandler(onMucAffiliationMessage, null, 'message', 'groupchat', null, null);
      refreshContactsFromRoster();
      refreshMucRooms();
    } else if (status === Strophe.Status.AUTHFAIL) {
      logStanza('recv', '<!-- authentication failed -->');
      stopKeepAlive();
    } else if (status === Strophe.Status.CONNFAIL) {
      logStanza('recv', '<!-- connection failed -->');
      stopKeepAlive();
    } else if (status === Strophe.Status.DISCONNECTED) {
      stopKeepAlive();
      mucRooms.clear();
      renderMucRoomSelect();
    }
  }

  form.addEventListener('submit', (event) => {
    event.preventDefault();

    const service = wsUrlInput.value.trim();
    const jid = jidInput.value.trim();
    const password = passwordInput.value.trim();
    if (!service || !jid || !password) return;

    // The HTTP auth backend only implements plaintext check_password, so
    // restrict SASL to PLAIN — otherwise Strophe defaults to SCRAM-SHA-512,
    // which that backend can't satisfy.
    connection = new Strophe.Connection(service, { mechanisms: [Strophe.SASLPlain] });
    connection.rawInput = (data) => logStanza('recv', data);
    connection.rawOutput = (data) => logStanza('sent', data);

    setStatus(Strophe.Status.CONNECTING);
    console.log(password)
    connection.connect(jid, password, onStatusChanged);
  });

  disconnectBtn.addEventListener('click', () => {
    if (connection) connection.disconnect();
  });

  requestTokensBtn.addEventListener('click', () => {
    if (!connection || !connection.jid) return;

    const to = Strophe.getBareJidFromJid(connection.jid);
    const iq = $iq({ type: 'get', to }).c('query', {
      xmlns: 'erlang-solutions.com:xmpp:token-auth:0',
    });

    connection.send(iq);
  });

  serverTimeBtn.addEventListener('click', () => {
    if (!connection || !connection.jid) return;

    // XEP-0202 (Entity Time), served by mod_time — addressed to the domain
    // itself rather than a bare JID.
    const to = Strophe.getDomainFromJid(connection.jid);
    const iq = $iq({ type: 'get', to }).c('time', { xmlns: 'urn:xmpp:time' });

    connection.send(iq);
  });

  mucRefreshRoomsBtn.addEventListener('click', refreshMucRooms);

  mucCreateAddOccupantBtn.addEventListener('click', () => {
    const jid = mucCreateOccupantJidInput.value.trim();
    if (!jid || pendingOccupants.includes(jid)) return;
    pendingOccupants.push(jid);
    mucCreateOccupantJidInput.value = '';
    renderPendingOccupants();
  });

  mucCreateRoomBtn.addEventListener('click', () => {
    if (!connection) return;

    const name = mucCreateNameInput.value.trim();
    const roomId = mucCreateRoomIdInput.value.trim();
    const to = roomId ? `${roomId}@${getMucDomain()}` : getMucDomain();

    const iq = $iq({ type: 'set', to }).c('query', { xmlns: 'urn:xmpp:muclight:0#create' });
    iq.c('configuration');
    if (name) iq.c('roomname').t(name).up();
    iq.up().c('occupants');
    pendingOccupants.forEach((jid) => {
      iq.c('user', { affiliation: 'member' }).t(jid).up();
    });

    connection.send(iq);

    pendingOccupants = [];
    renderPendingOccupants();
    mucCreateNameInput.value = '';
    mucCreateRoomIdInput.value = '';
  });

  mucRenameBtn.addEventListener('click', () => {
    const to = mucRoomSelect.value;
    const name = mucRenameInput.value.trim();
    if (!connection || !to || !name) return;

    const iq = $iq({ type: 'set', to })
      .c('query', { xmlns: 'urn:xmpp:muclight:0#configuration' })
      .c('roomname').t(name);

    connection.send(iq);
    mucRenameInput.value = '';
  });

  mucAffiliationBtn.addEventListener('click', () => {
    const to = mucRoomSelect.value;
    const jid = mucAffiliationJidInput.value.trim();
    if (!connection || !to || !jid) return;

    const iq = $iq({ type: 'set', to })
      .c('query', { xmlns: 'urn:xmpp:muclight:0#affiliations' })
      .c('user', { affiliation: mucAffiliationSelect.value }).t(jid);

    connection.send(iq);
  });

  mucGetConfigBtn.addEventListener('click', () => {
    const to = mucRoomSelect.value;
    if (!connection || !to) return;

    const iq = $iq({ type: 'get', to }).c('query', { xmlns: 'urn:xmpp:muclight:0#configuration' });
    connection.send(iq);
  });

  mucGetAffiliationsBtn.addEventListener('click', () => {
    const to = mucRoomSelect.value;
    if (!connection || !to) return;

    const iq = $iq({ type: 'get', to }).c('query', { xmlns: 'urn:xmpp:muclight:0#affiliations' });
    connection.send(iq);
  });

  mucSendMessageBtn.addEventListener('click', () => {
    const to = mucRoomSelect.value;
    const body = mucMessageBodyInput.value.trim();
    if (!connection || !to || !body) return;

    const msg = $msg({ to, type: 'groupchat' }).c('body').t(body);
    connection.send(msg);
    mucMessageBodyInput.value = '';
  });

  mucBlockApplyBtn.addEventListener('click', () => {
    if (!connection) return;

    const isRoom = mucBlockTargetTypeSelect.value === 'room';
    const target = isRoom ? mucRoomSelect.value : mucBlockJidInput.value.trim();
    if (!target) return;

    const iq = $iq({ type: 'set', to: getMucDomain() })
      .c('query', { xmlns: 'urn:xmpp:muclight:0#blocking' })
      .c(isRoom ? 'room' : 'user', { action: mucBlockActionSelect.value }).t(target);

    connection.send(iq);
  });

  mucGetBlocklistBtn.addEventListener('click', () => {
    if (!connection) return;

    const iq = $iq({ type: 'get', to: getMucDomain() })
      .c('query', { xmlns: 'urn:xmpp:muclight:0#blocking' });

    connection.send(iq);
  });

  mucDestroyRoomBtn.addEventListener('click', () => {
    const to = mucRoomSelect.value;
    if (!connection || !to) return;

    const iq = $iq({ type: 'set', to }).c('query', { xmlns: 'urn:xmpp:muclight:0#destroy' });
    connection.send(iq);
  });

  addRosterBtn.addEventListener('click', () => {
    if (!connection) return;

    const jid = rosterJidInput.value.trim();
    if (!jid) return;
    const name = rosterNameInput.value.trim() || undefined;

    const iq = $iq({ type: 'set' })
      .c('query', { xmlns: 'jabber:iq:roster' })
      .c('item', { jid, name });

    connection.send(iq);
  });

  sendPresenceBtn.addEventListener('click', () => {
    if (!connection) return;

    const type = presenceTypeSelect.value || undefined;
    const to = presenceToInput.value.trim() || undefined;
    const status = presenceStatusInput.value.trim();

    const pres = $pres({ type, to });
    if (status) pres.c('status').t(status);

    connection.send(pres);
  });

  sendMessageBtn.addEventListener('click', () => {
    if (!connection) return;

    const to = messageToInput.value.trim();
    const body = messageBodyInput.value.trim();
    if (!to || !body) return;

    const id = messageIdInput.value.trim() || connection.getUniqueId('msg');
    const msg = $msg({ to, type: 'chat', id }).c('body').t(body);
    if (requestReceiptCheckbox.checked) {
      msg.up().c('request', { xmlns: 'urn:xmpp:receipts' });
    }
    connection.send(msg);
    messageBodyInput.value = '';
  });

  sendDeliveryReceiptBtn.addEventListener('click', () => {
    if (!connection) return;

    const to = messageToInput.value.trim();
    const ackId = ackMessageIdInput.value.trim();
    if (!to || !ackId) return;

    const msg = $msg({ to }).c('received', { xmlns: 'urn:xmpp:receipts', id: ackId });
    connection.send(msg);
  });

  sendReadReceiptBtn.addEventListener('click', () => {
    if (!connection) return;

    const to = messageToInput.value.trim();
    const ackId = ackMessageIdInput.value.trim();
    if (!to || !ackId) return;

    const msg = $msg({ to }).c('displayed', { xmlns: 'urn:xmpp:chat-markers:0', id: ackId });
    connection.send(msg);
  });

  clearLogBtn.addEventListener('click', () => {
    logEl.innerHTML = '';
  });

  (window.TEST_ACCOUNTS || []).forEach((account, index) => {
    const option = document.createElement('option');
    option.value = String(index);
    option.textContent = account.label;
    testAccountSelect.appendChild(option);
    addContact(Strophe.getBareJidFromJid(account.jid));
  });

  testAccountSelect.addEventListener('change', () => {
    const account = (window.TEST_ACCOUNTS || [])[testAccountSelect.value];
    if (!account) return;
    jidInput.value = account.jid;
    passwordInput.value = account.password;
  });
})();
