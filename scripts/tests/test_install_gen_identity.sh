#!/usr/bin/env bash
# GH #35: actual generator/renderer and owned YAML/files; no network or builds.
# Fixtures are retained. Default tests the dependency-free scalar reader.
# --parser-fixture additionally exercises typed admission with a PyYAML-backed
# yq transport fixture, NOT native yq interoperability or full CLI qualification.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
exec python3 - "$ROOT" "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
module = Path(os.environ.get('GENERATOR_TEST_MODULE', str(root / 'src/install_gen.sh'))).resolve()
assert sys.argv[2:] in ([], ['--parser-fixture']), 'Use --parser-fixture or no options'
work = Path(tempfile.mkdtemp(prefix='dsr-installer-identity-')).resolve()
print('Identity regression evidence retained:', work, flush=True)
bin_dir = work / 'bin'
bin_dir.mkdir()
for name in ('bash', 'grep', 'sed', 'cat', 'awk', 'dirname', 'basename', 'mkdir', 'chmod',
             'tr', 'cmp', 'sha256sum', 'shasum', 'wc', 'sort', 'head', 'tar', 'base64', 'python3'):
    executable = shutil.which(name)
    if executable:
        (bin_dir / name).symlink_to(executable)
checks = failures = 0

def check(label, condition):
    global checks, failures
    checks += 1
    if not condition:
        failures += 1
    print(('ok ' if condition else 'not ok ') + str(checks) + ' - ' + label, flush=True)

def fixture():
    case = work / ('case-%03d' % (len(list(work.glob('case-*'))) + 1))
    for part in ('cwd/config/repos.d', 'user/repos.d', 'out/example', 'outside'):
        (case / part).mkdir(parents=True, exist_ok=True)
    (case / 'out/example/install.sh').write_bytes(b'previous installer retained\n')
    (case / 'outside/install.sh').write_bytes(b'outside file retained\n')
    return case

def document(tool='example', repo='owner/example', binary='example'):
    return 'tool_name: ' + tool + '\nrepo: ' + repo + '\nbinary_name: ' + binary + '\nlanguage: go\n'

def run(case, tool='example', extra=(), prefix='', action='install_gen_create'):
    environment = {k:v for k,v in os.environ.items() if not k.startswith('BASH_FUNC_') and k not in ('BASH_ENV', 'ENV')}
    environment.update(PATH=str(bin_dir), DSR_CONFIG_DIR=str(case / 'user'),
                       DSR_INSTALLER_DIR=str(case / 'out'), HOME=str(case), NO_COLOR='1')
    command = ['bash', '-c', 'source "$1" || exit $?; _IG_SCRIPT_DIR=$2; shift 2; ' + prefix + '\n' + action + ' "$@"',
               '_', str(module), str(root / 'src'), tool, *extra]
    result = subprocess.run(command, cwd=case / 'cwd', env=environment, capture_output=True, timeout=30)
    (case / ('run-%03d.out' % len(list(case.glob('run-*.out'))))).write_bytes(result.stdout + b'\nSTDERR\n' + result.stderr)
    return result

# Instrument only the next boundary to establish rejection order. The module,
# CLI identifier checks and configuration identity reader are the real code.
for value in ('', '../outside', '/absolute', 'a/b', '-option', 'name\n', 'name\r', 'name\t',
              'name space', 'name"quote', "name'quote", 'name$(printf unsafe)', 'name`id`',
              'x' * 129, 'x__SOURCE_BUILD_ENGINE__'):
    case = fixture()
    probe = '_install_gen_load_config() { printf lookup >&2; return 97; };'
    result = run(case, value, prefix=probe)
    check('unsafe CLI identity refused before lookup: ' + repr(value),
          result.returncode == 4 and b'lookup' not in result.stderr and not result.stdout)

