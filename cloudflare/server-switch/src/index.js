/**
 * VidKwaii - Server Switch (Cloudflare Worker, free plan)
 *
 * A password-protected control panel that changes the backend address the app
 * reads at startup. The GitHub token lives here as a Worker secret, so it is
 * never stored in a browser.
 *
 * Secrets required:
 *   ADMIN_PASSWORD  - the password you type to open the panel
 *   GITHUB_TOKEN    - fine-grained PAT with Contents: Read and write
 */

const REPO = 'Champsg/vidkwaii';
const BRANCH = 'main';
const CONFIG_PATH = 'config.json';
const RAW_URL = 'https://raw.githubusercontent.com/' + REPO + '/' + BRANCH + '/' + CONFIG_PATH;
const API_URL = 'https://api.github.com/repos/' + REPO + '/contents/' + CONFIG_PATH;
const SESSION_COOKIE = 'vk_session';
const SESSION_TTL = 60 * 60 * 24 * 7;
const HEALTH_TIMEOUT_MS = 8000;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: baseHeaders() });

    if (path === '/') {
      const ok = await validSession(request, env);
      return html(ok ? panelPage() : loginPage());
    }

    if (path === '/api/login' && request.method === 'POST') {
      const body = await safeJson(request);
      const password = String((body && body.password) || '');
      if (!env.ADMIN_PASSWORD) return json({ error: 'ADMIN_PASSWORD secret is not set' }, 500);
      const a = await fingerprint(env, password);
      const b = await fingerprint(env, env.ADMIN_PASSWORD);
      if (!timingSafeEqual(a, b)) {
        await sleep(500);
        return json({ error: 'wrong password' }, 401);
      }
      const session = await makeSession(env);
      return json({ ok: true }, 200, {
        'Set-Cookie': SESSION_COOKIE + '=' + session + '; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=' + SESSION_TTL,
      });
    }

    if (path === '/api/logout' && request.method === 'POST') {
      return json({ ok: true }, 200, { 'Set-Cookie': SESSION_COOKIE + '=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0' });
    }

    // Everything below requires a valid session.
    if (!(await validSession(request, env))) return json({ error: 'not signed in' }, 401);

    if (path === '/api/state') {
      try {
        const config = await readConfig();
        return json({ repo: REPO, branch: BRANCH, config });
      } catch (err) {
        return json({ error: String(err.message || err) }, 502);
      }
    }

    if (path === '/api/health') {
      const target = url.searchParams.get('url') || '';
      if (!isHttpUrl(target)) return json({ error: 'invalid url' }, 400);
      return json({ result: await checkHealth(target) });
    }

    if (path === '/api/switch' && request.method === 'POST') {
      const body = await safeJson(request);
      const target = String((body && body.url) || '').trim().replace(/\/+$/, '');
      const force = Boolean(body && body.force);
      if (!isHttpUrl(target)) return json({ error: 'url must start with http:// or https://' }, 400);

      const health = await checkHealth(target);
      if (!health.ok && !force) {
        return json({ error: 'server did not answer /health', health }, 409);
      }
      if (!env.GITHUB_TOKEN) return json({ error: 'GITHUB_TOKEN secret is not set' }, 500);

      try {
        const updated = await writeConfig(env, target);
        return json({ ok: true, config: updated, health });
      } catch (err) {
        return json({ error: String(err.message || err) }, 502);
      }
    }

    return json({ error: 'not found' }, 404);
  },
};

/* ---------------------------------------------------------------- helpers */

function baseHeaders() {
  return {
    'Cache-Control': 'no-store',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
  };
}

function html(body, status) {
  return new Response(body, {
    status: status || 200,
    headers: {
      ...baseHeaders(),
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Security-Policy': "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'",
    },
  });
}

function json(data, status, extraHeaders) {
  return new Response(JSON.stringify(data, null, 2), {
    status: status || 200,
    headers: { ...baseHeaders(), 'Content-Type': 'application/json; charset=utf-8', ...(extraHeaders || {}) },
  });
}

async function safeJson(request) {
  try { return await request.json(); } catch (e) { return null; }
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

function isHttpUrl(value) {
  try {
    const u = new URL(String(value));
    return (u.protocol === 'http:' || u.protocol === 'https:') && !!u.hostname;
  } catch (e) { return false; }
}

async function fingerprint(env, text) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode('vidkwaii-panel'), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(String(text)));
  return b64url(new Uint8Array(sig));
}

