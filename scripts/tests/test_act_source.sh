#!/usr/bin/env bash
# Real Git selection/custody and production act projection. Container execution
# is an explicit fixture boundary; installed act can separately parse/dry-run
# the projected workflow without claiming a live Docker build.
set -uo pipefail

DSR_TEST_ACT_SOURCE_GIT_ONLY=false
if [[ $# == 1 && $1 == --git-environment-only ]]; then
    DSR_TEST_ACT_SOURCE_GIT_ONLY=true
elif [[ $# != 0 ]]; then
    printf 'Usage: %s [--git-environment-only]\n' "$0" >&2
    exit 4
fi
export DSR_TEST_ACT_SOURCE_GIT_ONLY

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SRC_DIR=$(cd "$SCRIPT_DIR/../../src" && pwd -P)
export SRC_DIR

python3 -I - "$SRC_DIR" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

modules = Path(sys.argv[1])
work = Path(tempfile.mkdtemp(prefix='dsr-act-sources-'))
print('Retained act source evidence: ' + str(work), flush=True)
checks = failures = 0

def check(label, valid):
    global checks, failures
    checks += 1
    failures += not valid
    print(('PASS: ' if valid else 'FAIL: ') + label, flush=True)

def git(root, *arguments):
    return subprocess.check_output(['git', '-c', 'user.name=DSR Fixture', '-c', 'user.email=fixture@example.invalid',
        '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', '-C', str(root), *arguments],
        stderr=subprocess.PIPE).decode().strip()

def repository(root, text):
    root.mkdir(parents=True)
    git(root, 'init', '-q', '-b', 'main')
    (root / 'value.txt').write_text(text + '\n')
    git(root, 'add', '.')
    git(root, 'commit', '-qm', text)
    return git(root, 'rev-parse', 'HEAD')

def snapshot(root):
    return {str(path.relative_to(root)): (os.readlink(path) if path.is_symlink() else hashlib.sha256(path.read_bytes()).hexdigest())
            for path in root.rglob('*') if path.is_file() or path.is_symlink()}

home, config, state, invocation = [work / name for name in ('home', 'config', 'state', 'invocation')]
for directory in (home, config / 'repos.d', state, invocation):
    directory.mkdir(parents=True)
main = work / 'developer with spaces' / 'application'
repository(main, 'project pin')
sibling = work / 'other developer' / 'library'
repository(sibling, 'library pin')
(sibling / 'build-helper.sh').write_text('#!/bin/sh\nprintf "pinned helper\\n"\n')
(sibling / 'build-helper.sh').chmod(0o755)
git(sibling, 'add', 'build-helper.sh')
child = sibling / 'vendor/child'
child_sha = repository(child, 'child pin')
(sibling / '.gitmodules').write_text('[submodule "vendor/child"]\n\tpath = vendor/child\n\turl = https://must-not-fetch.invalid/child.git\n')
git(sibling, 'add', '.gitmodules')
git(sibling, 'update-index', '--add', '--cacheinfo', '160000,' + child_sha + ',vendor/child')
git(sibling, 'commit', '-qm', 'pin child')
sibling_sha = git(sibling, 'rev-parse', 'HEAD')
(child / 'value.txt').write_text('unrelated child checkout\n')
git(child, 'add', '.')
git(child, 'commit', '-qm', 'unrelated child HEAD')
(child / 'value.txt').write_text('dirty child bytes\n')
(sibling / 'value.txt').write_text('dirty developer bytes\n')
git(sibling, 'add', 'value.txt')
git(sibling, 'config', 'credential.helper', '!must-never-copy-this-helper')
(main / '.github/workflows').mkdir(parents=True)
workflow = '.github/workflows/release.yml'
document = {'name': 'pinned siblings', 'on': {'push': {'tags': ['v*']}}, 'env': {'PIN': '${{ github.sha }}'},
    'jobs': {
        'prepare': {'runs-on': 'ubuntu-latest', 'steps': [{'run': 'test -f ../library/value.txt'}]},
        'build': {'runs-on': 'ubuntu-latest', 'needs': ['prepare'],
            'strategy': {'matrix': {'target': ['linux'], 'version': [1, '2']}},
            'steps': [{'uses': 'actions/checkout@v4'}, {'run': 'cat ../library/value.txt'}, {'uses': 'docker://alpine:3'}]},
        'unrelated': {'uses': './.github/workflows/reusable.yml'}}}
(main / workflow).write_text(json.dumps(document))
git(main, 'add', '.')
git(main, 'commit', '-qm', 'release workflow')
project_sha = git(main, 'rev-parse', 'HEAD')
checkouts = [dict(relative_path='library', local_path=str(sibling), git_sha=sibling_sha)]
tool = dict(repo='owner/application', local_path=str(main), workflow=workflow, language='rust', binary_name='application',
            targets=['linux/amd64'], act_job_map={'linux/amd64': 'build'}, sibling_crates=[dict(
                relative_path='library', local_path=str(sibling), revision=sibling_sha)],
            act_overrides={'platform_image': 'alpine:3'})
(config / 'repos.d/application.yaml').write_text(json.dumps(tool))
(config / 'repos.yaml').write_text('{"tools":{}}')
(home / '.config/act').mkdir(parents=True)
(home / '.config/act/actrc').write_text('--container-options --user 1000:1000 --memory 1g\n')
(home / '.actrc').write_text('--container-options --user 1001:1001 --memory 2g\n')
(invocation / '.actrc').write_text('--container-options --user 1002:1002 --memory 3g\n')
env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'), DSR_CONFIG_DIR=str(config),
           ACT_CONFIG_DIR=str(config), ACT_REPOS_DIR=str(config / 'repos.d'), DSR_REPOS_FILE=str(config / 'repos.yaml'),
           DSR_STATE_DIR=str(state), ACT_ARTIFACTS_DIR=str(state / 'artifacts'), ACT_LOGS_DIR=str(state / 'logs'),
           DSR_NON_INTERACTIVE='true', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
base = 'source "$1/logging.sh"; source "$1/config.sh"; source "$1/act_runner.sh"; source "$1/act_source.sh"; shift; '

def call(label, command, *args, environment=None, timeout=40):
    result = subprocess.run(['bash', '-c', base + command, '_', str(modules), *map(str, args)],
                            env=environment or env, cwd=invocation, capture_output=True, text=True, timeout=timeout)
    (work / (label + '.stdout')).write_text(result.stdout)
    (work / (label + '.stderr')).write_text(result.stderr)
    (work / (label + '.exit')).write_text(str(result.returncode) + '\n')
    return result

def make_plan(label, extra=None, source=None):
    return call(label, 'act_source_plan "$@"', main, workflow, 'build', json.dumps(source or checkouts), json.dumps(extra or []))

before_main, before_sibling = snapshot(main), snapshot(sibling)
result = make_plan('plan')
check('production planner accepts selected ordinary jobs and their local needs', result.returncode == 0)
if result.returncode:
    print(result.stderr, flush=True)
    raise SystemExit(1)
plan = json.loads(result.stdout)
check('effective actrc container options follow XDG, home, then invocation precedence',
      plan['containers']['build']['options'] == '--user 1002:1002 --memory 3g')
check('source identity retains original workflow hash, selected jobs and exact sibling pin',
      plan['identity']['workflow_sha256'] == hashlib.sha256((main / workflow).read_bytes()).hexdigest() and
      plan['identity']['jobs'] == ['build', 'prepare'] and plan['identity']['dependencies'] ==
      [dict(relative_path='library', git_sha=sibling_sha)])
result = make_plan('literal-options', ['--container-options=--user 123:456 --memory 4g --env "VALUE=a b"'])
literal_plan = json.loads(result.stdout)
check('literal CLI container options override ambient options without shell evaluation', result.returncode == 0 and
      literal_plan['containers']['build']['options'] == '--user 123:456 --memory 4g --env "VALUE=a b"')
result = call('materialize', 'act_source_materialize "$@"', json.dumps(plan), state / 'sources')
check('production materializer selects exact sibling and nested gitlink despite dirty unrelated developer HEAD', result.returncode == 0)
if result.returncode:
    print(result.stderr, flush=True)
    raise SystemExit(1)
receipt = json.loads(result.stdout)
private = Path(receipt['dependencies'][0]['source_root'])
projected = json.loads(Path(receipt['projected_workflow']).read_text())
check('private source contains pinned root and child bytes', (private / 'value.txt').read_text() == 'library pin\n' and
      (private / 'vendor/child/value.txt').read_text() == 'child pin\n' and git(private / 'vendor/child', 'rev-parse', 'HEAD') == child_sha)
check('private repositories have independent metadata without developer credentials or alternates',
      (private / '.git').is_dir() and (private / 'vendor/child/.git').is_dir() and
      'must-never-copy' not in (private / '.git/config').read_text() and not (private / '.git/objects/info/alternates').exists())
mount = receipt['mounts'][0]
volume = mount['source'] + ':' + mount['destination'] + ':ro'
check('literal read-only sibling volumes reach both selected job container declarations', all(
      volume in projected['jobs'][name]['container']['volumes'] for name in ('build', 'prepare')) and
      mount['destination'] == str(main.parent / 'library'))
check('projection preserves on, expressions, matrix scalar types, steps and unrelated reusable jobs',
      all(projected[key] == document[key] for key in ('name', 'on', 'env')) and
      all({key: value for key, value in projected['jobs'][name].items() if key != 'container'} == spec
          for name, spec in document['jobs'].items()))
check('private permissions preserve executable bits and allow container users to read source files',
      private.stat().st_mode & 0o555 == 0o555 and (private / 'value.txt').stat().st_mode & 0o444 == 0o444 and
      (private / 'value.txt').stat().st_mode & 0o111 == 0 and (private / 'build-helper.sh').stat().st_mode & 0o111 == 0o111)
check('materialization retains developer HEAD, index, working bytes, and workflow exactly',
      snapshot(main) == before_main and snapshot(sibling) == before_sibling)
check('custody verification accepts unchanged recursive source graph',
      call('verify', 'act_source_verify "$1"', json.dumps(receipt)).returncode == 0)

# Materialize the mount destination as a fixture, without a Docker daemon.
# Git's own ownership test boundary exercises its real protected-config and
# safe.directory checks even when this executor cannot change UID/groups.
mounted = Path(mount['destination'])
mirror = call('git-destination-fixture', '_act_source_load_git && git_ops_materialize_source "$@"',
              sibling, sibling_sha, mounted)
check('exact container destination fixture materializes the same pinned Git graph', mirror.returncode == 0)

def git_in_runner(root, settings, *arguments):
    runner_env = {key: value for key, value in env.items() if not key.startswith('GIT_CONFIG_')}
    runner_env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_TEST_ASSUME_DIFFERENT_OWNER='1')
    runner_env.update({key: str(value) for key, value in settings.items()})
    return subprocess.run(['git', '-C', str(root), *arguments], env=runner_env, capture_output=True, text=True)

plain = git_in_runner(mounted, {}, 'rev-parse', 'HEAD')
check('real Git rejects the foreign-owner boundary without projected trust',
      plain.returncode == 128 and 'dubious ownership' in plain.stderr)
trusted = projected['jobs']['build']['container'].get('env', {})
check('projection trusts only the exact mounted root and recursive Git child', trusted == {
      'GIT_CONFIG_COUNT': '2', 'GIT_CONFIG_KEY_0': 'safe.directory', 'GIT_CONFIG_VALUE_0': str(mounted),
      'GIT_CONFIG_KEY_1': 'safe.directory', 'GIT_CONFIG_VALUE_1': str(mounted / 'vendor/child')})
for label, path, sha in (('root', mounted, sibling_sha), ('child', mounted / 'vendor/child', child_sha)):
    observed = git_in_runner(path, trusted, 'rev-parse', 'HEAD')
    check('real Git reads the pinned ' + label + ' at the foreign-owner boundary',
          observed.returncode == 0 and observed.stdout.strip() == sha)
unrelated = git_in_runner(main, trusted, 'rev-parse', 'HEAD')
check('scoped trust still refuses an unrelated foreign-owner repository',
      unrelated.returncode == 128 and 'dubious ownership' in unrelated.stderr)
check('Git projection never changes developer or private Git configuration',
      snapshot(main) == before_main and snapshot(sibling) == before_sibling and
      'safe.directory' not in (private / '.git/config').read_text())
expression_source = [dict(checkouts[0], local_path=str(sibling) + '${{ matrix.source }}')]
check('literal source paths cannot introduce act expressions into scoped Git environment',
      make_plan('expression-source-path', source=expression_source).returncode == 4)

for index, argv in enumerate((['--directory=/tmp'], ['-C/tmp'], ['--workflows=other.yml'], ['-Wother.yml'],
    ['--bind'], ['--no-skip-checkout'], ['--reuse'], ['--job=other'], ['--container-options', '--mount type=bind,source=/tmp,target=/source'],
    ['--container-options=--volume /tmp:/source'], ['--container-options=--workdir /tmp'],
    ['--container-options=--tmpfs /tmp'], ['--container-options=-itv/tmp:/source'])):
    check('pre-execution refusal of conflicting act argv ' + repr(argv), make_plan('argv-' + str(index), argv).returncode == 4)
for index, argv in enumerate((['-P', 'ubuntu-latest=-self-hosted'], ['-Pubuntu-latest=-SELF-HOSTED'],
                             ['--platform=ubuntu-latest=-self-hosted'],
                             ['-P', 'ubuntu-latest=-self-hosted', '-P', 'ubuntu-latest=alpine:3=ignored'])):
    check('host execution cannot bypass private mounts ' + repr(argv), make_plan('host-' + str(index), argv).returncode == 4)

saved_rc = (home / '.actrc').read_text()
(home / '.actrc').write_text('--container-options --mount type=bind,source=/tmp,target=/source\n')
check('ambient actrc mount override is refused before staging', make_plan('ambient-mount').returncode == 4)
(home / '.actrc').write_text(saved_rc)
(home / '.actrc').write_text('-P ubuntu-latest=-self-hosted\n')
check('ambient host execution cannot bypass private mounts', make_plan('ambient-host').returncode == 4)
(home / '.actrc').write_text(saved_rc)
(home / '.actrc').write_text('--env GIT_CONFIG_COUNT=0\n')
check('ambient actrc Git array override is refused instead of silently replaced', make_plan('ambient-git-env').returncode == 4)
(home / '.actrc').write_text(saved_rc)

for index, argv in enumerate((['--env', 'GIT_CONFIG_COUNT=0'], ['--env=GIT_CONFIG_KEY_0=safe.directory'],
    ['--env=GIT_CONFIG_PARAMETERS=x'], ['--container-options=--env GIT_CONFIG_COUNT=0'],
    ['--container-options=-eGIT_CONFIG_COUNT=0'], ['--container-options=-iteGIT_CONFIG_COUNT=0'],
    ['--container-options=--env-file /tmp/settings'])):
    check('pre-execution refusal of conflicting external Git configuration ' + repr(argv),
          make_plan('git-env-argv-' + str(index), argv).returncode == 4)
env_file = work / 'runner.env'
env_file.write_text('MESSAGE="GIT_CONFIG_COUNT=0 is literal message text"\n')
file_plan = make_plan('plain-env-file', ['--env-file', str(env_file)])
check('unrelated act environment files retain their literal contents', file_plan.returncode == 0 and
      env_file.read_text() == 'MESSAGE="GIT_CONFIG_COUNT=0 is literal message text"\n')
file_receipt = call('plain-env-materialize', 'act_source_materialize "$@"', file_plan.stdout, state / 'env-sources')
check('environment-file digest is bound through source materialization', file_receipt.returncode == 0 and
      json.loads(file_receipt.stdout)['identity'].get('act_env_file_sha256') == hashlib.sha256(env_file.read_bytes()).hexdigest())
env_file.write_text('MESSAGE="changed value"\n')
check('environment file drift invalidates retained source admission',
      call('changed-env-verify', 'act_source_verify "$1"', file_receipt.stdout).returncode == 4)
env_file.write_text('export GIT_CONFIG_COUNT=0\n')
check('dotenv Git configuration is refused before projection',
      make_plan('dotenv-git-env', ['--env-file=' + str(env_file)]).returncode == 4)
for label, content in (('CR-only dotenv', 'MESSAGE=kept\rGIT_CONFIG_COUNT=0\r'),
                       ('Unicode-spaced dotenv', '\u00a0export\u00a0GIT_CONFIG_COUNT=0\n')):
    env_file.write_text(content)
    check(label + ' cannot hide a Git environment override',
          make_plan(label, ['--env-file', str(env_file)]).returncode == 4)
yaml_env = work / 'runner-env.yaml'
yaml_env.write_text('MESSAGE: "GIT_CONFIG_COUNT=0 is literal message text"\n')
check('unrelated YAML environment values are admitted from their captured bytes',
      make_plan('yaml-literal-env', ['--env-file', str(yaml_env)]).returncode == 0)
yaml_env.write_text('"GIT_CONFIG_\\u0043OUNT": "0"\n')
check('escaped YAML Git environment keys cannot shadow projected trust',
      make_plan('yaml-git-env', ['--env-file', str(yaml_env)]).returncode == 4)

def variant(label, mutate, expected=True):
    changed = copy.deepcopy(document)
    mutate(changed)
    (main / workflow).write_text(json.dumps(changed))
    observed = make_plan(label)
    check(label, (observed.returncode == 0) == expected)
    (main / workflow).write_text(json.dumps(document))
    return json.loads(observed.stdout) if observed.returncode == 0 else None

explicit = variant('explicit container mapping retains image options env and unrelated volumes', lambda doc: doc['jobs']['build'].update(
    container={'image': 'alpine:3', 'options': '--user 77:88 --memory 9g', 'env': {'A': 'B'}, 'volumes': ['cache:/cache']}))
check('job-level options keep act precedence over ambient CLI options', explicit['containers']['build'] ==
      dict(image='alpine:3', options='--user 77:88 --memory 9g', env={'A': 'B'}, volumes=['cache:/cache']))
null_container = variant('explicit null container remains a job-level declaration',
    lambda doc: doc['jobs']['build'].update(container=None))
check('explicit null ignores ambient options while an absent container retains them',
      null_container['containers']['build'] == {} and
      null_container['containers']['prepare']['options'] == '--user 1002:1002 --memory 3g')
variant('expression-valued container refused', lambda doc: doc['jobs']['build'].update(container='${{ matrix.container }}'), False)
variant('dynamic container options refused', lambda doc: doc['jobs']['build'].update(container={'options': '${{ matrix.options }}'}), False)
variant('conflicting sibling volume refused', lambda doc: doc['jobs']['build'].update(container={'volumes': ['/tmp:' + str(main.parent)]}), False)
variant('selected reusable dependency refused', lambda doc: doc['jobs']['build'].update(needs=['unrelated']), False)
variant('checkout source override refused', lambda doc: doc['jobs']['build']['steps'][0].update({'with': {'ref': 'other'}}), False)

for label, setting in (
    ('dynamic Git configuration refused', {'GIT_CONFIG_COUNT': '${{ matrix.count }}'}),
    ('orphan Git configuration refused', {'GIT_CONFIG_KEY_0': 'core.quotePath'}),
    ('incomplete Git configuration refused', {'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'core.quotePath'}),
    ('unsupported Git parameter injection refused', {'GIT_CONFIG_PARAMETERS': "'safe.directory'='*'"})):
    variant(label, lambda doc, value=setting: doc['jobs']['build'].update(env=value), False)
variant('step-level dynamic config cannot shadow pinned Git trust',
        lambda doc: doc['jobs']['build']['steps'][1].update(env={'GIT_CONFIG_COUNT': '${{ matrix.count }}'}), False)
variant('container-level dynamic config cannot shadow pinned Git trust',
        lambda doc: doc['jobs']['build'].update(container={'env': {'GIT_CONFIG_COUNT': '${{ matrix.count }}'}}), False)

configured = copy.deepcopy(document)
configured['env'].update(GIT_CONFIG_COUNT='2', GIT_CONFIG_KEY_0='fixture.value', GIT_CONFIG_VALUE_0='workflow',
                         GIT_CONFIG_KEY_1='safe.directory', GIT_CONFIG_VALUE_1=str(main), GIT_CONFIG_GLOBAL='/dev/null')
configured['jobs']['build']['env'] = {'GIT_CONFIG_VALUE_0': 'job', 'PRESERVED': '${{ matrix.target }}'}
configured['jobs']['build']['container'] = {'env': {'GIT_CONFIG_VALUE_0': 'container', 'CONTAINER_VALUE': 'kept'}}
configured['jobs']['build']['steps'][1]['env'] = {'GIT_CONFIG_VALUE_0': 'step', 'STEP_VALUE': 'kept'}
(main / workflow).write_text(json.dumps(configured))
configured_plan = make_plan('configured-git-plan')
configured_copy = call('configured-git-copy', 'act_source_materialize "$@"', configured_plan.stdout, state / 'configured-source')
check('literal Git arrays survive workflow job container and step precedence', configured_copy.returncode == 0)
if configured_copy.returncode == 0:
    configured_receipt = json.loads(configured_copy.stdout)
    actual = json.loads(Path(configured_receipt['projected_workflow']).read_text())
    container_env = dict(actual['env'], **actual['jobs']['build']['env'])
    container_env.update(actual['jobs']['build']['container']['env'])
    step_env = dict(container_env, **actual['jobs']['build']['steps'][1]['env'])
    check('original environment and non-Git expressions remain unchanged', actual['env'] == configured['env'] and
          actual['jobs']['build']['env'] == configured['jobs']['build']['env'] and
          container_env['CONTAINER_VALUE'] == 'kept' and step_env['STEP_VALUE'] == 'kept')
    for label, settings, expected_value in (('container', container_env, 'container'), ('step', step_env, 'step')):
        observed = git_in_runner(mounted, settings, 'config', '--get', 'fixture.value')
        head = git_in_runner(mounted / 'vendor/child', settings, 'rev-parse', 'HEAD')
        check('real Git preserves ' + label + ' settings alongside exact recursive trust', observed.returncode == 0 and
              observed.stdout.strip() == expected_value and head.returncode == 0 and head.stdout.strip() == child_sha)
    check('configured Git projection passes independent reconstruction and custody checks',
          call('configured-git-verify', 'act_source_verify "$1"', configured_copy.stdout).returncode == 0)
    operator_trust = git_in_runner(main, container_env, 'rev-parse', 'HEAD')
    check('an existing explicit operator trust entry is preserved without reset',
          operator_trust.returncode == 0 and operator_trust.stdout.strip() == project_sha)
    forged_git = copy.deepcopy(configured_receipt)
    projected_path = Path(forged_git['projected_workflow'])
    actual['jobs']['build']['container']['env']['GIT_CONFIG_VALUE_2'] = '*'
    projected_path.write_text(json.dumps(actual))
    forged_git['projected_workflow_sha256'] = hashlib.sha256(projected_path.read_bytes()).hexdigest()
    (projected_path.parent / 'source-layout.json').write_text(json.dumps(forged_git))
    check('rewriting projection hashes cannot widen DSR Git trust to a wildcard',
          call('configured-git-forgery', 'act_source_verify "$1"', json.dumps(forged_git)).returncode == 4)
(main / workflow).write_text(json.dumps(document))

if os.environ['DSR_TEST_ACT_SOURCE_GIT_ONLY'] == 'true':
    print('act source Git environment: %d passed, %d failed; ownership boundary simulated, no live Docker execution' %
          (checks - failures, failures), flush=True)
    raise SystemExit(bool(failures))

# This fixture replaces only act/Docker execution. Production runner planning,
# private Git selection, workflow writing, receipt admission, artifact counting,
# and post-execution verification all execute unchanged.
runner = r'''
act_check() { return 0; }
_act_run_with_timeout() {
  shift
  python3 - "$@" <<'BOUNDARY'
import json, os, pathlib, sys
args = sys.argv[1:]
projected = pathlib.Path(args[args.index('-W') + 1])
doc = json.loads(projected.read_text())
layout = json.loads((projected.parent / 'source-layout.json').read_text())
root = pathlib.Path(layout['dependencies'][0]['source_root'])
assert (root / 'value.txt').read_text() == 'library pin\n'.replace('\\n', '\n')
assert (root / 'vendor/child/value.txt').read_text() == 'child pin\n'.replace('\\n', '\n')
assert args[args.index('--directory') + 1] == layout['root']
assert doc['jobs']['build']['container']['volumes'][0].endswith(':ro')
pathlib.Path(os.environ['BOUNDARY_ARGS']).write_text(json.dumps(args))
with pathlib.Path(os.environ['BOUNDARY_ARGS'] + '.calls').open('a') as stream:
    stream.write(str(projected) + '\n')
out = pathlib.Path(args[args.index('--artifact-server-path') + 1])
(out / 'application').write_text('fixture compiler output\n')
if os.environ.get('BOUNDARY_MUTATE') == 'child':
    (root / 'vendor/child/value.txt').write_text('mutated\n')
BOUNDARY
}
act_load_repo_config application >/dev/null || exit 4
_ACT_WORKFLOW_SOURCE_TOOL=application
act_run_workflow "$ACT_REPO_LOCAL_PATH" "$ACT_REPO_WORKFLOW" build push 1.2.3 -P ubuntu-latest=alpine:3
'''
run_env = dict(env, BOUNDARY_ARGS=str(work / 'runner-argv.json'))
result = call('runner', runner, environment=run_env)
check('production runner executes projected workflow with literal argv and verifies source after act', result.returncode == 0)
if result.returncode:
    print(result.stderr, flush=True)
else:
    run_receipt = json.loads(result.stdout.splitlines()[-1])
    check('projection evidence is separate from uploaded artifacts and retains original workflow identity',
          run_receipt['artifact_count'] == 1 and run_receipt['workflow'] == workflow and
          run_receipt['source_layout']['identity']['workflow_sha256'] == plan['identity']['workflow_sha256'] and
          not str(run_receipt['source_layout']['projected_workflow']).startswith(run_receipt['artifact_dir'] + '/'))
    admitted = run_receipt['source_layout']['identity']
    check('successful result source evidence matches its admitted task identity', call('result-source-valid',
          '_act_validate_workflow_source_result "$@"', json.dumps(run_receipt), json.dumps(admitted)).returncode == 0)
    missing = {key: value for key, value in run_receipt.items() if key != 'source_layout'}
    check('successful output without its source receipt cannot authorize resume', call('result-source-missing',
          '_act_validate_workflow_source_result "$@"', json.dumps(missing), json.dumps(admitted)).returncode == 4)
    changed = copy.deepcopy(run_receipt)
    changed['source_layout']['identity']['dependencies'][0]['git_sha'] = '1' * 40
    check('a rewritten source identity cannot replace the admitted task graph', call('result-source-changed',
          '_act_validate_workflow_source_result "$@"', json.dumps(changed), json.dumps(admitted)).returncode == 4)
    forged = copy.deepcopy(run_receipt['source_layout'])
    projected_path = Path(forged['projected_workflow'])
    original_projection = projected_path.read_bytes()
    original_layout = (projected_path.parent / 'source-layout.json').read_bytes()
    changed_document = json.loads(original_projection)
    changed_document['jobs']['build']['steps'][1]['run'] = 'echo changed producer'
    projected_path.write_text(json.dumps(changed_document))
    forged['projected_workflow_sha256'] = hashlib.sha256(projected_path.read_bytes()).hexdigest()
    (projected_path.parent / 'source-layout.json').write_text(json.dumps(forged))
    check('rewriting both projection hash and local receipt cannot alter original workflow semantics',
          call('projection-forged', 'act_source_verify "$1"', json.dumps(forged)).returncode == 4)
    projected_path.write_bytes(original_projection)
    (projected_path.parent / 'source-layout.json').write_bytes(original_layout)
result = call('runner-mutated', runner, environment=dict(run_env, BOUNDARY_MUTATE='child'))
check('source mutation after backend success fails the production workflow with exit4', result.returncode == 4 and
      bool(result.stdout.splitlines()) and json.loads(result.stdout.splitlines()[-1])['status'] == 'failed')
check('all projected attempts preserve original dirty developer repositories',
      snapshot(main) == before_main and snapshot(sibling) == before_sibling)

result = call('task-plan', 'act_load_repo_config application >/dev/null; _act_build_task_plan application 1.2.3 \'["linux/amd64"]\' false')
check('existing scheduler task identity retains source plan for exact resume comparison', result.returncode == 0 and
      json.loads(result.stdout)[0]['workflow_source']['dependencies'] == plan['identity']['dependencies'])

run_id = '4a777f65-9490-4b33-9c62-29aa6242813a'
coordinator = runner[:runner.rindex('act_run_workflow')] + '\nsource "$SRC_DIR/build_state.sh"; act_orchestrate_build application 1.2.3 "$@"'
schedule_env = dict(run_env, DSR_DISABLE_HOST_SELECTOR='1')
result = call('scheduled', coordinator, '--run-id', run_id, '--git-sha', project_sha, '--git-ref', 'main',
              '--no-source-sync-gate', environment=schedule_env, timeout=60)
check('production scheduler dispatches a pinned workflow and retains successful graph evidence', result.returncode == 0 and
      json.loads(result.stdout.splitlines()[-1])['targets'][0]['source_layout']['identity']['dependencies'] == plan['identity']['dependencies'])
if result.returncode == 0:
    calls = Path(run_env['BOUNDARY_ARGS'] + '.calls')
    before_resume = calls.read_text()
    resumed = call('scheduled-resume', coordinator, '--resume-run-id', run_id, '--no-source-sync-gate',
                   environment=schedule_env, timeout=60)
    check('unchanged graph resumes successful output without another backend invocation', resumed.returncode == 0 and
          calls.read_text() == before_resume and json.loads(resumed.stdout.splitlines()[-1])['targets'][0]['resume_reused'])
    changed_config = copy.deepcopy(tool)
    changed_config['sibling_crates'][0]['revision'] = '1' * 40
    (config / 'repos.d/application.yaml').write_text(json.dumps(changed_config))
    changed_resume = call('scheduled-changed-pin', coordinator, '--resume-run-id', run_id, '--no-source-sync-gate',
                          environment=schedule_env, timeout=30)
    check('changed sibling pin refuses scheduler resume before any backend starts', changed_resume.returncode == 4 and
          calls.read_text() == before_resume)
    (config / 'repos.d/application.yaml').write_text(json.dumps(tool))
    checkpoint = state / 'builds/application/1.2.3' / run_id / 'state.json'
    saved = json.loads(checkpoint.read_text())
    target_state = saved['target_statuses']['linux/amd64']
    target_state['result'].pop('source_layout')
    sidecar = Path(target_state['result_path'])
    saved_sidecar = json.loads(sidecar.read_text())
    saved_sidecar.pop('source_layout')
    checkpoint.write_text(json.dumps(saved))
    sidecar.write_text(json.dumps(saved_sidecar))
    missing_resume = call('scheduled-missing-layout', coordinator, '--resume-run-id', run_id, '--no-source-sync-gate',
                          environment=schedule_env, timeout=60)
    check('missing embedded and sidecar graph evidence rebuilds instead of reusing successful artifacts',
          missing_resume.returncode == 0 and calls.read_text().count('\n') == before_resume.count('\n') + 1 and
          json.loads(missing_resume.stdout.splitlines()[-1])['targets'][0]['attempt'] == 2)
else:
    print(result.stderr, flush=True)

large = copy.deepcopy(document)
large['jobs']['build']['steps'][1]['run'] = '# large workflow\n' + ('echo source\n' * 18000)
(main / workflow).write_text(json.dumps(large))
large_plan = make_plan('large-plan')
check('workflow larger than execve per-argument limit is admitted through streaming transport',
      (main / workflow).stat().st_size > 131072 and large_plan.returncode == 0)
large_path = work / 'large-plan.json'
large_path.write_text(large_plan.stdout)
large_copy = call('large-copy', 'act_source_materialize "$(cat "$1")" "$2"', large_path, state / 'large-source')
check('large workflow projection and recursive custody verification avoid argv/environment transport limits',
      large_copy.returncode == 0 and Path(json.loads(large_copy.stdout)['projected_workflow']).stat().st_size > 131072)
(main / workflow).write_text(json.dumps(document))

(private / 'vendor/child/value.txt').write_text('tampered after build\n')
check('retained custody rejects changed nested child bytes', call('changed-child', 'act_source_verify "$1"', json.dumps(receipt)).returncode == 4)

real_act = os.environ.get('DSR_TEST_REAL_ACT')
if real_act:
    # Use a standalone minimal projected workflow so dryrun does not fetch
    # external actions, while real act parses the no-image container mapping.
    dry_document = {'on': 'push', 'jobs': {'build': {'runs-on': 'ubuntu-latest',
        'steps': [{'run': 'cat ../library/value.txt'}]}}}
    # act's custom Docker-options parser consults the daemon even in dryrun.
    # Verify the image-less projected shape here; option precedence above is
    # covered without pretending this environment has a Docker daemon.
    rc_paths = [home / '.config/act/actrc', home / '.actrc', invocation / '.actrc']
    saved_configs = [path.read_text() for path in rc_paths]
    for path in rc_paths:
        path.write_text('')
    (main / workflow).write_text(json.dumps(dry_document))
    dry_plan = make_plan('real-act-plan', ['-P', 'ubuntu-latest=alpine:3'])
    dry_copy = call('real-act-materialize', 'act_source_materialize "$@"', dry_plan.stdout, state / 'real-act')
    check('real act probe materializes an independently verified projection', dry_copy.returncode == 0)
    if dry_copy.returncode == 0:
        projected_path = json.loads(dry_copy.stdout)['projected_workflow']
        parsed = subprocess.run([real_act, '-W', projected_path, '--list'], cwd=invocation, env=env,
                                capture_output=True, text=True, timeout=20)
        (work / 'real-act-list.stdout').write_text(parsed.stdout)
        (work / 'real-act-list.stderr').write_text(parsed.stderr)
        check('installed real act parses the image-less projected container and lists its job',
              parsed.returncode == 0 and 'build' in parsed.stdout)
        probe = subprocess.run([real_act, '-W', projected_path, '-j', 'build', 'push', '-P', 'ubuntu-latest=alpine:3',
            '--directory', str(main), '--dryrun', '--no-cache-server', '--container-daemon-socket', '-'],
            cwd=invocation, env=env, capture_output=True, text=True, timeout=45)
        (work / 'real-act.stdout').write_text(probe.stdout)
        (work / 'real-act.stderr').write_text(probe.stderr)
        (work / 'real-act.exit').write_text(str(probe.returncode) + '\n')
        check('installed real act selects the original runner image for the projected image-less job',
              'Start image=alpine:3' in probe.stdout)
        if probe.returncode != 0:
            print('SKIP: real act dryrun reached image setup but this environment cannot connect to Docker; full container execution unproved', flush=True)
    for path, content in zip(rc_paths, saved_configs):
        path.write_text(content)
    (main / workflow).write_text(json.dumps(document))
else:
    print('SKIP: set DSR_TEST_REAL_ACT to an installed act for independent parser/dryrun verification', flush=True)

print('act source projection: %d passed, %d failed; live Docker execution not exercised' % (checks - failures, failures), flush=True)
raise SystemExit(bool(failures))
PY
