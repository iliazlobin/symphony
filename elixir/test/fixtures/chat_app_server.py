#!/usr/bin/env python3
"""A deterministic stdio peer for management-runtime lifecycle tests."""
import json
import os
import signal
from pathlib import Path
import sys
import time

home = Path(os.environ['CODEX_HOME'])
mode = (home / 'fixture-mode').read_text().strip()
(home / 'child-pid').write_text(str(os.getpid()))
if mode == 'hang': signal.signal(signal.SIGTERM, signal.SIG_IGN)
config = {}
for arg in sys.argv[1:]:
    if '=' not in arg:
        continue
    key, value = arg.split('=', 1)
    obj = config
    bits = key.split('.')
    for bit in bits[:-1]:
        obj = obj.setdefault(bit, {})
    obj[bits[-1]] = json.loads(value)

def write(message):
    raw = json.dumps(message) + '\n'
    if mode == 'split':
        sys.stdout.write(raw[:8]); sys.stdout.flush(); time.sleep(.001)
        sys.stdout.write(raw[8:]); sys.stdout.flush()
    else:
        sys.stdout.write(raw); sys.stdout.flush()

def notification(method, **params):
    write(dict(method=method, params=params))

def finished(status='completed'):
    notification('turn/completed', threadId='thread-1', turn={'id': 'turn-1', 'status': status})