function b64url(bytes) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function makeSession(env) {
  const exp = Math.floor(Date.now() / 1000) + SESSION_TTL;
  const sig = await fingerprint(env, 'vk:' + exp + ':' + env.ADMIN_PASSWORD);
  return exp + '.' + sig;
}

async function validSession(request, env) {
  if (!env.ADMIN_PASSWORD) return false;
  const cookie = request.headers.get('Cookie') || '';
  const match = cookie.match(new RegExp(SESSION_COOKIE + '=([^;]+)'));
  if (!match) return false;
  const parts = match[1].split('.');
  if (parts.length !== 2) return false;
  const exp = parseInt(parts[0], 10);
  if (!exp || exp < Math.floor(Date.now() / 1000)) return false;
  const expected = await fingerprint(env, 'vk:' + exp + ':' + env.ADMIN_PASSWORD);
  return timingSafeEqual(parts[1], expected);
}

function encodeBase64Utf8(text) {
    const bytes = new TextEncoder().encode(text);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function decodeBase64Utf8(b64) {
    const binary = atob(String(b64).replace(/\n/g, ''));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return new TextDecoder().decode(bytes);
}

async function readConfig() {
  const res = await fetch(RAW_URL + '?t=' + Date.now(), { headers: { 'cache-control': 'no-cache' } });
  if (!res.ok) throw new Error('config read failed (HTTP ' + res.status + ')');
  return await res.json();
}

async function writeConfig(env, baseUrl) {
  const headers = {
    Authorization: 'Bearer ' + env.GITHUB_TOKEN,
    Accept: 'application/vnd.github+json',
    'User-Agent': 'vidkwaii-server-switch',
  };
  const current = await fetch(API_URL + '?ref=' + BRANCH, { headers });
  if (!current.ok) throw new Error('GitHub read failed (HTTP ' + current.status + ')');
  const meta = await current.json();
  let existing = {};
  try { existing = JSON.parse(decodeBase64Utf8(meta.content)); } catch (e) { existing = {}; }

  const updated = {
    api_base_url: baseUrl,
    _comment: existing._comment || 'Live backend address for VidKwaii. Managed from the Server Switch panel.',
    updated: new Date().toISOString().slice(0, 10),
  };

  const put = await fetch(API_URL, {
    method: 'PUT',
    headers: { ...headers, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      message: 'Switch backend to ' + baseUrl,
      content: encodeBase64Utf8(JSON.stringify(updated, null, 2) + '\n'),
      sha: meta.sha,
      branch: BRANCH,
    }),
  });
  if (!put.ok) throw new Error('GitHub write failed (HTTP ' + put.status + ') ' + (await put.text()).slice(0, 160));
  return updated;
}

async function checkHealth(target) {
  const started = Date.now();
  const base = String(target).replace(/\/+$/, '');
  try {
    const res = await fetch(base + '/health', { signal: AbortSignal.timeout(HEALTH_TIMEOUT_MS), headers: { 'cache-control': 'no-cache' } });
    const latencyMs = Date.now() - started;
    let data = null;
    try {
      const text = await res.clone().text();
      try { data = JSON.parse(text); } catch (e) { data = text.slice(0, 200); }
    } catch (e) { data = null; }
    return { ok: res.ok, status: res.status, latencyMs, data };
  } catch (err) {
    return { ok: false, status: 0, latencyMs: Date.now() - started, error: String((err && err.message) || err) };
  }
}

/* ------------------------------------------------------------------- pages */

