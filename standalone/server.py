#!/usr/bin/env python3
"""検査情報アプリ（スタンドアロン版）サーバー

Python 3.8 以上の標準ライブラリだけで動く。社内 PC やサーバーで起動し、
同じネットワークのパソコン・タブレット・スマホのブラウザから使う。

    python server.py adduser 管理者名     # 管理者を追加（パスワードを入力）
    python server.py                      # サーバー起動（http://<このPC>:8080/）

閲覧はログイン不要。データの変更はログインした管理者だけが行える。
"""
import argparse
import getpass
import hashlib
import hmac
import http.server
import json
import mimetypes
import os
import re
import secrets
import shutil
import socketserver
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from http import HTTPStatus
from http.cookies import SimpleCookie
from urllib.parse import urlparse, unquote

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.path.join(BASE_DIR, 'static')
SAMPLE_DATA = os.path.join(BASE_DIR, 'sample-data.json')

SESSION_COOKIE = 'insp_session'
SESSION_TTL = 8 * 60 * 60            # ログインの有効時間（秒）
MAX_BODY = 5 * 1024 * 1024           # 保存できるデータの上限
HISTORY_KEEP = 200                   # 残す履歴の数
PBKDF2_ITERATIONS = 310_000
LOGIN_MAX_FAILS = 5                  # この回数失敗すると
LOGIN_LOCK_SECONDS = 60              # この秒数ログインを受け付けない
CSRF_HEADER = 'X-Insp-Request'       # 変更系 API で必須（他サイトからの送信を防ぐ）

mimetypes.add_type('application/javascript', '.js')
mimetypes.add_type('text/css', '.css')


# ---------------------------------------------------------------------------- 保存先

