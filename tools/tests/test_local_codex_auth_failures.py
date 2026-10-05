"""Failure contracts for the private auth relay, using synthetic stdio peers.

Every peer lives in the production ProcessGroup guardian's owned process group.
No personal Codex directory, provider, Docker daemon or real token is accessed.
"""
import base64
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
AUTH_ERROR = "Local Codex sign-in needs recovery; no credentials were exposed"
REFRESH_METHOD = "account/chatgptAuthTokens/refresh"


def fixture_token():
    claims = {"https://api.openai.com/auth": {
        "chatgpt_account_id": "fixture-account", "chatgpt_plan_type": "fixture",
    }}
    encoded = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return "eyJhbGciOiJub25lIn0." + encoded + ".FAKE_SIGNATURE_ONLY"


def production_guardian():
    source = (ROOT / "elixir/lib/symphony_elixir/process_group.ex").read_text()
    match = re.search(r'@guardian ~S"""\n(.*?)\n  """', source, re.DOTALL)
    if match is None:
        raise AssertionError("Production ProcessGroup guardian was not found")
    return textwrap.dedent(match.group(1))


def stop_owned_process(process):
    """Close our guardian; its production finally block settles its child group."""
    if process is None:
        return
    try:
        if process.stdin is not None and not process.stdin.closed:
            process.stdin.close()
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=5)
    finally:
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None and not stream.closed:
                stream.close()


class PipeReader:
    def __init__(self, stream):
        self.stream = stream
        self.buffer = bytearray()
        self.eof = False
        self.selector = selectors.DefaultSelector()
        self.selector.register(stream, selectors.EVENT_READ)

    def close(self):
        self.selector.close()

    def next(self, timeout=5):
        deadline = time.monotonic() + timeout
        while True:
            if b"\n" in self.buffer:
                line, _, remaining = self.buffer.partition(b"\n")
                self.buffer[:] = remaining
                return json.loads(line)
            if self.eof:
                if self.buffer:
                    raise AssertionError("Relay output ended with an incomplete frame")
                return None
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise AssertionError("Fixture relay response timed out")
            data = os.read(self.stream.fileno(), 65536)
            if not data:
                self.eof = True
            else:
                self.buffer.extend(data)


class LocalCodexAuthFailureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.serial = 0

    def fixture(self, *, silent_refresh=False, callback=None):
        self.serial += 1
        directory = self.root / str(self.serial)
        directory.mkdir(mode=0o700)
        home = directory / ".codex"
        cwd = directory / "auth-client"
        home.mkdir(mode=0o700)
        cwd.mkdir(mode=0o700)
        history = directory / "host-methods.jsonl"
        host = directory / "host-codex"
        secret = fixture_token()
        callback = callback if callback is not None else {
            "id": 901, "method": REFRESH_METHOD,
            "params": {"reason": "unauthorized", "previousAccountId": "fixture-account"},
        }
        host.write_text(textwrap.dedent(f'''\
            #!{sys.executable}
            import json,os,sys,time
            with open({str(directory / 'host.pid')!r}, 'w') as record:
                record.write(str(os.getpid()))
            for line in sys.stdin:
                message=json.loads(line)
                method=message.get('method')
                params=message.get('params', {{}})
                with open({str(history)!r}, 'a') as record:
                    record.write(json.dumps({{'method':method,'refresh':params.get('refreshToken')}})+'\\n')
                if 'id' not in message: continue
                if method=='initialize': result={{'userAgent':'auth-only-fixture'}}
                elif method=='getAuthStatus':
                    if params.get('refreshToken') and {silent_refresh!r}: time.sleep(30)
                    result={{'authMethod':'chatgpt','authToken':{secret!r}}}
                else: raise SystemExit('Forbidden host RPC')
                print(json.dumps({{'id':message['id'],'result':result}}),flush=True)
        '''))
        host.chmod(0o700)
        worker = directory / "worker.py"
        worker.write_text(textwrap.dedent(f'''\
            import json,os,sys,time
            with open({str(directory / 'worker.pid')!r}, 'w') as record:
                record.write(str(os.getpid()))
            current=None
            for line in sys.stdin:
                message=json.loads(line)
                method=message.get('method')
                if method=='initialize':
                    assert message['params']['capabilities']['experimentalApi'] is True
                    result={{'userAgent':'isolated-worker-fixture'}}
                elif method=='initialized': continue
                elif method=='account/login/start':
                    assert message['params']['type']=='chatgptAuthTokens'
                    current=message['params']['accessToken']
                    result={{'type':'chatgptAuthTokens'}}
                elif method=='fixture/refresh':
                    print({json.dumps(callback)!r},flush=True)
                    continue
                elif method=='fixture/finish':
                    for index in range(160):
                        print(json.dumps({{'method':'fixture/progress','params':{{
                            'index':index,'text':'x'*512+' '+current}}}}),flush=True)
                    print(json.dumps({{'id':message['id'],'result':{{'text':'final frame'}}}}),flush=True)
                    raise SystemExit(23)
                elif method=='fixture/running':
                    print(json.dumps({{'id':message['id'],'result':{{'running':True}}}}),flush=True)
                    time.sleep(30)
                    continue
                else: raise SystemExit('Unexpected worker RPC')
                print(json.dumps({{'id':message['id'],'result':result}}),flush=True)
        '''))
        driver = directory / "driver.py"
        driver.write_text(textwrap.dedent(f'''\
            import os,pathlib,sys
            sys.path.insert(0,{str(ROOT / 'tools')!r})
            import local_codex_auth as auth
            pathlib.Path.home=classmethod(lambda cls:pathlib.Path({str(directory)!r}))
            with open({str(directory / 'driver.pid')!r}, 'w') as record:
                record.write(str(os.getpid()))
            try:
                with auth.LocalCodexAuth(binary={str(host)!r},home={str(home)!r},cwd={str(cwd)!r}) as owner:
                    raise SystemExit(auth.bridge([sys.executable,'-B',{str(worker)!r}],{{}},owner))
            except auth.LocalCodexAuthError:
                print(auth.AUTH_ERROR,file=sys.stderr)
                raise SystemExit(78)
        '''))
        command = [sys.executable, "-I", "-B", "-u", "-c", production_guardian(),
                   str(directory / "guard.lock"), sys.executable, "-I", "-B", str(driver)]
        return {"directory": directory, "home": home, "cwd": cwd, "history": history,
                "secret": secret, "command": command}

    def launch(self, fixture):
        process = subprocess.Popen(fixture["command"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(stop_owned_process, process)
        reader = PipeReader(process.stdout)
        self.addCleanup(reader.close)
        self.send(process, {"id": 1, "method": "initialize", "params": {}})
        self.assertEqual(reader.next(), {"id": 1, "result": {"userAgent": "isolated-worker-fixture"}})
        return process, reader

    @staticmethod
    def send(process, message):
        process.stdin.write(json.dumps(message).encode() + b"\n")
        process.stdin.flush()

    @staticmethod
    def live(pid):
        try:
            os.kill(pid, 0)  # Query only fixture-owned identities; send no signal.
        except ProcessLookupError:
            return False
        if sys.platform.startswith("linux"):
            try:
                state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
            except FileNotFoundError:
                return False
            return state != "Z"
        return True

    def assert_peers_stopped(self, fixture):
        pids = [int((fixture["directory"] / name).read_text())
                for name in ("driver.pid", "host.pid", "worker.pid")]
        deadline = time.monotonic() + 5
        while any(self.live(pid) for pid in pids) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(any(self.live(pid) for pid in pids), "An owned relay peer remains alive")
        self.assertEqual(list(fixture["home"].iterdir()), [])
        self.assertEqual(list(fixture["cwd"].iterdir()), [])

    def assert_auth_lookup(self, fixture, refreshes):
        calls = [json.loads(line) for line in fixture["history"].read_text().splitlines()]
        self.assertEqual([call["method"] for call in calls],
                         ["initialize", "initialized"] + ["getAuthStatus"] * len(refreshes))
        self.assertEqual([call["refresh"] for call in calls if call["method"] == "getAuthStatus"], refreshes)
        self.assertNotIn(fixture["secret"], fixture["history"].read_text())

    def test_silent_refresh_has_a_real_bounded_deadline_and_owned_cleanup(self):
        fixture = self.fixture(silent_refresh=True)
        process, reader = self.launch(fixture)
        started = time.monotonic()
        self.send(process, {"id": 2, "method": "fixture/refresh", "params": {}})
        self.assertIsNone(reader.next(timeout=13))
        self.assertEqual(process.wait(timeout=5), 78)
        elapsed = time.monotonic() - started
        self.assertGreaterEqual(elapsed, 8.5)
        self.assertLess(elapsed, 12.5)
        error = process.stderr.read().decode()
        self.assertEqual(error.strip(), AUTH_ERROR)
        self.assertNotIn(fixture["secret"], error)
        self.assert_auth_lookup(fixture, [False, True])
        self.assert_peers_stopped(fixture)

    def test_worker_final_frames_survive_immediate_exit_and_keep_exit_status(self):
        fixture = self.fixture()
        process, reader = self.launch(fixture)
        self.send(process, {"id": 2, "method": "fixture/finish", "params": {}})
        output = []
        while (message := reader.next()) is not None:
            output.append(message)
        self.assertEqual(len(output), 161)
        self.assertEqual([item["params"]["index"] for item in output[:-1]], list(range(160)))
        self.assertEqual(output[-1], {"id": 2, "result": {"text": "final frame"}})
        self.assertNotIn(fixture["secret"], json.dumps(output))
        self.assertTrue(all(item["params"]["text"].endswith("[redacted]") for item in output[:-1]))
        self.assertEqual(process.wait(timeout=5), 23)
        self.assertEqual(process.stderr.read(), b"")
        self.assert_auth_lookup(fixture, [False])
        self.assert_peers_stopped(fixture)

    def test_invalid_refresh_callbacks_fail_before_refresh_lookup(self):
        cases = [
            {"id": 901, "params": {"reason": "unauthorized", "previousAccountId": "different-account"}},
            {"id": 901, "params": {"reason": "unauthorized", "previousAccountId": []}},
            {"id": 901, "params": {"reason": "unauthorized", "previousAccountId": 123}},
            {"id": True, "params": {"reason": "unauthorized"}},
            {"id": 901, "params": {"reason": "other"}},
            {"id": 901, "params": {"reason": "unauthorized", "unexpected": "PRIVATE_FIXTURE"}},
        ]
        for callback in cases:
            with self.subTest(callback=callback):
                fixture = self.fixture(callback={"method": REFRESH_METHOD, **callback})
                process, reader = self.launch(fixture)
                self.send(process, {"id": 2, "method": "fixture/refresh", "params": {}})
                self.assertIsNone(reader.next())
                self.assertEqual(process.wait(timeout=5), 78)
                error = process.stderr.read().decode()
                self.assertEqual(error.strip(), AUTH_ERROR)
                self.assertNotIn(fixture["secret"], error)
                self.assertNotIn("PRIVATE_FIXTURE", error)
                self.assert_auth_lookup(fixture, [False])
                self.assert_peers_stopped(fixture)

    def test_malformed_auth_status_params_stop_without_tracebacks_or_host_refresh(self):
        for params in (None, [], "PRIVATE_FIXTURE"):
            with self.subTest(params=params):
                fixture = self.fixture()
                process, reader = self.launch(fixture)
                self.send(process, {"id": 2, "method": "getAuthStatus", "params": params})
                self.assertIsNone(reader.next())
                self.assertEqual(process.wait(timeout=5), 78)
                error = process.stderr.read().decode()
                self.assertEqual(error.strip(), AUTH_ERROR)
                self.assertNotIn(fixture["secret"], error)
                self.assertNotIn("PRIVATE_FIXTURE", error)
                self.assert_auth_lookup(fixture, [False])
                self.assert_peers_stopped(fixture)

    def test_controller_sigkill_closes_production_guardian_and_all_relay_peers(self):
        fixture = self.fixture()
        owner_file = fixture["directory"] / "owner.py"
        guardian_pid = fixture["directory"] / "guardian.pid"
        owner_file.write_text(textwrap.dedent(f'''\
            import json,os,selectors,subprocess,sys,time
            guardian=subprocess.Popen({fixture['command']!r},stdin=subprocess.PIPE,stdout=subprocess.PIPE)
            with open({str(guardian_pid)!r},'w') as record:
                record.write(str(guardian.pid))
            selector=selectors.DefaultSelector()
            selector.register(guardian.stdout,selectors.EVENT_READ)
            def exchange(message):
                guardian.stdin.write(json.dumps(message).encode()+b'\\n')
                guardian.stdin.flush()
                assert selector.select(5), 'Production guardian fixture timed out'
                return json.loads(guardian.stdout.readline())
            assert exchange({{'id':1,'method':'initialize','params':{{}}}})['id']==1
            assert exchange({{'id':2,'method':'fixture/running','params':{{}}}})['result']['running'] is True
            print('READY',flush=True)
            time.sleep(30)
        '''))
        owner = subprocess.Popen([sys.executable, "-I", "-B", str(owner_file)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(stop_owned_process, owner)
        with selectors.DefaultSelector() as selector:
            selector.register(owner.stdout, selectors.EVENT_READ)
            self.assertTrue(selector.select(7), "Controller fixture did not become ready")
            self.assertEqual(owner.stdout.readline(), b"READY\n")
        owner.kill()  # SIGKILL only the direct child created by this test.
        self.assertEqual(owner.wait(timeout=5), -9)
        self.assert_peers_stopped(fixture)
        guardian = int(guardian_pid.read_text())
        deadline = time.monotonic() + 5
        while self.live(guardian) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(self.live(guardian), "Production guardian did not settle after its input owner died")
        self.assertEqual(owner.stderr.read(), b"")
        self.assert_auth_lookup(fixture, [False])
        self.assertEqual(list(fixture["directory"].glob("guard.lock.*.cid*")), [])


if __name__ == "__main__":
    unittest.main()