function loginPage() {
  return `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>VidKwaii - Server Switch</title>
<style>
 body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#06060f;color:#f5f0ff;font:15px/1.5 -apple-system,"Segoe UI",Roboto,sans-serif}
 .card{width:320px;background:#0d0d1a;border:1px solid #2a2a4a;border-radius:16px;padding:24px}
 h1{font-size:18px;margin:0 0 4px} p{color:#9d8fbf;font-size:13px;margin:0 0 18px}
 input{width:100%;box-sizing:border-box;padding:11px 12px;border-radius:10px;background:#161628;border:1px solid #2a2a4a;color:#f5f0ff;font:inherit}
 button{width:100%;margin-top:12px;padding:11px;border:none;border-radius:10px;font:inherit;font-weight:700;color:#fff;background:linear-gradient(120deg,#ff7eb3,#c084fc);cursor:pointer}
 #msg{color:#fb7185;font-size:13px;margin-top:10px;min-height:18px}
</style></head>
<body><div class="card">
 <h1>VidKwaii Server Switch</h1>
 <p>Sign in to change the backend address.</p>
 <form id="f"><input id="pw" type="password" placeholder="Password" autocomplete="current-password"><button type="submit">Sign in</button></form>
 <div id="msg"></div>
</div>
<script>
 document.getElementById('f').addEventListener('submit', async (e) => {
   e.preventDefault();
   const msg = document.getElementById('msg');
   msg.textContent = '';
   const res = await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password: document.getElementById('pw').value }) });
   if (res.ok) { location.href = '/'; return; }
   const data = await res.json().catch(() => ({}));
   msg.textContent = data.error || 'Sign in failed';
 });
</script>
</body></html>`;
}