class Store:
    """data/ フォルダー内のファイルを扱う。書き込みは 1 つずつ行う。"""

    def __init__(self, data_dir):
        self.dir = os.path.abspath(data_dir)
        self.data_path = os.path.join(self.dir, 'data.json')
        self.users_path = os.path.join(self.dir, 'users.json')
        self.history_dir = os.path.join(self.dir, 'history')
        self.log_path = os.path.join(self.dir, 'audit.log')
        self.lock = threading.Lock()
        os.makedirs(self.history_dir, exist_ok=True)
        if not os.path.exists(self.data_path):
            if os.path.exists(SAMPLE_DATA):
                shutil.copyfile(SAMPLE_DATA, self.data_path)
            else:
                self._write_atomic(self.data_path, json.dumps({'version': 1, 'products': []}, ensure_ascii=False))

    # --- 共通
    @staticmethod
    def _write_atomic(path, text):
        d = os.path.dirname(path)
        fd, tmp = tempfile.mkstemp(dir=d, prefix='.tmp-')
        try:
            with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as f:
                f.write(text)
            os.replace(tmp, path)
        except BaseException:
            if os.path.exists(tmp):
                os.remove(tmp)
            raise

    def log(self, user, action, detail=''):
        line = f'{datetime.now().isoformat(timespec="seconds")}\t{user}\t{action}\t{detail}\n'
        with self.lock, open(self.log_path, 'a', encoding='utf-8') as f:
            f.write(line)

    # --- データ
    def read_data(self):
        with open(self.data_path, 'rb') as f:
            raw = f.read()
        return raw, etag_of(raw)

    def write_data(self, payload, user, message, if_match):
        """if_match が現在の ETag と違えば None（他の管理者が先に保存した）"""
        with self.lock:
            with open(self.data_path, 'rb') as f:
                current = f.read()
            if if_match != etag_of(current):
                return None
            now = datetime.now(timezone.utc)
            payload['updatedAt'] = now.isoformat().replace('+00:00', 'Z')
            payload['updatedBy'] = user
            text = json.dumps(payload, ensure_ascii=False, indent=2) + '\n'
            # 履歴：初回は保存前のデータも残し、以降は保存した版を 1 つずつ残す
            if not self.history_ids():
                self._write_atomic(os.path.join(self.history_dir, '00000000T000000Z.json'), current.decode('utf-8'))
                self._write_atomic(os.path.join(self.history_dir, '00000000T000000Z.meta.json'),
                                   json.dumps({'savedAt': '', 'user': '', 'message': '最初のデータ'}, ensure_ascii=False))
            stamp = now.strftime('%Y%m%dT%H%M%S%fZ')
            hist = {'savedAt': payload['updatedAt'], 'user': user, 'message': message}
            self._write_atomic(os.path.join(self.history_dir, f'{stamp}.json'), text)
            self._write_atomic(os.path.join(self.history_dir, f'{stamp}.meta.json'),
                               json.dumps(hist, ensure_ascii=False))
            self._write_atomic(self.data_path, text)
            self._prune_history()
            return etag_of(text.encode('utf-8'))

    def _prune_history(self):
        ids = self.history_ids()
        for old in ids[HISTORY_KEEP:]:
            for suffix in ('.json', '.meta.json'):
                p = os.path.join(self.history_dir, old + suffix)
                if os.path.exists(p):
                    os.remove(p)

    def history_ids(self):
        ids = [n[:-5] for n in os.listdir(self.history_dir)
               if n.endswith('.json') and not n.endswith('.meta.json')]
        return sorted(ids, reverse=True)

    def history_list(self):
        out = []
        for hid in self.history_ids():
            meta = {}
            try:
                with open(os.path.join(self.history_dir, hid + '.meta.json'), encoding='utf-8') as f:
                    meta = json.load(f)
            except (OSError, ValueError):
                pass
            out.append({'id': hid, 'savedAt': meta.get('savedAt', ''), 'user': meta.get('user', ''),
                        'message': meta.get('message', '')})
        return out

    def history_read(self, hid):
        if not re.fullmatch(r'[0-9TZ]+', hid or ''):
            return None
        p = os.path.join(self.history_dir, hid + '.json')
        if not os.path.exists(p):
            return None
        with open(p, 'rb') as f:
            return f.read()

    # --- 管理者
    def load_users(self):
        if not os.path.exists(self.users_path):
            return {}
        with open(self.users_path, encoding='utf-8') as f:
            return json.load(f)

    def save_users(self, users):
        with self.lock:
            self._write_atomic(self.users_path, json.dumps(users, ensure_ascii=False, indent=2) + '\n')


def etag_of(raw):
    return '"' + hashlib.sha256(raw).hexdigest()[:32] + '"'


def hash_password(password, salt=None, iterations=PBKDF2_ITERATIONS):
    salt = salt or secrets.token_hex(16)
    dk = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), bytes.fromhex(salt), iterations)
    return f'pbkdf2_sha256${iterations}${salt}${dk.hex()}'


def verify_password(password, stored):
    try:
        algo, iterations, salt, digest = stored.split('$')
        if algo != 'pbkdf2_sha256':
            return False
        return hmac.compare_digest(hash_password(password, salt, int(iterations)), stored)
    except (ValueError, AttributeError):
        return False


# 存在しないユーザーでも同じだけ時間をかける（ユーザー名の推測を防ぐ）
_DUMMY_HASH = hash_password(secrets.token_hex(8))


def validate_payload(obj):
    """保存されるデータの形を確認する。問題があればメッセージを返す。"""
    if not isinstance(obj, dict) or not isinstance(obj.get('products'), list):
        return 'products がありません'
    for p in obj['products']:
        if not isinstance(p, dict) or not isinstance(p.get('items', []), list):
            return '製品データの形式が正しくありません'
        for it in p.get('items', []):
            if not isinstance(it, dict) or not isinstance(it.get('equipment', {}), dict):
                return '検査項目データの形式が正しくありません'
    return None


# ---------------------------------------------------------------------------- セッション

