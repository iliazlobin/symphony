import base64
import importlib.util
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('local_codex_auth', ROOT / 'tools/local_codex_auth.py')
AUTH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUTH)


def token(account='fixture-account', revision=1):
    claims = {'https://api.openai.com/auth': {
        'chatgpt_account_id': account, 'chatgpt_plan_type': 'fixture', 'revision': revision,
    }}
    payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip('=')
    return 'eyJhbGciOiJub25lIn0.' + payload + '.FAKE_SIGNATURE_ONLY'


class LocalCodexAuthTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.home, self.cwd = self.root / '.codex', self.root / 'auth-client'
        self.home.mkdir(mode=0o700)
        self.cwd.mkdir(mode=0o700)
        self.host = self.root / 'host-codex'
        self.host.write_text('#!/bin/sh\nexit 0\n')
        self.host.chmod(0o700)

    def client(self):
        with patch.object(Path, 'home', return_value=self.root):
            return AUTH.LocalCodexAuth(binary=self.host, home=self.home, cwd=self.cwd)

    def test_cached_bootstrap_then_same_account_refresh_without_model_rpc(self):
        client = self.client()
        values = [token(), token(revision=2)]
        with patch.object(client, '_rpc', side_effect=[{'authMethod': 'chatgpt', 'authToken': value} for value in values]) as rpc:
            first = client.cached_tokens()
            second = client.cached_tokens(refresh=True, previous_account_id='fixture-account')
        self.assertEqual(first['chatgptAccountId'], second['chatgptAccountId'])
        self.assertNotEqual(first['accessToken'], second['accessToken'])
        self.assertEqual([call.args[0] for call in rpc.call_args_list], ['getAuthStatus', 'getAuthStatus'])
        self.assertEqual([call.args[1]['refreshToken'] for call in rpc.call_args_list], [False, True])
        self.assertEqual(client.scrub({'message': ' '.join(values), values[0]: values[1], 'authToken': values[0]}),
                         {'message': '[redacted] [redacted]', '[redacted]': '[redacted]', 'authToken': None})

    def test_account_change_and_unbound_refresh_fail_before_returning_credentials(self):
        client = self.client()
        with patch.object(client, '_rpc', return_value={'authMethod': 'chatgpt', 'authToken': token()}) as rpc:
            with self.assertRaises(AUTH.LocalCodexAuthError):
                client.cached_tokens(refresh=True)
            rpc.assert_not_called()
            client.cached_tokens()
            rpc.reset_mock()
            with self.assertRaises(AUTH.LocalCodexAuthError):
                client.cached_tokens(refresh=True, previous_account_id='different-account')
            rpc.assert_not_called()
        with patch.object(client, '_rpc', return_value={'authMethod': 'chatgpt', 'authToken': token('different-account')}):
            with self.assertRaises(AUTH.LocalCodexAuthError) as error:
                client.cached_tokens(refresh=True)
            self.assertEqual(str(error.exception), AUTH.AUTH_ERROR)

    def test_missing_invalid_or_non_chatgpt_tokens_are_safe_failures(self):
        for status in ({}, {'authMethod': 'apikey', 'authToken': token()},
                       {'authMethod': 'chatgpt', 'authToken': 'PRIVATE_INVALID_CREDENTIAL'},
                       {'authMethod': 'chatgpt', 'authToken': token(account='')}):
            with self.subTest(status=status):
                client = self.client()
                with patch.object(client, '_rpc', return_value=status), self.assertRaises(AUTH.LocalCodexAuthError) as error:
                    client.cached_tokens()
                self.assertEqual(str(error.exception), AUTH.AUTH_ERROR)

    def test_host_client_rejects_model_and_tool_methods(self):
        client = self.client()
        for method in ('thread/start', 'turn/start', 'thread/shellCommand', 'command/exec'):
            with self.subTest(method=method), self.assertRaises(AUTH.LocalCodexAuthError):
                client._rpc(method, {}, time.monotonic() + 1)

    def test_missing_home_symlinks_and_untrusted_cwd_are_auth_recovery(self):
        with patch.object(Path, 'home', return_value=self.root):
            for home, cwd in ((self.root / 'missing', self.cwd), (self.home, self.home),
                              (self.home, self.root / 'missing'), (self.home, self.home / 'child')):
                with self.subTest(home=home, cwd=cwd), self.assertRaises(AUTH.LocalCodexAuthError):
                    AUTH.LocalCodexAuth(binary=self.host, home=home, cwd=cwd)
            self.cwd.chmod(0o755)
            with self.assertRaises(AUTH.LocalCodexAuthError):
                self.client()

    def test_refresh_requests_reject_unknown_reasons_and_account_scope(self):
        client = self.client()
        requests = [
            {'id': True, 'params': {'reason': 'unauthorized'}},
            {'id': 9, 'params': {'reason': 'other'}},
            {'id': 9, 'params': {'reason': 'unauthorized', 'unexpected': 'PRIVATE'}},
            {'params': {'reason': 'unauthorized'}},
        ]
        with patch.object(client, 'cached_tokens') as tokens:
            for request in requests:
                with self.subTest(request=request), self.assertRaises(AUTH.LocalCodexAuthError):
                    AUTH._refresh(None, request, client)
            tokens.assert_not_called()

    def test_binary_target_requires_owner_control_and_trusted_location(self):
        self.host.chmod(0o777)
        with self.assertRaises(AUTH.LocalCodexAuthError):
            self.client()
        self.host.chmod(0o700)
        link = self.root / 'codex-link'
        link.symlink_to(self.host)
        with patch.object(Path, 'home', return_value=self.root):
            client = AUTH.LocalCodexAuth(binary=link, home=self.home, cwd=self.cwd)
            self.assertEqual(client.binary, self.host)
            unsafe = self.cwd / 'codex'
            unsafe.write_text('#!/bin/sh\nexit 0\n')
            unsafe.chmod(0o700)
            with self.assertRaises(AUTH.LocalCodexAuthError):
                AUTH.LocalCodexAuth(binary=unsafe, home=self.home, cwd=self.cwd)

    def test_standard_owner_home_preserves_protected_credential_leaf(self):
        self.home.chmod(0o755)
        self.assertEqual(self.client().home, self.home)
        credential = self.home / 'auth.json'
        credential.write_text('FAKE_ONLY')
        credential.chmod(0o600)
        self.assertEqual(self.client().home, self.home)
        self.assertEqual(credential.read_text(), 'FAKE_ONLY')
        self.assertEqual(credential.stat().st_mode & 0o777, 0o600)
        credential.chmod(0o644)
        with self.assertRaises(AUTH.LocalCodexAuthError):
            self.client()

    def test_original_credential_leaf_rejects_links_and_nonregular_paths(self):
        credential = self.home / 'auth.json'
        credential.symlink_to(self.root / 'missing')
        with self.assertRaises(AUTH.LocalCodexAuthError):
            self.client()
        credential.unlink()
        credential.mkdir(mode=0o700)
        with self.assertRaises(AUTH.LocalCodexAuthError):
            self.client()
        credential.rmdir()
        original = self.root / 'fake-auth'
        original.write_text('FAKE_ONLY')
        original.chmod(0o600)
        os.link(original, credential)
        with self.assertRaises(AUTH.LocalCodexAuthError):
            self.client()
        credential.unlink()
        self.home.chmod(0o775)
        with self.assertRaises(AUTH.LocalCodexAuthError):
            self.client()

    def fixture(self, *, account_switch=False, status_leak=False):
        first = token()
        second = token('other-account' if account_switch else 'fixture-account', 2)
        history = self.root / 'host-methods.jsonl'
        self.host.write_text(textwrap.dedent(f'''\
            #!/usr/bin/python3
            import json,sys
            first={first!r}; second={second!r}
            for line in sys.stdin:
                message=json.loads(line)
                with open({str(history)!r},'a') as record:
                    record.write(json.dumps({{'method':message.get('method')}})+'\\n')
                if 'id' not in message: continue
                method=message['method']
                if method=='initialize': result={{'userAgent':'fixture'}}
                elif method=='getAuthStatus':
                    result={{'authMethod':'chatgpt','authToken':second if message['params']['refreshToken'] else first}}
                else: raise RuntimeError('Forbidden host RPC')
                print(json.dumps({{'id':message['id'],'result':result}}),flush=True)
        '''))
        self.host.chmod(0o700)
        worker = self.root / 'worker.py'
        worker.write_text(textwrap.dedent('''\
            import json,sys
            current=None; original=None; turn=None
            for line in sys.stdin:
                message=json.loads(line)
                method=message.get('method')
                if method=='initialize':
                    assert message['params']['capabilities']['experimentalApi'] is True
                    result={'userAgent':'isolated-worker'}
                elif method=='initialized': continue
                elif method=='account/login/start':
                    assert message['params']['type']=='chatgptAuthTokens'
                    current=message['params']['accessToken']; original=current
                    result={'type':'chatgptAuthTokens'}
                elif method=='getAuthStatus': result={'authMethod':'chatgptAuthTokens','authToken':STATUS_TOKEN}
                elif method=='account/read': result={'account':{'type':'chatgpt'},'requiresOpenaiAuth':True}
                elif method=='account/rateLimits/read':
                    assert message['params'] is None
                    result={'rateLimits':{'primary':{'usedPercent':0}},'rateLimitsByLimitId':{}}
                elif method=='turn/start':
                    turn=message['id']
                    print(json.dumps({'id':901,'method':'account/chatgptAuthTokens/refresh',
                          'params':{'reason':'unauthorized','previousAccountId':'fixture-account'}}),flush=True)
                    continue
                elif message.get('id')==901:
                    current=message['result']['accessToken']
                    print(json.dumps({'id':turn,'result':{'message':original+' '+current,
                          'accessToken':current}}),flush=True)
                    continue
                elif method=='echo': result={'message':current,'nested':{'refreshToken':current}}
                else: raise RuntimeError('Unexpected worker RPC')
                print(json.dumps({'id':message['id'],'result':result}),flush=True)
        ''').replace('STATUS_TOKEN', 'current' if status_leak else 'None'))
        driver = self.root / 'driver.py'
        driver.write_text(textwrap.dedent(f'''\
            import pathlib,sys
            sys.path.insert(0,{str(ROOT/'tools')!r})
            import local_codex_auth as auth
            pathlib.Path.home=classmethod(lambda cls:pathlib.Path({str(self.root)!r}))
            try:
                with auth.LocalCodexAuth(binary={str(self.host)!r},home={str(self.home)!r},cwd={str(self.cwd)!r}) as owner:
                    raise SystemExit(auth.bridge([sys.executable,{str(worker)!r}],{{}},owner))
            except auth.LocalCodexAuthError:
                print(auth.AUTH_ERROR,file=sys.stderr)
                raise SystemExit(78)
        '''))
        process = subprocess.Popen([sys.executable, str(driver)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: AUTH._stop(process))
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        self.addCleanup(selector.close)
        def exchange(message):
            process.stdin.write(json.dumps(message).encode() + b'\n')
            process.stdin.flush()
            if not selector.select(5):
                self.fail('Fixture relay response timed out')
            line = process.stdout.readline()
            return json.loads(line) if line else None
        return process, exchange, history, (first, second)

    def test_private_bootstrap_refresh_redaction_and_eof_cleanup_over_real_pipes(self):
        process, exchange, history, secrets = self.fixture()
        ready = exchange({'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'fixture'}}})
        self.assertEqual(ready, {'id': 1, 'result': {'userAgent': 'isolated-worker'}})
        status = exchange({'id': 2, 'method': 'getAuthStatus', 'params': {'includeToken': False}})
        self.assertEqual(status['result'], {'authMethod': 'chatgptAuthTokens', 'authToken': None})
        account = exchange({'id': 5, 'method': 'account/read', 'params': {'refreshToken': False}})
        limits = exchange({'id': 6, 'method': 'account/rateLimits/read', 'params': None})
        self.assertEqual(account['result']['account']['type'], 'chatgpt')
        self.assertIsInstance(limits['result']['rateLimits'], dict)
        echoed = exchange({'id': 3, 'method': 'echo', 'params': {}})
        refreshed = exchange({'id': 4, 'method': 'turn/start', 'params': {}})
        self.assertEqual(refreshed['result'], {'message': '[redacted] [redacted]', 'accessToken': None})
        process.stdin.close()
        self.assertEqual(process.wait(timeout=5), 0)
        output = json.dumps([ready, status, echoed, refreshed]) + process.stderr.read().decode()
        for secret in secrets:
            self.assertNotIn(secret, output)
        methods = [json.loads(line)['method'] for line in history.read_text().splitlines()]
        self.assertEqual(methods, ['initialize', 'initialized', 'getAuthStatus', 'getAuthStatus'])
        self.assertFalse((self.home / 'auth.json').exists())
        self.assertFalse(list(self.cwd.iterdir()))

    def test_mid_turn_account_change_stops_with_safe_auth_exit_and_no_token_output(self):
        process, exchange, _history, secrets = self.fixture(account_switch=True)
        exchange({'id': 1, 'method': 'initialize', 'params': {}})
        self.assertIsNone(exchange({'id': 2, 'method': 'turn/start', 'params': {}}))
        self.assertEqual(process.wait(timeout=5), 78)
        error = process.stderr.read().decode()
        self.assertEqual(error.strip(), AUTH.AUTH_ERROR)
        for secret in secrets:
            self.assertNotIn(secret, error)

    def test_auth_status_rejects_unexpected_token_before_redaction(self):
        process, exchange, _history, secrets = self.fixture(status_leak=True)
        exchange({'id': 1, 'method': 'initialize', 'params': {}})
        self.assertIsNone(exchange({'id': 2, 'method': 'getAuthStatus', 'params': {'includeToken': False}}))
        self.assertEqual(process.wait(timeout=5), 78)
        error = process.stderr.read().decode()
        self.assertEqual(error.strip(), AUTH.AUTH_ERROR)
        for secret in secrets:
            self.assertNotIn(secret, error)

    def test_controller_cannot_extract_tokens_or_change_login(self):
        for request in ({'id': 2, 'method': 'getAuthStatus', 'params': {'includeToken': True}},
                        {'id': 2, 'method': 'account/login/start', 'params': {}},
                        {'id': 2, 'method': 'account/logout', 'params': {}}):
            with self.subTest(request=request):
                process, exchange, _history, _secrets = self.fixture()
                exchange({'id': 1, 'method': 'initialize', 'params': {}})
                self.assertIsNone(exchange(request))
                self.assertEqual(process.wait(timeout=5), 78)
                self.assertEqual(process.stderr.read().decode().strip(), AUTH.AUTH_ERROR)


if __name__ == '__main__':
    unittest.main()
