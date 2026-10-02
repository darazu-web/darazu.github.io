"""サーバーのテスト:  python -m unittest discover -s tests"""
import json
import os
import shutil
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import server  # noqa: E402

CSRF = {'X-Insp-Request': '1'}


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.httpd, self.store = server.make_server('127.0.0.1', 0, self.tmp)
        server.cmd_adduser(self.store, 'admin', 'correct-horse')
        self.base = 'http://127.0.0.1:%d' % self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.cookie = None

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        shutil.rmtree(self.tmp)

    def req(self, method, path, body=None, headers=None, cookie=True):
        h = dict(headers or {})
        if body is not None:
            h['Content-Type'] = 'application/json'
        if cookie and self.cookie:
            h['Cookie'] = self.cookie
        r = urllib.request.Request(self.base + path, method=method, headers=h,
                                   data=json.dumps(body).encode() if body is not None else None)
        try:
            with urllib.request.urlopen(r) as res:
                return res.status, res.headers, res.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read()

    def login(self, password='correct-horse'):
        st, h, _ = self.req('POST', '/api/login', {'username': 'admin', 'password': password}, CSRF)
        if st == 200:
            self.cookie = h['Set-Cookie'].split(';')[0]
        return st, h

    def current(self):
        st, h, raw = self.req('GET', '/data.json')
        self.assertEqual(st, 200)
        return json.loads(raw), h['ETag']

    def test_viewer_files_and_data_are_public(self):
        for p in ('/', '/admin.html', '/viewer.js', '/app.css'):
            st, h, _ = self.req('GET', p)
            self.assertEqual(st, 200, p)
            self.assertIn('nosniff', h['X-Content-Type-Options'])
        data, _ = self.current()
        self.assertTrue(data['products'])

    def test_path_traversal_blocked(self):
        for p in ('/../server.py', '/%2e%2e/server.py', '/..%2fdata/users.json', '/data/users.json'):
            st, _, _ = self.req('GET', p)
            self.assertEqual(st, 404, p)

    def test_login_wrong_password_and_lockout(self):
        st, _ = self.login('wrong')
        self.assertEqual(st, 401)
        for _ in range(server.LOGIN_MAX_FAILS - 1):
            self.login('wrong')
        st, _ = self.login()  # 正しくてもロック中
        self.assertEqual(st, 429)

    def test_login_requires_csrf_header(self):
        st, _, _ = self.req('POST', '/api/login', {'username': 'admin', 'password': 'correct-horse'})
        self.assertEqual(st, 403)

    def test_cookie_flags(self):
        st, h = self.login()
        self.assertEqual(st, 200)
        c = h['Set-Cookie']
        self.assertIn('HttpOnly', c)
        self.assertIn('SameSite=Strict', c)

    def test_save_requires_login(self):
        data, tag = self.current()
        st, _, _ = self.req('PUT', '/api/data', {'data': data}, dict(CSRF, **{'If-Match': tag}))
        self.assertEqual(st, 401)

    def test_save_requires_csrf_header(self):
        self.login()
        data, tag = self.current()
        st, _, _ = self.req('PUT', '/api/data', {'data': data}, {'If-Match': tag})
        self.assertEqual(st, 403)

    def test_save_conflict_history_and_restore(self):
        self.login()
        data, tag = self.current()
        original_name = data['products'][0]['name']
        data['products'][0]['name'] = '変更後の製品名'
        st, h, raw = self.req('PUT', '/api/data', {'data': data, 'message': 'テスト保存'}, dict(CSRF, **{'If-Match': tag}))
        self.assertEqual(st, 200, raw)
        new_tag = json.loads(raw)['etag']
        saved, cur_tag = self.current()
        self.assertEqual(saved['products'][0]['name'], '変更後の製品名')
        self.assertEqual(saved['updatedBy'], 'admin')
        self.assertEqual(cur_tag, new_tag)

        # 古い ETag での保存は 409
        st, _, _ = self.req('PUT', '/api/data', {'data': data}, dict(CSRF, **{'If-Match': tag}))
        self.assertEqual(st, 409)

        st, _, raw = self.req('GET', '/api/history')
        hist = json.loads(raw)['history']
        self.assertEqual([h['message'] for h in hist], ['テスト保存', '最初のデータ'])
        st, _, raw = self.req('GET', '/api/history/' + hist[-1]['id'])
        self.assertEqual(json.loads(raw)['products'][0]['name'], original_name)

    def test_history_requires_login_and_validates_id(self):
        st, _, _ = self.req('GET', '/api/history')
        self.assertEqual(st, 401)
        self.login()
        st, _, _ = self.req('GET', '/api/history/..%2F..%2Fusers')
        self.assertEqual(st, 404)

    def test_invalid_payload_rejected(self):
        self.login()
        _, tag = self.current()
        st, _, _ = self.req('PUT', '/api/data', {'data': {'products': 'x'}}, dict(CSRF, **{'If-Match': tag}))
        self.assertEqual(st, 400)

    def test_logout_and_deleted_user(self):
        self.login()
        st, _, _ = self.req('GET', '/api/me')
        self.assertEqual(st, 200)
        server.cmd_deluser(self.store, 'admin')
        st, _, _ = self.req('GET', '/api/me')
        self.assertEqual(st, 401)

    def test_password_hash_roundtrip(self):
        h = server.hash_password('abc12345')
        self.assertTrue(server.verify_password('abc12345', h))
        self.assertFalse(server.verify_password('abc12346', h))
        self.assertNotIn('abc12345', open(self.store.users_path, encoding='utf-8').read())


if __name__ == '__main__':
    unittest.main()
