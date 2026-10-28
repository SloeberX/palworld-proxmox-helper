#!/usr/bin/python3
import collections
import functools
import json
import os
import re
import secrets
import subprocess
import tempfile
import time
from pathlib import Path

from flask import Flask, abort, jsonify, make_response, redirect, request, send_file, session, url_for
from werkzeug.security import check_password_hash

CONFIG = Path('/opt/palworld/server/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini')
ADMIN_HASH = Path('/etc/palworld-web/admin.hash')
SESSION_KEY = Path('/etc/palworld-web/session.key')
BACKUP_PATTERN = re.compile(r'^palworld_[0-9]{8}_[0-9]{6}\.tar\.gz$')
app = Flask(__name__)
app.secret_key = SESSION_KEY.read_text().strip()
app.config.update(SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SECURE=True,
                  SESSION_COOKIE_SAMESITE='Strict', MAX_CONTENT_LENGTH=4 * 1024 * 1024 * 1024,
                  PERMANENT_SESSION_LIFETIME=3600)
LOGIN_ATTEMPTS = collections.defaultdict(collections.deque)

def ctl(*args, data=None, timeout=30):
    return subprocess.run(['/usr/bin/sudo', '-n', '/usr/local/sbin/palworld-webctl', *args],
                          input=data, text=True, capture_output=True, timeout=timeout, check=False)

def login_required(fn):
    @functools.wraps(fn)
    def wrapped(*args, **kwargs):
        if not session.get('authenticated'):
            if request.path.startswith('/api/'):
                return jsonify(error='Sign in required.'), 401
            return redirect(url_for('login'))
        return fn(*args, **kwargs)
    return wrapped

def require_csrf():
    supplied = request.headers.get('X-CSRF-Token') or request.form.get('csrf_token')
    if not supplied or not secrets.compare_digest(str(supplied), str(session.get('csrf', ''))):
        abort(403)

def config_settings():
    text = CONFIG.read_text(errors='replace')
    line = next((ln for ln in text.splitlines() if re.match(r'^\s*OptionSettings=\(', ln)), '')
    result = {}
    for key in ('ServerName','ServerDescription','ServerPlayerMaxNum','PublicPort','CrossplayPlatforms'):
        pat = r'(?<![A-Za-z0-9_])' + re.escape(key) + r'=("((?:\\.|[^"\\])*)"|\(([^)]*)\)|([^,)]*))'
        match = re.search(pat, line)
        if match:
            value = match.group(2) if match.group(2) is not None else (match.group(3) if match.group(3) is not None else match.group(4))
            result[key] = value.replace('\\"','"').replace('\\\\','\\')
        else:
            result[key] = ''
    return result

@app.after_request
def security_headers(response):
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-Frame-Options'] = 'DENY'
    response.headers['Referrer-Policy'] = 'no-referrer'
    response.headers['Content-Security-Policy'] = "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
    return response

@app.get('/login')
def login():
    if session.get('authenticated'):
        return redirect(url_for('home'))
    token = session.setdefault('csrf', secrets.token_urlsafe(32))
    return make_response(LOGIN_HTML.replace('{{csrf}}', token).replace('{{error}}',''))

@app.post('/login')
def login_post():
    require_csrf()
    peer = request.remote_addr or 'unknown'
    now = time.time()
    attempts = LOGIN_ATTEMPTS[peer]
    while attempts and now - attempts[0] > 300:
        attempts.popleft()
    if len(attempts) >= 8:
        return make_response(LOGIN_HTML.replace('{{csrf}}', session['csrf']).replace('{{error}}','Too many attempts. Wait five minutes.'), 429)
    try:
        valid = request.form.get('username','') == 'admin' and check_password_hash(ADMIN_HASH.read_text().strip(), request.form.get('password',''))
    except (OSError, ValueError):
        valid = False
    if not valid:
        attempts.append(now)
        return make_response(LOGIN_HTML.replace('{{csrf}}', session['csrf']).replace('{{error}}','Invalid password.'), 401)
    attempts.clear()
    session.clear()
    session['authenticated'] = True
    session['csrf'] = secrets.token_urlsafe(32)
    session.permanent = True
    return redirect(url_for('home'))

@app.post('/logout')
@login_required
def logout():
    require_csrf()
    session.clear()
    return redirect(url_for('login'))

