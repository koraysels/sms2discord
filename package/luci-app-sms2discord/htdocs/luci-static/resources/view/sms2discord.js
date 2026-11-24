'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';
'require poll';
'require dom';

var BIN = '/usr/bin/sms2discord';
var WEBHOOK_RE = /^https:\/\/([a-z]+\.)?discord(app)?\.com\/api\/webhooks\/\d+\/[\w-]+$/;
var OTP_NAME_RE = /^[A-Za-z0-9][\w.-]{0,31}$/;
var OTP_SECRET_RE = /^(otpauth:\/\/totp\/\S+|[A-Za-z2-7=\s-]{8,})$/i;

function getStatus() {
	return fs.exec(BIN, [ 'status', '--json' ]).then(function(res) {
		try { return JSON.parse(res.stdout); }
		catch (e) { return null; }
	}).catch(function() { return null; });
}

function getLog() {
	return fs.exec('/sbin/logread', [ '-e', 'sms2discord' ]).then(function(res) {
		return (res.stdout || '').trim().split('\n').slice(-15).join('\n');
	}).catch(function() { return ''; });
}

/* Discord lets a bot post over REST only after it has logged in to the
 * Gateway once. The router only speaks REST, so do that login from here. */
function gatewayLogin(token) {
	return new Promise(function(resolve, reject) {
		var ws = new WebSocket('wss://gateway.discord.gg/?v=10&encoding=json');
		var done = false;
		var finish = function(fn, arg) {
			if (done) return;
			done = true;
			clearTimeout(timer);
			try { ws.close(); } catch (e) {}
			fn(arg);
		};
		var timer = setTimeout(function() { finish(reject, new Error(_('Timed out waiting for Discord'))); }, 20000);

		ws.onmessage = function(ev) {
			var msg = JSON.parse(ev.data);
			if (msg.op == 10)
				ws.send(JSON.stringify({ op: 2, d: { token: token, intents: 0,
					properties: { os: 'linux', browser: 'luci-app-sms2discord', device: 'luci-app-sms2discord' } } }));
			else if (msg.t == 'READY')
				finish(resolve, msg.d.user);
			else if (msg.op == 9)
				finish(reject, new Error(_('Discord rejected the session')));
		};
		ws.onclose = function(ev) {
			finish(reject, new Error(ev.code == 4004 ? _('Wrong bot token') : _('Connection closed (%d)').format(ev.code)));
		};
		ws.onerror = function() {
			finish(reject, new Error(_('Cannot reach the Discord gateway from this browser')));
		};
	});
}

/* notices that must survive the reload after "Detect" */
var NOTICE_KEY = 'sms2discord-notice';

function stashNotice(msg, type) {
	try { sessionStorage.setItem(NOTICE_KEY, JSON.stringify([ msg, type ])); } catch (e) {}
}

function showStashedNotice() {
	try {
		var n = JSON.parse(sessionStorage.getItem(NOTICE_KEY) || 'null');
		sessionStorage.removeItem(NOTICE_KEY);
		if (n) ui.addNotification(null, E('p', {}, n[0]), n[1]);
	} catch (e) {}
}

function yesNo(v, yes, no) {
	return E('span', { 'class': 'label ' + (v ? 'success' : 'warning') }, v ? yes : no);
}

