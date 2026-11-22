#!/usr/bin/env bash
# Real Git, private descriptors, signed local plans and signed remote-byte
# verification. GitHub credentials and HTTP/download delivery use isolated fixtures.
set -euo pipefail
ROOT="${DSR_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
python3 - "$ROOT" <<'PY'
import hashlib
import errno
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError:
    raise SystemExit('Strict release contract tests require Python jsonschema')

root = Path(sys.argv[1])
os.umask(0o077)
# Private receipt descriptors require canonical absolute parents. System temp
# directories may themselves be exposed through a symlink (macOS /var).
work = Path(tempfile.mkdtemp(prefix='dsr-strict-finalize-')).resolve()
source = Path(os.environ.get('DSR_TEST_COMMAND_FILE', str(root / 'dsr'))).read_text()
names = re.findall(r'^(_release_[A-Za-z0-9_]+)\(\) \{', source, re.M)
names += ['json_envelope', '_source_release_read_private_receipt', '_source_release_metadata_matches',
          '_source_release_restore_draft', '_source_release_identity',
          '_source_release_inputs_match', 'cmd_release_finalize', 'cmd_release', 'cmd_release_verify', 'cmd_fallback', 'main']
functions = work / 'functions.sh'
extracted=[]
for name in names:
    # The real envelope contains a column-zero JSON brace in its heredoc.
    ending=r'^EOF\n\}' if name=='json_envelope' else r'^\}'
    extracted.append(re.search(r'^'+re.escape(name)+r'\(\) \{\n.*?'+ending,source,re.M|re.S).group(0))
functions.write_text('\n'.join(extracted))
print('Fixtures: ' + str(work), flush=True)
checks = 0

def check(label, value):
    global checks
    if not value:
        raise AssertionError(label)
    checks += 1
    print('PASS ' + label, flush=True)

