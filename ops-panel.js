// ops-panel.js - the STAFF "Ops" panel in the web app. See ops/panel.sh.
//
// Served by edge at /ops-panel.js and loaded by index.html BEFORE the app bundle
// (overlay.sh puts it there). Two jobs:
//   1. Keep the latest session token the app sends to its own /api/, by wrapping
//      XMLHttpRequest. The app deletes window.localStorage at start-up and sends its
//      REST calls through XHR with an Authorization header, so this is the place to see
//      it - and only if installed before the bundle runs.
//   2. Add "Ops…" to the STAFF (developer tools) menu, opening a panel that calls the
//      bridge at /ops-api/. The bridge checks STAFF itself; nothing here is a control.
// Plain ES2017, no build step. Every failure stays inside this file: the app must
// never notice it is here.
(function () {
	'use strict';
	if (window.__fluxerOpsPanel) return;
	window.__fluxerOpsPanel = true;

	// --- 1. the session token --------------------------------------------------------
	var token = null;
	var nativeFetch = window.fetch.bind(window);
	var xhrOpen = XMLHttpRequest.prototype.open;
	var xhrSetHeader = XMLHttpRequest.prototype.setRequestHeader;

	function isOwnApi(url) {
		try {
			var u = new URL(String(url), location.href);
			return u.origin === location.origin && u.pathname.indexOf('/api/') === 0;
		} catch (e) {
			return false;
		}
	}
	XMLHttpRequest.prototype.open = function (method, url) {
		try { this.__opsOwnApi = isOwnApi(url); } catch (e) { /* never break the app */ }
		return xhrOpen.apply(this, arguments);
	};
	XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
		try {
			if (this.__opsOwnApi && value && String(name).toLowerCase() === 'authorization') token = String(value);
		} catch (e) { /* never break the app */ }
		return xhrSetHeader.apply(this, arguments);
	};

	// --- the bridge ----------------------------------------------------------------
	function call(method, path, body) {
		if (!token) {
			return Promise.resolve({status: 0, data: {error: 'No session seen yet. Reload the page, let the app load, then try again.'}});
		}
		var init = {method: method, credentials: 'omit', cache: 'no-store', headers: {'Authorization': token}};
		if (body !== undefined) {
			init.headers['Content-Type'] = 'application/json';
			init.body = JSON.stringify(body);
		}
		return nativeFetch('/ops-api' + path, init).then(function (r) {
			return r.json().catch(function () {
				return {error: 'HTTP ' + r.status + ': the bridge did not answer. Is it running? (fluxer panel status)'};
			}).then(function (data) { return {status: r.status, data: data}; });
		}, function (e) {
			return {status: 0, data: {error: 'Bridge unreachable: ' + e.message}};
		});
	}

	// --- what the panel offers (mirrors ops_bridge.ACTIONS) --------------------------
	var USER = {key: 'user', label: 'User', placeholder: 'username or username#tag'};
	var CODE = {key: 'code', label: 'Code', placeholder: '32 letters and digits'};
	var TABS = [
		{label: 'Gifts', forms: [
			{action: 'gifts.create', title: 'Create gift links', button: 'Create', fields: [
				{key: 'duration', label: 'Duration', value: '1m', placeholder: '1w, 1m, 3m, 1y… or lifetime'},
				{key: 'count', label: 'How many', type: 'number', value: 1, min: 1, max: 50}]},
			{action: 'gifts.list', title: 'List codes', button: 'List', fields: [
				{key: 'filter', label: 'Which', type: 'select', options: ['all', 'unredeemed', 'redeemed', 'revoked']}]},
			{action: 'gifts.show', title: 'Show a code', button: 'Show', fields: [CODE]},
			{action: 'gifts.revoke', title: 'Revoke an unredeemed code', button: 'Revoke', confirm: true, fields: [CODE]},
			{action: 'gifts.rm', title: 'Delete a code', button: 'Delete', confirm: true, fields: [CODE]},
			{action: 'gifts.redeem', title: 'Redeem a code onto an account', button: 'Redeem', fields: [CODE, USER]}]},
		{label: 'Premium', forms: [
			{action: 'premium.grant', title: 'Grant Plutonium', button: 'Grant', fields: [USER,
				{key: 'kind', label: 'Kind', type: 'select', options: ['lifetime', 'duration', 'subscriber']},
				{key: 'duration', label: 'Duration (when kind is duration)', placeholder: '1w, 1m, 1y…'}],
				prepare: function (a) { if (a.kind !== 'duration') delete a.duration; return a; }},
			{action: 'premium.revoke', title: 'Revoke Plutonium', button: 'Revoke', confirm: true, fields: [USER]},
			{action: 'premium.list', title: 'Who has premium', button: 'List', fields: []}]},
		{label: 'Users', forms: [
			{action: 'users.list', title: 'Recent accounts', button: 'List', fields: [
				{key: 'recent', label: 'How many', type: 'number', value: 20, min: 1, max: 200}]},
			{action: 'users.show', title: 'Show an account', button: 'Show', fields: [USER]},
			{action: 'users.stats', title: 'Instance counts', button: 'Show', fields: []},
			{action: 'users.staff', title: 'Set or clear STAFF', button: 'Apply', fields: [USER,
				{key: 'off', label: 'Remove STAFF instead', type: 'checkbox'}],
				confirmIf: function (a) { return a.off === true; }},
			{action: 'users.verify-email', title: 'Mark the email verified', button: 'Verify', fields: [USER]}]},
		{label: 'Health', forms: [
			{action: 'health.status', title: 'Status at a glance', button: 'Run', fields: []},
			{action: 'health.check', title: 'Is it serving now (check)', button: 'Run', fields: []},
			{action: 'health.doctor', title: 'Drift and next-week risks (doctor)', button: 'Run', fields: []},
			{action: 'health.errors', title: 'Errors in the last hour', button: 'Run', fields: []},
			{action: 'health.disk', title: 'Disk', button: 'Run', fields: []},
			{action: 'health.backups', title: 'Backups', button: 'Run', fields: []}]}
	];
	var GIFT_LINK = /https:\/\/[^\s/]+\/gift\/[A-Za-z0-9]{32}/g;
	var JSON_OUTPUT = {'health.status': true, 'health.disk': true};

	var CSS = [
		':host{all:initial}',
		'.backdrop{position:fixed;inset:0;background:rgba(0,0,0,.55)}',
		'.box{position:fixed;top:5vh;left:50%;transform:translateX(-50%);width:min(900px,94vw);max-height:90vh;display:flex;flex-direction:column;background:#1e1f24;color:#e6e6e9;border:1px solid #33343b;border-radius:10px;font:14px/1.45 system-ui,sans-serif;box-shadow:0 12px 40px rgba(0,0,0,.5)}',
		'header{display:flex;align-items:center;gap:12px;padding:12px 16px;border-bottom:1px solid #33343b}',
		'h2{margin:0;font-size:16px}.who{color:#a0a1aa;font-size:12px;flex:1}',
		'button{font:inherit;background:#3c3f4a;color:#fff;border:0;border-radius:6px;padding:6px 12px;cursor:pointer}',
		'button:hover{background:#4a4e5c}button.primary{background:#5865f2}button.danger{background:#d83c3e}button:disabled{opacity:.6;cursor:wait}',
		'nav{display:flex;gap:4px;padding:8px 16px 0}nav button{background:transparent;color:#a0a1aa;border-radius:6px 6px 0 0}',
		'nav button[aria-selected="true"]{background:#2b2d35;color:#fff}',
		'.body{display:grid;grid-template-columns:minmax(260px,1fr) 1.4fr;gap:12px;padding:12px 16px 16px;overflow:hidden;min-height:0;flex:1;background:#2b2d35;border-radius:0 0 10px 10px}',
		'.forms,.out{overflow:auto;min-height:0}',
		'form{background:#1e1f24;border-radius:8px;padding:10px 12px;margin:0 0 8px}h3{margin:0 0 8px;font-size:13px}',
		'label{display:flex;flex-direction:column;gap:2px;font-size:12px;color:#a0a1aa;margin:0 0 6px}label.check{flex-direction:row;align-items:center;gap:6px}',
		'input,select{font:inherit;background:#111214;color:#e6e6e9;border:1px solid #3c3f4a;border-radius:5px;padding:5px 7px}',
		'.out{background:#111214;border-radius:8px;padding:10px 12px}',
		'pre{white-space:pre-wrap;word-break:break-word;font:12px/1.4 ui-monospace,Consolas,monospace;margin:6px 0 0}pre.stderr{color:#f0b232}',
		'.ok{color:#3ba55d;font-weight:600}.err{color:#ed4245;font-weight:600}.muted{color:#a0a1aa}',
		'.links,.choices{display:flex;flex-direction:column;gap:6px;margin:8px 0}.link{display:flex;gap:8px;align-items:center}',
		'.link code{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12px}',
		'@media (max-width:700px){.body{grid-template-columns:1fr}}'
	].join('\n');

	// --- small DOM helpers ---------------------------------------------------------
	function el(tag, attrs, children) {
		var n = document.createElement(tag);
		Object.keys(attrs || {}).forEach(function (k) {
			var v = attrs[k];
			if (v !== undefined && v !== null && v !== false) n.setAttribute(k, v === true ? '' : String(v));
		});
		(children || []).forEach(function (c) { n.appendChild(typeof c === 'string' ? document.createTextNode(c) : c); });
		return n;
	}
	// Two clicks for anything destructive: no native dialog, which would block the page.
	function arm(b) {
		b.__armed = true;
		b.__text = b.textContent;
		b.textContent = 'Click again to confirm';
		b.__timer = setTimeout(function () { disarm(b); }, 4000);
	}
	function disarm(b) {
		if (!b.__armed) return;
		clearTimeout(b.__timer);
		b.__armed = false;
		b.textContent = b.__text;
	}
	function flash(b, text) {
		var old = b.textContent;
		b.textContent = text;
		setTimeout(function () { b.textContent = old; }, 1200);
	}
	function copy(text, b) {
		navigator.clipboard.writeText(text).then(function () { flash(b, 'Copied'); }, function () { flash(b, 'Copy failed'); });
	}

	// --- the panel -----------------------------------------------------------------
	var host = null, who = null, forms = null, out = null, tabButtons = [];

	function isOpen() { return host !== null && host.style.display !== 'none'; }

	function build() {
		host = el('div', {'data-ops-panel': true});
		host.style.cssText = 'position:fixed;inset:0;z-index:2147483000;display:none';
		var root = host.attachShadow({mode: 'open'});
		root.appendChild(el('style', {}, [CSS]));
		var backdrop = el('div', {class: 'backdrop'});
		backdrop.addEventListener('click', closePanel);
		var close = el('button', {type: 'button', 'aria-label': 'Close'}, ['Close']);
		close.addEventListener('click', closePanel);
		who = el('span', {class: 'who'}, ['']);
		var nav = el('nav', {role: 'tablist'});
		tabButtons = TABS.map(function (t, i) {
			var b = el('button', {type: 'button', role: 'tab'}, [t.label]);
			b.addEventListener('click', function () { showTab(i); });
			nav.appendChild(b);
			return b;
		});
		forms = el('div', {class: 'forms'});
		out = el('div', {class: 'out'}, [el('div', {class: 'muted'}, ['Output appears here.'])]);
		root.appendChild(backdrop);
		root.appendChild(el('div', {class: 'box', role: 'dialog', 'aria-label': 'Ops'}, [
			el('header', {}, [el('h2', {}, ['Ops']), who, close]),
			nav,
			el('div', {class: 'body'}, [forms, out])
		]));
		document.body.appendChild(host);
		showTab(0);
	}

	function openPanel() {
		if (!host) build();
		host.style.display = 'block';
		refreshWho();
	}
	function closePanel() { if (host) host.style.display = 'none'; }

	function refreshWho() {
		who.textContent = '…';
		call('GET', '/whoami').then(function (res) {
			var d = res.data || {};
			if (res.status === 200 && !d.error) who.textContent = 'as ' + d.username + (d.staff ? '' : ' (not STAFF: the bridge will refuse)');
			else who.textContent = d.error || ('HTTP ' + res.status);
		});
	}

	function showTab(i) {
		tabButtons.forEach(function (b, j) { b.setAttribute('aria-selected', String(i === j)); });
		forms.textContent = '';
		TABS[i].forms.forEach(function (spec) { forms.appendChild(buildForm(spec)); });
	}

	function buildForm(spec) {
		var inputs = {};
		var form = el('form', {}, [el('h3', {}, [spec.title])]);
		spec.fields.forEach(function (f) {
			var input;
			if (f.type === 'select') {
				input = el('select', {}, f.options.map(function (o) { return el('option', {value: o}, [o]); }));
			} else if (f.type === 'checkbox') {
				input = el('input', {type: 'checkbox'});
			} else {
				input = el('input', {type: f.type === 'number' ? 'number' : 'text', placeholder: f.placeholder,
					min: f.min, max: f.max, value: f.value, autocomplete: 'off', spellcheck: 'false'});
			}
			inputs[f.key] = input;
			form.appendChild(el('label', {class: f.type === 'checkbox' ? 'check' : null},
				f.type === 'checkbox' ? [input, f.label] : [f.label, input]));
		});
		var button = el('button', {type: 'submit', class: spec.confirm ? 'danger' : 'primary'}, [spec.button]);
		form.appendChild(button);
		form.addEventListener('submit', function (e) {
			e.preventDefault();
			submit(spec, inputs, button);
		});
		return form;
	}

	function collect(spec, inputs) {
		var a = {};
		spec.fields.forEach(function (f) {
			var n = inputs[f.key];
			if (f.type === 'checkbox') a[f.key] = n.checked;
			else if (f.type === 'number') { if (n.value !== '') a[f.key] = Number(n.value); }
			else { var v = n.value.trim(); if (v !== '') a[f.key] = v; }
		});
		return spec.prepare ? spec.prepare(a) : a;
	}

	function submit(spec, inputs, button) {
		var args = collect(spec, inputs);
		var needsConfirm = spec.confirm || (spec.confirmIf && spec.confirmIf(args));
		if (needsConfirm && !button.__armed) { arm(button); return; }
		disarm(button);
		button.disabled = true;
		run(spec.action, args).then(function () { button.disabled = false; });
	}

	function run(action, args) {
		out.textContent = '';
		out.appendChild(el('div', {class: 'muted'}, ['Running ' + action + '…']));
		return call('POST', '/run', {action: action, args: args}).then(function (res) {
			render(action, args, res);
			return res;
		});
	}

	function render(action, args, res) {
		out.textContent = '';
		var d = res.data || {};
		if (res.status !== 200 || d.error) {
			out.appendChild(el('div', {class: 'err'}, [d.error || ('HTTP ' + res.status)]));
			return;
		}
		out.appendChild(el('div', {class: d.exit === 0 ? 'ok' : 'err'},
			[action + ': exit ' + d.exit + (d.timed_out ? ' (timed out)' : '')]));
		var links = (d.stdout || '').match(GIFT_LINK) || [];
		if (links.length) {
			var all = el('button', {type: 'button', class: 'primary'}, ['Copy all ' + links.length]);
			all.addEventListener('click', function () { copy(links.join('\n'), all); });
			var list = el('div', {class: 'links'}, [all]);
			links.forEach(function (link) {
				var b = el('button', {type: 'button'}, ['Copy']);
				b.addEventListener('click', function () { copy(link, b); });
				list.appendChild(el('div', {class: 'link'}, [el('code', {}, [link]), b]));
			});
			out.appendChild(list);
		}
		if (d.choices) renderChoices(args, d.choices);
		var stdout = d.stdout || '';
		if (JSON_OUTPUT[action]) {
			try { stdout = JSON.stringify(JSON.parse(stdout), null, 2); } catch (e) { /* show it raw */ }
		}
		if (stdout) out.appendChild(el('pre', {}, [stdout]));
		if (d.stderr) out.appendChild(el('pre', {class: 'stderr'}, [d.stderr]));
	}

	function renderChoices(args, choices) {
		var box = el('div', {class: 'choices'}, [el('div', {}, [
			'Lifetime links need one community to hold the Visionary role. Pick it: this creates the role there if it is missing, and restarts the gateway once.'])]);
		choices.forEach(function (c) {
			var b = el('button', {type: 'button', class: 'danger'}, [c.name + ' (' + c.id + ')']);
			b.addEventListener('click', function () {
				if (!b.__armed) { arm(b); return; }
				disarm(b);
				run('gifts.setup-lifetime', {community: c.id}).then(function (res) {
					if (res.status === 200 && res.data.exit === 0) run('gifts.create', args);
				});
			});
			box.appendChild(b);
		});
		out.appendChild(box);
	}

	// Keystrokes in the panel are the panel's. This capture listener is registered
	// before the bundle's, so it runs first: the app's global shortcuts and its
	// "typing anywhere goes to the composer" never see them. Typing still works, since
	// stopping propagation does not cancel the default action.
	['keydown', 'keyup', 'keypress'].forEach(function (type) {
		window.addEventListener(type, function (e) {
			try {
				if (!isOpen() || e.composedPath().indexOf(host) === -1) return;
				if (type === 'keydown' && e.key === 'Escape') closePanel();
				e.stopImmediatePropagation();
			} catch (err) { /* never break the app */ }
		}, true);
	});

	// --- 2. the menu item ------------------------------------------------------------
	// The STAFF menu is a [role=menu] holding icons whose data-flx starts with this.
	// Items themselves carry only generic data-flx values, so it is found by content.
	var MENU_MARK = '[data-flx^="channel.channel-header-components.developer-tools-context-menu."]';

	function addMenuItem(menu) {
		if (menu.querySelector('[data-ops-panel-item]')) return;
		var items = menu.querySelectorAll('[role="menuitem"]');
		if (!items.length) return;
		// A neutral item to copy: not the red "Clear all" one, not the greyed-out heading.
		var proto = null;
		for (var i = 0; i < items.length; i++) {
			if (/danger|disabled/i.test(items[i].className) || items[i].hasAttribute('aria-disabled')) continue;
			proto = items[i];
		}
		proto = proto || items[items.length - 1];
		var lastGroup = items[items.length - 1].parentElement;
		var group = lastGroup.cloneNode(false);
		group.removeAttribute('id');
		var item = proto.cloneNode(true);
		['id', 'aria-haspopup', 'aria-expanded', 'data-highlighted', 'aria-checked', 'data-checked', 'aria-disabled', 'data-disabled']
			.forEach(function (a) { item.removeAttribute(a); });
		Array.prototype.forEach.call(item.querySelectorAll('svg,[role="img"]'), function (n) { n.remove(); });
		var label = item.querySelector('[class*="itemLabelText"]') || item;
		label.textContent = 'Ops…';
		item.setAttribute('data-flx', 'ops-panel.menu-item');
		item.setAttribute('data-ops-panel-item', '');
		item.addEventListener('mouseenter', function () { item.setAttribute('data-highlighted', ''); });
		item.addEventListener('mouseleave', function () { item.removeAttribute('data-highlighted'); });
		item.addEventListener('click', function (e) {
			e.preventDefault();
			e.stopPropagation();
			menu.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}));
			openPanel();
		});
		group.appendChild(item);
		lastGroup.parentElement.appendChild(group);
	}

	var scheduled = false;
	function scan() {
		scheduled = false;
		try {
			var menus = document.querySelectorAll('[role="menu"]');
			for (var i = 0; i < menus.length; i++) if (menus[i].querySelector(MENU_MARK)) addMenuItem(menus[i]);
		} catch (e) { /* never break the app */ }
	}
	function start() {
		new MutationObserver(function () {
			if (!scheduled) {
				scheduled = true;
				requestAnimationFrame(scan);
			}
		}).observe(document.body, {childList: true, subtree: true});
	}
	if (document.body) start();
	else document.addEventListener('DOMContentLoaded', start);
})();
