#!/usr/bin/env python3
"""Fake `glab` for tests. No network.

Only `glab api [--hostname H] [-X M] [--paginate] <path> [-f k=v | -F k=v]…` and
`glab auth status [--hostname H]` are understood.

$FAKE_GLAB_DIR/routes.json maps "METHOD path" (query string included, exactly as
called) to {"status": 0, "body": <json or string>} or a list of those, served in
order (the last one repeats). A missing route exits 1 with "404 Not Found".
Every call is appended to $FAKE_GLAB_DIR/calls.log as one JSON line:
{"method", "path", "fields": {k: v}, "host"}.
"""
import json
import os
import sys

d = os.environ['FAKE_GLAB_DIR']
args = sys.argv[1:]
log = os.path.join(d, 'calls.log')

if args[:2] == ['auth', 'status']:
    ok = not os.path.exists(os.path.join(d, 'auth-fail'))
    with open(log, 'a') as f:
        f.write(json.dumps({'method': 'AUTH', 'path': 'auth status', 'fields': {}, 'host': None}) + '\n')
    print('Logged in' if ok else 'not logged in', file=sys.stderr)
    sys.exit(0 if ok else 1)

if not args or args[0] != 'api':
    print('fake glab: only `api` and `auth status`', file=sys.stderr)
    sys.exit(2)

method, path, host, fields = 'GET', None, None, {}
i = 1
while i < len(args):
    a = args[i]
    if a in ('-X', '--method'):
        method = args[i + 1]; i += 2
    elif a == '--hostname':
        host = args[i + 1]; i += 2
    elif a in ('-f', '-F', '--field', '--raw-field'):
        k, _, v = args[i + 1].partition('='); fields[k] = v; i += 2
    elif a == '--paginate':
        i += 1
    elif a.startswith('-'):
        i += 1
    else:
        path = a; i += 1
if fields and method == 'GET' and any(a in ('-f', '-F', '--field', '--raw-field') for a in args):
    method = 'POST'  # glab, like gh, switches to POST when fields are given

with open(log, 'a') as f:
    f.write(json.dumps({'method': method, 'path': path, 'fields': fields, 'host': host}) + '\n')

routes = json.load(open(os.path.join(d, 'routes.json')))
key = f'{method} {path}'
r = routes.get(key)
if r is None:
    print(f'glab: 404 Not Found ({key})', file=sys.stderr)
    sys.exit(1)
if isinstance(r, list):
    state = os.path.join(d, '.served.json')
    served = json.load(open(state)) if os.path.exists(state) else {}
    n = served.get(key, 0)
    served[key] = n + 1
    json.dump(served, open(state, 'w'))
    r = r[min(n, len(r) - 1)]
body = r.get('body', '')
print(body if isinstance(body, str) else json.dumps(body))
sys.exit(r.get('status', 0))