base = work / 'base'
repo = base / 'repo'
repo.mkdir(parents=True)
subprocess.run(['minisign', '-G', '-W', '-p', str(repo/'minisign.pub'), '-s', str(base/'fixture.key')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
(repo/'README.md').write_text('Isolated signing fixture. No release compilation.\n')
(repo/'install.sh').write_text('#!/bin/sh\nprintf "isolated installer fixture\\n"\n')
for args in [['init','-q'],['config','user.name','DSR fixture'],['config','user.email','dsr@example.invalid'],['add','README.md','minisign.pub','install.sh'],['commit','-qm','signed source fixture'],['tag','-a','v1.2.3','-m','fixture'],['remote','add','origin','https://github.com/owner/app.git']]:
    subprocess.run(['git','-C',str(repo)]+args,check=True)
sha = subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
contract = {'checksum_sidecar':'sha256','minisign_public_key_file':'minisign.pub',
            'exact_primary_assets':{'linux/amd64':'payload.tar.gz'},
            'exact_additional_assets':['SHA256SUMS','SHA256SUMS.minisig']}
installer_digest=hashlib.sha256((repo/'install.sh').read_bytes()).hexdigest()
installer_url='https://raw.githubusercontent.com/owner/app/refs/heads/main/install.sh'
def checksum_text(digest=installer_digest,url=installer_url):
    return '# Private downstream generator fixture\ninstallers:\n  app:\n'+f'    url: "{url}"\n    sha256: "{digest}"\n'
downstream=base/'downstream'
downstream.mkdir()
for args in [['init','-q','-b','main'],['config','user.name','DSR fixture'],['config','user.email','dsr@example.invalid']]:
    subprocess.run(['git','-C',str(downstream)]+args,check=True)
(downstream/'checksums.yaml').write_text(checksum_text('0'*64))
for args in [['add','checksums.yaml'],['commit','-qm','old installer pin']]:
    subprocess.run(['git','-C',str(downstream)]+args,check=True)
subprocess.run(['git','init','--bare','-q','-b','main',str(base/'downstream-public.git')],check=True)
for args in [['remote','add','origin',str(base/'downstream-public.git')],['push','-q','origin','main']]:
    subprocess.run(['git','-C',str(downstream)]+args,check=True)
(downstream/'checksums.yaml').write_text(checksum_text())
for args in [['add','checksums.yaml'],['commit','-qm','refreshed installer pin']]:
    subprocess.run(['git','-C',str(downstream)]+args,check=True)

api = r'''
import base64, hashlib, json, os, signal, subprocess, time
from pathlib import Path
import sys
c=Path(os.environ['CASE']); args=sys.argv[1:]
if not args:
    raw=sys.stdin.buffer.read(); assert raw.endswith(b'\0')
    args=[part.decode() for part in raw[:-1].split(b'\0')]
endpoint=args[0]
control=json.loads((c/'control.json').read_text())
with (c/'requests.jsonl').open('a') as f:f.write(json.dumps(args)+'\n')
r=json.loads((c/'remote.json').read_text())
def stop_boundary(name):
    if control.get('helper_stop_boundary')!=name:
        return
    phase=control.get('helper_stop_phase','any')
    if phase=='published' and (r['draft'] or not control.get('publication_attempts')):
        return
    if phase=='restoring' and not control.get('restoration_attempts'):
        return
    if phase=='complete-draft' and (not r['draft'] or len(r['assets'])!=len(json.loads((c/'plan.json').read_text())['assets'])):
        return
    count=control.get('helper_boundary_calls',0)+1
    control['helper_boundary_calls']=count
    (c/'control.json').write_text(json.dumps(control))
    if count<=control.get('helper_stop_skip',0):
        return
    (c/'stopped-request.json').write_text(json.dumps(args))
    if control.get('helper_partial_metadata'):
        print(json.dumps(r))
    sys.exit(control['helper_stop_status'])
if endpoint.startswith(('repos/owner/', 'repos/Dicklesworthstone/agentic_coding_flywheel_setup/')) and '/git/ref/heads/main' in endpoint:
    stop_boundary('raw-main')
    if control.get('raw_auth_denied'):
        print('Controlled authentication refusal',file=sys.stderr);sys.exit(1)
    source=endpoint.startswith('repos/owner/app/')
    sha=os.environ['SOURCE_SHA'] if source else subprocess.check_output(
        ['git','--git-dir',str(c/'downstream-public.git'),'rev-parse','refs/heads/main'],text=True).strip()
    field='raw_source_reads' if source else 'raw_downstream_reads'
    control[field]=control.get(field,0)+1
    (c/'control.json').write_text(json.dumps(control))
    if control.get('raw_move_source') and source and control[field]>1:sha='f'*40
    if control.get('raw_move_downstream') and not source and control[field]>1:sha='e'*40
    value={'ref':'refs/heads/main','object':{'type':'commit','sha':sha}}
    if control.get('raw_bad_ref'):value['ref']='refs/heads/stale'
    print(json.dumps(value))
elif endpoint.startswith(('repos/owner/app/contents/install.sh?ref=', 'repos/owner/downstream/contents/',
                          'repos/Dicklesworthstone/agentic_coding_flywheel_setup/contents/')):
    stop_boundary('raw-file')
    ref=endpoint.split('?ref=',1)[1]
    source=endpoint.startswith('repos/owner/app/')
    path=endpoint.split('/contents/',1)[1].split('?ref=',1)[0]
    checker=path.startswith('scripts/lib/')
    if checker and control.get('checker_auth_denied'):
        print('Controlled checker authentication refusal',file=sys.stderr);sys.exit(1)
    data=(subprocess.check_output(['git','-C',str(c/'repo'),'show',ref+':install.sh']) if source else
          subprocess.check_output(['git','--git-dir',str(c/'downstream-public.git'),'show',ref+':'+path]))
    if checker and control.get('checker_post_publication_failure') and not r['draft']:
        data=b'#!/bin/bash\nprintf "Controlled late checker failure\\n" >&2\nexit 23\n'
    if source and control.get('raw_wrong_source_blob'):data+=b'changed immutable main installer\n'
    blob=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
    value={'type':'file','path':path,'encoding':'base64','size':len(data),'sha':blob,
           'content':base64.b64encode(data).decode()}
    if control.get('raw_bad_blob'):value['sha']='0'*40
    if checker and control.get('checker_bad_blob'):value['sha']='0'*40
    if control.get('raw_bad_size'):value['size']+=1
    print(json.dumps(value))
elif endpoint=='raw-installer-download':
    stop_boundary('raw-curl')
    data=(c/'repo/install.sh').read_bytes()
    if control.get('raw_wrong_bytes'):data+=b'changed public installer\n'
    sys.stdout.buffer.write(data)
elif endpoint=='signed-download':
    stop_boundary('download')
    target=Path(args[2]);assert not target.exists()
    target.write_bytes((c/'bytes'/args[1]).read_bytes())
elif endpoint=='repos/owner/app' or endpoint.startswith('repos/owner/app/rulesets/'):
    stop_boundary('ruleset')
    policy={'id':22,'name':'immutable tags','source':'owner/app','source_type':'Repository',
            'target':'tag','enforcement':'active','bypass_actors':[],
            'conditions':{'ref_name':{'include':['refs/tags/v*'],'exclude':[]}},
            'rules':[{'type':'update'},{'type':'deletion'}],
            'node_id':'ruleset-node','created_at':'2026-01-01T00:00:00Z','updated_at':'2026-01-01T00:00:00Z',
            'current_user_can_bypass':'never','_links':{'self':{'href':'https://api.github.com/repos/owner/app/rulesets/22'}}}
    if endpoint=='repos/owner/app':
        value={'id':11,'node_id':'repository-node','full_name':'owner/app'}
    elif '/history/33' in endpoint:
        value={'version_id':33,'updated_at':policy['updated_at'],'state':policy}
    elif '/history?' in endpoint:
        value=[{'version_id':33,'updated_at':policy['updated_at']}]
    else:
        value=policy
    print(json.dumps(value))
elif endpoint=='upload-boundary':
    source=Path(args[1]);name=args[2];data=source.read_bytes();aid=100+len(r['assets'])
    if control.get('pause_upload'):
        (c/'upload-paused').write_text(name)
        time.sleep(20)
        sys.exit(91)
    if control.get('fail_upload_name')==name:
        print('Controlled upload failure',file=sys.stderr);sys.exit(1)
    (c/'bytes'/str(aid)).write_bytes(data)
    asset={'id':aid,'name':name,'state':'uploaded','size':len(data),'digest':'sha256:'+hashlib.sha256(data).hexdigest(),
           'browser_download_url':'https://github.com/owner/app/releases/download/v1.2.3/'+name}
    r['assets'].append(asset);(c/'remote.json').write_text(json.dumps(r));print(json.dumps(asset))
    if control.get('upload_stop_status') and control.get('upload_stop_name',name)==name:
        (c/'stopped-request.json').write_text(json.dumps(args))
        sys.exit(control['upload_stop_status'])
    if control.get('lost_upload_name')==name:sys.exit(1)
elif endpoint=='checksum-download':
    matches=[a for a in r['assets'] if a.get('browser_download_url')==args[1]]
    if len(matches)!=1:sys.exit(89)
    Path(args[2]).write_bytes((c/'bytes'/str(matches[0]['id'])).read_bytes())
elif endpoint=='repos/owner/app/releases' and '--post' in args:
    request=json.loads(args[args.index('--post')+1])
    r=dict(request,id=9,assets=[],upload_url='https://uploads.github.com/repos/owner/app/releases/9/assets{?name,label}',
           html_url='https://github.com/owner/app/releases/tag/untagged-fixture')
    control['absent']=False;(c/'control.json').write_text(json.dumps(control))
    (c/'remote.json').write_text(json.dumps(r));print(json.dumps(r))
    if control.get('create_stop_status'):sys.exit(control['create_stop_status'])
elif endpoint.startswith('repos/owner/app/releases?'):
    stop_boundary('scan')
    print(json.dumps([] if control.get('absent') or 'page=2' in endpoint else [dict(r,id=99) if control.get('wrong_scan_id') else r]))
elif endpoint=='repos/owner/app/git/ref/tags/v1.2.3':
    stop_boundary('tag')
    moved=control.get('tag_drift_always') or (control.get('tag_drift_after_publish') and not r['draft'])
    print(json.dumps({'object':{'type':'commit','sha':'f'*40 if moved else os.environ['SOURCE_SHA']}}))
elif endpoint=='repos/owner/app/releases/9':
    pending=list((c/'state/releases').glob('app-v1.2.3-finalization-pending.*'))
    if '--method' not in args and pending:
        if control.get('pause_finalizer') and not (c/'finalizer-paused').exists():
            (c/'finalizer-paused').write_text(str(pending[0]))
            deadline=time.monotonic()+30
            while not (c/'continue-finalizer').exists():
                if time.monotonic()>deadline:sys.exit(92)
                time.sleep(0.02)
        if control.get('change_finalizer_lease') and not (c/'original-finalizer-lease').exists():
            lock=c/'state/builds/app/v1.2.3/.lock'
            if lock.is_file() and not lock.is_symlink():
                (c/'original-finalizer-lease').write_bytes(lock.read_bytes())
                lock.write_text('changed fixture custody record\n')
    if '--method' in args:
        patch=json.loads(args[args.index('--data')+1])
        if patch.get('draft') is False:
            control['publication_attempts']=control.get('publication_attempts',0)+1
        elif patch.get('draft') is True:
            control['restoration_attempts']=control.get('restoration_attempts',0)+1
        (c/'control.json').write_text(json.dumps(control))
        if patch.get('draft') is True:
            stop_boundary('restore')
        if patch.get('draft') is False and control.get('pause_promotion'):
            # Model an exec transport which retains no build/supervisor fds
            # and needs escalation to stop. Only the explicit fixture gate
            # permits the remote publication mutation below.
            signal.signal(signal.SIGTERM,signal.SIG_IGN)
            os.closerange(3,1024)
            (c/'promotion.pid').write_text(str(os.getpid()))
            deadline=time.monotonic()+40
            while not (c/'continue-promotion').exists():
                if time.monotonic()>deadline:sys.exit(92)
                time.sleep(0.02)
        if patch.get('draft') is False and control.get('fail_publish'):
            print('Controlled publication failure',file=sys.stderr);sys.exit(1)
        if patch.get('draft') is False and control.get('publish_stop_before'):
            sys.exit(control['publish_stop_status'])
        r.update(patch)
        if r['draft'] is False and control.get('raw_drift_after_publish'):
            p=c/'downstream/checksums.yaml'
            p.write_text(p.read_text().replace(os.environ['INSTALLER_DIGEST'],'0'*64))
            for a in [['add','checksums.yaml'],['commit','-qm','concurrent wrong installer pin'],['push','-q','origin','main']]:
                subprocess.run(['git','-C',str(c/'downstream')]+a,check=True)
        if r['draft'] is False and control.get('metadata_drift_after_publish'):r['body']='changed after publish'
        if r['draft'] is False and control.get('prerelease_drift_after_publish'):r['prerelease']=not r['prerelease']
        (c/'remote.json').write_text(json.dumps(r));print(json.dumps(r))
        if patch.get('draft') is False and control.get('publish_stop_status'):
            sys.exit(control['publish_stop_status'])
        if patch.get('draft') is True and control.get('restore_stop_status'):
            sys.exit(control['restore_stop_status'])
        sys.exit(1 if control.get('lost_patch') else 0)
    stop_boundary('metadata')
    count=control.get('reads',0)+1;control['reads']=count
    if count==2 and control.get('receipt_replace'):
        p=c/'tmp/dsr-api-response.ABCDEF12'; retained=p.with_name(p.name+'.retained');p.rename(retained)
        if control['receipt_replace']=='symlink':p.symlink_to(retained)
        else:p.write_bytes(retained.read_bytes());p.chmod(0o600)
    if count==2 and control.get('config_drift'):
        p=c/'config/repos.d/app.yaml';p.write_text(p.read_text()+'\n')
    if count==2 and control.get('registry_appears'):
        (c/'config/repos.yaml').write_text(json.dumps({'tools':{'app':{'release_contract':{}}}}))
    (c/'control.json').write_text(json.dumps(control))
    observed=dict(r,assets=r['assets'][:100])
    if control.get('embedded_fault')=='duplicate':observed['assets']+=observed['assets'][:1]
    if control.get('embedded_fault')=='malformed' and observed['assets']:
        observed['assets'][0]=dict(observed['assets'][0],size='invalid')
    print(json.dumps(observed))
elif endpoint.startswith('repos/owner/app/releases/9/assets?'):
    stop_boundary('inventory')
    page=int(endpoint.rsplit('page=',1)[1]);assets=list(r['assets'])
    if page==1:
        control['inventories']=control.get('inventories',0)+1
        (c/'control.json').write_text(json.dumps(control))
    if control.get('hidden_asset') or (control.get('post_hidden_asset') and not r['draft']):assets.append(dict(assets[0],id=999,name='hidden.bin'))
    fault=control.get('inventory_fault')
    if fault=='missing-last':assets=assets[:-1]
    if fault=='extra':assets.append(dict(assets[0],id=999999,name='unselected.bin'))
    if fault=='late-change' and control.get('inventories',0)>1:
        assets[-1]=dict(assets[-1],id=999998)
    selected=assets[(page-1)*100:page*100]
    if page==2:
        if fault=='failed-page':sys.exit(91)
        if fault=='malformed-page':selected={'message':'not an asset page'}
        if fault=='duplicate-id':selected=[dict(assets[0])]+selected[1:]
        if fault=='duplicate-name':selected=[dict(assets[0],id=999997)]+selected[1:]
        if fault=='case-alias':selected=[dict(assets[0],id=999997,name=assets[0]['name'].upper())]+selected[1:]
    print(json.dumps(selected))
else:print('Unexpected API '+endpoint,file=sys.stderr);sys.exit(89)
'''

script = r'''
set -uo pipefail
[[ "${STRICT_TEST_LASTPIPE:-false}" != true ]] || shopt -s lastpipe
source "$ROOT/src/github.sh"
source "$ROOT/src/config.sh"
source "$ROOT/src/git_ops.sh"
source "$ROOT/src/build_state.sh"
source "$ROOT/src/act_runner.sh"
source "${DSR_TEST_SIGNING_MODULE:-$ROOT/src/signing.sh}"
source "$ROOT/src/artifact_naming.sh"
source "$ROOT/src/sbom.sh"
source "$FUNCTIONS"
export DSR_CHECKER_SECRET_PROBE='must not reach the downstream process'
dsr_checker_injected_function() { return 42; }
export -f dsr_checker_injected_function
log_error() { printf 'ERROR %s\n' "$*" >&2; }
log_info() { printf 'INFO %s\n' "$*" >&2; }
log_ok() { log_info "$@"; }
log_warn() { log_info "$@"; }
log_debug() { :; }
log_set_tool() { :; }
log_set_level_from_flags() { :; }
log_set_command() { :; }
log_init() { :; }
log_session_finished() { :; }
_dsr_load_all_modules() { :; }
_dsr_require() {
    case "$1" in release_finalize_core) source "$ROOT/src/release_finalize_core.sh" ;; esac
}
_dispatch_load_config() { printf 'false|||\n'; }
_dispatch_is_true() { [[ "$1" == true ]]; }
gh_check() { return 0; }
gh_check_token() { return 0; }
gh_api() {
    if [[ "$1" == */contents/scripts/lib/* ]]; then
        # Like the real API helper, fill a safely pre-created response file.
        # Exclusive destination creation must not leak noclobber into here.
        local response_file
        response_file=$(command mktemp "$CASE/tmp/script-delivery.XXXXXXXX") || return
        python3 "$CASE/api.py" "$@" > "$response_file" || return
        cat "$response_file"
    else
        python3 "$CASE/api.py" "$@"
    fi
}
curl() {
    [[ "${!#}" == 'https://raw.githubusercontent.com/owner/app/refs/heads/main/install.sh' ]] || return 89
    python3 "$CASE/api.py" raw-installer-download
}
# Stop only the selected external validation process after it consumes input.
# Production pipeline status selection and every upstream adapter remain real.
python3() {
    if [[ "${STRICT_TEST_PYTHON_STOP:-}" != '' && "${1:-}" == -I && "${2:-}" == -c ]]; then
        local selected=false
        case "${STRICT_TEST_PYTHON_STAGE:-}:${3:-}" in
            main:*'value = json.load(sys.stdin'*) selected=true ;;
            text:*'import base64, hashlib, json, sys'*) selected=true ;;
            hash:*'import hashlib,sys; print(hashlib.sha256'*) selected=true ;;
            download:*'data = sys.stdin.buffer.read(2097153)'*) selected=true ;;
            checksum:*'selected, url, digest = sys.argv[1:]'*) selected=true ;;
        esac
        if $selected; then
            command cat >/dev/null
            return "$STRICT_TEST_PYTHON_STOP"
        fi
    fi
    command python3 "$@"
}
jq() {
    if [[ "${STRICT_TEST_JQ_STOP:-}" != '' && "${1:-}" == -cse &&
          "${2:-}" == *'map(.name | ascii_downcase)'* ]]; then
        command cat >/dev/null
        return "$STRICT_TEST_JQ_STOP"
    fi
    command jq "$@"
}
gh_download_release_asset() { python3 "$CASE/api.py" signed-download "$2" "$3"; }
mktemp() {
    if [[ "${FAIL_PENDING:-false}" == true && "$*" == *finalization-pending* ]]; then return 1; fi
    if [[ "${FAIL_FINAL:-false}" == true && "$*" == *-finalized.* ]]; then return 1; fi
    if [[ "${FAIL_CREATION_CUSTODY:-false}" == true && "$*" == *dsr-create-custody.* ]]; then return 1; fi
    command mktemp "$@"
}
DRY_RUN=false
JSON_MODE=false
DSR_VERSION=fixture
VERBOSE=false
QUIET=false
NON_INTERACTIVE=false
if [[ "$1" == create || "$1" == publish || "$1" == fallback || "$1" == verify || "$1" == public-finalize ]]; then
    mode="$1"
    shift
    # Retain the real API adapter and creation producer. Only HTTP transport
    # and upload delivery are fixtures; receipt files are never synthesized.
    source "$ROOT/src/github.sh"
    gh_check() { return 0; }
    gh_check_token() { return 0; }
    # The real adapter now authenticates inside each timed request attempt.
    # Route that credential boundary to the same explicit HTTP fixture; never
    # depend on a developer's logged-in account to exercise draft creation.
    _gh_check_cli_auth() { return 0; }
    gh_download_release_asset() { python3 "$CASE/api.py" signed-download "$2" "$3"; }
    _gh_api_with_gh() {
        case "$2" in
            POST) python3 "$CASE/api.py" < <(printf '%s\0' "$1" --post "$3") ;;
            PATCH) python3 "$CASE/api.py" < <(printf '%s\0' "$1" --method PATCH --data "$3") ;;
            *) python3 "$CASE/api.py" "$1" ;;
        esac
    }
    gh_upload_asset_named() { python3 "$CASE/api.py" upload-boundary "$2" "$3"; }
    JSON_MODE=true
    if [[ "$mode" == create ]]; then
        cmd_release app 1.2.3 --draft --no-dispatch "$@"
    elif [[ "$mode" == publish ]]; then
        cmd_release app 1.2.3 --no-dispatch "$@"
    elif [[ "$mode" == verify ]]; then
        curl() {
            [[ $# == 4 && "$1" == -sL && "$3" == -o ]] || return 89
            python3 "$CASE/api.py" checksum-download "$2" "$4"
        }
        DRY_RUN="$1"; shift
        cmd_release_verify app 1.2.3 "$@"
    elif [[ "$mode" == public-finalize ]]; then
        # Exercise the real public dispatcher, API adapter, timeout ownership,
        # signed verification and build leases. Only remote bytes are local.
        if [[ "${BORROW_BUILD_CUSTODY:-false}" == true ]]; then
            build_state_init || exit $?
            build_lock_acquire app v1.2.3 || exit $?
            trap 'printf "caller exit\n" >> "$CASE/caller-exit"' EXIT
            trap -p EXIT > "$CASE/caller-trap.before"
            caller_snapshot() {
                declare -p _BUILD_LOCK_PATHS _BUILD_LOCK_FDS _BUILD_LOCK_IDENTITIES \
                    _BUILD_LOCK_OWNERS _BUILD_LOCK_RECORDS
                _build_state_file_identity "$DSR_STATE_DIR/builds/app/v1.2.3/.lock"
                _build_state_file_identity "$DSR_STATE_DIR/builds/app/v1.2.3/.lock.lease"
                cat "$DSR_STATE_DIR/builds/app/v1.2.3/.lock"
            }
            caller_snapshot > "$CASE/caller-custody.before"
        fi
        main --json release finalize "$@"
        status=$?
        if [[ "${BORROW_BUILD_CUSTODY:-false}" == true ]]; then
            trap -p EXIT > "$CASE/caller-trap.after"
            caller_snapshot > "$CASE/caller-custody.after"
            printf '%s\n' "$status" > "$CASE/public-return"
            count=0
            while [[ ! -e "$CASE/release-caller" ]]; do
                ((count+=1)); ((count<=1500)) || exit 93
                sleep 0.02
            done
            build_lock_release app v1.2.3 || exit 94
        fi
        exit "$status"
    else
        # These are only quality/build execution boundaries. Every source,
        # checkpoint, manifest, signature, custody and publication gate is real.
        _check_repo() { printf '{"status":"ok"}\n'; }
        notify_event() { printf '%s\n' "$1" >> "$CASE/notifications"; }
        qg_run_checks() { printf 'quality\n' >> "$CASE/build-calls"; }
        cmd_build() {
            local out="" tasks run result
            while (($#)); do
                case "$1" in --output-dir) out="$2"; shift 2 ;; *) shift ;; esac
            done
            [[ -n "$out" && ! -e "$out" && ! -L "$out" ]] || return 4
            mkdir -p "$out" || return 4
            cp -a "$CASE/build-inputs/." "$out/" || return 4
            printf 'build\n' >> "$CASE/build-calls"
            run=$(DSR_RUN_ID=11111111-1111-4111-8111-111111111111 build_state_create app 1.2.3 linux/amd64) || return 4
            tasks=$(_act_build_task_plan app 1.2.3 '["linux/amd64"]' true) || return 4
            build_state_set_context app 1.2.3 "$run" "$SOURCE_SHA" v1.2.3 '{}' "$out" 1 '{}' release \
                "$tasks" '' null "$(_act_sha256 "$ACT_REPOS_DIR/app.yaml")" || return 4
            # This fixture compiler reports the event selected by the real
            # planner, so completed reuse retains the same workflow binding.
            result=$(jq -c '.[0] | {result:{status:"success",method:.method,
                platform:.platform,workflow_event:.workflow_event}}' <<< "$tasks") || return 4
            build_state_update_target app 1.2.3 linux/amd64 completed "$result" "$run" || return 4
            build_state_update_status app 1.2.3 completed "$run" || return 4
        }
        cmd_fallback app --version 1.2.3 --expected-sha "$SOURCE_SHA" "$@"
    fi
elif [[ "$1" == helper ]]; then
    shift
    "$@"
elif [[ "$1" == prepare ]]; then
    act_load_repo_config app || exit
    contract=$(config_get_release_contract_json app) || exit
    _release_contract_preflight app v1.2.3 owner/app "$CASE/repo" "$CASE/state/artifacts/app-v1.2.3" "$CASE/state/artifacts/app-v1.2.3/app-v1.2.3-manifest.json" "$contract" create > "$CASE/plan.json"
else
    shift
    DRY_RUN="$1"; shift
    cmd_release_finalize "$@"
fi
'''

def setup(label, controls=None, extra_assets=0, long_names=False, large_notes=False, raw_installer=False, acfs_checker=False, tag_ruleset=False):
    c=work/label;shutil.copytree(base,c)
    case_sha=sha
    if large_notes:
        # Create actual Git notes, retaining all original Git objects in this
        # isolated fixture. Source, manifests and signed plans bind the new SHA.
        message=c/'commit-message'
        message.write_text('Reviewed λ change '*9000+'literal "quote" \\ @file $HOME\n')
        for args in [['tag','v1.2.2'],['commit','-q','--allow-empty','-F',str(message)],
                     ['tag','-f','-a','v1.2.3','-m','large-note fixture'],['update-index','--refresh']]:
            subprocess.run(['git','-C',str(c/'repo')]+args,check=True,stdout=subprocess.DEVNULL)
        case_sha=subprocess.check_output(['git','-C',str(c/'repo'),'rev-parse','HEAD'],text=True).strip()
    for name in ['tmp','config/repos.d','state/artifacts/app-v1.2.3','bytes']:(c/name).mkdir(parents=True)
    (c/'api.py').write_text(api);(c/'requests.jsonl').write_text('');(c/'control.json').write_text(json.dumps(controls or {}))
    extra_names=['companion-%03d-%s.txt'%(i,'x'*220 if long_names else 'data') for i in range(extra_assets)]
    selected_contract=dict(contract,exact_additional_assets=contract['exact_additional_assets']+extra_names)
    if tag_ruleset:
        selected_contract['github_tag_ruleset']={'repository_id':11,'ruleset_id':22}
    if raw_installer or acfs_checker:
        selected_contract['raw_installer_checksum']={'downstream_repo':'owner/downstream','checksum_path':'checksums.yaml',
                                                     'installer_key':'app','installer_path':'install.sh'}
        subprocess.run(['git','-C',str(c/'downstream'),'remote','set-url','origin',str(c/'downstream-public.git')],check=True)
        if acfs_checker:
            selected_contract['raw_installer_checksum'].update(checker='acfs',
                downstream_repo='Dicklesworthstone/agentic_coding_flywheel_setup')
            lib=c/'downstream/scripts/lib';lib.mkdir(parents=True)
            # R2 script-delivery boundary: real Git commits/blob transport and
            # actual child process, with an explicit substitute for ACFS code.
            # A separate real public-checker run is required for native credit.
            (lib/'logging.sh').write_text('CHECKER_LOGGING_LOADED=yes\n')
            (lib/'security.sh').write_text('#!/usr/bin/env bash\nset -euo pipefail\n'
                'source "${BASH_SOURCE[0]%/*}/logging.sh"\n'
                '[[ $# == 3 && $1 == --checksum && $2 == '+installer_url+' && $3 == --retain-temp-files ]]\n'
                '[[ $CHECKER_LOGGING_LOADED == yes && -z ${DSR_MINISIGN_KEY:-} && -z ${DSR_CHECKER_SECRET_PROBE:-} ]]\n'
                'if declare -F dsr_checker_injected_function; then exit 24; fi\n'
                'printf "checker invoked with clean environment\\n" > "$TMPDIR/checker-invoked"\n'
                'printf "%s\\n" '+installer_digest+'\n')
            for args in [['add','scripts/lib'],['commit','-qm','private checker delivery fixture']]:
                subprocess.run(['git','-C',str(c/'downstream')]+args,check=True)
        subprocess.run(['git','-C',str(c/'downstream'),'push','-q','origin','main'],check=True)
    (c/'config/repos.d/app.yaml').write_text(json.dumps({'tool_name':'app','repo':'owner/app','local_path':str(c/'repo'),'targets':['linux/amd64'],'release_contract':selected_contract}))
    artifacts=c/'state/artifacts/app-v1.2.3'
    # A real tar archive; this test does not claim a native binary build.
    subprocess.run(['tar','-czf',str(artifacts/'payload.tar.gz'),'-C',str(c/'repo'),'README.md'],check=True)
    payload=(artifacts/'payload.tar.gz').read_bytes()
    manifest={'tool':'app','version':'v1.2.3','source':{'git_sha':case_sha,'git_ref':'v1.2.3','dependencies':[]},
              'build_purpose':'release','publishable':True,'requested_targets':['linux/amd64'],
              'status':'success','summary':{'total':1,'success':1,'failed':0},
              'artifacts':[{'name':'payload.tar.gz','target':'linux/amd64','sha256':hashlib.sha256(payload).hexdigest(),'size_bytes':len(payload),'build_purpose':'release','publishable':True}]}
    for name in extra_names:
        data=('Authenticated release companion: '+name+'\n').encode()
        (artifacts/name).write_bytes(data)
        manifest['artifacts'].append(dict(name=name,target='additional',sha256=hashlib.sha256(data).hexdigest(),
                                         size_bytes=len(data),build_purpose='release',publishable=True))
    (artifacts/'app-v1.2.3-manifest.json').write_text(json.dumps(manifest))
    original={'id':9,'tag_name':'v1.2.3','name':'v1.2.3','target_commitish':case_sha,'draft':True,'prerelease':False,'assets':[],
              'body':'Release 1.2.3\n\n<!-- dsr-create-nonce:'+'1'*64+' -->',
              'upload_url':'https://uploads.github.com/repos/owner/app/releases/9/assets{?name,label}',
              'html_url':'https://github.com/owner/app/releases/tag/untagged-fixture'}
    (c/'remote.json').write_text(json.dumps(original))
    response=c/'tmp/dsr-api-response.ABCDEF12';response.write_text(json.dumps(original));response.chmod(0o600)
    env=dict(os.environ,ROOT=str(root),FUNCTIONS=str(functions),CASE=str(c),SOURCE_SHA=case_sha,
             DSR_CONFIG_DIR=str(c/'config'),DSR_STATE_DIR=str(c/'state'),TMPDIR=str(c/'tmp'),DSR_MINISIGN_KEY=str(c/'fixture.key'),
             INSTALLER_DIGEST=installer_digest,NO_COLOR='1')
    r=subprocess.run(['bash','-c',script,'fixture','prepare'],env=env,capture_output=True,text=True)
    (c/'prepare.log').write_text(r.stdout+r.stderr)
    if r.returncode:raise AssertionError(label+' real preflight: '+r.stderr[-2500:])
    plan=json.loads((c/'plan.json').read_text());remote=dict(original,assets=[])
    for i,a in enumerate(plan['assets'],100):
        shutil.copyfile(a['path'],c/'bytes'/str(i))
        remote['assets'].append({'id':i,'name':a['name'],'state':'uploaded','size':a['size_bytes'],'digest':'sha256:'+a['sha256'],
                                'browser_download_url':'https://github.com/owner/app/releases/download/v1.2.3/'+a['name']})
    (c/'remote.json').write_text(json.dumps(remote))
    (c/'requests.jsonl').write_text('')
    return c,env,response,original

def invoke(c,env,response,dry=False,flags=None):
    args=flags if flags is not None else ['app','1.2.3','--create-response',str(response),'--no-dispatch']
    r=subprocess.run(['bash','-c',script,'fixture','run',str(dry).lower()]+args,env=env,capture_output=True,text=True)
    (c/'finalize.log').write_text(r.stdout+r.stderr)
    requests=[json.loads(l) for l in (c/'requests.jsonl').read_text().splitlines()]
    patches=[q for q in requests if '--method' in q]
    return r,patches


def test_raw_installer_checksum_publication():
    # Git repositories, commits, pushes, immutable blobs and Minisign are real.
    # GitHub/HTTP transport remains the existing isolated delivery fixture;
    # these cases do not certify a public release or native packaged binaries.
    def published(c):
        return json.loads((c/'remote.json').read_text())['draft'] is False

    def commit_pin(c, text, push=True):
        (c/'downstream/checksums.yaml').write_bytes(text.encode())
        # Keep adversarial record delimiters in the actual committed blob;
        # caller Git attributes or autocrlf must not normalize the control.
        blob=subprocess.check_output(['git','-C',str(c/'downstream'),'hash-object','-w',
                                      '--no-filters','checksums.yaml'],text=True).strip()
        for args in [['update-index','--add','--cacheinfo','100644,'+blob+',checksums.yaml'],
                     ['commit','-qm','checksum transition']]:
            subprocess.run(['git','-C',str(c/'downstream')]+args,check=True)
        if push:
            subprocess.run(['git','-C',str(c/'downstream'),'push','-q','origin','main'],check=True)

    for mode in ['finalize','publish','finalize-crlf','publish-crlf']:
        c,env,response,_=setup('raw-installer-'+mode,raw_installer=True)
        if mode.endswith('-crlf'):
            commit_pin(c,checksum_text().replace('installers:\n','installers:\n \t \n').replace('\n','\r\n'))
        (c/'control.json').write_text(json.dumps({'absent':True} if mode.startswith('publish') else {}))
        if mode.startswith('publish'):
            result=subprocess.run(['bash','-c',script,'fixture','publish'],env=env,capture_output=True,text=True,timeout=90)
            patches=[q for q in map(json.loads,(c/'requests.jsonl').read_text().splitlines()) if '--method' in q]
        else:
            result,patches=invoke(c,env,response)
        (c/'raw-transition.log').write_text(result.stdout+result.stderr)
        check('raw installer '+mode+' publishes the verified candidate',result.returncode==0 and published(c))
        check('raw installer '+mode+' makes one publication mutation',sum('draft' in q[q.index('--data')+1] and
              json.loads(q[q.index('--data')+1]).get('draft') is False for q in patches)==1)
        requests=list(map(json.loads,(c/'requests.jsonl').read_text().splitlines()))
        check('raw installer '+mode+' rechecks both public branch authorities',
              sum(q[0]=='repos/owner/app/git/ref/heads/main' for q in requests)>=4 and
              sum(q[0]=='repos/owner/downstream/git/ref/heads/main' for q in requests)>=4)

    for label in ['stale','wrong-url','duplicate-key','duplicate-root','duplicate-field','missing-key',
                  'bare-cr','unicode-linebreak','unicode-space-record',
                  'auth-denied','wrong-bytes','cached-raw','bad-ref','bad-blob','bad-size','move-source','move-downstream',
                  'uncommitted-refresh','push-failed','post-publication-drift']:
        c,env,response,_=setup('raw-installer-'+label,raw_installer=True)
        controls={}
        if label=='stale':commit_pin(c,checksum_text('0'*64))
        elif label=='wrong-url':commit_pin(c,checksum_text(url=installer_url.replace('/main/','/stale/')))
        elif label=='duplicate-key':commit_pin(c,checksum_text()+'  app:\n'+checksum_text().split('  app:\n',1)[1])
        elif label=='duplicate-root':commit_pin(c,checksum_text()+'installers:\n')
        elif label=='duplicate-field':commit_pin(c,checksum_text()+f'    sha256: "{installer_digest}"\n')
        elif label=='missing-key':commit_pin(c,checksum_text().replace('  app:','  other:'))
        elif label=='bare-cr':commit_pin(c,checksum_text().replace('\n','\r'))
        elif label=='unicode-linebreak':commit_pin(c,checksum_text().replace('\n','\u2028'))
        elif label=='unicode-space-record':commit_pin(c,checksum_text().replace('installers:\n','installers:\n\u00a0\n'))
        elif label in ['uncommitted-refresh','push-failed']:
            commit_pin(c,checksum_text('0'*64))
            (c/'downstream/checksums.yaml').write_text(checksum_text())
            if label=='push-failed':
                subprocess.run(['git','-C',str(c/'downstream'),'add','checksums.yaml'],check=True)
                subprocess.run(['git','-C',str(c/'downstream'),'commit','-qm','local refresh not published'],check=True)
                hook=c/'downstream-public.git/hooks/pre-receive'
                hook.write_text('#!/bin/sh\nexit 1\n');hook.chmod(0o700)
                push=subprocess.run(['git','-C',str(c/'downstream'),'push','origin','main'],capture_output=True,text=True)
                (c/'failed-downstream-push.stdout').write_text(push.stdout)
                (c/'failed-downstream-push.stderr').write_text(push.stderr)
                check('real failed downstream push is retained',push.returncode!=0 and
                      'pre-receive hook declined' in push.stderr)
        else:
            field={'auth-denied':'raw_auth_denied','wrong-bytes':'raw_wrong_bytes','bad-ref':'raw_bad_ref',
                   'cached-raw':'raw_wrong_source_blob',
                   'bad-blob':'raw_bad_blob','bad-size':'raw_bad_size','move-source':'raw_move_source',
                   'move-downstream':'raw_move_downstream','post-publication-drift':'raw_drift_after_publish'}[label]
            controls[field]=True
        (c/'control.json').write_text(json.dumps(controls))
        result,patches=invoke(c,env,response)
        check('raw installer '+label+' cannot report publication success',result.returncode!=0)
        check('raw installer '+label+' leaves the owned release as a draft',not published(c))
        if label!='post-publication-drift':
            check('raw installer '+label+' refuses before publication mutation',not patches)
        else:
            check('raw installer post-publication drift triggers owned-draft restoration',len(patches)==2)

    # The direct producer has its own promotion and post-publication branch.
    # Exercise its failures independently of retained-draft finalization.
    for label in ['stale','wrong-bytes','cached-raw','bare-cr','unicode-linebreak','unicode-space-record','push-failed','post-publication-drift']:
        c,env,_,_=setup('raw-direct-'+label,raw_installer=True)
        controls={'absent':True}
        if label in ['stale','push-failed']:
            commit_pin(c,checksum_text('0'*64))
            if label=='push-failed':
                commit_pin(c,checksum_text(),push=False)
                hook=c/'downstream-public.git/hooks/pre-receive'
                hook.write_text('#!/bin/sh\nexit 1\n');hook.chmod(0o700)
                push=subprocess.run(['git','-C',str(c/'downstream'),'push','origin','main'],capture_output=True,text=True)
                (c/'failed-downstream-push.stdout').write_text(push.stdout)
                (c/'failed-downstream-push.stderr').write_text(push.stderr)
                check('direct real failed downstream push is retained',push.returncode!=0 and
                      'pre-receive hook declined' in push.stderr)
        elif label=='bare-cr':commit_pin(c,checksum_text().replace('\n','\r'))
        elif label=='unicode-linebreak':commit_pin(c,checksum_text().replace('\n','\u2028'))
        elif label=='unicode-space-record':commit_pin(c,checksum_text().replace('installers:\n','installers:\n\u00a0\n'))
        else:
            controls[{'wrong-bytes':'raw_wrong_bytes','cached-raw':'raw_wrong_source_blob',
                      'post-publication-drift':'raw_drift_after_publish'}[label]]=True
        (c/'control.json').write_text(json.dumps(controls))
        result=subprocess.run(['bash','-c',script,'fixture','publish'],env=env,capture_output=True,text=True,timeout=90)
        (c/'raw-transition.log').write_text(result.stdout+result.stderr)
        patches=[q for q in map(json.loads,(c/'requests.jsonl').read_text().splitlines()) if '--method' in q]
        check('raw direct '+label+' refuses publication success',result.returncode!=0)
        check('raw direct '+label+' leaves a draft',not published(c))
        check('raw direct '+label+' has only the expected publication mutations',
              len(patches)==(2 if label=='post-publication-drift' else 0))


def test_acfs_checksum_checker_publication():
    # Both actual publishers must execute the mandatory checker, without
    # rescuing its failure through the generic hasher or a previously good pin.
    for mode in ['finalize','publish']:
        for failure in [None,'exit','empty','invalid','wrong-digest','good-digest-error',
                        'logging-missing','auth-denied','bad-blob','late-failure']:
            label=f'acfs-{mode}-{failure or "valid"}'
            c,env,response,_=setup(label,acfs_checker=True)
            prepared_snapshots=set((c/'tmp').glob('dsr-acfs-check.*'))
            controls={'absent':True} if mode=='publish' else {}
            if failure in ['auth-denied','bad-blob','late-failure']:
                controls[{'auth-denied':'checker_auth_denied','bad-blob':'checker_bad_blob',
                          'late-failure':'checker_post_publication_failure'}[failure]]=True
            elif failure:
                # Change and push the actual downstream script object. A
                # syntactically valid old checksum pin cannot bypass its error.
                contents={
                    'exit':'printf "Controlled checker failure\\n" >&2\nexit 23\n',
                    'empty':'exit 0\n',
                    'invalid':'printf "invalid checksum\\n"\n',
                    'wrong-digest':'printf "%s\\n" '+'0'*64+'\n',
                    'good-digest-error':'printf "%s\\n" '+installer_digest+'\nexit 23\n',
                    'logging-missing':'source "${BASH_SOURCE[0]%/*}/missing-logging.sh"\n'
                }[failure]
                (c/'downstream/scripts/lib/security.sh').write_text('#!/bin/bash\nset -euo pipefail\n'+contents)
                for args in [['add','scripts/lib/security.sh'],['commit','-qm','adversarial checker delivery'],
                             ['push','-q','origin','main']]:
                    subprocess.run(['git','-C',str(c/'downstream')]+args,check=True)
            (c/'control.json').write_text(json.dumps(controls))
            if mode=='publish':
                result=subprocess.run(['bash','-c',script,'fixture','publish'],env=env,
                                      capture_output=True,text=True,timeout=90)
                patches=[q for q in map(json.loads,(c/'requests.jsonl').read_text().splitlines()) if '--method' in q]
            else:
                result,patches=invoke(c,env,response)
            (c/'checker-transition.log').write_text(result.stdout+result.stderr)
            published=json.loads((c/'remote.json').read_text())['draft'] is False
            if failure:
                check(label+' cannot report publication success',result.returncode!=0)
                check(label+' preserves the owned draft',not published)
                check(label+' has only expected publication mutations',
                      len(patches)==(2 if failure=='late-failure' else 0))
            else:
                check(label+' publishes the verified candidate',result.returncode==0 and published)
                check(label+' makes exactly one publication mutation',len(patches)==1)
                snapshots=list(set((c/'tmp').glob('dsr-acfs-check.*'))-prepared_snapshots)
                check(label+' executes and retains the isolated checker at every observation',
                      len(snapshots)>=3 and all((p/'checker-invoked').is_file() for p in snapshots))
                check(label+' keeps snapshot and output private',all(stat.S_IMODE(p.stat().st_mode)==0o700
                      and all(stat.S_IMODE((p/name).stat().st_mode)==0o600
                              for name in ['security.sh','logging.sh','stdout','stderr']) for p in snapshots))
                requests=list(map(json.loads,(c/'requests.jsonl').read_text().splitlines()))
                revision=subprocess.check_output(['git','--git-dir',str(c/'downstream-public.git'),
                                                  'rev-parse','refs/heads/main'],text=True).strip()
                script_requests=[q for q in requests if '/contents/scripts/lib/' in q[0]]
                check(label+' binds both script files to the downstream pin revision',
                    len(script_requests)==2*len(snapshots) and
                    {q[0].split('/scripts/lib/',1)[1].split('?ref=',1)[0] for q in script_requests}
                        == {'security.sh','logging.sh'} and
                    all('?ref='+revision in q[0] for q in script_requests))


def test_large_note_creation_and_finalization():
    c,env,_,_=setup('large-note-creation',{'absent':True},large_notes=True)
    r=subprocess.run(['bash','-c',script,'fixture','create','--generate-notes'],
                     env=env,capture_output=True,text=True,timeout=90)
    (c/'create.log').write_text(r.stdout+r.stderr)
    check('large notes strict draft creation succeeds',r.returncode==0)
    details=json.loads(r.stdout)['details']
    response=Path(details['create_response']); raw=response.read_bytes(); inode=response.stat().st_ino
    original=json.loads(raw)
    commits=subprocess.check_output(['git','-C',str(c/'repo'),'log','--oneline','v1.2.2..v1.2.3'],text=True).rstrip('\n')
    prefix='## Changes since v1.2.2\n\n'+commits+'\n\n<!-- dsr-create-nonce:'
    check('large notes use real Git bytes above argument limit',len(prefix.encode())>131072
          and original['body'].startswith(prefix)
          and re.fullmatch(r'[0-9a-f]{64} -->',original['body'][len(prefix):]) is not None)
    check('large notes retain original private empty draft response',original['draft'] is True
          and original['assets']==[] and original['target_commitish']==env['SOURCE_SHA']
          and stat.S_IMODE(response.stat().st_mode)==0o600)
    intent=json.loads((response.parent/'creation-intent.json').read_text())
    check('large notes bind complete frozen creation intent',intent['plan']['release']['body']==original['body'])
    env['TMPDIR']=details['finalization_tmpdir']
    r,patches=invoke(c,env,response,dry=True)
    check('large notes strict finalization dry run is read only',r.returncode==0 and not patches
          and json.loads((c/'remote.json').read_text())['draft'] is True)
    remote=json.loads((c/'remote.json').read_text())
    remote['body']+='unrelated note drift'
    (c/'remote.json').write_text(json.dumps(remote))
    r,patches=invoke(c,env,response)
    check('large notes changed remote body blocks publication',r.returncode==7 and not patches
          and response.read_bytes()==raw and response.stat().st_ino==inode)
    remote['body']=original['body']
    (c/'remote.json').write_text(json.dumps(remote))
    r,patches=invoke(c,env,response)
    check('large notes signed strict finalization publishes once',r.returncode==0 and len(patches)==1
          and json.loads((c/'remote.json').read_text())['draft'] is False)
    pending=list((c/'state/releases').glob('app-v1.2.3-finalization-pending.*'))
    final=list((c/'state/releases').glob('app-v1.2.3-finalized.*'))
    check('large notes survive both durable finalization receipts',len(pending)==1 and len(final)==1
          and json.loads(pending[0].read_text())['metadata']['body']==original['body']
          and json.loads(final[0].read_text())['release']['body']==original['body'])
    requests=[json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]
    check('large notes retain one creation and original custody',sum('--post' in row for row in requests)==1
          and response.read_bytes()==raw and response.stat().st_ino==inode)

def prepare_cases(cases):
    # Each case has its own repository, signing key copy, state and transport
    # logs. Execute every real preflight; only independent preparation overlaps.
    # Keep mutations/assertions in their original order, and propagate every
    # preparation error before the case can be counted as passing.
    with ThreadPoolExecutor(max_workers=4) as pool:
        prepared=list(pool.map(lambda case: setup(*case),cases))
    return zip(cases,prepared)

def interruption_statuses():
    selected=os.environ.get('DSR_TEST_RELEASE_INTERRUPTION_STATUS','all')
    if selected not in ('all','2','5','124','125','129','130','143','255'):
        raise AssertionError('Select a known strict interruption or supervisor status')
    return (5,124,130) if selected=='all' else (int(selected),)


def test_shared_strict_helper_interruptions():
    names=('inventory','download','tag','ruleset','raw-main','raw-file','scan','restore','preflight')
    selected=os.environ.get('DSR_TEST_STRICT_HELPER_CASE','all')
    if selected not in ('all',)+names+('raw-curl','visibility','transient','consumer'):
        raise AssertionError('Select a known shared strict helper case')
    for name in names:
        if selected not in ('all',name):continue
        for stop_status in interruption_statuses():
            label='helper-'+name+'-'+str(stop_status)
            c,env,_,original=setup(label,raw_installer=name.startswith('raw-'),tag_ruleset=name=='ruleset')
            plan=json.loads((c/'plan.json').read_text())
            boundary='tag' if name=='preflight' else name
            controls={'helper_stop_boundary':boundary,'helper_stop_status':stop_status}
            if name=='restore':
                remote=json.loads((c/'remote.json').read_text());remote['draft']=False
                (c/'remote.json').write_text(json.dumps(remote))
            (c/'control.json').write_text(json.dumps(controls))
            if name in ('inventory','download'):
                args=['_release_contract_verify_remote_assets','owner/app','9',json.dumps(plan['assets']),
                      'true','v1.2.3',json.dumps(original)]
            elif name=='tag':
                args=['_release_contract_verify_remote_tag_identity','owner/app','v1.2.3',env['SOURCE_SHA']]
            elif name=='ruleset':
                args=['_release_contract_verify_tag_ruleset_receipt',json.dumps(plan['tag_ruleset_receipt'])]
            elif name.startswith('raw-'):
                args=['_release_contract_verify_raw_installer_checksum',json.dumps(plan['raw_installer_checksum'])]
            elif name=='scan':
                args=['_release_contract_scan_release_by_tag','owner/app','v1.2.3']
            elif name=='restore':
                args=['_source_release_restore_draft','owner/app','9',json.dumps(original)]
            else:
                directory=c/'state/artifacts/app-v1.2.3'
                args=['_release_contract_preflight','app','v1.2.3','owner/app',str(c/'repo'),str(directory),
                      str(directory/'app-v1.2.3-manifest.json'),json.dumps(plan['contract']),'verify']
            result=subprocess.run(['bash','-c',script,'fixture','helper']+args,
                                  env=env,capture_output=True,text=True,timeout=120)
            (c/'interrupted.stdout').write_text(result.stdout);(c/'interrupted.stderr').write_text(result.stderr)
            rows=[json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]
            check(label+' retains the original terminal adapter status',result.returncode==stop_status)
            check(label+' stops before any later request',rows[-1]==json.loads((c/'stopped-request.json').read_text()))
            check(label+' preserves the legacy empty failure stream',result.stdout=='')

    if selected in ('all','raw-curl'):
        c,env,_,_=setup('helper-raw-curl-dns',raw_installer=True)
        plan=json.loads((c/'plan.json').read_text())
        (c/'control.json').write_text(json.dumps({'helper_stop_boundary':'raw-curl','helper_stop_status':5}))
        result=subprocess.run(['bash','-c',script,'fixture','helper','_release_contract_verify_raw_installer_checksum',
                               json.dumps(plan['raw_installer_checksum'])],env=env,capture_output=True,text=True,timeout=120)
        check('raw curl DNS exit5 remains an ordinary verification failure',result.returncode==7 and not result.stdout)

    if selected in ('all','visibility'):
        for retained in (False,True):
            c,env,_,original=setup('helper-visibility-'+str(retained))
            plan=json.loads((c/'plan.json').read_text())
            (c/'control.json').write_text(json.dumps({'helper_stop_boundary':'inventory','helper_stop_status':130}))
            args=['_release_contract_verify_remote_assets','owner/app','9',json.dumps(plan['assets']),
                  'true','v1.2.3',json.dumps(original)]
            if retained:args+=['true']
            result=subprocess.run(['bash','-c',script,'fixture','helper']+args,
                                  env=env,capture_output=True,text=True,timeout=120)
            check('metadata retention is explicitly selected '+str(retained),result.returncode==130 and
                  (json.loads(result.stdout)['draft'] is True if retained else result.stdout==''))
        for mismatch in ('tag_name','body','target_commitish'):
            c,env,_,original=setup('helper-visibility-wrong-'+mismatch)
            plan=json.loads((c/'plan.json').read_text())
            original[mismatch]='foreign-'+mismatch
            (c/'control.json').write_text(json.dumps({'helper_stop_boundary':'inventory','helper_stop_status':130,
                                                    'helper_partial_metadata':True}))
            result=subprocess.run(['bash','-c',script,'fixture','helper','_release_contract_verify_remote_assets',
                                  'owner/app','9',json.dumps(plan['assets']),'true','v1.2.3',json.dumps(original),'true'],
                                  env=env,capture_output=True,text=True,timeout=120)
            check('unbound '+mismatch+' never becomes retained visibility',result.returncode==130 and result.stdout=='')

    if selected in ('all','transient'):
        c,env,_,original=setup('helper-transient-restoration',{'lost_patch':True})
        remote=json.loads((c/'remote.json').read_text());remote['draft']=False
        (c/'remote.json').write_text(json.dumps(remote))
        result=subprocess.run(['bash','-c',script,'fixture','helper','_source_release_restore_draft',
                               'owner/app','9',json.dumps(original)],env=env,capture_output=True,text=True,timeout=120)
        rows=[json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]
        check('ordinary lost restoration response still reconciles',result.returncode==0 and not result.stdout and
              json.loads((c/'remote.json').read_text())['draft'] is True and sum('--method' in row for row in rows)==1)


    if selected in ('all','consumer'):
        for stage,stop,expected in [('main',143,143),('text',143,143),('hash',143,143),('download',143,143),
                                    ('checksum',143,143),('main',5,7)]:
            c,env,_,_=setup('helper-consumer-'+stage+'-'+str(stop),raw_installer=True)
            plan=json.loads((c/'plan.json').read_text())
            env.update(STRICT_TEST_PYTHON_STAGE=stage,STRICT_TEST_PYTHON_STOP=str(stop))
            result=subprocess.run(['bash','-c',script,'fixture','helper','_release_contract_verify_raw_installer_checksum',
                                   json.dumps(plan['raw_installer_checksum'])],env=env,capture_output=True,text=True,timeout=120)
            rows=[json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]
            check(stage+' consumer exit'+str(stop)+' retains its correct classification',
                  result.returncode==expected and not result.stdout)
            check(stage+' consumer stop prevents subsequent source observations',
                  len(rows)=={'main':1,'text':3,'hash':3,'download':4,'checksum':5}[stage])
        for stop,expected in [(143,143),(5,7)]:
            c,env,_,_=setup('helper-inventory-consumer-'+str(stop))
            env.update(STRICT_TEST_JQ_STOP=str(stop),STRICT_TEST_LASTPIPE='true')
            result=subprocess.run(['bash','-c',script,'fixture','helper','gh_release_asset_inventory','owner/app','9'],
                                  env=env,capture_output=True,text=True,timeout=120)
            rows=[json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]
            check('lastpipe inventory consumer exit'+str(stop)+' retains its correct classification',
                  result.returncode==expected and not result.stdout)
            check('inventory consumer stop does not re-read complete input',len(rows)==1)


def test_strict_upload_interruptions():
    for stop_status in interruption_statuses():
        c,env,_,_=setup('upload-stop-'+str(stop_status),{'absent':True,'upload_stop_status':stop_status})
        result=subprocess.run(['bash','-c',script,'fixture','publish'],env=env,capture_output=True,text=True)
        (c/'interrupted.stdout').write_text(result.stdout)
        (c/'interrupted.stderr').write_text(result.stderr)
        check('strict upload '+str(stop_status)+' is terminal interrupted',result.returncode==5)
        details=json.loads(result.stdout)['details']
        rows=[json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]
        check('strict upload '+str(stop_status)+' stops before reconciliation or publication',
              [row for row in rows if row[0]=='upload-boundary']==[rows[-1]] and
              not any('--method' in row for row in rows) and
              json.loads((c/'remote.json').read_text())['draft'] is True)
        check('strict upload '+str(stop_status)+' retains original custody and uncertainty',
              details['verification']=='interrupted' and
              details['interruption']==dict(stage='upload',exit_code=stop_status,outcome='unconfirmed') and
              Path(details['create_response']).is_file() and
              json.loads(Path(details['create_response']).read_text())['assets']==[] and
              len(json.loads((c/'remote.json').read_text())['assets'])==1)
        validator=Draft202012Validator(json.loads((root/'schemas/release-details.json').read_text()))
        check('strict upload '+str(stop_status)+' result satisfies release schema',not list(validator.iter_errors(details)))


def test_strict_verification_interruptions():
    names=('inventory','download','tag','ruleset','raw-main','raw-file','restore','restore-read','pre-inventory','preflight','prescan')
    selected=os.environ.get('DSR_TEST_STRICT_VERIFICATION_CASE','inventory')
    entry=os.environ.get('DSR_TEST_STRICT_VERIFICATION_ENTRY','finalize')
    if selected not in names or entry not in ('finalize','publish'):
        raise AssertionError('Select a known strict verification boundary and finalize/publish entry')
    for stop_status in interruption_statuses():
        label='strict-'+entry+'-'+selected+'-'+str(stop_status)
        c,env,_,_=setup(label,{'absent':True},raw_installer=selected.startswith('raw-'),tag_ruleset=selected=='ruleset')
        response=None
        original=None
        identity=None
        if entry=='finalize':
            created=subprocess.run(['bash','-c',script,'fixture','create'],
                                   env=env,capture_output=True,text=True,timeout=120)
            (c/'producer.stdout').write_text(created.stdout);(c/'producer.stderr').write_text(created.stderr)
            check(label+' uses the real signed draft producer',created.returncode==0)
            details=json.loads(created.stdout)['details']
            response=Path(details['create_response']);env['TMPDIR']=details['finalization_tmpdir']
            original=response.read_bytes();identity=(response.stat().st_dev,response.stat().st_ino)
        boundary={'restore-read':'metadata','pre-inventory':'inventory','preflight':'tag','prescan':'scan'}.get(selected,selected)
        phase={'restore-read':'restoring','pre-inventory':'complete-draft','preflight':'any','prescan':'any'}.get(selected,'published')
        controls=json.loads((c/'control.json').read_text())
        controls.update(helper_stop_boundary=boundary,helper_stop_status=stop_status,helper_stop_phase=phase)
        if selected in ('restore','restore-read'):controls['tag_drift_after_publish']=True
        if selected=='restore-read':controls['helper_partial_metadata']=True
        (c/'control.json').write_text(json.dumps(controls));(c/'requests.jsonl').write_text('')
        args=['bash','-c',script,'fixture','publish'] if entry=='publish' else [
            'bash','-c',script,'fixture','public-finalize','app','1.2.3',
            '--create-response',str(response),'--no-dispatch']
        result=subprocess.run(args,env=env,capture_output=True,text=True,timeout=120)
        (c/'interrupted.stdout').write_text(result.stdout);(c/'interrupted.stderr').write_text(result.stderr)
        check(label+' is terminal interrupted',result.returncode==5)
        rows=[json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]
        check(label+' makes no request after the stopped boundary',
              rows[-1]==json.loads((c/'stopped-request.json').read_text()))
        envelope=json.loads(result.stdout);details=envelope['details']
        stage='restore' if selected in ('restore','restore-read') else 'verification'
        check(label+' reports original status and unconfirmed outcome',
              envelope['status']=='error' and envelope['exit_code']==5 and
              details['verification']=='interrupted' and
              details['interruption']==dict(stage=stage,exit_code=stop_status,outcome='unconfirmed'))
        if selected in ('preflight','prescan'):
            check(label+' allocates no draft or finalization receipt after cancelled admission',
                  not any('--post' in row or '--method' in row or row[0]=='upload-boundary' for row in rows) and
                  not list((c/'state/releases').glob('app-v1.2.3-finalization-pending.*')))
            continue
        last_draft=selected=='pre-inventory'
        check(label+' retains only completed bound visibility',details['draft'] is last_draft)
        if entry=='publish':
            response=Path(details['create_response']);env['TMPDIR']=details['finalization_tmpdir']
            original=response.read_bytes();identity=(response.stat().st_dev,response.stat().st_ino)
        pending=list((c/'state/releases').glob('app-v1.2.3-finalization-pending.*'))
        pending_before={p:(p.read_bytes(),p.stat().st_dev,p.stat().st_ino) for p in pending}
        check(label+' preserves original response and pending uncertainty',
              response.read_bytes()==original and (response.stat().st_dev,response.stat().st_ino)==identity and
              all(json.loads(p.read_text())['status']=='pending' for p in pending) and
              not list((c/'state/releases').glob('app-v1.2.3-finalized.*')))
        controls=json.loads((c/'control.json').read_text())
        for key in ('helper_stop_boundary','helper_stop_status','helper_stop_phase','helper_partial_metadata','tag_drift_after_publish'):
            controls.pop(key,None)
        (c/'control.json').write_text(json.dumps(controls));(c/'requests.jsonl').write_text('')
        resumed=subprocess.run(['bash','-c',script,'fixture','public-finalize','app','1.2.3',
                                '--create-response',str(response),'--no-dispatch'],
                               env=env,capture_output=True,text=True,timeout=120)
        (c/'resumed.stdout').write_text(resumed.stdout);(c/'resumed.stderr').write_text(resumed.stderr)
        later=[json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]
        check(label+' explicitly resumes the same release without reupload',resumed.returncode==0 and
              not any('--post' in row or row[0]=='upload-boundary' for row in later) and
              json.loads((c/'remote.json').read_text())['draft'] is False)
        check(label+' recovery preserves immutable original and pending receipts',
              response.read_bytes()==original and (response.stat().st_dev,response.stat().st_ino)==identity and
              all((p.read_bytes(),p.stat().st_dev,p.stat().st_ino)==before for p,before in pending_before.items()))


def test_strict_creation_interruptions():
    for stop_status in interruption_statuses():
        c,env,_,_=setup('creation-stop-'+str(stop_status),{'absent':True,'create_stop_status':stop_status})
        result=subprocess.run(['bash','-c',script,'fixture','publish'],env=env,capture_output=True,text=True)
        (c/'interrupted.stdout').write_text(result.stdout)
        (c/'interrupted.stderr').write_text(result.stderr)
        check('strict creation '+str(stop_status)+' is terminal interrupted',result.returncode==5)
        details=json.loads(result.stdout)['details']
        rows=[json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]
        check('strict creation '+str(stop_status)+' makes no later remote request',
              '--post' in rows[-1] and sum('--post' in row for row in rows)==1 and
              not any(row[0]=='upload-boundary' or '--method' in row for row in rows))
        custody=Path(details['creation_custody_dir'])
        check('strict creation '+str(stop_status)+' keeps pending intent without inventing authority',
              details['interruption']==dict(stage='create',exit_code=stop_status,outcome='unconfirmed') and
              (custody/'creation-intent.json').is_file() and not list(custody.glob('dsr-api-response.*')) and
              json.loads((c/'remote.json').read_text())['draft'] is True and
              json.loads((c/'remote.json').read_text())['assets']==[])
        validator=Draft202012Validator(json.loads((root/'schemas/release-details.json').read_text()))
        check('strict creation '+str(stop_status)+' result satisfies release schema',not list(validator.iter_errors(details)))


def test_strict_publication_interruptions():
    for stop_status in interruption_statuses():
        for accepted in (False, True):
            label='publish-stop-'+str(stop_status)+('-accepted' if accepted else '-unaccepted')
            c,env,_,_=setup(label,{'absent':True,'publish_stop_status':stop_status,
                                  'publish_stop_before':not accepted})
            result=subprocess.run(['bash','-c',script,'fixture','publish'],env=env,capture_output=True,text=True)
            (c/'interrupted.stdout').write_text(result.stdout)
            (c/'interrupted.stderr').write_text(result.stderr)
            check(label+' is terminal interrupted',result.returncode==5)
            details=json.loads(result.stdout)['details']
            rows=[json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]
            patches=[row for row in rows if '--method' in row]
            check(label+' performs no remote work after the interrupted publish',
                  len(patches)==1 and rows[-1]==patches[0] and
                  json.loads(patches[0][patches[0].index('--data')+1])['draft'] is False and
                  json.loads((c/'remote.json').read_text())['draft'] is not accepted)
            response=Path(details['create_response']);original=response.read_bytes();identity=response.stat().st_ino
            check(label+' retains original authority and last observed visibility',
                  details['verification']=='interrupted' and details['draft'] is True and
                  details['interruption']==dict(stage='publish',exit_code=stop_status,outcome='unconfirmed') and
                  json.loads(original)['draft'] is True and json.loads(original)['assets']==[])
            validator=Draft202012Validator(json.loads((root/'schemas/release-details.json').read_text()))
            check(label+' result satisfies release schema',not list(validator.iter_errors(details)))
            controls=json.loads((c/'control.json').read_text())
            controls.pop('publish_stop_status');controls.pop('publish_stop_before')
            (c/'control.json').write_text(json.dumps(controls))
            offset=len(rows)
            env['TMPDIR']=details['finalization_tmpdir']
            resumed=subprocess.run(['bash','-c',script,'fixture','public-finalize','app','1.2.3',
                                    '--create-response',str(response),'--no-dispatch'],
                                   env=env,capture_output=True,text=True)
            (c/'resumed.stdout').write_text(resumed.stdout)
            (c/'resumed.stderr').write_text(resumed.stderr)
            later=[json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()][offset:]
            check(label+' explicitly finalizes the same retained release without reupload',
                  resumed.returncode==0 and json.loads((c/'remote.json').read_text())['draft'] is False and
                  sum('--method' in row for row in later)==(0 if accepted else 1) and
                  not any('--post' in row or row[0]=='upload-boundary' for row in later))
            check(label+' preserves the exact original response through recovery',
                  response.read_bytes()==original and response.stat().st_ino==identity)


def test_fallback_recovery(pagination_only=False, prerelease_only=False, interruption_only=False,
                           caller_interruption_only=False):
    run_id='11111111-1111-4111-8111-111111111111'
    missing='payload.tar.gz.sha256'

    def prepare(label,controls=None,custom=False,extra_assets=0,long_names=False):
        c,env,_,_=setup('fallback-'+label,dict(absent=True,**(controls or {})),extra_assets,long_names)
        # copytree preserves the base Git index's cached stat data. Refresh
        # this new fixture checkout so diff-index sees its actual clean tree.
        subprocess.run(['git','-C',str(c/'repo'),'update-index','--refresh'],check=True)
        config=c/'config/repos.d/app.yaml'
        data=json.loads(config.read_text())
        # These retained payloads model workflow outputs, not native compiler
        # execution. Keep the configured job and manifest inventory truthful
        # so real release admission does not require a fabricated Go receipt.
        data.update(language='go',act_job_map={'linux/amd64':'build'})
        config.write_text(json.dumps(data))
        artifacts=c/'state/artifacts/app-v1.2.3'
        manifest=artifacts/'app-v1.2.3-manifest.json'
        data=json.loads(manifest.read_text());data['run_id']=run_id
        data['requested_targets']=['linux/amd64']
        data['build_environments']=[{'target':'linux/amd64','method':'act','host':'act-local'}]
        manifest.write_text(json.dumps(data))
        artifacts.rename(c/'build-inputs')
        output=c/'custom release artifacts' if custom else artifacts
        return c,env,output

    def requests(c):
        return [json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]

    def mutations(rows):
        return [row for row in rows if '--post' in row or '--method' in row or row[0]=='upload-boundary']

    def invoke_fallback(c,env,output,resume=False,extra=(),label=None):
        args=['bash','-c',script,'fixture','fallback','--output-dir',str(output)]
        if resume:args+=['--resume='+run_id]
        args+=list(extra)
        before=len(requests(c))
        name=label or ('resumed' if resume else 'initial')
        stdout=c/(name+'.stdout');stderr=c/(name+'.stderr')
        # Preserve the current operation's diagnostics even when an outer
        # test deadline interrupts Python before subprocess.run returns.
        with stdout.open('w') as out, stderr.open('w') as err:
            result=subprocess.run(args,env=env,stdout=out,stderr=err,text=True)
        result.stdout=stdout.read_text();result.stderr=stderr.read_text()
        return result,requests(c)[before:]

    def interrupt_upload(label,custom=False,extra_assets=0,long_names=False,options=()):
        c,env,output=prepare(label,{'fail_upload_name':missing},custom,extra_assets,long_names)
        result,rows=invoke_fallback(c,env,output,extra=options)
        check(label+' initial publication interrupted',result.returncode!=0)
        details=json.loads(result.stdout)['details']
        if details.get('publication_recovery',{}).get('status')!='ready':
            print(result.stderr[-6000:],file=sys.stderr,flush=True)
        check(label+' original custody retained in durable handoff',
              details['publication_recovery']['status']=='ready' and
              details['publication_recovery']['build_run_id']==run_id and
              Path(details['publication_recovery']['intent']).is_relative_to(c/'state/releases') and
              len([row for row in rows if '--post' in row])==1 and
              json.loads((c/'remote.json').read_text())['draft'] is True)
        return c,env,output,details['publication_recovery']

    if caller_interruption_only:
        selected=os.environ.get('DSR_TEST_FALLBACK_CALLER_INTERRUPTION_CASE','all')
        if selected not in ('all','release','tag','scan','inventory','download'):
            raise AssertionError('Select a known fallback caller interruption case')
        for stop_status in interruption_statuses():
            for boundary in ('release','tag','scan','inventory','download'):
                if selected not in ('all',boundary):
                    continue
                label='caller-'+boundary+'-'+str(stop_status)
                if boundary=='release':
                    c,env,output=prepare(label,{'upload_stop_status':stop_status,'upload_stop_name':missing})
                    result,rows=invoke_fallback(c,env,output,label='interrupted')
                    details=json.loads(result.stdout)['details']
                    intent=Path(details['publication_recovery']['intent'])
                    responses=list(intent.parent.glob('dsr-create-custody.*/dsr-api-response.????????'))
                    check(label+' normalizes the stopped release to fallback interruption',
                          result.returncode==5 and details['phases']['release']=='failed' and
                          details['interruption']==dict(stage='upload',exit_code=stop_status,outcome='unconfirmed') and
                          str(stop_status) in details['error'])
                    check(label+' never captures or reads remotely after the stopped upload',
                          rows[-1]==json.loads((c/'stopped-request.json').read_text()) and
                          rows[-1][0]=='upload-boundary' and
                          not (intent.parent/'custody.json').exists())
                    check(label+' retains the original creation response and prepared handoff',
                          len(responses)==1 and responses[0].is_file() and
                          details['publication_recovery']['status']=='prepared' and
                          len([row for row in rows if '--post' in row])==1 and
                          json.loads((c/'remote.json').read_text())['draft'] is True)
                else:
                    c,env,output,recovery=interrupt_upload(label)
                    response=Path(recovery['create_response'])
                    original=response.read_bytes();original_inode=response.stat().st_ino
                    intent=Path(recovery['intent']);original_intent=intent.read_bytes()
                    controls={'helper_stop_boundary':boundary,'helper_stop_status':stop_status}
                    # Skip the early expected-tag lookup and preparation's
                    # source checks to stop inside custody preflight itself.
                    if boundary=='tag':controls['helper_stop_skip']=3
                    (c/'control.json').write_text(json.dumps(controls))
                    result,rows=invoke_fallback(c,env,output,True,label='interrupted')
                    details=json.loads(result.stdout)['details']
                    check(label+' preserves terminal inspection as fallback interruption',
                          result.returncode==5 and str(stop_status) in details['error'] and
                          details['interruption']['exit_code']==stop_status and
                          details['interruption']['outcome']=='unconfirmed')
                    check(label+' performs no later reconciliation or publication request',
                          rows[-1]==json.loads((c/'stopped-request.json').read_text()) and not mutations(rows))
                    check(label+' preserves original custody without upgrading recovery',
                          response.read_bytes()==original and response.stat().st_ino==original_inode and
                          intent.read_bytes()==original_intent and
                          details['publication_recovery']['status'] in ('prepared','ready') and
                          json.loads((c/'remote.json').read_text())['draft'] is True)
                validator=Draft202012Validator(json.loads((root/'schemas/fallback-details.json').read_text()))
                check(label+' interrupted result satisfies fallback schema',not list(validator.iter_errors(details)))
        return

    if interruption_only:
        for stop_status in interruption_statuses():
            label='repair-stop-'+str(stop_status)
            c,env,output,recovery=interrupt_upload(label)
            response=Path(recovery['create_response'])
            original=response.read_bytes();original_inode=response.stat().st_ino
            intent=Path(recovery['intent']);original_intent=intent.read_bytes()
            (c/'control.json').write_text(json.dumps({'upload_stop_status':stop_status,'upload_stop_name':missing}))
            result,rows=invoke_fallback(c,env,output,True,label='interrupted')
            check(label+' remains interrupted after server accepts the asset',result.returncode==5)
            details=json.loads(result.stdout)['details']
            check(label+' stops before remote reconciliation and finalization',
                  [row for row in rows if row[0]=='upload-boundary']==[rows[-1]] and
                  not any('--post' in row or '--method' in row for row in rows) and
                  details['phases']['release']=='failed' and
                  details['publication_recovery']['status']=='ready' and
                  json.loads((c/'remote.json').read_text())['draft'] is True)
            check(label+' keeps exact original response and recovery intent',
                  response.read_bytes()==original and response.stat().st_ino==original_inode and
                  intent.read_bytes()==original_intent)
            (c/'control.json').write_text('{}')
            resumed,rows=invoke_fallback(c,env,output,True,label='explicit-resume')
            check(label+' explicit resume verifies committed bytes without reuploading',
                  resumed.returncode==0 and not any('--post' in row or row[0]=='upload-boundary' for row in rows) and
                  json.loads(resumed.stdout)['details']['publication_recovery']['status']=='finalized' and
                  json.loads((c/'remote.json').read_text())['draft'] is False and
                  response.read_bytes()==original and response.stat().st_ino==original_inode)
        return

    if prerelease_only:
        selected=os.environ.get('DSR_TEST_STRICT_PRERELEASE_CASE','all')
        if selected not in ('all','plan','new','recovery','stable','drift') or (
                selected!='all' and os.environ.get('DSR_TEST_STRICT_PRERELEASE_ONLY')!='1'):
            raise AssertionError('Select a known prerelease case together with DSR_TEST_STRICT_PRERELEASE_ONLY=1')
        if selected in ('all','plan'):
            c,env,output=prepare('prerelease-plan')
            result,rows=invoke_fallback(c,env,output,extra=['--prerelease','--dry-run'])
            check('explicit prerelease planning succeeds',result.returncode==0)
            details=json.loads(result.stdout)['details']
            check('prerelease plan retains selected and requested modes',
                  details['prerelease'] is True and details['prerelease_requested'] is True)
            check('prerelease plan performs no build or publication mutation',
                  not output.exists() and not (c/'build-calls').exists() and not mutations(rows))

        if selected in ('all','new'):
            c,env,output=prepare('prerelease-fresh')
            result,rows=invoke_fallback(c,env,output,extra=['--prerelease'])
            check('new strict prerelease publishes successfully',result.returncode==0)
            details=json.loads(result.stdout)['details']
            recovery=details['publication_recovery']
            intent=Path(recovery['intent'])
            response=Path(recovery['create_response'])
            original=response.read_bytes();original_inode=response.stat().st_ino
            remote=json.loads((c/'remote.json').read_text())
            posts=[json.loads(row[row.index('--post')+1]) for row in rows if '--post' in row]
            check('new strict prerelease creation and original intent select prerelease',
                  len(posts)==1 and posts[0]['prerelease'] is True and
                  json.loads(intent.read_text())['prerelease'] is True and
                  json.loads(original)['prerelease'] is True)
            check('new strict prerelease result and remote metadata prove public prerelease',
                  details['prerelease'] is True and details['prerelease_requested'] is True and
                  remote['draft'] is False and remote['prerelease'] is True)
            result,rows=invoke_fallback(c,env,output,True,['--prerelease'])
            check('completed prerelease retry preserves mode without compilation or publication mutation',
                  result.returncode==0 and not mutations(rows) and
                  (c/'build-calls').read_text().splitlines().count('build')==1 and
                  response.read_bytes()==original and response.stat().st_ino==original_inode)
            details=json.loads(result.stdout)['details']
            final=json.loads(Path(details['publication_recovery']['finalization_receipt']).read_text())
            check('completed prerelease retry retains a matching signed finalization receipt',
                  details['prerelease'] is True and details['prerelease_requested'] is True and
                  final['release']['draft'] is False and final['release']['prerelease'] is True)

        if selected in ('all','recovery'):
            c,env,output,recovery=interrupt_upload('prerelease-interrupted',options=['--prerelease'])
            response=Path(recovery['create_response'])
            original=response.read_bytes();original_inode=response.stat().st_ino
            intent=Path(recovery['intent']);intent_bytes=intent.read_bytes()
            check('interrupted strict prerelease retains requested mode in original custody',
                  json.loads(original)['prerelease'] is True and json.loads(intent_bytes)['prerelease'] is True)
            (c/'control.json').write_text('{}')
            result,rows=invoke_fallback(c,env,output,True,label='omitted-prerelease')
            check('omitting prerelease on strict recovery refuses before mutation',
                  result.returncode!=0 and not mutations(rows) and
                  (c/'build-calls').read_text().splitlines().count('build')==1 and
                  response.read_bytes()==original and response.stat().st_ino==original_inode and
                  intent.read_bytes()==intent_bytes and json.loads((c/'remote.json').read_text())['draft'] is True)
            remote=json.loads((c/'remote.json').read_text());remote['prerelease']=False
            (c/'remote.json').write_text(json.dumps(remote))
            result,rows=invoke_fallback(c,env,output,True,['--prerelease'],label='remote-mode-drift')
            check('changed remote prerelease mode blocks recovery before upload or publication',
                  result.returncode!=0 and not mutations(rows) and
                  response.read_bytes()==original and intent.read_bytes()==intent_bytes and
                  (c/'build-calls').read_text().splitlines().count('build')==1)
            remote['prerelease']=True
            (c/'remote.json').write_text(json.dumps(remote))
            result,rows=invoke_fallback(c,env,output,True,['--prerelease'],label='matching-prerelease')
            check('matching strict prerelease recovers only missing bytes and publishes',
                  result.returncode==0 and [row[2] for row in rows if row[0]=='upload-boundary']==[missing] and
                  not any('--post' in row for row in rows) and
                  json.loads((c/'remote.json').read_text())['draft'] is False and
                  json.loads((c/'remote.json').read_text())['prerelease'] is True)
            details=json.loads(result.stdout)['details']
            final=json.loads(Path(details['publication_recovery']['finalization_receipt']).read_text())
            check('recovered prerelease result and final receipt retain selection',
                  details['prerelease'] is True and details['prerelease_requested'] is True and
                  final['release']['prerelease'] is True and response.read_bytes()==original and
                  response.stat().st_ino==original_inode and intent.read_bytes()==intent_bytes and
                  (c/'build-calls').read_text().splitlines().count('build')==1)

        if selected in ('all','stable'):
            c,env,output,recovery=interrupt_upload('stable-mode-interrupted')
            response=Path(recovery['create_response']);original=response.read_bytes()
            (c/'control.json').write_text('{}')
            result,rows=invoke_fallback(c,env,output,True,['--prerelease'])
            check('switching a retained stable attempt to prerelease refuses before mutation',
                  result.returncode!=0 and not mutations(rows) and response.read_bytes()==original and
                  json.loads((c/'remote.json').read_text())['prerelease'] is False and
                  json.loads((c/'remote.json').read_text())['draft'] is True and
                  (c/'build-calls').read_text().splitlines().count('build')==1)

        if selected in ('all','drift'):
            c,env,output=prepare('prerelease-public-drift',{'prerelease_drift_after_publish':True})
            result,rows=invoke_fallback(c,env,output,extra=['--prerelease'])
            check('public prerelease metadata drift cannot report successful publication',
                  result.returncode!=0 and json.loads(result.stdout)['details']['phases']['release']!='success')
            patches=[row for row in rows if '--method' in row]
            check('public mode drift restores only the original owned release to draft',
                  any(json.loads(row[row.index('--data')+1]).get('draft') is False for row in patches) and
                  any(json.loads(row[row.index('--data')+1]).get('draft') is True for row in patches) and
                  all(row[0]=='repos/owner/app/releases/9' for row in patches) and
                  json.loads((c/'remote.json').read_text())['draft'] is True)
        return

    if pagination_only:
        # 201 assets, including a real signed aggregate and primary pair. Long
        # literal names make the actual frozen preflight/creation plan exceed
        # the single-argument limit independently of GitHub response padding.
        missing='SHA256SUMS.minisig'
        c,env,output,recovery=interrupt_upload('paginated-201',extra_assets=196,long_names=True)
        response=Path(recovery['create_response']);original=response.read_bytes();inode=response.stat().st_ino
        creation=response.parent/'creation-intent.json'
        selected=json.loads(creation.read_text())['plan']
        check('large strict preflight and creation preserve the complete streamed plan',
              len(selected['assets'])==201 and len(json.dumps(selected).encode())>131072)
        check('interrupted large draft has exactly two full pages before repair',
              len(json.loads((c/'remote.json').read_text())['assets'])==200)
        for fault in ['failed-page','malformed-page','extra','duplicate-id','duplicate-name','case-alias']:
            (c/'control.json').write_text(json.dumps({'inventory_fault':fault}))
            result,rows=invoke_fallback(c,env,output,True,label='refused-'+fault)
            check('large recovery refuses '+fault+' without remote mutation or compiler retry',
                  result.returncode!=0 and not mutations(rows) and
                  (c/'build-calls').read_text().splitlines().count('build')==1 and
                  response.read_bytes()==original and response.stat().st_ino==inode)
        (c/'control.json').write_text('{}')
        result,rows=invoke_fallback(c,env,output,True,label='large-resumed')
        if result.returncode:
            raise AssertionError('large strict resume: '+result.stderr[-6000:])
        details=json.loads(result.stdout)['details']
        receipt=json.loads(Path(details['publication_recovery']['finalization_receipt']).read_text())
        check('large recovery uploads only the missing signed asset and publishes the original ID',
              [row[2] for row in rows if row[0]=='upload-boundary']==[missing] and
              not any('--post' in row for row in rows) and receipt['release_id']==9 and
              receipt['release']['draft'] is False and len(receipt['release']['assets'])==201)
        check('large recovery observes all pages including empty page three at the exact200 boundary',
              any(row[0].endswith('assets?per_page=100&page=3') for row in requests(c)))
        check('large recovery retains complete plan, original custody and the single successful build',
              len(receipt['plan']['assets'])==201 and response.read_bytes()==original and
              response.stat().st_ino==inode and (c/'build-calls').read_text().splitlines().count('build')==1)
        for fault in ['missing-last','failed-page','malformed-page','extra','duplicate-id','duplicate-name',
                      'case-alias','late-change']:
            (c/'control.json').write_text(json.dumps({'inventory_fault':fault}))
            start=len(requests(c))
            result,_=invoke(c,dict(env,TMPDIR=recovery['finalization_tmpdir']),response)
            rows=requests(c)[start:]
            check('complete large finalization refuses '+fault+' before publication',
                  result.returncode!=0 and not mutations(rows))
        for fault in ['duplicate','malformed']:
            (c/'control.json').write_text(json.dumps({'embedded_fault':fault}))
            start=len(requests(c))
            result,_=invoke(c,dict(env,TMPDIR=recovery['finalization_tmpdir']),response)
            check('large finalization refuses '+fault+' embedded metadata',
                  result.returncode!=0 and not mutations(requests(c)[start:]))
        return

    for label,options,configured,expected in [
            ('explicit-sbom',['--sbom'],False,4),
            ('configured-sbom',[],True,4),
            ('configured-sbom-disabled',['--no-sbom','--dry-run'],True,0)]:
        c,env,output=prepare(label)
        if configured:(c/'config/config.yaml').write_text(json.dumps({'sbom':{'enabled':True}}))
        result,rows=invoke_fallback(c,env,output,extra=options)
        check(label+' honors strict SBOM policy before build',result.returncode==expected and
              not output.exists() and not (c/'build-calls').exists() and not mutations(rows))

    c,env,output=prepare('wrong-source-origin')
    subprocess.run(['git','-C',str(c/'repo'),'remote','set-url','origin','https://github.com/other/app.git'],check=True)
    result,rows=invoke_fallback(c,env,output)
    check('wrong source origin refuses before strict creation',result.returncode!=0 and not mutations(rows))

    for label in ['missing-upload','lost-upload-and-patch','custom-isolated']:
        c,env,output,recovery=interrupt_upload(label,custom=label=='custom-isolated')
        response=Path(recovery['create_response'])
        original=response.read_bytes();original_inode=response.stat().st_ino
        manifest=output/'app-v1.2.3-manifest.json';manifest_bytes=manifest.read_bytes()
        control={'lost_upload_name':missing,'lost_patch':True} if label=='lost-upload-and-patch' else {}
        (c/'control.json').write_text(json.dumps(control))
        extra=[]
        if label=='custom-isolated':
            source=c/'repo'
            (source/'README.md').write_text('Newer committed development source\n')
            subprocess.run(['git','-C',str(source),'commit','-am','newer source','-q'],check=True)
            (source/'README.md').write_text('Uncommitted user work\n')
            development_head=subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True)
            extra=['--isolate-source']
        result,rows=invoke_fallback(c,env,output,True,extra)
        check(label+' resume publishes successfully',result.returncode==0)
        details=json.loads(result.stdout)['details']
        check(label+' finalizer success is retained and public',
              details['publication_recovery']['status']=='finalized' and
              Path(details['publication_recovery']['finalization_receipt']).is_file() and
              details['phases']['release']=='success' and
              json.loads((c/'remote.json').read_text())['draft'] is False)
        check(label+' only missing bytes uploaded without a new POST',
              [row[2] for row in rows if row[0]=='upload-boundary']==[missing] and
              not any('--post' in row for row in rows))
        check(label+' compiler and original custody remain unchanged',
              (c/'build-calls').read_text().splitlines().count('build')==1 and
              response.read_bytes()==original and response.stat().st_ino==original_inode and
              manifest.read_bytes()==manifest_bytes)
        check(label+' recovery never dispatches',not any('/dispatches' in row[0] for row in rows))
        caches=list(Path(recovery['intent']).parent.glob('verify.*'))
        check(label+' verified download storage is bounded to one copy per asset',
              len(caches)==1 and
              len([path for path in caches[0].iterdir() if path.suffix!='.json'])==
              len(json.loads((c/'remote.json').read_text())['assets']))
        validator=Draft202012Validator(json.loads((root/'schemas/fallback-details.json').read_text()))
        check(label+' recovery result satisfies fallback JSON schema',not list(validator.iter_errors(details)))
        if label=='custom-isolated':
            check('isolated recovery preserves advanced dirty user checkout',
                  (source/'README.md').read_text()=='Uncommitted user work\n' and
                  subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True)==development_head)
        # A narrow rerun validates policy, provenance, retained-byte bounds
        # and the real publication lifecycle without repeating all drift cases.
        if os.environ.get('DSR_TEST_STRICT_FALLBACK_SMOKE_ONLY')=='1':return

    for label,controls in [('failed-publish',{'fail_publish':True}),('already-public',{})]:
        c,env,output=prepare(label,controls)
        initial,_=invoke_fallback(c,env,output)
        check(label+' expected initial outcome',(initial.returncode==0)==(label=='already-public'))
        (c/'control.json').write_text('{}')
        result,rows=invoke_fallback(c,env,output,True)
        check(label+' completed artifacts recover to public success',result.returncode==0 and
              json.loads((c/'remote.json').read_text())['draft'] is False)
        check(label+' no duplicate creation upload or compilation',
              not any('--post' in row or row[0]=='upload-boundary' for row in rows) and
              (c/'build-calls').read_text().splitlines().count('build')==1)
        check(label+' expected publication mutation',
              sum('--method' in row for row in rows)==(1 if label=='failed-publish' else 0))

    # Kill only the isolated process group created for this fixture, after the
    # real adapter retained its POST and before fallback can write custody.json.
    c,env,output=prepare('killed-after-post',{'pause_upload':True})
    args=['bash','-c',script,'fixture','fallback','--output-dir',str(output)]
    with (c/'killed.stdout').open('wb') as stdout,(c/'killed.stderr').open('wb') as stderr:
        process=subprocess.Popen(args,env=env,stdout=stdout,stderr=stderr,start_new_session=True)
        deadline=time.monotonic()+30
        while not (c/'upload-paused').exists() and process.poll() is None and time.monotonic()<deadline:
            time.sleep(0.05)
        paused=(c/'upload-paused').exists()
        if process.poll() is None:os.killpg(process.pid,signal.SIGKILL)
        process.wait(timeout=10)
    check('hard interruption reaches real post-custody upload boundary',paused)
    parents=list((c/'state/releases').glob('dsr-fallback.*'))
    check('hard interruption keeps original POST without completed fallback binding',
          len(parents)==1 and not (parents[0]/'custody.json').exists() and
          len(list(parents[0].glob('dsr-create-custody.*/dsr-api-response.????????')))==1)
    (c/'control.json').write_text('{}')
    result,rows=invoke_fallback(c,env,output,True)
    check('hard interruption resumes all missing assets and finalizes',result.returncode==0 and
          json.loads((c/'remote.json').read_text())['draft'] is False)
    check('hard interruption preserves original creation and completed build',
          not any('--post' in row for row in rows) and
          (c/'build-calls').read_text().splitlines().count('build')==1)

    for label in ['missing-original','replaced-original','creation-intent-drift','private-permissions',
                  'config-drift','manifest-drift','signature-drift','foreign-metadata','extra-asset',
                  'wrong-upload-url','remote-byte-corruption','remote-digest-mismatch','tag-drift']:
        c,env,output,recovery=interrupt_upload(label)
        response=Path(recovery['create_response'])
        control={}
        if label=='missing-original':response.rename(response.with_name(response.name+'.retained'))
        elif label=='replaced-original':
            retained=response.with_name(response.name+'.retained');response.rename(retained)
            response.write_bytes(retained.read_bytes());response.chmod(0o600)
        elif label=='creation-intent-drift':
            path=response.parent/'creation-intent.json'
            data=json.loads(path.read_text());data['plan']['release']['body']+='changed'
            path.write_text(json.dumps(data))
        elif label=='private-permissions':response.chmod(0o644)
        elif label=='config-drift':
            path=c/'config/repos.d/app.yaml';path.write_text(path.read_text()+'\n')
        elif label=='manifest-drift':
            path=output/'app-v1.2.3-manifest.json';path.write_text(path.read_text()+'\n')
        elif label=='signature-drift':(output/'payload.tar.gz.minisig').write_text('invalid signature\n')
        elif label=='tag-drift':control['tag_drift_always']=True
        else:
            path=c/'remote.json';data=json.loads(path.read_text())
            if label=='foreign-metadata':data['body']='A different publication owner'
            elif label=='extra-asset':data['assets'].append(dict(data['assets'][0],id=999,name='unexpected.bin'))
            elif label=='wrong-upload-url':data['upload_url']='https://uploads.github.com/repos/owner/other/releases/9/assets{?name,label}'
            elif label=='remote-digest-mismatch':data['assets'][0]['digest']='sha256:'+'f'*64
            elif label=='remote-byte-corruption':
                remote=c/'bytes'/str(data['assets'][0]['id'])
                content=bytearray(remote.read_bytes());content[0]^=1;remote.write_bytes(content)
            path.write_text(json.dumps(data))
        (c/'control.json').write_text(json.dumps(control))
        result,rows=invoke_fallback(c,env,output,True)
        check(label+' refuses automatic recovery',result.returncode!=0)
        check(label+' no remote mutation or rebuild',not mutations(rows) and
              (c/'build-calls').read_text().splitlines().count('build')==1)

    c,env,output=prepare('unrelated-draft')
    (c/'control.json').write_text('{}')
    for resume in [False,True]:
        result,rows=invoke_fallback(c,env,output,resume)
        check('unrelated draft '+('retry' if resume else 'creation')+' is not adopted',
              result.returncode!=0 and not mutations(rows))

