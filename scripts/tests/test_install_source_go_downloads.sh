#!/usr/bin/env bash
# Real cold-cache Go module downloads through the complete source installer.
# Use Go's file proxy protocol and checksum-pinned dependencies; acquisition,
# package discovery, compilation, executable checks and source receipts are real.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_MODULE="${DSR_TEST_INSTALL_SOURCE_MODULE:-$ROOT/src/install_source.sh}"
[[ $# == 0 ]] || { printf 'Usage: %s\n' "$0" >&2; exit 4; }
for dependency in python3 git jq go ps; do
    command -v "$dependency" >/dev/null 2>&1 || {
        printf 'SKIP: Go download fixtures require %s\n' "$dependency"; exit 0;
    }
done
go version >/dev/null 2>&1 || { printf 'SKIP: Go compiler is required\n'; exit 0; }
python3 -I - "$SOURCE_MODULE" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

module = Path(sys.argv[1]).resolve()
work = Path(tempfile.mkdtemp(prefix='dsr-source-go-downloads-')).resolve()
print('Go download source fixtures retained at: ' + str(work), flush=True)
upstream = work / 'upstream'
upstream.mkdir()
passed = failed = 0
env = dict(os.environ)
for name in list(env):
    if (name.startswith('GIT_') or name in ('DSR_GH_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN',
            'DSR_INSTALLER_GIT_TOKEN', 'DSR_INSTALLER_GIT_REPOSITORY', 'GOPRIVATE',
            'GONOPROXY', 'GONOSUMDB')):
        env.pop(name)
env.update(GOENV='off', GOWORK='off', GOFLAGS='', GOTOOLCHAIN='local', GOTELEMETRY='off',
           GO111MODULE='on', GOOS='', GOARCH='', GOMAXPROCS='2', GOSUMDB='off',
           GOPROXY=(work / 'proxy').as_uri(), GOMODCACHE=str(work / 'prepare-cache'),
           GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=str(work / 'gitconfig'),
           DSR_GH_TOKEN='', GH_TOKEN='', GITHUB_TOKEN='')
# Only the module-download cache must be cold. Preserve the normal compiler
# cache so this regression does not require rebuilding Go's standard library.
if env.get('DSR_TEST_GO_CACHE'):
    env['GOCACHE'] = env['DSR_TEST_GO_CACHE']

def run(arguments, **kwargs):
    return subprocess.run(arguments, env=env, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=60, **kwargs)

def require(arguments, **kwargs):
    result = run(arguments, **kwargs)
    if result.returncode:
        raise RuntimeError(repr(arguments) + '\n' + result.stderr)
    return result.stdout

def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print('PASS: ' + label, flush=True)
    else:
        failed += 1
        print('FAIL: ' + label, flush=True)

def commit(message):
    require(['git', '-C', str(upstream), 'add', '.'])
    require(['git', '-C', str(upstream), 'commit', '-qm', message])
    return require(['git', '-C', str(upstream), 'rev-parse', 'HEAD']).strip()

for name in ('app', 'helper'):
    dependency = 'example.invalid/' + name + '-dependency'
    version = 'v1.0.0'
    manifest = 'module ' + dependency + '\n\ngo 1.22\n'
    proxy = work / 'proxy' / dependency / '@v'
    proxy.mkdir(parents=True)
    (proxy / (version + '.info')).write_text(json.dumps({'Version': version, 'Time': '2026-01-01T00:00:00Z'}))
    (proxy / (version + '.mod')).write_text(manifest)
    (proxy / 'list').write_text(version + '\n')
    with zipfile.ZipFile(proxy / (version + '.zip'), 'w') as archive:
        archive.writestr(dependency + '@' + version + '/go.mod', manifest)
        archive.writestr(dependency + '@' + version + '/dependency.go',
                         'package dependency\nconst Message = "downloaded-' + name + '"\n')
    command = upstream / 'cmd' / name
    command.mkdir(parents=True)
    (command / 'main.go').write_text('package main\nimport ("fmt"; "' + dependency + '")\n'
                                   'func main() { fmt.Println(dependency.Message) }\n')
(upstream / 'go.mod').write_text('module example.invalid/cold-installer\n\ngo 1.22\n\nrequire (\n'
    ' example.invalid/app-dependency v1.0.0\n example.invalid/helper-dependency v1.0.0\n)\n')
require(['go', 'mod', 'download', 'all'], cwd=upstream)
checksum_bytes = (upstream / 'go.sum').read_bytes()
require(['git', 'init', '-q', '-b', 'main', str(upstream)])
require(['git', '-C', str(upstream), 'config', 'user.name', 'DSR cold Go fixture'])
require(['git', '-C', str(upstream), 'config', 'user.email', 'cold-go@example.invalid'])
pin = commit('Pinned Go executable family with downloadable dependencies')
require(['git', 'config', '--file', env['GIT_CONFIG_GLOBAL'],
         'url.' + upstream.as_uri() + '.insteadOf', 'https://github.com/example/cold-installer.git'])
env['GOMODCACHE'] = str(work / 'cold-cache')

def build(name):
    result = run(['bash', '-c', 'source "$1"; install_source_build example/cold-installer HEAD go app "$2" '
                  '--allow-build --timeout 60 --bin app --bin helper', '_', str(module), str(work / name)])
    (work / (name + '.json')).write_text(result.stdout)
    (work / (name + '.log')).write_text(result.stderr)
    try:
        receipt = json.loads(result.stdout)
    except (ValueError, TypeError):
        receipt = {}
    return result, receipt

check('source installation begins with no dependency cache', not (work / 'cold-cache').exists())
cold, receipt = build('cold')
check('cold dependency downloads permit the complete Go executable family', cold.returncode == 0)
for index, name in enumerate(('app', 'helper')):
    payload = work / 'cold' / 'output' / 'bin' / name
    output = run([str(payload)]).stdout.strip() if payload.is_file() else ''
    check(name + ' executes its own downloaded dependency', output == 'downloaded-' + name)
    log = work / 'cold' / 'output' / ('package-%d.log' % index)
    check(name + ' download diagnostics are retained', log.is_file() and
          'go: downloading example.invalid/' + name + '-dependency v1.0.0' in log.read_text())
check('successful receipt binds the source pin and exact requested family',
      receipt.get('source_commit') == pin and receipt.get('signed_release') is False and
      [item.get('name') for item in receipt.get('binaries', [])] == ['app', 'helper'])
check('receipt checksums bind actual executable bytes', len(receipt.get('binaries', [])) == 2 and
      all(hashlib.sha256(Path(item['path']).read_bytes()).hexdigest() == item.get('sha256')
          for item in receipt.get('binaries', [])))
check('readonly dependency resolution preserves committed checksum bytes',
      (work / 'cold' / 'source' / 'go.sum').read_bytes() == checksum_bytes)
# Warm every module explicitly: the unchanged implementation can stop at the
# first download before it ever reaches the companion dependency.
require(['go', 'mod', 'download', 'all'], cwd=upstream)
warm, warm_receipt = build('warm')
check('warm-cache source installation preserves the same successful family', warm.returncode == 0 and
      [item.get('name') for item in warm_receipt.get('binaries', [])] == ['app', 'helper'])

(upstream / 'cmd/helper/main.go').write_text('package main\nimport _ "example.invalid/helper-dependency/missing"\nfunc main() {}\n')
commit('Missing dependency package must remain a failed source build')
missing, _ = build('missing-package')
check('unresolvable dependency remains terminal despite a valid main package name', missing.returncode == 6)
check('failed dependency resolution cannot publish a successful family receipt',
      not missing.stdout.strip() and not (work / 'missing-package' / 'receipt.json').exists())
check('failed lookup retains the actual Go dependency diagnostic',
      'example.invalid/helper-dependency/missing' in missing.stderr)

(upstream / 'cmd/helper/main.go').write_text('this is not a Go package\n')
commit('Package admission errors stop before family compilation')
invalid, _ = build('invalid-package')
check('go list failures stop before any family executable is compiled', invalid.returncode == 6 and
      not invalid.stdout.strip() and not (work / 'invalid-package' / 'output' / 'bin').exists())
check('go list errors preserve their original compiler diagnostic', "expected 'package'" in invalid.stderr)

(upstream / 'cmd/helper/main.go').write_text('package helper\nconst Value = 1\n')
commit('A library cannot satisfy the selected executable family')
library, _ = build('library')
check('non-main companion still refuses the entire executable family', library.returncode == 6 and
      not library.stdout.strip() and not (work / 'library' / 'output' / 'bin').exists())

(upstream / 'cmd/helper/main.go').write_text('package main\nfunc main() { missingSymbol() }\n')
commit('Compiler errors after successful package admission remain failures')
broken, _ = build('compile-error')
check('real compiler failure cannot produce a successful family receipt', broken.returncode == 6 and
      not broken.stdout.strip() and not (work / 'compile-error' / 'receipt.json').exists())
check('real compiler error is retained after package admission', 'undefined: missingSymbol' in broken.stderr)
print('Go download source tests: %d passed, %d failed' % (passed, failed), flush=True)
sys.exit(0 if failed == 0 else 1)
PY
