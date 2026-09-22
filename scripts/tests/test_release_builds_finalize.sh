#!/usr/bin/env bash
# Execute the real build coordinator, collector, finalizer CLI and sourced APIs.
# Only native compilation and the network finalizer are boundary fixtures.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 jq flock timeout sha256sum; do
    command -v "$tool" >/dev/null || { printf 'SKIP requires %s\n' "$tool"; exit 0; }
done
[[ "$(uname -s)" == Linux ]] || { printf 'SKIP requires Linux\n'; exit 0; }
python3 - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
work = Path(tempfile.mkdtemp(prefix='dsr-build-finalize-test-'))
passed = 0

def check(label, valid):
    global passed
    assert valid, label
    passed += 1
    print('PASS '+label, flush=True)

def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))

def load(path): return json.loads(path.read_text())
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

try:
    repo = work/'repo'
    (repo/'src').mkdir(parents=True)
    for name in ('release_builds.sh','release_bundle.sh','release_finalize.sh','slsa.sh'):
        shutil.copyfile(root/'src'/name,repo/'src'/name)
    (repo/'dsr').write_text(r'''#!/usr/bin/env bash
set -uo pipefail
[[ "$1" == --json && "$2" == --non-interactive && "$3" == build ]] || exit 90
shift 3
tool='' tag='' targets='' output=''
while (($#)); do
    case "$1" in
        --tool) tool=$2 ;; --version) tag=$2 ;; --targets) targets=$2 ;; --output-dir) output=$2 ;;
        --jobs) : ;; *) exit 91 ;;
    esac
    shift 2
done
spec="$DSR_CONFIG_DIR/config.yaml"
control=$(jq -r .control "$spec")
printf '%s\n' "$targets" >> "$FIXTURE_BUILD_CALLS"
case "$(cat "$control")" in
    fail) exit 42 ;;
    slow) sleep 60 & child=$!; printf '%s\n' "$child" > "$control.pid"; wait "$child" ;;
esac
mkdir -p "$output"
name="demo-${targets//\//-}"
printf 'built %s\n' "$targets" > "$output/$name"
hash=$(sha256sum < "$output/$name"); hash=${hash%% *}
size=$(wc -c < "$output/$name")
manifest="$output/$tool-$tag-manifest.json"
jq -cn --arg tool "$tool" --arg tag "$tag" --arg target "$targets" --arg name "$name" --arg hash "$hash" --argjson size "$size" \
    '{schema_version:"1.0.0",tool:$tool,version:$tag,run_id:"12345678-1234-4123-8123-123456789abc",
      built_at:"2026-09-22T00:00:00Z",status:"success",source:{git_sha:("a"*40),git_ref:("refs/tags/"+$tag),dependencies:[]},
      summary:{total:1,success:1,failed:0},artifacts:[{name:$name,target:$target,sha256:$hash,size_bytes:$size,archive_format:"binary"}]}' > "$manifest"
jq -cn --arg manifest "$manifest" '{command:"build",status:"success",exit_code:0,details:{manifest:$manifest}}'
''')
    (repo/'src/release_finalize_core.sh').write_text(r'''#!/usr/bin/env bash
CORE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
source "$CORE_DIR/slsa.sh"
release_finalize() {
    local root=$1 manifest='' repo='' tag='' sha='' promoted=false
    jq -cn --args '$ARGS.positional' -- "$@" >> "$FIXTURE_FINALIZE_CALLS"
    shift
    while (($#)); do
        case "$1" in
            --build-manifest) manifest=$2; shift 2 ;;
            --repo) repo=$2; shift 2 ;; --tag) tag=$2; shift 2 ;; --sha) sha=$2; shift 2 ;;
            --promote) promoted=true; shift ;;
            *) shift ;;
        esac
    done
    [[ "$repo" == owner/demo && "$tag" == v1.2.3 && "$sha" == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]] || return 99
    _slsa_manifest_statement "$manifest" "$repo" fixture:finalizer > "$FIXTURE_PROOF" || return 99
    _slsa_release_assets "$FIXTURE_PROOF" "$root" || return 99
    case "$(cat "$FIXTURE_FINALIZE_MODE")" in
        fail) printf '{"kind":"dsr-release-finalization-result","status":"error","exit_code":7,"error":"publication fixture failure"}\n'; return 7 ;;
        malformed) printf '{}\n'; return 0 ;;
        planned) printf '{"kind":"dsr-release-finalization-result","status":"planned","exit_code":0}\n'; return 0 ;;
    esac
    jq -cn --argjson promoted "$promoted" '{kind:"dsr-release-finalization-result",status:(if $promoted then "published" else "ready" end),
        exit_code:0,dry_run:false,promotion_attempted:$promoted,verification:{fixture:true}}'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then printf 'Original finalizer help\n'; fi
''')
    controls = {}
    builds = []
    for identity, target in (('linux','linux/amd64'),('darwin','darwin/arm64')):
        cfg=work/('config-'+identity); control=work/('mode-'+identity); control.write_text('good'); controls[identity]=control
        write(cfg/'config.yaml',{'control':str(control)})
        write(cfg/'repos.yaml',{'tools':{}}); write(cfg/'hosts.yaml',{'hosts':{}})
        builds.append({'id':identity,'driver':'dsr','targets':[target],'config_dir':str(cfg),
                       'config_files':{p.name:sha(p) for p in cfg.iterdir()}})
    plan={'schema_version':1,'repo':'owner/demo','tool':'demo','tag':'v1.2.3','source_sha':'a'*40,
          'required_targets':['linux/amd64','darwin/arm64'],'builds':builds}
    planfile=work/'build-plan.json'; write(planfile,plan)
    calls=work/'build.calls'; finalcalls=work/'finalize.calls'; mode=work/'finalize.mode'; mode.write_text('good')
    env=dict(os.environ,FIXTURE_BUILD_CALLS=str(calls),FIXTURE_FINALIZE_CALLS=str(finalcalls),
             FIXTURE_FINALIZE_MODE=str(mode),FIXTURE_PROOF=str(work/'proof.json'))
    entry=repo/'src/release_finalize.sh'; output=work/'execution'
    def command(directory=output, selected=planfile):
        return ['bash',str(entry),'--build-plan',str(selected),'--build-dir',str(directory)]
    def run(arguments=(), expected=0, directory=output, selected=planfile, custom=None):
        proc=subprocess.run((custom or command(directory,selected))+list(arguments),env=env,
                            stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=45)
        if proc.returncode!=expected:
            print(proc.stderr.decode(),file=sys.stderr)
            raise AssertionError(f'expected {expected}, got {proc.returncode}: {proc.stdout.decode()}')
        result=json.loads(proc.stdout)
        check('one finalization envelope matches exit status',result['kind']=='dsr-release-finalization-result' and result['exit_code']==expected)
        return result
    result=run(['--build-jobs','2','--create-draft','--dry-run'])
    check('combined dry run neither builds nor invokes publication',not output.exists() and not calls.exists() and not finalcalls.exists())
    check('dry-run policy is explicitly unverified',result['stage']=='build-plan' and result['policy_verified'] is False and not result['builds']['publishable'])
    for options in (
        ['--require-signatures'], ['--repo','owner/other'], ['--bundle-dir',str(work/'other')],
        ['--build-jobs','0'], ['--build-jobs','2','--build-jobs','3'], ['--release-name','ignored'],
        ['--state-dir',str(output/'attempts')], ['--output-dir',str(output/'completed')],
        ['--output-dir',str(output/'bundle/release/artifacts')],
        ['--create-draft','--dispatch-repos','owner/consumer'], ['--format','unknown'],
    ):
        run(options,4)
        check('invalid policy never starts a build or creates state',not output.exists() and not calls.exists())
    controls['darwin'].write_text('fail')
    result=run(['--build-jobs','2','--create-draft'],1)
    check('failed build prevents all release API entry',result['status']=='builds_incomplete' and not finalcalls.exists())
    check('useful completed targets remain checkpointed',result['builds']['completed_builds']==1 and (output/'completed/linux/build-manifest.json').exists())
    check('no build-set is advertised before complete success',not (output/'build-set.json').exists())
    controls['darwin'].write_text('good')
    result=run(['--create-draft'])
    check('same CLI invocation resumes and finalizes the complete matrix',result['status']=='ready' and result['builds']['status']=='verified' and result['bundle']['status']=='verified')
    check('only failed native target was rebuilt',calls.read_text().splitlines().count('linux/amd64')==1 and calls.read_text().splitlines().count('darwin/arm64')==2)
    args=json.loads(finalcalls.read_text().splitlines()[-1])
    check('pipeline supplies exact complete aggregate identity',args[0]==str(output/'bundle/release/artifacts') and args[args.index('--build-manifest')+1]==str(output/'bundle/release/build-manifest.json') and '--upload-payloads' in args)
    check('no silent signing or promotion policy',not result['promotion_attempted'] and '--promote' not in args and '--require-signatures' not in args)
    before=calls.read_bytes(); manifest_pin=result['bundle']['manifest_sha256']
    mode.write_text('fail'); result=run(['--create-draft'],7)
    check('publication failure retains build receipt and diagnostic',result['builds']['status']=='verified' and result['error']=='publication fixture failure')
    mode.write_text('good'); result=run(['--create-draft'])
    check('publication retry does not recompile or change aggregate identity',calls.read_bytes()==before and result['bundle']['manifest_sha256']==manifest_pin)
    public=work/'public.key';public.write_text('boundary fixture')
    secret=work/'secret.key';secret.write_text('boundary fixture')
    title='Literal release; $(not-executed)'
    result=run(['--create-draft','--promote','--require-signatures','--public-key',str(public),'--secret-key',str(secret),
                '--release-name',title,'--dispatch-repos','owner/consumer'])
    args=json.loads(finalcalls.read_text().splitlines()[-1])
    check('explicit policies remain exact through the build path',result['status']=='published' and args[args.index('--release-name')+1]==title and args[args.index('--tool')+1]=='demo' and '--require-signatures' in args)
    run(['--prepared-signatures','--public-key',str(public),'--integrity-dir',str(work/'integrity')])
    args=json.loads(finalcalls.read_text().splitlines()[-1])
    check('prepared signature path never enables fresh signing', '--prepared-signatures' in args and '--require-signatures' not in args and '--secret-key' not in args)
    # Both earlier entry points remain usable with the exact completed bundle.
    old=['bash',str(entry),'--build-set',str(output/'build-set.json'),'--bundle-dir',str(output/'bundle')]
    result=run(custom=old)
    check('existing build-set result contract is unchanged','builds' not in result and result['status']=='ready')
    legacy=['bash',str(entry),str(output/'bundle/release/artifacts'),'--repo','owner/demo','--tag','v1.2.3','--sha','a'*40,
            '--upload-payloads','--build-manifest',str(output/'bundle/release/build-manifest.json')]
    result=run(custom=legacy)
    check('artifacts-first finalizer route is unchanged',result['status']=='ready' and 'builds' not in result)
    sourced=['bash','-c','source "$1"; trap ": caller trap" TERM; before=$(trap -p TERM); release_finalize_build_plan --build-plan "$2" --build-dir "$3"; rc=$?; [[ $(trap -p TERM) == "$before" ]] || exit 99; exit "$rc"','_',str(entry),str(planfile),str(output)]
    run(custom=sourced)
    check('sourced build-plan API preserves caller traps',calls.read_bytes()==before)
    for invalid in ('malformed','planned'):
        mode.write_text(invalid); run(expected=7)
    mode.write_text('good')
    before_final=finalcalls.read_bytes()
    payload=output/'completed/linux/artifacts/demo-linux-amd64'; saved=payload.read_bytes();payload.write_bytes(b'corrupt')
    run(expected=7)
    check('corrupt completed build cannot reach publication again',finalcalls.read_bytes()==before_final)
    payload.write_bytes(saved)
    # Cancellation must traverse finalizer -> controller -> owned compiler group.
    controls['linux'].write_text('slow')
    slow=dict(plan,required_targets=['linux/amd64'],builds=[dict(builds[0],timeout=20)])
    write(work/'slow.json',slow)
    with open(work/'cancel.out','wb') as out, open(work/'cancel.err','wb') as err:
        proc=subprocess.Popen(command(work/'cancel',work/'slow.json'),env=env,stdout=out,stderr=err)
        pidfile=Path(str(controls['linux'])+'.pid'); deadline=time.monotonic()+10
        while time.monotonic()<deadline and not pidfile.exists(): time.sleep(.05)
        check('combined CLI reached running compiler',pidfile.exists())
        proc.send_signal(signal.SIGTERM); code=proc.wait(timeout=12)
    check('combined CLI cancellation returns one interrupted envelope',code==5 and load(work/'cancel.out')['exit_code']==5)
    child=Path('/proc')/pidfile.read_text().strip()/'stat'
    check('combined cancellation stops descendant compiler',not child.exists() or child.read_text().split(') ',1)[1].split()[0]=='Z')
    check('cancellation never entered finalization',finalcalls.read_bytes()==before_final)
    text=subprocess.check_output(['bash',str(entry),'--help'],env=env).decode()
    check('help exposes all supported entry points','Original finalizer help' in text and '--build-set' in text and '--build-plan' in text)
    print(f'\nBuild-plan finalization: {passed} passed, 0 failed',flush=True)
except Exception:
    print('Retained failing fixtures: '+str(work),file=sys.stderr)
    raise
else:
    shutil.rmtree(work)
PY