class Sessions:
    def __init__(self):
        self._s = {}
        self._fails = {}
        self._lock = threading.Lock()

    def create(self, user):
        token = secrets.token_urlsafe(32)
        with self._lock:
            self._s[token] = (user, time.time() + SESSION_TTL)
        return token

    def get(self, token):
        if not token:
            return None
        with self._lock:
            v = self._s.get(token)
            if not v:
                return None
            if v[1] < time.time():
                del self._s[token]
                return None
            return v[0]

    def drop(self, token):
        with self._lock:
            self._s.pop(token, None)

    def drop_user(self, user):
        with self._lock:
            for t in [t for t, v in self._s.items() if v[0] == user]:
                del self._s[t]

    # --- ログイン失敗の制限（接続元ごと）
    def locked(self, ip):
        with self._lock:
            n, until = self._fails.get(ip, (0, 0))
            return until > time.time()

    def fail(self, ip):
        with self._lock:
            n, until = self._fails.get(ip, (0, 0))
            n += 1
            if n >= LOGIN_MAX_FAILS:
                self._fails[ip] = (0, time.time() + LOGIN_LOCK_SECONDS)
            else:
                self._fails[ip] = (n, until)

    def success(self, ip):
        with self._lock:
            self._fails.pop(ip, None)


# ---------------------------------------------------------------------------- HTTP

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = 'InspectionApp/1.0'
    store: Store = None
    sessions: Sessions = None
    secure_cookie = False

    # --- 共通
    def log_message(self, fmt, *args):
        sys.stderr.write('%s - %s\n' % (self.address_string(), fmt % args))

    def _headers_common(self):
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Frame-Options', 'SAMEORIGIN')
        self.send_header('Referrer-Policy', 'same-origin')
        self.send_header('Content-Security-Policy',
                         "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; "
                         "connect-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'self'")

    def send_json(self, status, obj, extra=None):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self._headers_common()
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def send_raw(self, status, body, ctype, extra=None):
        self.send_response(status)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self._headers_common()
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def error(self, status, message):
        self.send_json(status, {'error': message})

    def client_ip(self):
        return self.client_address[0]

    def session_token(self):
        c = SimpleCookie(self.headers.get('Cookie', ''))
        m = c.get(SESSION_COOKIE)
        return m.value if m else None

    def current_user(self):
        user = self.sessions.get(self.session_token())
        if user and user not in self.store.load_users():
            return None  # 削除された管理者
        return user

    def read_json_body(self):
        length = int(self.headers.get('Content-Length') or 0)
        if length > MAX_BODY:
            self.error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, 'データが大きすぎます')
            return None
        try:
            return json.loads(self.rfile.read(length).decode('utf-8') or 'null')
        except (UnicodeDecodeError, ValueError):
            self.error(HTTPStatus.BAD_REQUEST, 'JSON の形式が正しくありません')
            return None

    def require_admin(self, mutating=False):
        if mutating and self.headers.get(CSRF_HEADER) != '1':
            self.error(HTTPStatus.FORBIDDEN, '不正なリクエストです')
            return None
        user = self.current_user()
        if not user:
            self.error(HTTPStatus.UNAUTHORIZED, 'ログインが必要です')
            return None
        return user

    def cookie_header(self, value, max_age):
        parts = [f'{SESSION_COOKIE}={value}', 'Path=/', 'HttpOnly', 'SameSite=Strict', f'Max-Age={max_age}']
        if self.secure_cookie:
            parts.append('Secure')
        return '; '.join(parts)

    # --- ルーティング
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = urlparse(self.path).path
        if path == '/data.json':
            raw, tag = self.store.read_data()
            if self.headers.get('If-None-Match') == tag:
                self.send_response(HTTPStatus.NOT_MODIFIED)
                self.send_header('ETag', tag)
                self.end_headers()
                return
            return self.send_raw(HTTPStatus.OK, raw, 'application/json; charset=utf-8',
                                 {'ETag': tag, 'Cache-Control': 'no-cache'})
        if path == '/api/me':
            user = self.current_user()
            if not user:
                return self.error(HTTPStatus.UNAUTHORIZED, 'ログインが必要です')
            return self.send_json(HTTPStatus.OK, {'user': user})
        if path == '/api/history':
            if self.require_admin():
                return self.send_json(HTTPStatus.OK, {'history': self.store.history_list()})
            return
        m = re.fullmatch(r'/api/history/([^/]+)', path)
        if m:
            if not self.require_admin():
                return
            raw = self.store.history_read(m.group(1))
            if raw is None:
                return self.error(HTTPStatus.NOT_FOUND, '履歴が見つかりません')
            return self.send_raw(HTTPStatus.OK, raw, 'application/json; charset=utf-8', {'Cache-Control': 'no-store'})
        if path.startswith('/api/'):
            return self.error(HTTPStatus.NOT_FOUND, 'not found')
        return self.serve_static(path)

    def do_POST(self):
        path = urlparse(self.path).path
        if path == '/api/login':
            return self.login()
        if path == '/api/logout':
            if self.headers.get(CSRF_HEADER) != '1':
                return self.error(HTTPStatus.FORBIDDEN, '不正なリクエストです')
            self.sessions.drop(self.session_token())
            return self.send_json(HTTPStatus.OK, {'ok': True}, {'Set-Cookie': self.cookie_header('', 0)})
        return self.error(HTTPStatus.NOT_FOUND, 'not found')

    def do_PUT(self):
        path = urlparse(self.path).path
        if path != '/api/data':
            return self.error(HTTPStatus.NOT_FOUND, 'not found')
        user = self.require_admin(mutating=True)
        if not user:
            return
        body = self.read_json_body()
        if body is None:
            return
        if not isinstance(body, dict) or 'data' not in body:
            return self.error(HTTPStatus.BAD_REQUEST, 'data がありません')
        problem = validate_payload(body['data'])
        if problem:
            return self.error(HTTPStatus.BAD_REQUEST, problem)
        message = str(body.get('message') or '検査情報を更新')[:200]
        tag = self.store.write_data(body['data'], user, message, self.headers.get('If-Match'))
        if tag is None:
            return self.error(HTTPStatus.CONFLICT, '他の管理者が先に更新しました')
        self.store.log(user, 'save', message)
        return self.send_json(HTTPStatus.OK, {'ok': True, 'etag': tag, 'updatedAt': body['data']['updatedAt']},
                              {'ETag': tag})

    # --- ログイン
    def login(self):
        if self.headers.get(CSRF_HEADER) != '1':
            return self.error(HTTPStatus.FORBIDDEN, '不正なリクエストです')
        ip = self.client_ip()
        if self.sessions.locked(ip):
            return self.error(HTTPStatus.TOO_MANY_REQUESTS,
                              f'ログインの失敗が続いたため、{LOGIN_LOCK_SECONDS} 秒後にやり直してください')
        body = self.read_json_body()
        if body is None:
            return
        username = str((body or {}).get('username') or '').strip()
        password = str((body or {}).get('password') or '')
        stored = self.store.load_users().get(username, {}).get('password')
        ok = verify_password(password, stored or _DUMMY_HASH) and stored is not None
        if not ok:
            self.sessions.fail(ip)
            self.store.log(username or '-', 'login-failed', ip)
            return self.error(HTTPStatus.UNAUTHORIZED, 'ユーザー名またはパスワードが違います')
        self.sessions.success(ip)
        token = self.sessions.create(username)
        self.store.log(username, 'login', ip)
        return self.send_json(HTTPStatus.OK, {'user': username},
                              {'Set-Cookie': self.cookie_header(token, SESSION_TTL)})

    # --- 静的ファイル
    def serve_static(self, path):
        rel = unquote(path).lstrip('/') or 'index.html'
        full = os.path.realpath(os.path.join(STATIC_DIR, rel))
        if not full.startswith(os.path.realpath(STATIC_DIR) + os.sep) or not os.path.isfile(full):
            return self.error(HTTPStatus.NOT_FOUND, 'not found')
        ctype = mimetypes.guess_type(full)[0] or 'application/octet-stream'
        if ctype.startswith('text/') or ctype in ('application/javascript', 'application/json'):
            ctype += '; charset=utf-8'
        with open(full, 'rb') as f:
            body = f.read()
        return self.send_raw(HTTPStatus.OK, body, ctype, {'Cache-Control': 'no-cache'})


class ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def make_server(host, port, data_dir, secure_cookie=False):
    store = Store(data_dir)
    handler = type('BoundHandler', (Handler,), {
        'store': store, 'sessions': Sessions(), 'secure_cookie': secure_cookie,
    })
    return ThreadingServer((host, port), handler), store


# ---------------------------------------------------------------------------- コマンド

def ask_password():
    while True:
        pw = getpass.getpass('パスワード（8 文字以上）: ')
        if len(pw) < 8:
            print('8 文字以上にしてください。')
            continue
        if pw != getpass.getpass('もう一度入力: '):
            print('一致しません。')
            continue
        return pw


def cmd_adduser(store, name, password=None):
    users = store.load_users()
    if not re.fullmatch(r'[^\s:]{1,64}', name or ''):
        sys.exit('ユーザー名に空白や「:」は使えません（64 文字まで）。')
    existed = name in users
    users[name] = {'password': hash_password(password or ask_password()),
                   'createdAt': users.get(name, {}).get('createdAt') or datetime.now().isoformat(timespec='seconds')}
    store.save_users(users)
    store.log('-', 'passwd' if existed else 'adduser', name)
    print(('パスワードを変更しました: ' if existed else '管理者を追加しました: ') + name)


def cmd_deluser(store, name):
    users = store.load_users()
    if name not in users:
        sys.exit('その管理者は登録されていません: ' + name)
    del users[name]
    store.save_users(users)
    store.log('-', 'deluser', name)
    print('管理者を削除しました: ' + name)