for line in sys.stdin:
    request = json.loads(line)
    (home / 'requests.jsonl').open('a').write(line)
    method = request.get('method')
    params = request.get('params', {})
    rid = request.get('id')
    if method == 'initialize':
        if mode == 'startup-request':
            write({'id': 'unexpected-startup', 'method': 'item/commandExecution/requestApproval', 'params': {}})
            continue
        if mode == 'startup-tool':
            write({'id': 'unexpected-tool', 'method': 'item/tool/call', 'params': {
                'threadId': None, 'turnId': None, 'tool': 'symphony_status', 'arguments': {}}})
            continue
        if mode == 'startup-notification': notification('server/notice', message='Starting')
        if mode == 'wrong-response-id':
            write({'id': 'unrelated-id', 'result': {}}); continue
        if mode == 'non-object-result':
            write({'id': rid, 'result': []}); continue
        version = '0.100.0' if mode == 'old' else '0.154.0'
        result = {'userAgent': 'symphony-management/' + version + ' (test)'}
    elif method == 'config/read':
        if mode == 'unsafe': config['features']['shell_tool'] = True
        result = {'config': [] if mode == 'config-non-map' else config}
    elif method == 'account/read':
        result = {'account': None if mode == 'auth' else {'type': 'chatgpt'}, 'requiresOpenaiAuth': True}
    elif method == 'model/list':
        result = {'data': [] if mode == 'missing' else [{'model': 'gpt-6-astra'}], 'nextCursor': None}
        if mode == 'model-pages' or (mode == 'model-second-page' and params.get('cursor') is None):
            result = {'data': [], 'nextCursor': 'next-page'}
    elif method in ('thread/start', 'thread/resume'):
        if mode == 'reject':
            write({'id': rid, 'error': {'message': 'private diagnostic secret'}}); continue
        if method == 'thread/start':
            assert params['environments'] == []
            assert params['allowProviderModelFallback'] is False
            assert params['dynamicTools'][0]['name'] == 'symphony_status'
        else:
            assert params['threadId'] == ('previous-thread' if mode == 'resume-mismatch' else 'thread-1')
            assert (home / 'native-thread').exists()
        (home / 'native-thread').write_text('thread-1')
        result = {'thread': {'id': 'thread-1'}, 'model': 'gpt-6-astra', 'approvalPolicy': 'never', 'sandbox': {'type': 'readOnly'}}
        if mode == 'thread-empty': result['thread']['id'] = ''
        if mode == 'unsafe-model': result['model'] = 'another-model'
        if mode == 'unsafe-approval': result['approvalPolicy'] = 'on-request'
        if mode == 'unsafe-sandbox': result['sandbox']['type'] = 'workspaceWrite'
        if mode == 'unsafe-instructions': result['instructionSources'] = ['untrusted-home/AGENTS.md']
    elif method == 'turn/start':
        assert params['environments'] == []
        if mode in ('turn-started', 'turn-started-foreign', 'turn-started-noid'):
            notification('turn/started', threadId='foreign' if mode == 'turn-started-foreign' else 'thread-1',
                         turn={'id': None if mode == 'turn-started-noid' else 'turn-1'})
        if mode in ('turn-empty', 'turn-blank'):
            write({'id': rid, 'result': {'turn': {} if mode == 'turn-empty' else {'id': ''}}}); continue
        write({'id': rid, 'result': {'turn': {'id': 'turn-1'}}})
        if mode == 'turn-started-swapped':
            notification('turn/started', threadId='thread-1', turn={'id': 'turn-other'}); continue
        if mode == 'completion-shape': write({'unexpected': True}); continue
        if mode == 'completion-wrong-thread':
            notification('turn/completed', threadId='foreign', turn={'id': 'turn-1', 'status': 'completed'}); continue
        if mode == 'completion-wrong-turn':
            notification('turn/completed', threadId='thread-1', turn={'id': 'turn-other', 'status': 'completed'}); continue
        if mode == 'model-error': notification('error', willRetry=False); continue
        if mode == 'model-retry': notification('error', willRetry=True)
        if mode == 'turn-started':
            notification('item/started', threadId='thread-1', turnId='turn-1', item={'type': 'agentMessage'})
            notification('item/completed', threadId='thread-1', turnId='turn-1', item={'type': 'agentMessage'})
        if mode == 'malformed':
            print('{not json', flush=True); continue
        if mode == 'exit': sys.exit(6)
        if mode == 'hang': continue
        if mode == 'approval':
            write({'id': 'approval-1', 'method': 'item/commandExecution/requestApproval', 'params': {}}); continue
        if mode == 'builtin':
            notification('item/started', threadId='thread-1', turnId='turn-1', item={'type': 'fileChange'}); continue
        if mode == 'wrong-thread':
            notification('item/agentMessage/delta', threadId='foreign-thread', turnId='turn-1', delta='foreign data'); continue
        if mode in ('interrupt', 'interrupt-repeat'):
            notification('item/agentMessage/delta', threadId='thread-1', turnId='turn-1', delta='Working'); continue
        if mode == 'compact':
            notification('item/started', threadId='thread-1', turnId='turn-1', item={'type': 'contextCompaction'})
        notification('item/agentMessage/delta', threadId='thread-1', turnId='turn-1', delta='Current ')
        notification('item/agentMessage/delta', threadId='thread-1', turnId='turn-1', delta='tasks')
        notification('thread/tokenUsage/updated', threadId='thread-1', turnId='turn-1', tokenUsage={'last': {'totalTokens': 10}})
        write({'id': 'tool-1', 'method': 'item/tool/call', 'params': {
            'threadId': 'thread-1', 'turnId': 'turn-1', 'callId': 'call-1',
            'tool': 'exec_command' if mode == 'forbidden' else 'symphony_status', 'arguments': {}}})
        continue
    elif rid == 'tool-1':
        assert request['result']['contentItems'][0]['type'] == 'inputText'
        output = json.loads(request['result']['contentItems'][0]['text'])
        if output.get('error') == 'interrupted': continue
        finished('failed' if mode == 'failed' else 'completed'); continue
    elif method == 'turn/interrupt':
        assert params == {'threadId': 'thread-1', 'turnId': 'turn-1'}
        write({'id': rid, 'result': {}})
        if mode == 'interrupt-repeat':
            notification('item/agentMessage/delta', threadId='thread-1', turnId='turn-1', delta='Stopping')
            continue
        finished('interrupted'); continue
    elif method == 'initialized': continue
    else: continue
    write({'id': rid, 'result': result})