@app.get('/')
@login_required
def home():
    return make_response(APP_HTML.replace('{{csrf}}', session['csrf']))

@app.get('/api/status')
@login_required
def status():
    result = ctl('status')
    if result.returncode:
        return jsonify(error=result.stderr[-1000:] or 'Could not read server status.'), 500
    return jsonify(result=json.loads(result.stdout))

@app.get('/api/settings')
@login_required
def settings():
    try:
        return jsonify(settings=config_settings())
    except OSError:
        return jsonify(error='Palworld settings file is not readable.'), 500

@app.post('/api/action')
@login_required
def action():
    require_csrf()
    name = (request.json or {}).get('action','')
    if name not in {'start','stop','restart','update','helper-update'}:
        return jsonify(error='Unsupported action.'), 400
    result = ctl(name, timeout=35)
    if result.returncode:
        return jsonify(error=result.stderr[-1000:] or 'Action failed.'), 500
    return jsonify(message=result.stdout.strip() or 'Action completed.')

@app.post('/api/settings')
@login_required
def save_settings():
    require_csrf()
    data = request.json or {}
    current = config_settings()
    name = str(data.get('ServerName', current['ServerName']))
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_. -]{0,63}', name):
        return jsonify(error='Server name: use 1-64 letters, numbers, spaces, dots, underscores, or hyphens.'), 400
    players = str(data.get('ServerPlayerMaxNum', current['ServerPlayerMaxNum']))
    if not players.isdigit() or not 1 <= int(players) <= 32:
        return jsonify(error='Player limit must be from 1 to 32.'), 400
    port = str(data.get('PublicPort', current['PublicPort']))
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        return jsonify(error='Game port must be from 1 to 65535.'), 400
    platforms = str(data.get('CrossplayPlatforms','Steam,Xbox,PS5,Mac'))
    allowed = {'Steam','Xbox','PS5','Mac'}
    platform_list = platforms.split(',')
    if not platform_list or any(item not in allowed for item in platform_list) or len(set(platform_list)) != len(platform_list):
        return jsonify(error='Crossplay must be a comma-separated selection of Steam, Xbox, PS5, and Mac.'), 400
    description = str(data.get('ServerDescription', current['ServerDescription']))
    if len(description) > 128 or any(ord(char) < 32 for char in description):
        return jsonify(error='Description must be 128 characters or fewer and contain no control characters.'), 400
    values = {'ServerName':name, 'ServerPlayerMaxNum':players, 'PublicPort':port,
              'CrossplayPlatforms':','.join(platform_list), 'ServerDescription':description}
    for key in ('ServerPassword','AdminPassword'):
        password = str(data.get(key,''))
        if password:
            if len(password) > 30 or not re.fullmatch(r'[A-Za-z0-9_-]+', password):
                return jsonify(error=f'{key} must use letters, numbers, underscores, or hyphens (max 30 characters).'), 400
            values[key] = password
    for key, value in values.items():
        result = ctl('save', key, data=value, timeout=40)
        if result.returncode:
            return jsonify(error=result.stderr[-1000:] or f'Could not save {key}.'), 500
    result = ctl('restart', timeout=40)
    if result.returncode:
        return jsonify(error=result.stderr[-1000:] or 'Settings saved, but the restart failed.'), 500
    return jsonify(message='Settings saved and Palworld restarted.')

@app.post('/api/password')
@login_required
def change_password():
    require_csrf()
    password = str((request.json or {}).get('password',''))
    if len(password) < 12 or len(password) > 256:
        return jsonify(error='Web login password must be 12-256 characters.'), 400
    result = ctl('set-web-password', data=password)
    if result.returncode:
        return jsonify(error=result.stderr[-1000:] or 'Could not change web password.'), 500
    return jsonify(message='Web login password changed.')

@app.get('/api/logs')
@login_required
def logs():
    result = ctl('logs')
    if result.returncode:
        return jsonify(error=result.stderr[-1000:] or 'Could not read server logs.'), 500
    return jsonify(logs=result.stdout[-24000:])

@app.post('/api/backups')
@login_required
def create_backup():
    require_csrf()
    result = ctl('backup', timeout=180)
    if result.returncode:
        return jsonify(error=result.stderr[-1000:] or 'Backup failed.'), 500
    return jsonify(message='Backup created. The server paused briefly to make the save consistent.', file=result.stdout.strip())