def main(argv=None):
    ap = argparse.ArgumentParser(description='検査情報アプリ（スタンドアロン版）')
    ap.add_argument('--host', default='0.0.0.0', help='待ち受けるアドレス（既定: すべて）')
    ap.add_argument('--port', type=int, default=8080, help='ポート番号（既定: 8080）')
    ap.add_argument('--data-dir', default=os.path.join(BASE_DIR, 'data'), help='データの保存先フォルダー')
    ap.add_argument('--secure-cookie', action='store_true', help='HTTPS（リバースプロキシ経由）で使う場合に指定')
    sub = ap.add_subparsers(dest='cmd')
    sub.add_parser('serve', help='サーバーを起動する（既定）')
    p = sub.add_parser('adduser', help='管理者を追加する／パスワードを変更する')
    p.add_argument('name')
    p = sub.add_parser('passwd', help='管理者のパスワードを変更する')
    p.add_argument('name')
    p = sub.add_parser('deluser', help='管理者を削除する')
    p.add_argument('name')
    sub.add_parser('users', help='管理者の一覧')
    args = ap.parse_args(argv)

    if args.cmd in ('adduser', 'passwd', 'deluser', 'users'):
        store = Store(args.data_dir)
        if args.cmd == 'deluser':
            cmd_deluser(store, args.name)
        elif args.cmd == 'users':
            for n in sorted(store.load_users()):
                print(n)
        else:
            if args.cmd == 'passwd' and args.name not in store.load_users():
                sys.exit('その管理者は登録されていません: ' + args.name)
            cmd_adduser(store, args.name)
        return

    server, store = make_server(args.host, args.port, args.data_dir, args.secure_cookie)
    if not store.load_users():
        print('※ 管理者が登録されていません。編集するには次を実行してください:')
        print(f'   python {os.path.basename(__file__)} adduser <ユーザー名>')
    print(f'検査情報アプリを起動しました: http://localhost:{args.port}/  （データ: {store.dir}）')
    print('同じネットワークの端末からは http://<このPCのIPアドレス>:%d/ で開けます。Ctrl+C で終了します。' % args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n終了しました。')
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