for field, value in (
    ('tool_name', '../outside'), ('tool_name', 'example$(printf unsafe)'),
    ('tool_name', 'a__REPO__'), ('tool_name', 'x' * 129),
    ('repo', 'missing-slash'), ('repo', 'owner/repo/extra'), ('repo', '../example'),
    ('repo', 'owner/..'), ('repo', 'owner/"quoted"'), ('repo', 'owner/$(printf unsafe)'),
    ('repo', 'owner/repo`id`'), ('repo', 'owner/repo space'), ('repo', 'owner/repo\t'),
    ('repo', 'owner/x__BINARY_NAME__'), ('repo', 'owner/' + 'x' * 129),
    ('binary_name', '../outside'), ('binary_name', 'example$(printf unsafe)'),
    ('binary_name', 'x__SOURCE_BUILD_ENGINE__'), ('binary_name', 'x' * 129)):
    case = fixture()
    values = dict(tool_name='example', repo='owner/example', binary_name='example')
    values[field] = value
    text = ''.join(key + ': ' + json.dumps(item) + '\n' for key,item in values.items())
    (case / 'user/repos.d/example.yaml').write_text(text)
    before = (case / 'out/example/install.sh').read_bytes()
    outside = (case / 'outside/install.sh').read_bytes()
    result = run(case, prefix='_install_gen_workspace_cases() { printf workspace >&2; return 98; };')
    check('configured ' + field + ' refused before workspace/render: ' + repr(value),
          result.returncode in (3, 4) and b'workspace' not in result.stderr and not result.stdout and
          (case / 'out/example/install.sh').read_bytes() == before and
          (case / 'outside/install.sh').read_bytes() == outside)

for label, text in (
    ('missing repository', 'tool_name: example\nbinary_name: example\n'),
    ('empty repository', document(repo='""')),
    ('duplicate identity', document() + 'repo: other/repo\n'),
    ('multiple YAML documents', document() + '---\n' + document()),
    ('NUL identity', document(repo='owner/exa\0mple')),
    ('array identity', document(tool='[example]')),
    ('boolean identity', document(binary='false')),
    ('numeric identity', document(tool='123')),
    ('block scalar identity', document(repo='|\n  owner/example'))):
    case = fixture()
    (case / 'user/repos.d/example.yaml').write_text(text)
    before = (case / 'out/example/install.sh').read_bytes()
    result = run(case)
    check(label + ' does not replace an installer', result.returncode in (3, 4) and not result.stdout and
          (case / 'out/example/install.sh').read_bytes() == before)

# Concrete original-path counterexamples, without instrumentation. Never run
# an installer emitted from a rejected identity: inspect only the owned files.
for label, text in (
    ('tool traversal', document(tool='../outside')),
    ('repository shell substitution', document(repo='owner/$(printf harmless)')),
    ('repository extra path component', document(repo='owner/repository/extra'))):
    case = fixture()
    (case / 'user/repos.d/example.yaml').write_text(text)
    before = (case / 'out/example/install.sh').read_bytes()
    outside = (case / 'outside/install.sh').read_bytes()
    result = run(case)
    check('complete renderer refuses ' + label + ' without output changes',
          result.returncode == 4 and not result.stdout and
          (case / 'out/example/install.sh').read_bytes() == before and
          (case / 'outside/install.sh').read_bytes() == outside)

# Positive cases render the complete real template and real source engine.
# Only --help is executed; no downloaded/generated executable or build is run.
for tool, repo, binary in (
    ('bv', 'Dicklesworthstone/beads_viewer', 'bv'),
    ('cass', 'Dicklesworthstone/coding_agent_session_search', 'cass'),
    ('ntm', 'Dicklesworthstone/ntm', 'ntm'),
    ('mcp_agent_mail', 'Dicklesworthstone/mcp_agent_mail', 'am'),
    ('Example.v1+cli', 'owner/Repo_Name-1', 'example-cli'),
    ('x' * 128, 'owner/repository', 'binary')):
    case = fixture()
    (case / 'user/repos.d/example.yaml').write_text(document(tool, repo, binary))
    result = run(case)
    target = case / 'out' / tool / 'install.sh'
    check('valid identities render: ' + tool, result.returncode == 0 and target.is_file() and
          result.stdout.decode().strip() == str(target))
    if result.returncode == 0 and target.is_file():
        text = target.read_text()
        check('identity assignments are literal: ' + tool,
              "TOOL_NAME='" + tool + "'" in text and "REPO='" + repo + "'" in text and
              "BINARY_NAME='" + binary + "'" in text)
        parsed = subprocess.run(['bash', '-n', str(target)], capture_output=True)
        help_result = subprocess.run(['bash', str(target), '--help'], capture_output=True, timeout=10)
        check('genuine emitted installer parses and starts --help: ' + tool,
              parsed.returncode == 0 and help_result.returncode == 0 and b'Install ' + tool.encode() in help_result.stdout)