def test_strict_finalization_custody():
    names=('prune','canonical','bare','inherited','caller-flag','fallback',
           'early-error','dry-run','cleanup-error')
    selected=os.environ.get('DSR_TEST_STRICT_CUSTODY_CASE','')
    if selected and (selected not in names or os.environ.get('DSR_TEST_STRICT_CUSTODY_ONLY')!='1'):
        raise AssertionError('Select a known custody case together with DSR_TEST_STRICT_CUSTODY_ONLY=1')

    def inventory(*roots):
        rows=[]
        for root_path in roots:
            paths=[root_path]+(sorted(root_path.rglob('*')) if root_path.is_dir() else [])
            for path in paths:
                if not path.exists() and not path.is_symlink():
                    rows.append((str(path),None));continue
                info=path.lstat()
                content=(os.readlink(path) if stat.S_ISLNK(info.st_mode) else
                         hashlib.sha256(path.read_bytes()).hexdigest() if stat.S_ISREG(info.st_mode) else '')
                rows.append((str(path),info.st_dev,info.st_ino,info.st_mode,info.st_nlink,
                             info.st_uid,info.st_gid,info.st_mtime_ns,info.st_ctime_ns,content))
        return rows

    def lease_available(c,version):
        lease=c/'state/builds/app'/version/'.lock.lease'
        if not lease.exists():return True
        with lease.open('r+b') as stream:
            try:fcntl.flock(stream,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except OSError as error:
                if error.errno in (errno.EAGAIN,errno.EACCES):return False
                raise
        return True

    def until(predicate,seconds=20):
        deadline=time.monotonic()+seconds
        while not predicate():
            if time.monotonic()>=deadline:raise AssertionError('Strict custody fixture barrier timed out')
            time.sleep(0.02)

    def prepare(label):
        c,env,_,_=setup('custody-'+label,{'absent':True})
        created=subprocess.run(['bash','-c',script,'fixture','create'],env=env,capture_output=True,text=True)
        (c/'producer.stdout').write_text(created.stdout);(c/'producer.stderr').write_text(created.stderr)
        check(label+' actual signed draft producer succeeds',created.returncode==0)
        details=json.loads(created.stdout)['details']
        response=Path(details['create_response']);env['TMPDIR']=details['finalization_tmpdir']
        # Retain the completed producer's closed lease history separately so
        # this standalone finalizer's own acquisitions are directly observable.
        if (c/'state/builds').exists():(c/'state/builds').rename(c/'producer-build-custody')
        (c/'cache').mkdir()
        (c/'requests.jsonl').write_text('')
        return c,env,response

    def run_finalizer(c,env,response,driver=script,extra=()):
        args=(['bash','-c',driver,'fixture','run','false'] if driver==script else
              ['bash','-c',driver,'fixture'])
        result=subprocess.run(args+['app','1.2.3','--create-response',str(response),'--no-dispatch']+
                              list(extra),env=env,capture_output=True,text=True,timeout=40)
        (c/'finalizer.stdout').write_text(result.stdout);(c/'finalizer.stderr').write_text(result.stderr)
        return result

    holder_script=r'''
set -uo pipefail
source "$ROOT/src/build_state.sh"
fixture_barrier() {
    local count=0
    while [[ ! -e "$CASE/$1" ]]; do
        ((count+=1)); ((count<=1500)) || return 93
        sleep 0.02
    done
}
build_state_init || exit $?
build_lock_acquire app "$1" || exit $?
if [[ "$2" == inherited ]]; then
    (
        : > "$CASE/holder-ready"
        fixture_barrier holder-release || exit $?
        : > "$CASE/holder-finished"
    ) &
    fixture_barrier holder-ready || exit $?
    build_lock_release app "$1" || exit $?
else
    : > "$CASE/holder-ready"
    fixture_barrier holder-release || exit $?
    build_lock_release app "$1" || exit $?
fi
'''
    common=script.split('\nif [[ "$1" == create',1)[0]
    borrowed_driver=common+r'''
JSON_MODE=true
build_state_init || exit $?
build_lock_acquire app v1.2.3 || exit $?
trap 'printf "caller exit\n" >> "$CASE/caller-exit"' EXIT
trap -p EXIT > "$CASE/caller-trap.before"
caller_snapshot() {
    declare -p _BUILD_LOCK_PATHS _BUILD_LOCK_FDS _BUILD_LOCK_IDENTITIES \
        _BUILD_LOCK_OWNERS _BUILD_LOCK_RECORDS
    _build_state_file_identity "$DSR_STATE_DIR/builds/app/v1.2.3/.lock"
    _build_state_file_identity "$DSR_STATE_DIR/builds/app/v1.2.3/.lock.lease"
    cat "$DSR_STATE_DIR/builds/app/v1.2.3/.lock"
}
caller_snapshot > "$CASE/caller-custody.before"
export DSR_BUILD_LOCK_HELD_BY_CALLER=1
result=$(cmd_release_finalize "$@")
status=$?
printf '%s\n' "$result"
trap -p EXIT > "$CASE/caller-trap.after"
caller_snapshot > "$CASE/caller-custody.after"
[[ ! -e "$CASE/caller-exit" ]] || exit 94
probe=0; _build_lock_probe "$DSR_STATE_DIR/builds/app/v1.2.3/.lock" || probe=$?
[[ "$probe" == 2 ]] || exit 95
probe=0; _build_lock_probe "$DSR_STATE_DIR/builds/app/1.2.3/.lock" || probe=$?
[[ "$probe" == 0 ]] || exit 96
build_lock_release app v1.2.3 || exit 97
exit "$status"
'''

    for name in names:
        if selected and name!=selected:continue
        c,env,response=prepare(name)
        artifacts=c/'state/artifacts/app-v1.2.3'
        if name=='prune':
            sidecar=artifacts.with_name(artifacts.name+'-manifest.json')
            sidecar.write_bytes((artifacts/'app-v1.2.3-manifest.json').read_bytes())
            old=time.time()-60*86400
            for path in (artifacts,sidecar):os.utime(path,(old,old))
            control=json.loads((c/'control.json').read_text());control['pause_finalizer']=True
            (c/'control.json').write_text(json.dumps(control))
            before=inventory(artifacts,sidecar)
            args=['bash','-c',script,'fixture','run','false','app','1.2.3',
                  '--create-response',str(response),'--no-dispatch']
            with (c/'finalizer.stdout').open('w') as out,(c/'finalizer.stderr').open('w') as err:
                publisher=subprocess.Popen(args,env=env,stdout=out,stderr=err)
                try:
                    until(lambda:(c/'finalizer-paused').exists() or publisher.poll() is not None)
                    check('active finalizer reaches actual pending-receipt boundary',(c/'finalizer-paused').exists())
                    # Retention policy is deliberately disabled. Active custody
                    # must still protect a selected old release from deletion.
                    pruned=subprocess.run([str(root/'dsr'),'--json','--state-dir',str(c/'state'),
                        '--cache-dir',str(c/'cache'),'prune','--max-age','30','--keep-last','0',
                        '--no-keep-releases','--force'],env=env,capture_output=True,text=True,timeout=15)
                    (c/'prune.stdout').write_text(pruned.stdout);(c/'prune.stderr').write_text(pruned.stderr)
                    retained=inventory(artifacts,sidecar)==before
                finally:
                    (c/'continue-finalizer').write_text('continue\n')
                    status=publisher.wait(timeout=30)
            check('prune preserves complete active finalization inputs',pruned.returncode==0 and retained)
            details=json.loads(pruned.stdout)['details']
            check('prune reports active finalizer build custody',
                  any(row['path']==str(artifacts) and row['reason']=='build_custody'
                      for row in details['retained_artifact_paths']) and
                  all(row['path'] not in (str(artifacts),str(sidecar)) for row in details['pruned_paths']))
            check('protected strict finalization publishes successfully',status==0 and
                  json.loads((c/'remote.json').read_text())['draft'] is False)
        elif name in ('canonical','bare','inherited','caller-flag'):
            version='1.2.3' if name=='bare' else 'v1.2.3'
            mode='inherited' if name=='inherited' else 'coordinator'
            before=inventory(artifacts)
            if name=='caller-flag':env['DSR_BUILD_LOCK_HELD_BY_CALLER']='1'
            with (c/'holder.stdout').open('w') as out,(c/'holder.stderr').open('w') as err:
                holder=subprocess.Popen(['bash','-c',holder_script,'fixture',version,mode],env=env,stdout=out,stderr=err)
                try:
                    until(lambda:(c/'holder-ready').exists() or holder.poll() is not None)
                    check(name+' genuine lease holder is ready',(c/'holder-ready').exists())
                    if mode=='inherited':
                        check('inherited worker retains custody after coordinator exit',
                              holder.wait(timeout=10)==0 and not lease_available(c,version))
                    driver=(common+'\nJSON_MODE=true\ncmd_release_finalize "$@"\n' if name=='canonical' else script)
                    result=run_finalizer(c,env,response,driver)
                finally:
                    (c/'holder-release').write_text('continue\n')
                    holder.wait(timeout=10)
                    if mode=='inherited':until(lambda:(c/'holder-finished').exists() and lease_available(c,version))
            check(name+' contention blocks finalization before the API',result.returncode==2 and
                  not (c/'requests.jsonl').read_text() and inventory(artifacts)==before and
                  json.loads((c/'remote.json').read_text())['draft'] is True)
            if name=='canonical':
                envelope=json.loads(result.stdout)
                check('canonical contention emits exactly one precise JSON refusal',
                      envelope['command']=='release-finalize' and envelope['status']=='error' and
                      envelope['exit_code']==2 and envelope['details']['stage']=='build_custody' and
                      envelope['details']['lease_version']=='v1.2.3' and
                      isinstance(envelope['details']['error'],str) and bool(envelope['details']['error']))
        elif name=='fallback':
            result=run_finalizer(c,env,response,borrowed_driver)
            check('inherited fallback custody permits strict finalization',result.returncode==0 and
                  json.loads(result.stdout)['status']=='success' and
                  json.loads((c/'remote.json').read_text())['draft'] is False)
            check('borrowed finalizer preserves caller registry inode and owner record',
                  (c/'caller-custody.before').read_bytes()==(c/'caller-custody.after').read_bytes())
            check('borrowed finalizer preserves and does not prematurely run caller EXIT trap',
                  (c/'caller-trap.before').read_bytes()==(c/'caller-trap.after').read_bytes() and
                  (c/'caller-exit').read_text()=='caller exit\n')
        elif name=='early-error':
            with (artifacts/'payload.tar.gz').open('ab') as stream:stream.write(b'changed after signed publication\n')
            result=run_finalizer(c,env,response)
            check('invalid signed input is refused before the API',result.returncode==4 and
                  not (c/'requests.jsonl').read_text())
            check('early refusal acquired both leases before artifact admission',
                  all((c/'state/builds/app'/version/'.lock.lease').is_file() for version in ('v1.2.3','1.2.3')))
        elif name=='dry-run':
            before=inventory(c/'state',c/'cache')
            result=subprocess.run(['bash','-c',script,'fixture','run','true','app','1.2.3',
                '--create-response',str(response),'--no-dispatch'],env=env,capture_output=True,text=True,timeout=40)
            (c/'finalizer.stdout').write_text(result.stdout);(c/'finalizer.stderr').write_text(result.stderr)
            requests=[json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]
            check('dry-run verifies its plan without custody or persistent state changes',result.returncode==0 and
                  inventory(c/'state',c/'cache')==before and
                  not any('--post' in row or '--method' in row or row[0]=='upload-boundary' for row in requests))
        else:
            control=json.loads((c/'control.json').read_text());control['change_finalizer_lease']=True
            (c/'control.json').write_text(json.dumps(control))
            result=run_finalizer(c,env,response,common+'\nJSON_MODE=true\ncmd_release_finalize "$@"\n')
            check('cleanup fault changes actual held finalizer metadata',(c/'original-finalizer-lease').is_file() and
                  (c/'state/builds/app/v1.2.3/.lock').read_text()=='changed fixture custody record\n')
            envelope=json.loads(result.stdout)
            details=envelope.get('details',{});receipt=Path(details.get('receipt',''));record={}
            if receipt.parent==c/'state/releases' and receipt.is_file() and not receipt.is_symlink():
                record=json.loads(receipt.read_text())
            check('unverifiable cleanup emits exactly one error with its completed publication receipt',
                  result.returncode==4 and 'Strict release finalized and verified:' not in result.stderr and
                  envelope['command']=='release-finalize' and envelope['status']=='error' and
                  envelope['exit_code']==4 and details.get('stage')=='build_custody' and
                  isinstance(details.get('error'),str) and bool(details['error']) and
                  details.get('release_id')==9 and record.get('status')=='success' and
                  record.get('release_id')==9 and record.get('release',{}).get('draft') is False)
        check(name+' leaves no independently held finalizer lease',
              lease_available(c,'v1.2.3') and lease_available(c,'1.2.3'))


def test_standalone_finalization_interruptions():
    names=('publish-accepted','publish-unaccepted')
    selected=os.environ.get('DSR_TEST_STANDALONE_FINALIZE_CASE','')
    if selected and (selected not in names or os.environ.get('DSR_TEST_STANDALONE_FINALIZE_INTERRUPTION_ONLY')!='1'):
        raise AssertionError('Select a known standalone finalizer interruption case together with its focused lane')
    for stop_status in interruption_statuses():
        for name in names:
            if selected and name!=selected:continue
            accepted=name=='publish-accepted'
            label='standalone-'+name+'-'+str(stop_status)
            c,env,_,_=setup(label,{'absent':True})
            created=subprocess.run(['bash','-c',script,'fixture','create'],
                                   env=env,capture_output=True,text=True,timeout=120)
            (c/'producer.stdout').write_text(created.stdout);(c/'producer.stderr').write_text(created.stderr)
            check(label+' uses the actual signed draft producer',created.returncode==0)
            details=json.loads(created.stdout)['details']
            response=Path(details['create_response']);env['TMPDIR']=details['finalization_tmpdir']
            original=response.read_bytes();identity=(response.stat().st_dev,response.stat().st_ino)
            controls=json.loads((c/'control.json').read_text())
            controls.update(publish_stop_status=stop_status,publish_stop_before=not accepted)
            (c/'control.json').write_text(json.dumps(controls));(c/'requests.jsonl').write_text('')
            args=['bash','-c',script,'fixture','public-finalize','app','1.2.3',
                  '--create-response',str(response),'--no-dispatch']
            result=subprocess.run(args,env=env,capture_output=True,text=True,timeout=120)
            (c/'interrupted.stdout').write_text(result.stdout);(c/'interrupted.stderr').write_text(result.stderr)
            check(label+' is terminal interrupted',result.returncode==5)
            envelope=json.loads(result.stdout);details=envelope['details']
            rows=[json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]
            patches=[row for row in rows if '--method' in row]
            check(label+' stops at the interrupted publication boundary',
                  len(patches)==1 and rows[-1]==patches[0] and
                  json.loads(patches[0][patches[0].index('--data')+1])['draft'] is False and
                  json.loads((c/'remote.json').read_text())['draft'] is not accepted)
            pending=list((c/'state/releases').glob('app-v1.2.3-finalization-pending.*'))
            check(label+' retains the original authority and uncertain pending publication',
                  envelope['command']=='release-finalize' and envelope['status']=='error' and
                  envelope['exit_code']==5 and details['stage']=='interrupted' and details['draft'] is True and
                  details['interruption']==dict(stage='publish',exit_code=stop_status,outcome='unconfirmed') and
                  details['create_response']==str(response) and len(pending)==1 and
                  details['pending_receipt']==str(pending[0]) and
                  json.loads(pending[0].read_text())['status']=='pending' and
                  not list((c/'state/releases').glob('app-v1.2.3-finalized.*')) and
                  response.read_bytes()==original and (response.stat().st_dev,response.stat().st_ino)==identity)
            pending_bytes=pending[0].read_bytes();pending_identity=(pending[0].stat().st_dev,pending[0].stat().st_ino)
            controls=json.loads((c/'control.json').read_text())
            controls.pop('publish_stop_status');controls.pop('publish_stop_before')
            (c/'control.json').write_text(json.dumps(controls));(c/'requests.jsonl').write_text('')
            resumed=subprocess.run(args,env=env,capture_output=True,text=True,timeout=120)
            (c/'resumed.stdout').write_text(resumed.stdout);(c/'resumed.stderr').write_text(resumed.stderr)
            later=[json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]
            check(label+' explicitly resumes without reupload or compensating restoration',
                  resumed.returncode==0 and json.loads((c/'remote.json').read_text())['draft'] is False and
                  sum('--method' in row for row in later)==(0 if accepted else 1) and
                  not any('--post' in row or row[0]=='upload-boundary' for row in later) and
                  all(json.loads(row[row.index('--data')+1])['draft'] is False for row in later if '--method' in row))
            check(label+' preserves exact creation and pending custody through explicit recovery',
                  response.read_bytes()==original and (response.stat().st_dev,response.stat().st_ino)==identity and
                  pending[0].read_bytes()==pending_bytes and
                  (pending[0].stat().st_dev,pending[0].stat().st_ino)==pending_identity)


def test_public_finalizer_lifecycle():
    names=('success','term','kill','borrowed-success','borrowed-term','borrowed-kill','relative-success')
    selected=os.environ.get('DSR_TEST_STRICT_CLI_CASE','')
    if selected and (selected not in names or os.environ.get('DSR_TEST_STRICT_CLI_ONLY')!='1'):
        raise AssertionError('Select a known CLI case together with DSR_TEST_STRICT_CLI_ONLY=1')
    driver=work/'fixture-driver.sh';driver.write_text(script)

    def until(predicate,seconds=30):
        deadline=time.monotonic()+seconds
        while not predicate():
            if time.monotonic()>=deadline:raise AssertionError('Public finalizer fixture barrier timed out')
            time.sleep(0.02)

    def live(pid):
        if pid is None:return False
        result=subprocess.run(['ps','-o','stat=','-p',str(pid)],capture_output=True,text=True)
        return result.returncode==0 and bool(result.stdout.strip()) and not result.stdout.lstrip().startswith('Z')

    def lease_available(c,version):
        lease=c/'state/builds/app'/version/'.lock.lease'
        if not lease.exists():return True
        with lease.open('r+b') as stream:
            try:fcntl.flock(stream,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except OSError as error:
                if error.errno in (errno.EAGAIN,errno.EACCES):return False
                raise
        return True

    def published(c):
        try:return json.loads((c/'remote.json').read_text())['draft'] is False
        except (OSError,ValueError):return False

    for name in names:
        if selected and name!=selected:continue
        borrowed=name.startswith('borrowed-')
        action=name.rsplit('-',1)[-1]
        c,env,_,_=setup('public-cli-'+name,{'absent':True})
        created=subprocess.run(['bash',str(driver),'create'],env=env,capture_output=True,text=True,timeout=40)
        (c/'producer.stdout').write_text(created.stdout);(c/'producer.stderr').write_text(created.stderr)
        check(name+' CLI fixture uses the actual signed draft producer',created.returncode==0)
        details=json.loads(created.stdout)['details']
        response=Path(details['create_response']);env['TMPDIR']=details['finalization_tmpdir']
        if (c/'state/builds').exists():(c/'state/builds').rename(c/'producer-build-custody')
        controls=json.loads((c/'control.json').read_text())
        controls['pause_promotion']=action!='success'
        (c/'control.json').write_text(json.dumps(controls))
        (c/'requests.jsonl').write_text('')
        env.update(GH_MAX_RETRIES='1',GH_API_TIMEOUT='30',BORROW_BUILD_CUSTODY=str(borrowed).lower())
        if name=='relative-success':env['DSR_STATE_DIR']='state'
        # Retain a small, credential-free replay recipe for independent review.
        replay_keys=('ROOT','FUNCTIONS','CASE','SOURCE_SHA','DSR_CONFIG_DIR','DSR_STATE_DIR',
                     'TMPDIR','DSR_MINISIGN_KEY','NO_COLOR','PATH','GH_MAX_RETRIES',
                     'GH_API_TIMEOUT','BORROW_BUILD_CUSTODY')
        (c/'env.json').write_text(json.dumps({key:env[key] for key in replay_keys if key in env}))
        args=['bash',str(driver),'public-finalize','app','1.2.3',
              '--create-response',str(response),'--no-dispatch']
        (c/'argv.json').write_text(json.dumps(args))
        with (c/'finalizer.stdout').open('w') as out,(c/'finalizer.stderr').open('w') as err:
            publisher=subprocess.Popen(args,cwd=c,env=env,stdout=out,stderr=err,start_new_session=True)
            transport=None
            try:
                if action!='success':
                    until(lambda:((c/'promotion.pid').exists() and (c/'promotion.pid').read_text().strip().isdigit()) or
                          publisher.poll() is not None)
                    check(name+' actual CLI reaches the resistant promotion transport',(c/'promotion.pid').exists())
                    transport=int((c/'promotion.pid').read_text())
                    check(name+' both build leases protect the live promotion',live(transport) and
                          all(not lease_available(c,version) for version in ('v1.2.3','1.2.3')))
                    os.kill(publisher.pid,signal.SIGTERM if action=='term' else signal.SIGKILL)

                released_while_live=False
                deadline=time.monotonic()+25
                while True:
                    active=live(transport)
                    available=[lease_available(c,version) for version in ('v1.2.3','1.2.3')]
                    if active and any(available):released_while_live=True
                    if action=='kill':
                        complete=publisher.poll() is not None and all(available)
                    elif borrowed:
                        complete=(c/'public-return').exists() or publisher.poll() is not None
                    else:
                        complete=publisher.poll() is not None
                    if complete:break
                    if time.monotonic()>=deadline:raise AssertionError(name+' public command did not retire bounded work')
                    time.sleep(0.02)
                # Record at the first observed public return/custody release,
                # before permitting a still-live baseline transport to mutate.
                alive_at_return=live(transport)
                observation={'public_status':publisher.poll(),'transport_alive_at_return':alive_at_return,
                             'lease_available':available,'released_while_transport_live':released_while_live}
                (c/'continue-promotion').write_text('public command has returned\n')
                if alive_at_return:
                    until(lambda:published(c) or not live(transport),seconds=5)
                else:
                    time.sleep(0.1)
                observation['published_after_return']=published(c)
                (c/'return-observation.json').write_text(json.dumps(observation))
                check(name+' promotion is dead at public return or custody release',not alive_at_return)
                check(name+' build custody never releases ahead of live promotion',not released_while_live)
                if borrowed and action!='kill':
                    check(name+' borrowed canonical lease remains caller-owned after return',
                          not available[0] and available[1] and
                          (c/'caller-custody.before').read_bytes()==(c/'caller-custody.after').read_bytes())
                    check(name+' caller EXIT trap is preserved and has not run',
                          (c/'caller-trap.before').read_bytes()==(c/'caller-trap.after').read_bytes() and
                          not (c/'caller-exit').exists())
                else:
                    check(name+' independent finalizer leases are released',all(available))
                (c/'release-caller').write_text('release borrowed fixture lease\n')
                status=publisher.wait(timeout=5)
                if action=='kill':
                    check(name+' caller loss leaves the draft resumable without promotion',status==-signal.SIGKILL and
                          not published(c) and list((c/'state/releases').glob('app-v1.2.3-finalization-pending.*')) and
                          not list((c/'state/releases').glob('app-v1.2.3-finalized.*')))
                else:
                    result=json.loads((c/'finalizer.stdout').read_text())
                    expected=0 if action=='success' else 5
                    check(name+' actual dispatcher returns one correctly classified JSON envelope',
                          status==expected and result['command']=='release-finalize' and
                          result['exit_code']==expected and result['status']==('success' if expected==0 else 'error'))
                    if action=='success':
                        receipt=Path(result['details']['receipt'])
                        if not receipt.is_absolute():receipt=c/receipt
                        check(name+' normal publication retains its verified completion receipt',published(c) and
                              json.loads(receipt.read_text())['status']=='success' and
                              json.loads(receipt.read_text())['release']['draft'] is False)
                    else:
                        check(name+' cancellation leaves the original receipt and resumable draft',not published(c) and
                              response.is_file() and list((c/'state/releases').glob('app-v1.2.3-finalization-pending.*')) and
                              not list((c/'state/releases').glob('app-v1.2.3-finalized.*')))
                check(name+' no build lease survives the completed caller',
                      all(lease_available(c,version) for version in ('v1.2.3','1.2.3')))
            finally:
                (c/'continue-promotion').write_text('fixture cleanup\n')
                (c/'release-caller').write_text('fixture cleanup\n')
                # A failing baseline can orphan private process groups. Limit
                # cleanup to this fixture's newly created, unique session.
                rows=subprocess.check_output(['ps','-eo','pid=,sid='],text=True).splitlines()
                for row in rows:
                    pid,sid=map(int,row.split())
                    if sid==publisher.pid:
                        try:os.kill(pid,signal.SIGKILL)
                        except ProcessLookupError:pass
                publisher.wait(timeout=5)


def test_large_release_reporting():
    # Exercise the actual output blocks independently of compilation or HTTP.
    # Each populated name array exceeds one external-process argument while
    # every individual asset name remains below the filesystem's 255-byte cap.
    directory=work/'large-reporting';directory.mkdir()
    selected=['payload-%03d-'%index+'x'*220+'.tar.gz' for index in range(601)]
    extras=[name+'.sha256' for name in selected]
    check('large reporting fixture has 601 legal names and exceeds 128 KiB per array',
          len(selected)==601 and max(map(len,extras))<255 and len(json.dumps(selected).encode())>131072)
    (directory/'names').write_text('\n'.join(selected)+'\n')
    (directory/'extra').write_text('\n'.join(extras)+'\n')
    plan=[{'name':name,'size_bytes':8,'sha256':'1'*64,'upload_names':[name]} for name in selected]
    (directory/'artifacts').write_text(''.join(json.dumps(entry)+'\n' for entry in plan))
    (directory/'contract').write_text(json.dumps({'assets':[{'name':name} for name in selected]}))
    envelope=re.search(r'^json_envelope\(\) \{\n.*?^EOF\n\}',source,re.M|re.S).group(0)
    verify=re.search(r'^cmd_release_verify\(\) \{\n.*?^\}',source,re.M|re.S).group(0)
    verify_block=re.search(r'^    # Output\n    if \$JSON_MODE; then\n(.*?)^    else\n',verify,re.M|re.S).group(1)
    release=re.search(r'^cmd_release\(\) \{\n.*?^\}',source,re.M|re.S).group(0)
    dry_block=re.search(r'^        if \$JSON_MODE; then\n            local plan_artifacts_json=.*?^        fi$',release,re.M|re.S).group(0)
    prefix='set -euo pipefail\nDSR_VERSION=fixture\nlog_warn() { printf "%s\\n" "$*" >&2; }\n'+envelope+'\n'
    common=r'''
emit_report() {
    local tool_name=app repo=owner/app version=1.2.3 tag=v1.2.3 release_id=9
    local release_url=https://github.com/owner/app/releases/tag/v1.2.3
    local manifest_exists=true strict_remote_records_valid=true strict_tag_ruleset_receipt=null
    local fix_missing=false DRY_RUN=false JSON_MODE=true status=success exit_code=0 duration=12
    local repair_custody_error='' artifacts_dir=/fixture/artifacts requested_draft=true
    local publish_draft=false prerelease=false release_contract_enabled=true file_count=601
    local installer_report='{"status":"skipped","reason":"fixture"}'
    local ordinary_sbom_report='{"enabled":false,"status":"disabled","published":false}'
    local release_contract_plan
    local -a expected_assets=() present_assets=() missing_assets=() extra_assets=()
    local -a size_mismatches=() digest_mismatches=() verified_checksums=() checksum_errors=()
    local -a planned_fixes=() ordinary_repair_errors=() plan_artifacts=() plan_extra=()
    mapfile -t expected_assets < "$REPORT_CASE/names"
    case "$1" in
        empty) expected_assets=() ;;
        success)
            present_assets=("${expected_assets[@]}")
            verified_checksums=("${expected_assets[@]:0:3}") ;;
        mismatch)
            status=incomplete; exit_code=1; strict_remote_records_valid=false
            present_assets=("${expected_assets[@]}")
            extra_assets=("${expected_assets[@]/#/unexpected-}")
            size_mismatches=("${expected_assets[@]}")
            digest_mismatches=("${expected_assets[@]}")
            checksum_errors=("${expected_assets[@]:0:3}") ;;
        repair)
            status=error; exit_code=4; fix_missing=true; strict_remote_records_valid=false
            missing_assets=("${expected_assets[@]}")
            planned_fixes=("${expected_assets[@]}")
            ordinary_repair_errors=("${expected_assets[@]}" '' $'first\nsecond\n')
            repair_custody_error='Fixture custody changed' ;;
        strict|ordinary)
            DRY_RUN=true
            release_contract_plan=$(cat "$REPORT_CASE/contract")
            if [[ "$1" == ordinary ]]; then
                release_contract_enabled=false; file_count=1203
                mapfile -t plan_artifacts < "$REPORT_CASE/artifacts"
                mapfile -t plan_extra < "$REPORT_CASE/extra"
                plan_extra+=("${plan_extra[0]}")
            fi ;;
        *) return 91 ;;
    esac
'''
    verify_driver=directory/'verify.sh'
    verify_driver.write_text(prefix+common+verify_block+'\n}\nemit_report "$1"\n')
    dry_driver=directory/'dry.sh'
    dry_driver.write_text(prefix+common+dry_block+'\n}\nemit_report "$1"\n')
    env=dict(os.environ,REPORT_CASE=str(directory))

    for mode in ['empty','success','mismatch','repair']:
        result=subprocess.run(['bash',str(verify_driver),mode],env=env,capture_output=True,text=True,timeout=20)
        (directory/(mode+'.stdout')).write_text(result.stdout)
        (directory/(mode+'.stderr')).write_text(result.stderr)
        check(mode+' actual verification report completes without argument-size failure',result.returncode==0)
        data=json.loads(result.stdout)
        names=[] if mode=='empty' else selected
        present=names if mode in ['success','mismatch'] else []
        missing=names if mode=='repair' else []
        extra=['unexpected-'+name for name in names] if mode=='mismatch' else []
        mismatches=names if mode=='mismatch' else []
        expected={'repo':'owner/app','version':'1.2.3','tag':'v1.2.3','release_id':9,
                  'release_url':'https://github.com/owner/app/releases/tag/v1.2.3','manifest_found':True,
                  'verification':{'expected':len(names),'present':len(present),'missing':len(missing),
                      'extra':len(extra),'size_mismatches':len(mismatches),'digest_mismatches':len(mismatches),
                      'remote_records_valid':mode not in ['mismatch','repair'],'tag_ruleset_receipt':None},
                  'assets':{'present':present,'missing':missing,'extra':extra,
                      'size_mismatches':mismatches,'digest_mismatches':mismatches},
                  'checksums':{'verified':names[:3] if mode=='success' else [],
                               'errors':names[:3] if mode=='mismatch' else []},
                  'repair':{'dry_run':False,'uploads':names,'errors':names+['first','second']} if mode=='repair' else None,
                  'duration_seconds':12}
        if mode=='repair':expected.update(stage='build_custody',error='Fixture custody changed')
        check(mode+' report preserves exact keys counts arrays checksums repair and empty-line semantics',
              data['command']=='release-verify' and
              data['status']==({'mismatch':'incomplete','repair':'error'}.get(mode,'success')) and
              data['exit_code']==({'mismatch':1,'repair':4}.get(mode,0)) and data['details']==expected)

    for mode in ['strict','ordinary']:
        result=subprocess.run(['bash',str(dry_driver),mode],env=env,capture_output=True,text=True,timeout=20)
        (directory/(mode+'.stdout')).write_text(result.stdout)
        (directory/(mode+'.stderr')).write_text(result.stderr)
        check(mode+' actual dry-run report completes without argument-size failure',result.returncode==0)
        data=json.loads(result.stdout)
        expected={'tool':'app','version':'v1.2.3','tag':'v1.2.3','repo':'owner/app',
                  'artifacts_dir':'/fixture/artifacts','draft':True,'prerelease':False,
                  'promotion_requested':False,'file_count':601 if mode=='strict' else 1203,
                  'mode':'dry_run','dry_run':True,
                  'plan':({'strict':True,'assets':selected} if mode=='strict' else
                          {'strict':False,'artifacts':plan,'additional_files':extras,
                           'generated':['SHA256SUMS','<name>.sha256 per uploaded name']}),
                  'installer_check':{'status':'skipped','reason':'fixture'},
                  'sbom':{'enabled':False,'status':'disabled','published':False}}
        check(mode+' dry-run report preserves complete exact plan and metadata',
              data['command']=='release' and data['status']=='dry_run' and data['exit_code']==0 and
              data['details']==expected)


def test_custom_artifact_repair():
    missing='payload.tar.gz.minisig'
    c,env,_,_=setup('custom-artifact-repair',{'absent':True,'fail_upload_name':missing})
    default=c/'state/artifacts/app-v1.2.3'
    artifacts=c/'custom signed artifacts'
    default.rename(artifacts)
    selected=c/'selected artifacts'
    selected.symlink_to(artifacts,target_is_directory=True)

    def requests():
        return [json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]

    def mutations(rows):
        return [row for row in rows if '--post' in row or '--method' in row or row[0]=='upload-boundary']

    def inventory(directory):
        return {str(path.relative_to(directory)):(path.stat().st_ino,path.stat().st_mtime_ns,
                hashlib.sha256(path.read_bytes()).hexdigest())
                for path in directory.rglob('*') if path.is_file() and not path.is_symlink()}

    def verify(label,options=(),dry=False):
        start=len(requests())
        result=subprocess.run(['bash','-c',script,'fixture','verify',str(dry).lower(),*options],
                              env=env,capture_output=True,text=True)
        (c/(label+'.stdout')).write_text(result.stdout)
        (c/(label+'.stderr')).write_text(result.stderr)
        return result,requests()[start:]

    created=subprocess.run(['bash','-c',script,'fixture','create','--artifacts',str(selected)],
                           env=env,capture_output=True,text=True)
    (c/'create.stdout').write_text(created.stdout)
    (c/'create.stderr').write_text(created.stderr)
    check('custom repair begins with an actual interrupted strict draft',created.returncode!=0 and
          json.loads((c/'remote.json').read_text())['draft'] is True and
          sum('--post' in row for row in requests())==1)
    details=json.loads(created.stdout)['details']
    response=Path(details['create_response'])
    original=response.read_bytes();original_inode=response.stat().st_ino
    check('interrupted producer preserves custom output and original creation authority',
          details['artifacts_dir']==str(artifacts) and not default.exists() and response.is_file())

    before=inventory(artifacts)
    state_before=inventory(c/'state')
    result,rows=verify('preview',['--artifacts',str(selected),'--fix'],dry=True)
    report=json.loads(result.stdout) if result.stdout.strip() else {}
    check('custom repair preview selects the actual missing signed asset',result.returncode==1 and
          report.get('details',{}).get('repair')=={'dry_run':True,'uploads':[missing]})
    check('custom repair preview leaves remote assets and retained files unchanged',not mutations(rows) and
          inventory(artifacts)==before and inventory(c/'state')==state_before)

    # A valid default tree must not rescue an explicitly invalid selection.
    shutil.copytree(artifacts,default)
    unrelated=c/'different artifacts';unrelated.mkdir()
    file_path=c/'artifact-file';file_path.write_text('not a directory\n')
    linked=c/'linked manifest';linked.mkdir()
    (linked/'app-v1.2.3-manifest.json').symlink_to(artifacts/'app-v1.2.3-manifest.json')
    for label,path in [('missing-directory',c/'absent'),('non-directory',file_path),
                       ('different-directory',unrelated),('linked-manifest',linked)]:
        result,rows=verify(label,['--artifacts',str(path),'--fix'])
        check(label+' refuses before remote lookup without default fallback',result.returncode==4 and not rows)
    default.rename(c/'retained default artifacts')

    control=json.loads((c/'control.json').read_text());control.pop('fail_upload_name')
    (c/'control.json').write_text(json.dumps(control))
    result,rows=verify('repair',['--artifacts',str(selected),'--fix'])
    check('custom artifact repair verifies the complete signed draft',result.returncode==0 and
          json.loads(result.stdout)['details']['assets']['missing']==[] and
          json.loads((c/'remote.json').read_text())['draft'] is True)
    check('custom artifact repair uploads only the missing original bytes',
          [row[2] for row in rows if row[0]=='upload-boundary']==[missing] and
          all(row[0]=='upload-boundary' for row in mutations(rows)) and
          not default.exists() and inventory(artifacts)==before)
    check('custom repair retains the producer original response identity',
          response.read_bytes()==original and response.stat().st_ino==original_inode)

    env['TMPDIR']=details['finalization_tmpdir']
    finalized,patches=invoke(c,env,response,flags=['app','1.2.3','--artifacts',str(selected),
        '--create-response',str(response),'--no-dispatch'])
    check('unchanged finalizer publishes the repaired custom-output draft',finalized.returncode==0 and
          json.loads((c/'remote.json').read_text())['draft'] is False and
          len(patches)==1 and patches[0][0]=='repos/owner/app/releases/9')
    check('complete custom recovery never recreates its release or creation authority',
          sum('--post' in row for row in requests())==1 and response.read_bytes()==original and
          response.stat().st_ino==original_inode)

    shutil.copytree(artifacts,default)
    result,rows=verify('default-read-only')
    check('default artifact lookup still verifies a complete strict release',result.returncode==0 and
          json.loads(result.stdout)['details']['manifest_found'] is True and not mutations(rows))
    result,rows=verify('strict-checksums',['--verify-checksums'])
    check('strict complete inventory retains real checksum and payload download URLs',result.returncode==0 and
          json.loads(result.stdout)['details']['checksums']['verified']==['payload.tar.gz'] and
          json.loads(result.stdout)['details']['checksums']['errors']==[] and
          len([row for row in rows if row[0]=='checksum-download'])==2 and not mutations(rows))


def test_release_verify_caller_interruptions():
    selected=os.environ.get('DSR_TEST_RELEASE_VERIFY_INTERRUPTION_CASE','all')
    if selected not in ('all','scan','inventory','upload'):
        raise AssertionError('Select a known release-verify caller interruption case')
    for boundary in ('scan','inventory','upload'):
        if selected not in ('all',boundary):
            continue
        label='verify-caller-'+boundary
        c,env,response,_=setup(label)
        original=response.read_bytes();original_inode=response.stat().st_ino
        if boundary=='upload':
            remote=json.loads((c/'remote.json').read_text())
            missing=remote['assets'].pop()['name']
            (c/'remote.json').write_text(json.dumps(remote))
            controls={'upload_stop_status':130,'upload_stop_name':missing}
        else:
            controls={'helper_stop_boundary':boundary,'helper_stop_status':130}
        (c/'control.json').write_text(json.dumps(controls))
        stdout=c/'interrupted.stdout';stderr=c/'interrupted.stderr'
        with stdout.open('w') as out, stderr.open('w') as err:
            result=subprocess.run(['bash','-c',script,'fixture','verify','false','--fix'],
                                  env=env,stdout=out,stderr=err,text=True)
        rows=[json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]
        value=json.loads(stdout.read_text())
        check(label+' returns interrupted with the original adapter status',
              result.returncode==5 and value['command']=='release-verify' and
              value['exit_code']==5 and value['details']['interruption']['exit_code']==130)
        check(label+' stops at the interrupted remote operation',
              rows[-1]==json.loads((c/'stopped-request.json').read_text()))
        if boundary=='upload':
            check(label+' stops before restore or reconciliation after server acceptance',
                  rows[-1][0]=='upload-boundary' and
                  not any('--post' in row or '--method' in row for row in rows))
        else:
            check(label+' performs no repair mutation after an interrupted read',
                  not any('--post' in row or '--method' in row or row[0]=='upload-boundary' for row in rows))
        check(label+' preserves the original response receipt',
              response.read_bytes()==original and response.stat().st_ino==original_inode)


if os.environ.get('DSR_TEST_RELEASE_VERIFY_INTERRUPTION_ONLY')=='1':
    test_release_verify_caller_interruptions()
    print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
    raise SystemExit(0)

if os.environ.get('DSR_TEST_FALLBACK_CALLER_INTERRUPTION_ONLY')=='1':
    test_fallback_recovery(caller_interruption_only=True)
    print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
    raise SystemExit(0)

if os.environ.get('DSR_TEST_STRICT_VERIFICATION_INTERRUPTION_ONLY')=='1':
    test_strict_verification_interruptions()
    print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
    raise SystemExit(0)

if os.environ.get('DSR_TEST_STRICT_HELPER_INTERRUPTION_ONLY')=='1':
    test_shared_strict_helper_interruptions()
    print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
    raise SystemExit(0)

if os.environ.get('DSR_TEST_STANDALONE_FINALIZE_INTERRUPTION_ONLY')=='1':
    test_standalone_finalization_interruptions()
    print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
    raise SystemExit(0)

if os.environ.get('DSR_TEST_STRICT_INTERRUPTION_ONLY')=='1':
    selected=os.environ.get('DSR_TEST_STRICT_INTERRUPTION_CASE','all')
    if selected not in ('all','upload','create','repair','publish'):
        raise AssertionError('Select a known strict interruption case: all, upload, create, repair, or publish')
    if selected in ('all','upload'):test_strict_upload_interruptions()
    if selected in ('all','create'):test_strict_creation_interruptions()
    if selected in ('all','repair'):test_fallback_recovery(interruption_only=True)
    if selected in ('all','publish'):test_strict_publication_interruptions()
    print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
    raise SystemExit(0)

if os.environ.get('DSR_TEST_STRICT_ACFS_CHECKER_ONLY')=='1':
    test_acfs_checksum_checker_publication()
    print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
    raise SystemExit(0)

if os.environ.get('DSR_TEST_STRICT_RAW_INSTALLER_ONLY')=='1':
    test_raw_installer_checksum_publication()
    test_acfs_checksum_checker_publication()
    print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
    raise SystemExit(0)

if os.environ.get('DSR_TEST_STRICT_LARGE_NOTES_ONLY')=='1':
    test_large_note_creation_and_finalization()
    print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
    raise SystemExit(0)

if os.environ.get('DSR_TEST_STRICT_REPORTING_ONLY')=='1':
    test_large_release_reporting()
    print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
    raise SystemExit(0)

if os.environ.get('DSR_TEST_STRICT_PAGINATION_ONLY')=='1':
    test_fallback_recovery(pagination_only=True)
    print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
    raise SystemExit(0)

if os.environ.get('DSR_TEST_STRICT_PRERELEASE_ONLY')=='1':
    test_fallback_recovery(prerelease_only=True)
    print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
    raise SystemExit(0)

if os.environ.get('DSR_TEST_STRICT_CLI_ONLY')=='1':
    test_public_finalizer_lifecycle()
    print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
    raise SystemExit(0)

if os.environ.get('DSR_TEST_STRICT_CUSTOM_REPAIR_ONLY')=='1':
    test_custom_artifact_repair()
    print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
    raise SystemExit(0)

if os.environ.get('DSR_TEST_STRICT_FALLBACK_ONLY')=='1':
    test_fallback_recovery()
    print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
    raise SystemExit(0)

if os.environ.get('DSR_TEST_STRICT_CREATION_ONLY')!='1':
    test_strict_finalization_custody()
if os.environ.get('DSR_TEST_STRICT_CUSTODY_ONLY')=='1':
    print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
    raise SystemExit(0)

if os.environ.get('DSR_TEST_STRICT_CREATION_ONLY')!='1':
    test_custom_artifact_repair()
    test_public_finalizer_lifecycle()
    test_large_release_reporting()

# Execute the complete producer-to-consumer handoff. The response's name,
# bytes, permissions and directory come from production creation, not setup().
test_raw_installer_checksum_publication()
test_acfs_checksum_checker_publication()
test_large_note_creation_and_finalization()
c,env,_,_=setup('creation-handoff',{'absent':True})
# Existing release state may be readable by other users; preserve that parent
# while allocating the irreplaceable POST response in a new private child.
(c/'state/releases').mkdir(mode=0o755)
(c/'state/releases').chmod(0o755)
r=subprocess.run(['bash','-c',script,'fixture','create'],env=env,capture_output=True,text=True)
(c/'create.log').write_text(r.stdout+r.stderr)
check('strict draft creation terminal0',r.returncode==0)
result=json.loads(r.stdout)
# Validate the real producer's complete details against the existing public
# schema, including its required asset download URLs and new custody fields.
schema=json.loads((root/'schemas/release-details.json').read_text())
Draft202012Validator.check_schema(schema)
validator=Draft202012Validator(schema,format_checker=FormatChecker())
check('creation result satisfies public release-details schema',not list(validator.iter_errors(result['details'])))
for field in ('create_response','finalization_tmpdir'):
    for invalid in (7,''):
        wrong=dict(result['details'],**{field:invalid})
        check(field+' schema refuses '+repr(invalid),bool(list(validator.iter_errors(wrong))))
wrong=json.loads(json.dumps(result['details']))
del wrong['assets_uploaded'][0]['download_url']
check('asset schema still requires download URL',bool(list(validator.iter_errors(wrong))))
response=Path(result['details']['create_response'])
private=Path(result['details']['finalization_tmpdir'])
check('direct creation custody survives independently of caller temporary storage',
      private.parent==c/'state/releases' and
      re.fullmatch(r'dsr-create-custody\.[A-Za-z0-9]{8}',private.name) is not None and
      stat.S_IMODE(private.parent.stat().st_mode)==0o755)
check('creation exposes original response in owner-only storage',response.parent==private and
      private.stat().st_mode & 0o777==0o700 and response.stat().st_mode & 0o777==0o600)
raw=response.read_bytes();before=response.stat()
original=json.loads(raw)
check('creation retains actual empty nonce-bound POST bytes',original['assets']==[] and
      original['draft'] is True and original['target_commitish']==sha and
      re.search(r'<!-- dsr-create-nonce:[0-9a-f]{64} -->$',original['body']) is not None)
requests=[json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]
check('creation makes exactly one POST',sum('--post' in q for q in requests)==1)
# Simulate loss of the original temporary namespace without deleting evidence.
# The public response must still locate the exact original inode for a later
# process; a copied response or a new remote GET cannot replace that authority.
caller_temporary=Path(env['TMPDIR'])
caller_temporary.rename(c/'retained-caller-temporary')
check('caller temporary directory is gone while original creation custody remains',
      not caller_temporary.exists() and response.read_bytes()==raw and response.stat().st_ino==before.st_ino)
env['TMPDIR']=str(private)
r,patches=invoke(c,env,response)
check('captured creation response feeds unchanged finalizer',r.returncode==0)
check('handoff retains original descriptor identity',response.read_bytes()==raw and response.stat().st_ino==before.st_ino)
check('handoff publishes only its owned signed draft',json.loads((c/'remote.json').read_text())['draft'] is False and
      all(q[0]=='repos/owner/app/releases/9' for q in patches))

for label in ('state-file','state-link','state-writable','allocation-failure',
              'override-outside-state','override-missing','override-parent-traversal','override-link'):
    c,env,_,_=setup('creation-custody-'+label,{'absent':True})
    releases=c/'state/releases'
    if label=='state-file':
        releases.write_text('preserved unrelated state\n')
    elif label=='state-link':
        releases.symlink_to(c/'tmp',target_is_directory=True)
    elif label=='state-writable':
        releases.mkdir();releases.chmod(0o777)
    elif label=='allocation-failure':
        env['FAIL_CREATION_CUSTODY']='true'
    elif label=='override-outside-state':
        env['_DSR_STRICT_CREATE_CUSTODY_PARENT']=env['TMPDIR']
    elif label=='override-missing':
        env['_DSR_STRICT_CREATE_CUSTODY_PARENT']=str(releases/'missing-handoff')
    elif label=='override-parent-traversal':
        env['_DSR_STRICT_CREATE_CUSTODY_PARENT']=str(releases/'..')
    else:
        releases.mkdir()
        (releases/'linked-handoff').symlink_to(c/'tmp',target_is_directory=True)
        env['_DSR_STRICT_CREATE_CUSTODY_PARENT']=str(releases/'linked-handoff')
    r=subprocess.run(['bash','-c',script,'fixture','create'],env=env,capture_output=True,text=True)
    (c/'create.log').write_text(r.stdout+r.stderr)
    rows=[json.loads(line) for line in (c/'requests.jsonl').read_text().splitlines()]
    check(label+' refuses strict creation without temporary-storage fallback',r.returncode==4 and
          'Cannot preserve private strict creation custody before POST' in r.stderr)
    check(label+' never creates or uploads a remote draft',
          not any('--post' in row or '--method' in row or row[0]=='upload-boundary' for row in rows) and
          json.loads((c/'control.json').read_text())['absent'] is True and
          not list((c/'tmp').glob('dsr-create-custody.*')))

if os.environ.get('DSR_TEST_STRICT_CREATION_ONLY')=='1':
    print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
    raise SystemExit(0)

# Custom build outputs must flow through the real producer and consumer with
# the same signed preflight. A symlink alias is supported by canonicalizing its
# existing directory, just as creation does; the physical path contains spaces.
c,env,_,_=setup('custom-creation-handoff',{'absent':True})
custom=c/'custom signed artifacts'
(c/'state/artifacts/app-v1.2.3').rename(custom)
selected=c/'selected artifacts'
selected.symlink_to(custom,target_is_directory=True)
r=subprocess.run(['bash','-c',script,'fixture','create','--artifacts',str(selected)],
                 env=env,capture_output=True,text=True)
(c/'create.log').write_text(r.stdout+r.stderr)
check('custom strict draft creation terminal0',r.returncode==0)
result=json.loads(r.stdout)
check('custom producer reports canonical directory with spaces',
      result['details']['artifacts_dir']==str(custom.resolve()))
response=Path(result['details']['create_response'])
env['TMPDIR']=result['details']['finalization_tmpdir']
raw=response.read_bytes();before=response.stat()
base_flags=['app','1.2.3','--create-response',str(response),'--no-dispatch']
wrong=c/'wrong artifacts';wrong.mkdir()
for label,extra in [
    ('custom needs explicit path',[]),
    ('missing artifacts argument',['--artifacts']),
    ('empty artifacts argument',['--artifacts','']),
    ('option is not artifacts argument',['--artifacts','--no-dispatch']),
    ('nonexistent artifacts directory',['--artifacts',str(c/'missing artifacts')]),
    ('wrong existing artifacts directory',['--artifacts',str(wrong)])]:
    r,patches=invoke(c,env,response,flags=base_flags+extra)
    check(label+' refused',r.returncode==4)
    check(label+' before publication',not patches and
          json.loads((c/'remote.json').read_text())['draft'] is True)
r,patches=invoke(c,env,response,flags=base_flags+['--artifacts',str(selected)])
check('custom producer response feeds canonicalizing finalizer',r.returncode==0)
check('custom handoff publishes only its owned draft',len(patches)==1 and
      patches[0][0]=='repos/owner/app/releases/9' and
      json.loads((c/'remote.json').read_text())['draft'] is False)
check('custom handoff retains original creation response',
      response.read_bytes()==raw and response.stat().st_ino==before.st_ino)
finalized=list((c/'state/releases').glob('*-finalized.*'))
# The receipt binds physical paths, including a symlinked system temp root
# (macOS exposes /private/var through /var). Compare against that exact root.
canonical_custom=custom.resolve()
check('custom finalization receipt binds canonical manifest and asset paths',
      len(finalized)==1 and
      json.loads(finalized[0].read_text())['plan']['manifest_file']==str(canonical_custom/'app-v1.2.3-manifest.json') and
      all(Path(a['path']).parent==canonical_custom for a in json.loads(finalized[0].read_text())['plan']['assets']))

for label,filename in [('custom-payload-tamper','payload.tar.gz'),
                       ('custom-signature-tamper','payload.tar.gz.minisig')]:
    c,env,response,_=setup(label)
    custom=c/'custom signed artifacts'
    (c/'state/artifacts/app-v1.2.3').rename(custom)
    (custom/filename).write_bytes(b'changed custom input\n')
    r,patches=invoke(c,env,response,flags=['app','1.2.3','--create-response',str(response),
                                        '--artifacts',str(custom),'--no-dispatch'])
    check(label+' refused by real signed preflight',r.returncode==4)
    check(label+' before publication',not patches and
          json.loads((c/'remote.json').read_text())['draft'] is True)

for (label,controls),(c,env,response,_) in prepare_cases([('success',{}),('lost-patch',{'lost_patch':True}),('already-public',{}),('dry-run',{})]):
    raw=response.read_bytes();before=response.stat()
    if label=='already-public':
        remote=json.loads((c/'remote.json').read_text());remote['draft']=False;(c/'remote.json').write_text(json.dumps(remote))
    r,patches=invoke(c,env,response,dry=label=='dry-run')
    check(label+' terminal0',r.returncode==0)
    check(label+' expected mutation count',len(patches)==(1 if label in ['success','lost-patch'] else 0))
    check(label+' original receipt preserved',response.read_bytes()==raw and response.stat().st_ino==before.st_ino)
    check(label+' no creation POST',not any('--post' in q for q in map(json.loads,(c/'requests.jsonl').read_text().splitlines())))
    if label!='dry-run':check(label+' public exact source',json.loads((c/'remote.json').read_text())['draft'] is False)

for (label,_),(c,env,response,original) in prepare_cases([(label,None) for label in ['wrong-id','wrong-tag','wrong-target','wrong-nonce','wrong-url','initial-assets','permissions','hardlink','symlink','outside','duplicate-key','no-contract','source-only-mode','conflicting-registry','local-bytes','local-signature','remote-bytes','metadata','extra-asset','missing-asset','no-dispatch','extra-argument','optimized-python','pending-write-failure']]):
    flags=None
    if label.startswith('wrong-') or label=='initial-assets':
        field,value={'wrong-id':('id',99),'wrong-tag':('tag_name','v9.9.9'),'wrong-target':('target_commitish','f'*40),'wrong-nonce':('body','no nonce'),'wrong-url':('upload_url','https://example.invalid/'),'initial-assets':('assets',[{'id':1}])}[label]
        original[field]=value;response.write_text(json.dumps(original))
    elif label=='permissions':response.chmod(0o644)
    elif label=='hardlink':os.link(response,response.with_name('second-link'))
    elif label=='symlink':
        retained=response.with_name('retained');response.rename(retained);response.symlink_to(retained)
    elif label=='outside':
        out=c/'dsr-api-response.ABCDEF12';out.write_bytes(response.read_bytes());out.chmod(0o600);response=out
    elif label=='duplicate-key':response.write_text(response.read_text()[:-1]+',"id":9}')
    elif label=='no-contract':
        p=c/'config/repos.d/app.yaml';data=json.loads(p.read_text());data.pop('release_contract');p.write_text(json.dumps(data))
    elif label=='source-only-mode':
        p=c/'config/repos.d/app.yaml';data=json.loads(p.read_text());data['publication_mode']='source-only';p.write_text(json.dumps(data))
    elif label=='conflicting-registry':(c/'config/repos.yaml').write_text(json.dumps({'tools':{'app':{}}}))
    elif label in ['local-bytes','local-signature']:
        p=c/'state/artifacts/app-v1.2.3'/('payload.tar.gz' if label=='local-bytes' else 'payload.tar.gz.minisig');p.write_bytes(b'bad bytes\n')
    elif label=='remote-bytes':(c/'bytes/100').write_bytes(b'bad served bytes\n')
    elif label in ['metadata','extra-asset','missing-asset']:
        p=c/'remote.json';data=json.loads(p.read_text())
        if label=='metadata':data['target_commitish']='f'*40
        elif label=='extra-asset':data['assets'].append(dict(data['assets'][0],id=999,name='extra.bin'))
        else:data['assets'].pop()
        p.write_text(json.dumps(data))
    elif label=='no-dispatch':flags=['app','1.2.3','--create-response',str(response)]
    elif label=='extra-argument':flags=['app','1.2.3','--create-response',str(response),'--no-dispatch','extra']
    elif label=='optimized-python':response.chmod(0o644);env['PYTHONOPTIMIZE']='1'
    elif label=='pending-write-failure':env['FAIL_PENDING']='true'
    r,patches=invoke(c,env,response,flags=flags)
    check(label+' refused',r.returncode!=0)
    check(label+' no publication',not patches)

for (label,controls),(c,env,response,_) in prepare_cases([('same-bytes-replacement',{'receipt_replace':'regular'}),('symlink-replacement',{'receipt_replace':'symlink'}),('config-drift',{'config_drift':True}),('registry-appears',{'registry_appears':True}),('wrong-scan-id',{'wrong_scan_id':True}),('hidden-asset',{'hidden_asset':True})]):
    r,patches=invoke(c,env,response)
    check(label+' refused',r.returncode!=0);check(label+' no publication',not patches)

for (label,controls),(c,env,response,_) in prepare_cases([('post-metadata-drift',{'metadata_drift_after_publish':True}),('post-tag-drift',{'tag_drift_after_publish':True}),('post-hidden-asset',{'post_hidden_asset':True}),('final-write-failure',{})]):
    if label=='final-write-failure':env['FAIL_FINAL']='true'
    r,patches=invoke(c,env,response)
    check(label+' terminal failure',r.returncode!=0)
    check(label+' restored owned draft',json.loads((c/'remote.json').read_text())['draft'] is True)
    check(label+' only frozen ID mutated',all(q[0]=='repos/owner/app/releases/9' for q in patches))
    check(label+' pending record retained',len(list((c/'state/releases').glob('*finalization-pending.*')))==1)

test_fallback_recovery()
test_fallback_recovery(pagination_only=True)
test_fallback_recovery(prerelease_only=True)
test_strict_upload_interruptions()
test_strict_creation_interruptions()
test_strict_publication_interruptions()
test_standalone_finalization_interruptions()
test_shared_strict_helper_interruptions()
test_strict_verification_interruptions()
test_fallback_recovery(interruption_only=True)
print(json.dumps({'checks':checks,'passed':True,'fixtures':str(work)}),flush=True)
PY