@app.post('/api/backups/import')
@login_required
def import_backup():
    require_csrf()
    uploaded = request.files.get('backup')
    if not uploaded or not uploaded.filename or not uploaded.filename.lower().endswith(('.tar.gz', '.tgz')):
        return jsonify(error='Choose a Palworld .tar.gz or .tgz backup archive.'), 400
    temp_path = None
    try:
        fd, temp_path = tempfile.mkstemp(prefix='import-', suffix='.tar.gz', dir='/var/lib/palworld-web/imports')
        with os.fdopen(fd, 'wb') as target:
            while True:
                block = uploaded.stream.read(1024 * 1024)
                if not block: break
                target.write(block)
        result = ctl('import-backup', temp_path, timeout=300)
        if result.returncode:
            return jsonify(error=result.stderr[-1000:] or 'Import failed.'), 400
        return jsonify(message=result.stdout.strip())
    except OSError:
        return jsonify(error='Could not stage the uploaded archive. Check free disk space.'), 500
    finally:
        if temp_path:
            try: os.unlink(temp_path)
            except FileNotFoundError: pass

@app.get('/api/backups')
@login_required
def list_backups():
    result = ctl('list-backups')
    backups=[]
    if not result.returncode:
        for line in result.stdout.splitlines():
            fields=line.split('\t')
            if len(fields)==2 and BACKUP_PATTERN.fullmatch(fields[0]):
                backups.append({'name':fields[0], 'bytes':int(fields[1])})
    return jsonify(backups=backups)

@app.get('/api/backups/<filename>')
@login_required
def download_backup(filename):
    if not BACKUP_PATTERN.fullmatch(filename): abort(404)
    result=ctl('backup-path',filename)
    if result.returncode: abort(404)
    return send_file(result.stdout.strip(), as_attachment=True, download_name=filename)

@app.post('/api/backups/<filename>/restore')
@login_required
def restore_backup(filename):
    require_csrf()
    if not BACKUP_PATTERN.fullmatch(filename): abort(404)
    if (request.json or {}).get('confirm') is not True:
        return jsonify(error='Confirm the restore before continuing.'), 400
    result = ctl('restore', filename, timeout=240)
    if result.returncode:
        return jsonify(error=result.stderr[-1000:] or 'Restore failed.'), 500
    return jsonify(message=result.stdout.strip())

@app.errorhandler(413)
def too_large(_):
    return jsonify(error='Request too large.'), 413