for label, text in (
    ('defaults', 'repo: owner/example\n'),
    ('quoted identities', document("'example'", '"owner/example"', "'example'")),
    ('scalar comments', 'tool_name: example # alias\nrepo: owner/example # origin\nbinary_name: example\n'),
    ('CRLF', document().replace('\n', '\r\n')),
    ('null optional names', document(tool='null', binary='null'))):
    case = fixture()
    (case / 'user/repos.d/example.yaml').write_text(text)
    result = run(case)
    check('simple YAML ' + label + ' remains usable', result.returncode == 0 and
          b"REPO='owner/example'" in (case / 'out/example/install.sh').read_bytes())

case = fixture()
(case / 'cwd/config/repos.d/example.yaml').write_text(document(repo='local/repository'))
(case / 'user/repos.d/example.yaml').write_text(document(repo='selected/repository'))
result = run(case)
check('default local configuration precedence remains explicit in logs', result.returncode == 0 and
      b'Loading config from: ./config/repos.d/example.yaml' in result.stderr and
      b"REPO='local/repository'" in (case / 'out/example/install.sh').read_bytes())
result = run(case, extra=('--config-dir', str(case / 'user')))
check('explicit config root selects the requested repository rather than PWD', result.returncode == 0 and
      str(case / 'user/repos.d/example.yaml').encode() in result.stderr and
      b"REPO='selected/repository'" in (case / 'out/example/install.sh').read_bytes())
(case / 'empty/repos.d').mkdir(parents=True)
before = (case / 'out/example/install.sh').read_bytes()
result = run(case, extra=('--config-dir', str(case / 'empty')))
check('missing explicit configuration never falls back', result.returncode == 4 and not result.stdout and
      (case / 'out/example/install.sh').read_bytes() == before)
for extra in (('--config-dir',), ('--unexpected', 'value'), ('--config-dir', str(case / 'user'), '--config-dir', str(case / 'user'))):
    result = run(case, extra=extra)
    check('malformed selector options are rejected: ' + repr(extra), result.returncode == 4 and not result.stdout)

case = fixture()
result = run(case, '../outside', action='_install_gen_load_config')
check('direct configuration-loader API rejects traversal', result.returncode == 4 and not result.stdout)
result = run(case, '../outside', action='install_gen_validate')
check('generated-file validation also rejects traversal', result.returncode == 4 and b'Validating:' not in result.stderr)

if sys.argv[2:] == ['--parser-fixture']:
    import yaml
    # Convert the real YAML syntax tree into the exact top-level entries the
    # generator requests from yq. No production identity predicate is copied.
    adapter = bin_dir / 'yq'
    adapter.write_text('#!' + sys.executable + '\n' + r'''
import json,sys,yaml
assert sys.argv[1:4]==['-o=json','-I=0','to_entries']
for node in yaml.compose_all(open(sys.argv[4]).read()):
    if not isinstance(node,yaml.MappingNode): sys.exit(2)
    def value(node):
        return yaml.safe_load(yaml.serialize(node))
    print(json.dumps([{'key':value(k),'value':value(v)} for k,v in node.value]))
''')
    adapter.chmod(0o755)
    (bin_dir / 'jq').symlink_to(shutil.which('jq'))
    for label, text, code in (
        ('typed valid mapping', document(), 0),
        ('quoted key', '"repo": "owner/example"\n', 0),
        ('typed false', document(tool='false'), 4),
        ('typed number', document(tool='42'), 4),
        ('typed array', document(binary='[example]'), 4),
        ('trailing newline', document(repo='"owner/example\\n"'), 4),
        ('escaped NUL', document(repo='"owner/exa\\0mple"'), 4),
        ('duplicate mapping key', document() + 'repo: second/repository\n', 4),
        ('multiple mappings', document() + '---\n' + document(), 4),
        ('invalid YAML', 'repo: [\n', 4)):
        case = fixture()
        (case / 'user/repos.d/example.yaml').write_text(text)
        result = run(case, action='_install_gen_identities', tool=str(case / 'user/repos.d/example.yaml'), extra=('example',))
        check('explicit parser fixture: ' + label, result.returncode == code and
              (not result.stdout if code else result.stdout == b'example\towner/example\texample\n'))

print(json.dumps(dict(checks=checks, failures=failures, evidence=str(work))))
sys.exit(1 if failures else 0)
PY