return view.extend({
	load: function() {
		return Promise.all([ uci.load('sms2discord'), getStatus(), getLog() ]);
	},

	renderStatusRows: function(st) {
		if (!st)
			return [ E('tr', { 'class': 'tr' }, E('td', { 'class': 'td' }, _('sms2discord is not responding.'))) ];

		var row = function(label, value) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, label),
				E('td', { 'class': 'td left' }, value)
			]);
		};

		return [
			row(_('Service'), [ yesNo(st.running, _('Running'), st.enabled ? _('Not running') : _('Disabled')),
				' ', E('small', {}, 'v' + st.version) ]),
			row(_('Receiving'), st.webhook_set
				? (st.configured ? yesNo(true, _('Forwarding to Discord'), '') : E('em', {}, st.errors))
				: yesNo(false, '', _('No webhook URL set'))),
			row(_('Sending (!sms)'), st.outbound
				? yesNo(true, _('Enabled in channel %s').format(st.channel_id), '')
				: yesNo(false, '', st.bot_set ? _('Bot token set; channel or allowed users missing') : _('Off'))),
			row(_('Authenticator (!otp)'), st.otp_names
				? E([], [ yesNo(st.outbound, st.otp_names.split(' ').join(', '), _('Needs the bot (Sending tab)')),
					st.clock_ok ? '' : [ ' ', yesNo(false, '', _('Router clock not synced')) ],
					st.otp_errors ? [ ' ', E('em', {}, st.otp_errors) ] : '' ])
				: (st.otp_errors ? E('em', {}, st.otp_errors) : yesNo(false, '', _('No accounts')))),
			row(_('Forwarded SMS'), st.initialised ? String(st.seen) : _('Not started yet (existing inbox is skipped on first start)')),
			row(_('Watching'), E('code', {}, st.watching || _('smstools3 config not found')))
		];
	},

	runAction: function(args, okMsg) {
		return fs.exec(BIN, args).then(function(res) {
			var out = (res.stdout || '') + (res.stderr || '');
			ui.addNotification(null, E('p', {}, [ res.code == 0 ? okMsg : _('Failed: '), E('pre', {}, out.trim()) ]),
				res.code == 0 ? 'info' : 'warning');
			return res;
		}).catch(function(e) {
			ui.addNotification(null, E('p', {}, _('Error: %s').format(e.message)), 'danger');
		});
	},

	render: function(data) {
		var self = this;
		var m, s, o, oToken;

		var statusTable = E('table', { 'class': 'table' }, this.renderStatusRows(data[1]));
		var logBox = E('pre', { 'style': 'max-height:20em;overflow:auto;white-space:pre-wrap' }, data[2] || _('No log entries yet.'));

		var statusSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Status')),
			statusTable,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, function() {
					return this.runAction([ 'test' ], _('Test message sent. Check your Discord channel.'));
				}) }, _('Send test message')),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, function() {
					return fs.exec('/etc/init.d/sms2discord', [ 'restart' ]).then(function() {
						ui.addNotification(null, E('p', {}, _('Service restarted.')), 'info');
					});
				}) }, _('Restart service'))
			]),
			E('h4', {}, _('Recent log')),
			logBox
		]);

		poll.add(function() {
			return Promise.all([ getStatus(), getLog() ]).then(function(r) {
				dom.content(statusTable, self.renderStatusRows(r[0]));
				dom.content(logBox, r[1] || _('No log entries yet.'));
			});
		}, 5);

		m = new form.Map('sms2discord', _('SMS to Discord'),
			_('Forwards every new SMS received by smstools3 to a Discord channel, sends SMS from <code>!sms +15555550100 text</code> messages in that channel, and answers <code>!otp NAME</code> with an authenticator code. Existing SMS are never forwarded and the inbox is never changed.') +
			' <a href="https://github.com/koraysels/sms2discord" target="_blank" rel="noreferrer">' + _('Documentation') + '</a>');

		s = m.section(form.NamedSection, 'main', 'sms2discord');
		s.tab('general', _('Receiving'));
		s.tab('bot', _('Sending (!sms)'));
		s.tab('advanced', _('Advanced'));

		o = s.taboption('general', form.Flag, 'enabled', _('Enabled'));
		o.rmempty = false;
		o.default = '1';

		o = s.taboption('general', form.Value, 'webhook_url', _('Discord webhook URL'),
			_('In Discord: channel → <em>Edit Channel</em> → <em>Integrations</em> → <em>Webhooks</em> → <em>New Webhook</em> → <em>Copy Webhook URL</em>. Use a private channel: everyone in it can read your OTP codes.'));
		o.password = true;
		o.placeholder = 'https://discord.com/api/webhooks/…';
		o.validate = function(section_id, value) {
			return (!value || WEBHOOK_RE.test(value)) ? true : _('Must be a Discord webhook URL');
		};

		o = s.taboption('bot', form.DummyValue, '_bot_help', _('Setup'));
		o.rawhtml = true;
		o.default = '<ol style="margin:0;padding-left:1.2em">' +
			'<li>' + _('<a href="https://discord.com/developers/applications" target="_blank" rel="noreferrer">Developer Portal</a> → New Application → <em>Bot</em>: enable <strong>Message Content Intent</strong>, turn off <em>Public Bot</em> (set <em>Installation → Install Link</em> to None first), <em>Reset Token</em>.') + '</li>' +
			'<li>' + _('Invite: <code>https://discord.com/oauth2/authorize?client_id=APPLICATION_ID&amp;scope=bot&amp;permissions=68672</code> and add the bot to the private channel.') + '</li>' +
			'<li>' + _('Paste the token below and click <em>Connect bot</em>.') + '</li>' +
			'<li>' + _('<em>Save &amp; Apply</em>, then <em>Detect</em> to fill in the channel and your user ID.') + '</li></ol>';

		oToken = o = s.taboption('bot', form.Value, 'bot_token', _('Bot token'), _('Leave empty to only receive.'));
		o.password = true;
		o.validate = function(section_id, value) {
			return (!value || /^[\w.-]+$/.test(value)) ? true : _('Unexpected characters in token');
		};

		o = s.taboption('bot', form.Button, '_gateway', _('One-time Gateway login'),
			_('Discord only lets a bot post after it logged in to the Gateway once. This runs from your browser.'));
		o.inputtitle = _('Connect bot');
		o.inputstyle = 'action';
		o.onclick = function(ev, section_id) {
			var token = oToken.formvalue(section_id);
			if (!token)
				return ui.addNotification(null, E('p', {}, _('Enter the bot token first.')), 'warning');
			return gatewayLogin(token).then(function(user) {
				ui.addNotification(null, E('p', {}, _('Gateway login OK as %s. Now Save & Apply, then Detect.').format(user.username)), 'info');
			}).catch(function(e) {
				ui.addNotification(null, E('p', {}, _('Gateway login failed: %s').format(e.message)), 'danger');
			});
		};

		o = s.taboption('bot', form.Value, 'channel_id', _('Channel ID'), _('Channel the bot reads <code>!sms</code> commands from. Empty = the webhook\'s channel.'));
		o.datatype = 'uinteger';

		o = s.taboption('bot', form.DynamicList, 'allowed_user', _('Allowed Discord user IDs'), _('Only these users may use <code>!sms</code> and <code>!otp</code>. Empty = the bot\'s owner.'));
		o.datatype = 'uinteger';

		o = s.taboption('bot', form.Button, '_detect', _('Detect channel and owner'),
			_('Uses the saved settings: takes the channel from the webhook and your user ID from the bot\'s owner, then checks that the bot can read the channel.'));
		o.inputtitle = _('Detect');
		o.inputstyle = 'action';
		o.onclick = function() {
			return fs.exec(BIN, [ 'detect' ]).then(function(res) {
				var r = {};
				try { r = JSON.parse(res.stdout); } catch (e) {}
				var msg;
				if (r.bot_read_http == 200)
					msg = _('Bot can read channel %s. Sending is enabled.').format(r.channel_id);
				else if (r.bot_read_http == 403)
					msg = _('HTTP 403: add the bot to the channel (View Channel, Read Message History).');
				else if (r.bot_read_http == 401)
					msg = _('HTTP 401: wrong bot token.');
				else
					msg = _('Could not enable sending: %s').format((res.stdout || res.stderr || '').trim());
				stashNotice(msg, r.bot_read_http == 200 ? 'info' : 'warning');
				return fs.exec('/etc/init.d/sms2discord', [ 'restart' ]);
			}).then(function() {
				location.reload(); // show the detected IDs in the form
			});
		};

		o = s.taboption('advanced', form.Value, 'poll_sms', _('Inbox check interval'), _('Seconds'));
		o.datatype = 'range(1,60)';
		o.placeholder = '2';

		o = s.taboption('advanced', form.Value, 'poll_discord', _('Discord check interval'), _('Seconds'));
		o.datatype = 'range(2,300)';
		o.placeholder = '4';

		o = s.taboption('advanced', form.Value, 'out_max_per_hour', _('Max outgoing SMS per hour'));
		o.datatype = 'range(0,1000)';
		o.placeholder = '10';

		s = m.section(form.GridSection, 'otp', _('Authenticator (!otp)'),
			_('For shared accounts that allow only one authenticator app. An allowed user types <code>!otp NAME</code> in the channel and the bot replies with the current code, then deletes that reply once the code has expired. Everyone in the channel can see the code, so only add accounts every member may use.') + '<br>' +
			_('To add an account, set up the authenticator in that service and choose <em>can\'t scan the QR code?</em> (or decode the QR code) to get the secret key or the <code>otpauth://</code> link. If an authenticator app already has it, you usually have to turn 2FA off and on again to see the secret.'));
		s.anonymous = true;
		s.addremove = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add account');

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.rmempty = false;
		o.editable = true;

		o = s.option(form.Value, 'name', _('Name'), _('Used in <code>!otp NAME</code>, e.g. <code>meta</code>.'));
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return OTP_NAME_RE.test(value || '') ? true : _('Letters, digits, . _ - (max 32)');
		};

		o = s.option(form.Value, 'secret', _('Secret key or otpauth:// link'),
			_('Base32 secret (e.g. <code>JBSW Y3DP EHPK 3PXP</code>) or the full <code>otpauth://totp/…</code> link. SHA1 codes only, which is what nearly every service uses.'));
		o.password = true;
		o.modalonly = true;
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return OTP_SECRET_RE.test((value || '').trim()) ? true : _('Not a base32 secret or otpauth://totp link');
		};

		return m.render().then(function(mapEl) {
			// LuCI replaces the page content after render(); notify once it's in place
			window.setTimeout(showStashedNotice, 0);
			return E([], [ statusSection, mapEl ]);
		});
	}
});