LOGIN_HTML = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Palworld Admin Login</title><style>body{background:#111827;color:#e5e7eb;font:16px system-ui;display:grid;place-items:center;min-height:100vh;margin:0}.card{background:#1f2937;padding:2rem;border-radius:14px;width:min(90vw,380px)}input,button{box-sizing:border-box;width:100%;padding:.8rem;margin:.45rem 0;border-radius:8px;border:1px solid #4b5563;background:#111827;color:#fff}button{background:#2563eb;border:0;font-weight:700;cursor:pointer}.err{color:#fca5a5}</style><div class="card"><h1>Palworld Server</h1><p>LAN management panel</p><p class="err">{{error}}</p><form method="post"><input type="hidden" name="csrf_token" value="{{csrf}}"><input name="username" autocomplete="username" placeholder="Username" value="admin" required autofocus><input type="password" name="password" autocomplete="current-password" placeholder="Web password" required><button>Sign in</button></form></div></html>'''

APP_HTML = '''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Palworld Server Manager</title><style>
:root{color-scheme:dark;--bg:#0b1220;--panel:#172235;--line:#2b3b52;--muted:#9fb0c5;--blue:#3b82f6;--fg:#e5edf7;--input:#0c1524;--secondary:#26374d}*{box-sizing:border-box}body{margin:0;background:linear-gradient(140deg,#101b2d,var(--bg));color:var(--fg);font:15px system-ui,sans-serif}.wrap{max-width:1120px;margin:auto;padding:24px}.top{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:16px;margin:18px 0}.card{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:18px;box-shadow:0 10px 28px #0002}.card h2{margin:0 0 12px;font-size:18px}.status{font-size:22px;font-weight:700}.muted{color:var(--muted)}label{display:block;margin:.75rem 0 .25rem;color:#cbd5e1}input,textarea,button{font:inherit;border-radius:8px;border:1px solid #40516a;background:var(--input);color:var(--fg);padding:.7rem;width:100%}textarea{min-height:70px}button{background:var(--blue);border-color:var(--blue);cursor:pointer;font-weight:650;margin:.25rem 0}.secondary{background:var(--secondary)!important;border-color:#40516a!important}.danger{background:#991b1b!important;border-color:#b91c1c!important}.buttons{display:grid;grid-template-columns:repeat(2,1fr);gap:8px}.toast{padding:10px;border-radius:8px;background:#123428;color:#bbf7d0;display:none;margin:12px 0}.toast.error{background:#3b171d;color:#fecaca}pre{white-space:pre-wrap;word-break:break-word;background:var(--input);border-radius:8px;padding:12px;max-height:390px;overflow:auto;color:#d1d5db}.backup{display:flex;justify-content:space-between;padding:8px;border-bottom:1px solid var(--line);gap:10px}.backup a{color:#93c5fd}.foot{padding:18px 0;color:var(--muted);font-size:12px}@media(max-width:600px){.wrap{padding:12px}}
.light{color-scheme:light;--bg:#edf2f7;--panel:#fff;--line:#cbd5e1;--muted:#526174;--fg:#172033;--input:#f8fafc;--secondary:#dbe4ef;background:linear-gradient(140deg,#fff,var(--bg))}.light .secondary{color:#172033!important}.light .backup a{color:#1d4ed8}</style></head><body><main class="wrap"><div class="top"><div><h1>Palworld Server</h1><div class="muted">LAN management panel | HTTPS</div></div><div style="display:flex;gap:8px"><button class="secondary" style="width:auto" id="theme-toggle" onclick="toggleTheme()">Light mode</button><form method="post" action="/logout"><input type="hidden" name="csrf_token" value="{{csrf}}"><button class="secondary">Sign out</button></form></div></div><div id="toast" class="toast"></div><section class="grid"><div class="card"><h2>Live status</h2><div id="state" class="status">Loading...</div><p>Public IPv4: <strong id="publicip">—</strong></p><p class="muted">Game UDP port <span id="portview">8211</span> · refreshes automatically</p><div class="buttons"><button onclick="action('start')">Start</button><button onclick="action('stop')" class="danger">Stop</button><button onclick="action('restart')" class="secondary">Restart</button><button onclick="action('update')">Update game + helper</button></div><button class="secondary" onclick="action('helper-update')">Update helper only</button></div><div class="card"><h2>Server settings</h2><form id="settings"><label>Server name</label><input name="ServerName" maxlength="64"><label>Description</label><textarea name="ServerDescription" maxlength="128"></textarea><label>Max players</label><input name="ServerPlayerMaxNum" type="number" min="1" max="32"><label>Game port (UDP)</label><input name="PublicPort" type="number" min="1" max="65535"><small>If changed, update your router's UDP forward too.</small><label>Crossplay platforms</label><input name="CrossplayPlatforms" placeholder="Steam,Xbox,PS5,Mac"><small>Comma-separated: Steam, Xbox, PS5, Mac</small><label>New server password (optional)</label><input name="ServerPassword" type="password" autocomplete="new-password"><label>New admin password (optional)</label><input name="AdminPassword" type="password" autocomplete="new-password"><small>Leave password fields blank to keep current values.</small><button>Save settings and restart</button></form></div><div class="card"><h2>Backups</h2><p class="muted">Creates a consistent save/config archive; the server pauses briefly. Restores create a safety backup first.</p><button onclick="backup()">Create backup now</button><label for="backup-file">Import an offsite backup</label><input id="backup-file" type="file" accept=".tar.gz,.tgz,application/gzip"><button class="secondary" onclick="importBackup()">Upload and restore backup</button><div id="backups"></div></div><div class="card"><h2>Web login</h2><label>Change web password (12+ characters)</label><input id="newwebpass" type="password" autocomplete="new-password"><button class="secondary" onclick="changePassword()">Change web password</button><p class="muted">LAN-only access. Do not forward TCP 8443 on your router.</p></div></section><section class="card"><div class="top"><h2>Recent server logs</h2><button class="secondary" style="width:auto" onclick="loadLogs()">Refresh logs</button></div><pre id="logs">Loading logs...</pre></section><div class="foot">No RCON or REST administration port is exposed.</div></main><script>
const csrf='{{csrf}}';function toggleTheme(){let light=document.body.classList.toggle('light');localStorage.setItem('palworld-theme',light?'light':'dark');document.getElementById('theme-toggle').textContent=light?'Dark mode':'Light mode'}if(localStorage.getItem('palworld-theme')==='light'){document.body.classList.add('light');document.getElementById('theme-toggle').textContent='Dark mode'}function toast(t,e=false){let x=document.getElementById('toast');x.textContent=t;x.className='toast'+(e?' error':'');x.style.display='block';setTimeout(()=>x.style.display='none',7000)}async function api(u,o={}){o.headers={...(o.headers||{}),'X-CSRF-Token':csrf};if(o.body&&typeof o.body!=='string'){o.headers['Content-Type']='application/json';o.body=JSON.stringify(o.body)}let r=await fetch(u,o);let d=await r.json();if(!r.ok)throw Error(d.error||'Request failed');return d}async function refresh(){try{let d=await api('/api/status'),s=d.result;let e=document.getElementById('state');e.textContent=s.status.toUpperCase();e.style.color=s.status==='active'?'#4ade80':'#fca5a5';document.getElementById('publicip').textContent=s.public_ip||'Detecting...';let manager=document.getElementById('managerurl');manager.textContent=s.local_ip?`${s.local_ip}:8443`:'Unavailable';manager.href=s.local_ip?`https://${s.local_ip}:${s.web_port||8443}`:'#';let x=await api('/api/settings');for(let k in x.settings){let f=document.querySelector(`[name="${k}"]`);if(f&&!f.value)f.value=x.settings[k]}document.getElementById('portview').textContent=x.settings.PublicPort;await listBackups()}catch(e){toast(e.message,true)}}async function action(a){if(a==='stop'&&!confirm('Stop the Palworld server?'))return;try{let r=await api('/api/action',{method:'POST',body:{action:a}});toast(r.message);setTimeout(refresh,1500)}catch(e){toast(e.message,true)}}document.getElementById('settings').addEventListener('submit',async e=>{e.preventDefault();try{let r=await api('/api/settings',{method:'POST',body:Object.fromEntries(new FormData(e.target))});toast(r.message);e.target.ServerPassword.value='';e.target.AdminPassword.value='';setTimeout(refresh,1500)}catch(e){toast(e.message,true)}});async function changePassword(){try{let r=await api('/api/password',{method:'POST',body:{password:document.getElementById('newwebpass').value}});toast(r.message);document.getElementById('newwebpass').value=''}catch(e){toast(e.message,true)}}async function loadLogs(){try{let r=await api('/api/logs');let p=document.getElementById('logs');p.textContent=r.logs;p.scrollTop=p.scrollHeight}catch(e){toast(e.message,true)}}async function backup(){try{let r=await api('/api/backups',{method:'POST',body:{}});toast(r.message+' '+r.file);await listBackups()}catch(e){toast(e.message,true)}}async function importBackup(){let f=document.getElementById('backup-file').files[0];if(!f){toast('Choose a backup archive first.',true);return}if(!confirm('Import this archive? Current world/config will be replaced after a safety backup is created.'))return;let form=new FormData();form.append('backup',f);try{let r=await fetch('/api/backups/import',{method:'POST',headers:{'X-CSRF-Token':csrf},body:form});let d=await r.json();if(!r.ok)throw Error(d.error||'Import failed');toast(d.message);document.getElementById('backup-file').value='';setTimeout(refresh,1500)}catch(e){toast(e.message,true)}}async function restoreBackup(name){if(!confirm(`Restore ${name}? This replaces the current world/config. A safety backup will be made first.`))return;try{let r=await api(`/api/backups/${encodeURIComponent(name)}/restore`,{method:'POST',body:{confirm:true}});toast(r.message);setTimeout(refresh,1500)}catch(e){toast(e.message,true)}}async function listBackups(){try{let r=await api('/api/backups');document.getElementById('backups').innerHTML=r.backups.map(b=>`<div class="backup"><span>${b.name} · ${(b.bytes/1048576).toFixed(1)} MiB</span><span><a href="/api/backups/${encodeURIComponent(b.name)}">Download</a> <button class="danger" style="width:auto" onclick="restoreBackup('${b.name}')">Restore</button></span></div>`).join('')||'<p class="muted">No backups yet.</p>'}catch(e){}}loadLogs();refresh();setInterval(refresh,15000);
</script></body></html>'''