function panelPage() {
  return `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>VidKwaii - Server Switch</title>
<style>
 :root{--bg:#06060f;--surface:#0d0d1a;--surface2:#161628;--border:#2a2a4a;--text:#f5f0ff;--muted:#9d8fbf;--accent:#ff7eb3;--primary:#c084fc;--ok:#4ade80;--bad:#fb7185;--warn:#fbbf24}
 *{box-sizing:border-box}
 body{margin:0;padding:24px 16px 60px;background:var(--bg);color:var(--text);font:15px/1.5 -apple-system,"Segoe UI",Roboto,sans-serif}
 .wrap{max-width:820px;margin:0 auto}
 h1{font-size:21px;margin:0 0 4px} h1 span{background:linear-gradient(120deg,var(--accent),var(--primary));-webkit-background-clip:text;background-clip:text;color:transparent}
 .sub{color:var(--muted);font-size:13px;margin:0 0 20px}
 .card{background:var(--surface);border:1px solid var(--border);border-radius:16px;padding:18px;margin-bottom:14px}
 .card h2{font-size:12px;text-transform:uppercase;letter-spacing:.9px;color:var(--muted);margin:0 0 12px}
 .live{font-size:18px;font-weight:700;word-break:break-all}
 .live small{display:block;font-weight:400;font-size:12px;color:var(--muted);margin-top:6px}
 table{width:100%;border-collapse:collapse} td{padding:10px 8px;border-top:1px solid var(--border);vertical-align:middle} tr:first-child td{border-top:none}
 .url{font-family:ui-monospace,Consolas,monospace;font-size:13px;word-break:break-all}
 .tag{font-size:11px;padding:2px 7px;border-radius:6px;background:var(--surface2);color:var(--muted);margin-left:6px}
 .tag.active{color:#06060f;background:var(--ok);font-weight:700}
 button{font:inherit;font-size:13px;font-weight:600;padding:8px 12px;border-radius:10px;border:1px solid var(--border);background:var(--surface2);color:var(--text);cursor:pointer}
 button:hover{border-color:var(--primary)} button.primary{background:linear-gradient(120deg,var(--accent),var(--primary));color:#fff;border:none}
 button.tiny{padding:5px 9px;font-size:12px} input{font:inherit;font-size:14px;padding:10px 12px;border-radius:10px;color:var(--text);background:var(--surface2);border:1px solid var(--border);width:100%}
 .row{display:flex;gap:8px;align-items:center;flex-wrap:wrap} .row>input{flex:1 1 200px}
 .hint{color:var(--muted);font-size:12px;margin:10px 0 0}
 .status{font-size:12px;color:var(--muted)} .status.ok{color:var(--ok)} .status.bad{color:var(--bad)} .status.warn{color:var(--warn)}
 #log div{font-family:ui-monospace,Consolas,monospace;font-size:12px;padding:7px 10px;border-radius:8px;background:var(--surface);border:1px solid var(--border);margin-top:8px;color:var(--muted)}
 #log div.ok{color:var(--ok);border-color:rgba(74,222,128,.35)} #log div.bad{color:var(--bad);border-color:rgba(251,113,133,.35)}
</style></head>
<body><div class="wrap">
 <h1>VidKwaii <span>Server Switch</span></h1>
 <p class="sub">Changes the backend address the app reads at startup. Takes effect within ~5 minutes. Apps verify a new server answers before switching, so a bad address cannot lock users out.</p>

 <div class="card">
  <h2>Live config</h2>
  <div class="live" id="live">Loading...</div>
  <div class="row" style="margin-top:14px">
   <button id="reload">Reload</button>
   <button id="logout">Sign out</button>
  </div>
 </div>

 <div class="card">
  <h2>Servers</h2>
  <table id="servers"></table>
  <div class="row" style="margin-top:14px">
   <input id="newLabel" placeholder="Label (e.g. Lightsail)">
   <input id="newUrl" placeholder="http://1.2.3.4">
   <button id="add">Add</button>
  </div>
  <p class="hint">Test checks /health through this panel, so http:// servers work too.</p>
 </div>

 <div id="log"></div>
</div>
<script>
const LS_SERVERS = 'vk_servers_remote';
let liveConfig = null;

function log(message, kind) {
  const el = document.createElement('div');
  if (kind) el.className = kind;
  el.textContent = new Date().toLocaleTimeString() + '  ' + message;
  const box = document.getElementById('log');
  box.prepend(el);
  while (box.children.length > 12) box.removeChild(box.lastChild);
}

function getServers() {
  try {
    const parsed = JSON.parse(localStorage.getItem(LS_SERVERS) || '[]');
    if (Array.isArray(parsed) && parsed.length) return parsed;
  } catch (e) {}
  return liveConfig && liveConfig.api_base_url ? [{ label: 'Current', url: liveConfig.api_base_url }] : [];
}

function saveServers(list) { localStorage.setItem(LS_SERVERS, JSON.stringify(list)); }

function explainFailure(result) {
  if (result.status === 404 && String(result.data || '').indexOf('1042') !== -1) return 'Cloudflare blocks a Worker from calling another Worker on the same workers.dev domain (error 1042). Test the origin server instead';
  if (result.status === 404) return '404 - no /health at that address. Use the API base URL only, with no path and no /config.json';
  if (result.status === 401) return '401 - that address is the switch panel itself, not the API';
  if (result.status === 403) return '403 - Cloudflare refuses to fetch a bare IP address. Use a hostname';
  if (!result.status) return 'no connection: ' + (result.error || 'unreachable');
  return 'HTTP ' + result.status;
}

function trimSlash(value) {
  let s = String(value);
  while (s.length > 0 && s.charAt(s.length - 1) === '/') s = s.slice(0, -1);
  return s;
}

async function api(path, options) {
  const res = await fetch(path, Object.assign({ signal: AbortSignal.timeout(15000) }, options || {})).catch((err) => {
    throw new Error('network error: ' + (err && err.message ? err.message : err));
  });
  if (res.status === 401) { location.href = '/'; throw new Error('session expired'); }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || ('HTTP ' + res.status));
  return data;
}

async function loadLive() {
  document.getElementById('live').textContent = 'Loading...';
  try {
    const data = await api('/api/state');
    liveConfig = data.config;
    document.getElementById('live').innerHTML = (liveConfig.api_base_url || 'missing api_base_url') +
      '<small>' + data.repo + ' @ ' + data.branch + ' - updated ' + (liveConfig.updated || 'unknown') + '</small>';
    log('Live address: ' + liveConfig.api_base_url, 'ok');
    render();
  } catch (err) {
    document.getElementById('live').textContent = 'Could not load config';
    log('Load failed: ' + (err && err.message ? err.message : String(err)), 'bad');
  }
}

function render() {
  const list = getServers();
  const active = liveConfig && liveConfig.api_base_url ? trimSlash(liveConfig.api_base_url) : '';
  const table = document.getElementById('servers');
  table.innerHTML = '';
  if (!list.length) { table.innerHTML = '<tr><td class="status">No servers yet - add one below.</td></tr>'; return; }
  list.forEach((server, index) => {
    const clean = trimSlash(server.url);
    const isActive = clean === active;
    const tr = document.createElement('tr');
    tr.innerHTML = '<td><div class="url">' + clean + '</div><div class="status">' + (server.label || 'Server') +
      (isActive ? '<span class="tag active">LIVE</span>' : '') + '</div></td><td id="s' + index + '" class="status" style="width:140px"></td>';
    const cell = document.createElement('td');
    cell.style.textAlign = 'right';
    cell.style.whiteSpace = 'nowrap';
    const testBtn = document.createElement('button');
    testBtn.className = 'tiny'; testBtn.textContent = 'Test';
    testBtn.onclick = () => testServer(clean, index);
    const switchBtn = document.createElement('button');
    switchBtn.className = 'tiny primary'; switchBtn.textContent = 'Switch';
    switchBtn.style.marginLeft = '6px'; switchBtn.disabled = isActive;
    switchBtn.onclick = () => switchTo(clean);
    const delBtn = document.createElement('button');
    delBtn.className = 'tiny'; delBtn.textContent = 'x'; delBtn.style.marginLeft = '6px';
    delBtn.onclick = () => { saveServers(getServers().filter((_, i) => i !== index)); render(); };
    cell.appendChild(testBtn); cell.appendChild(switchBtn); cell.appendChild(delBtn);
    tr.appendChild(cell);
    table.appendChild(tr);
  });
}

async function testServer(url, index) {
  const cell = document.getElementById('s' + index);
  cell.className = 'status warn'; cell.textContent = 'testing...';
  try {
    const data = await api('/api/health?url=' + encodeURIComponent(url));
    const r = data.result;
    if (r.ok) {
      const info = r.data || {};
      cell.className = 'status ok'; cell.textContent = 'online ' + r.latencyMs + 'ms';
      log(url + ' - ' + (info.service || 'ok') + ' v' + (info.version || '?') + ', redis ' + (info.redis ? 'ok' : 'off') + ', ffmpeg ' + (info.ffmpeg ? 'ok' : 'off'), 'ok');
    } else {
      const reason = explainFailure(r);
      cell.className = 'status bad'; cell.textContent = r.status === 404 ? '404' : 'no answer';
      log(url + ' - ' + reason, 'bad');
    }
  } catch (err) {
    cell.className = 'status bad'; cell.textContent = 'error';
    log('Test failed: ' + err.message, 'bad');
  }
}

async function switchTo(url) {
  try {
    log('Switching to ' + url + ' ...');
    let data;
    try {
      data = await api('/api/switch', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ url: url }) });
    } catch (err) {
      if (String(err.message).indexOf('did not answer') === -1) throw err;
      if (!confirm('That server did not answer /health. Switch anyway?')) { log('Switch cancelled.', 'bad'); return; }
      data = await api('/api/switch', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ url: url, force: true }) });
    }
    log('Switched to ' + data.config.api_base_url + '. Apps pick it up within ~5 minutes.', 'ok');
    setTimeout(loadLive, 1500);
  } catch (err) {
    log('Switch failed: ' + err.message, 'bad');
  }
}

document.getElementById('reload').onclick = loadLive;
document.getElementById('logout').onclick = async () => { await fetch('/api/logout', { method: 'POST' }); location.href = '/'; };
document.getElementById('add').onclick = () => {
  const label = document.getElementById('newLabel').value.trim();
  const url = trimSlash(document.getElementById('newUrl').value.trim());
  if (!(url.startsWith('http://') || url.startsWith('https://'))) { log('URL must start with http:// or https://', 'bad'); return; }
  const list = getServers();
  if (list.some((s) => trimSlash(s.url) === url)) { log('Already in the list.', 'bad'); return; }
  list.push({ label: label || url, url: url });
  saveServers(list);
  document.getElementById('newLabel').value = '';
  document.getElementById('newUrl').value = '';
  render();
  log('Added ' + url, 'ok');
};

setTimeout(function () {
  const el = document.getElementById('live');
  if (el && el.textContent.trim().indexOf('Loading') === 0) {
    el.textContent = 'No response from the panel API';
    log('No answer from /api/state after 10s. Open the browser console and check the Worker logs.', 'bad');
  }
}, 10000);

try {
  loadLive();
} catch (err) {
  log('Startup error: ' + (err && err.message ? err.message : String(err)), 'bad');
}
</script>
</body></html>`;
}