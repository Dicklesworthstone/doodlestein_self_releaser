#!/usr/bin/env bash
# Private, pinned sibling sources for ordinary act workflow jobs.
# The source reader owns Git authentication; this module owns the container
# layout, workflow projection, and retained evidence at the act boundary.

_ACT_SOURCE_MODULE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || return 3
export _ACT_SOURCE_MODULE_DIR

_act_source_load_git() {
    if ! declare -F git_ops_materialize_source >/dev/null; then
        # shellcheck source=SCRIPTDIR/git_ops.sh
        source "$_ACT_SOURCE_MODULE_DIR/git_ops.sh" || return 3
    fi
    _git_ops_load_source_reader
}

# Resolve the effective workflow and act configuration before creating any
# source copies. The identity excludes attempt-local paths, so retries can
# recreate the same graph without rewriting the original checkpoint.
# Args: repo workflow job canonical_checkouts_json literal_extra_argv_json
act_source_plan() {
    local repo="$1" workflow="$2" job="$3" checkouts="$4" arguments="$5" document
    [[ "$checkouts" != '[]' ]] || { printf 'null\n'; return 0; }
    document=$(_config_read_single_mapping_json "$repo/$workflow") || return 4
    _act_source_python plan "$repo" "$workflow" "$job" "$checkouts" "$arguments" "$document"
}

# Materialize fresh independent repositories for this one invocation. Nothing
# from the developer's working tree, configuration, credentials or index is
# copied into the container. Children come from authenticated parent gitlinks.
act_source_materialize() {
    local plan="$1" storage="$2" directory row name source sha materialized repositories dependencies='[]' receipt
    local private_root repository_path
    _act_source_load_git || return 3
    mkdir -p -- "$storage" || return 4
    directory=$(umask 077; mktemp -d "$storage/attempt.XXXXXXXX") || return 4
    directory=$(cd "$directory" && pwd -P) || return 4
    mkdir -m 700 -- "$directory/siblings" || return 4
    while IFS= read -r row; do
        name=$(jq -r .relative_path <<< "$row") || return 4
        source=$(jq -r .local_path <<< "$row") || return 4
        sha=$(jq -r .git_sha <<< "$row") || return 4
        materialized=$(git_ops_materialize_source "$source" "$sha" "$directory/siblings/$name") || return 4
        repositories=$(source_git_materialized_repositories_json "$directory/siblings/$name" "$sha") || return 4
        dependencies=$(jq -c --arg name "$name" --argjson materialized "$materialized" \
            --argjson repositories "$repositories" '. + [{relative_path:$name,
                source_root:$materialized.source_root,git_sha:$materialized.git_sha,
                repositories:$repositories}]' <<< "$dependencies") || return 4
    done < <(jq -c '.checkouts[]' <<< "$plan")
    receipt=$(_act_source_python project "$plan" "$dependencies" "$directory") || return 4
    # Making private files readable changes their ctime. Refresh only these
    # new indexes, deepest children first, so Git's stat cache cannot turn a
    # byte-identical chmod into a false dirty-source refusal.
    while IFS= read -r row; do
        private_root=$(jq -r .source_root <<< "$row") || return 4
        while IFS= read -r repository_path; do
            _git_ops_build_git -C "$private_root${repository_path:+/$repository_path}" \
                update-index --refresh >/dev/null || return 4
        done < <(jq -r '.repositories | reverse | .[].path' <<< "$row")
    done < <(jq -c '.dependencies[]' <<< "$receipt")
    act_source_verify "$receipt" || return 4
    printf '%s\n' "$receipt"
}

# Verify both projection evidence and the exact private root/child bytes.
# Called before launch, after act exits, and before reusing completed output.
act_source_verify() {
    local receipt="$1" row root sha observed expected original document
    original=$(jq -r .original_workflow <<< "$receipt") || return 4
    document=$(_config_read_single_mapping_json "$original") || return 4
    _act_source_python verify "$receipt" "$document" || return 4
    _act_source_load_git || return 3
    while IFS= read -r row; do
        root=$(jq -r .source_root <<< "$row") || return 4
        sha=$(jq -r .git_sha <<< "$row") || return 4
        git_ops_verify_materialized_source "$root" "$sha" || return 4
        observed=$(source_git_materialized_repositories_json "$root" "$sha" | jq -cS .) || return 4
        expected=$(jq -cS .repositories <<< "$row") || return 4
        [[ "$observed" == "$expected" ]] || return 4
    done < <(jq -c '.dependencies[]' <<< "$receipt")
}

_act_source_python() {
    # Bash keeps function arguments in process memory. Stream them through a
    # separate descriptor so large workflow documents never enter execve argv
    # or environment entries (both have a much smaller per-string limit).
    python3 -I - 3< <(printf '%s\0' "$@") <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import stat
import sys

class Refused(Exception):
    pass

def require(ok, message):
    if not ok:
        raise Refused(message)

def canonical(value):
    return (json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(',', ':')) + '\n').encode()

def digest(value):
    return hashlib.sha256(value).hexdigest()

def regular(path):
    require(path.is_file() and not path.is_symlink(), 'missing or linked evidence: ' + str(path))
    return path.read_bytes()

def literal(value):
    return isinstance(value, str) and not any(ord(c) < 32 or ord(c) == 127 for c in value)

def absolute(value):
    require(literal(value) and value.startswith('/') and ':' not in value and '\\' not in value,
            'source mounts require literal Unix paths without colon or control characters')
    require(str(PurePosixPath(value)) == value and '..' not in PurePosixPath(value).parts,
            'source mount path must be canonical: ' + value)
    return value

def overlaps(left, right):
    return left == right or left.startswith(right.rstrip('/') + '/') or right.startswith(left.rstrip('/') + '/')

def expand_go_environment(value):
    # act expands environment references, not shell quoting or substitutions.
    return re.sub(r'\$(?:\{([^}]+)\}|([A-Za-z0-9_]+|[^A-Za-z0-9_]))',
                  lambda match: os.environ.get(match[1] or match[2], ''), value)

def configuration():
    home = Path(os.environ.get('HOME', str(Path.home())))
    if os.environ.get('XDG_CONFIG_HOME'):
        config = Path(os.environ['XDG_CONFIG_HOME'])
    elif sys.platform == 'darwin':
        config = home / 'Library/Application Support'
    else:
        config = home / '.config'
    locations = [config / 'act/actrc', home / '.actrc', Path.cwd() / '.actrc']
    arguments, evidence = [], []
    for path in locations:
        path = path.absolute()
        if not path.exists() and not path.is_symlink():
            evidence.append(dict(path=str(path), sha256=None))
            continue
        content = regular(path)
        evidence.append(dict(path=str(path), sha256=digest(content)))
        for line in content.decode('utf-8').splitlines():
            line = expand_go_environment(line.strip())
            if line.startswith('-'):
                arguments.extend(re.split(r'\s', line, maxsplit=1))
    return arguments, evidence

def options(value):
    require(literal(value), 'container options must be a literal string')
    # Expressions may expand into a mount or workdir switch. They cannot be
    # admitted from the unexpanded YAML and are not rewritten or evaluated.
    require('${{' not in value, 'dynamic container options cannot bind a pinned source layout')
    for arg in shlex.split(value):
        name = arg.split('=', 1)[0]
        require(name not in ('--volume', '--mount', '--tmpfs', '--volumes-from', '--workdir', '--privileged') and
                not (arg.startswith('-v') and not arg.startswith('--')) and
                not (arg.startswith('-w') and not arg.startswith('--')),
                'container options may not override mounts, workdir, or privilege: ' + name)
    return value

def act_options(arguments):
    effective = ''
    # act v0.2.86 supplies these Docker mappings before applying repeated -P
    # values. Its runs-on label selection stops at the first mapped label.
    platforms = {name: 'act-default-container' for name in
                 ('ubuntu-latest', 'ubuntu-22.04', 'ubuntu-20.04', 'ubuntu-18.04')}
    position = 0
    forbidden = {'--directory', '--workflows', '--job', '--bind', '--no-skip-checkout',
                 '--artifact-server-path', '--reuse', '--privileged'}
    while position < len(arguments):
        arg = arguments[position]
        require(literal(arg), 'invalid act argument')
        name, equal, value = arg.partition('=')
        require(name not in forbidden and not re.match(r'^-[CWjbr](?:[^-]|$)', arg),
                'act option conflicts with pinned source layout: ' + name)
        if name == '--container-options':
            if not equal:
                position += 1
                require(position < len(arguments), '--container-options requires a value')
                value = arguments[position]
            effective = options(value)
        elif name in ('--platform', '-P') or (arg.startswith('-P') and len(arg) > 2):
            if arg.startswith('-P') and len(arg) > 2:
                value = arg[2:].lstrip('=')
            elif not equal:
                position += 1
                require(position < len(arguments), '--platform requires a value')
                value = arguments[position]
            platform, separator, image = value.partition('=')
            require(separator and platform and image and value.count('=') == 1,
                    'invalid act runner image mapping')
            platforms[platform.lower()] = image
        position += 1
    return effective, platforms

def select_jobs(document, job):
    jobs = document.get('jobs')
    require(isinstance(jobs, dict) and jobs, 'workflow jobs must be a mapping')
    require(not job or job in jobs, 'selected workflow job is missing')
    selected, visiting = set(), set()
    def visit(name):
        require(isinstance(name, str) and name in jobs, 'job dependency must name a local workflow job')
        require(name not in visiting, 'workflow job dependencies contain a cycle')
        if name in selected:
            return
        visiting.add(name)
        spec = jobs[name]
        require(isinstance(spec, dict) and 'uses' not in spec,
                'pinned sibling sources do not support reusable workflow jobs: ' + name)
        needs = spec.get('needs', [])
        if isinstance(needs, str):
            needs = [needs]
        require(isinstance(needs, list), 'job needs must be literal job names')
        for dependency in needs:
            visit(dependency)
        selected.add(name)
        visiting.remove(name)
    for name in ([job] if job else jobs):
        visit(name)
    return sorted(selected)

def check_job(spec, effective, protected, platforms):
    container = spec.get('container')
    if isinstance(container, str):
        require(literal(container) and '${{' not in container,
                'expression-valued container declarations are unsupported for pinned sources')
        container = dict(image=container)
    elif container is None:
        # An explicit YAML null is still a scalar container declaration in
        # act's model: its empty job options override CLI container options.
        container = dict(options=effective) if effective and 'container' not in spec else {}
    else:
        require(isinstance(container, dict), 'unsupported workflow container declaration')
        container = copy.deepcopy(container)
    if 'options' in container:
        options(container['options'])
    image = container.get('image', '')
    require(literal(image), 'container image must be a string')
    if not image or '${{' in image:
        runners = spec.get('runs-on', [])
        if isinstance(runners, str):
            runners = [runners]
        if not isinstance(runners, list) or any(not literal(name) or '${{' in name for name in runners):
            require(not any(value.lower() == '-self-hosted' for value in platforms.values()),
                    'dynamic runner selection could bypass pinned container mounts with -self-hosted')
        else:
            for runner in runners:
                mapped = platforms.get(runner.lower(), '')
                if mapped:
                    require(mapped.lower() != '-self-hosted',
                            'host execution bypasses pinned sibling container mounts: ' + runner)
                    break
    volumes = container.get('volumes', [])
    require(isinstance(volumes, list), 'container volumes must be a literal array')
    for volume in volumes:
        require(literal(volume) and '${{' not in volume, 'container volume must be literal')
        parts = volume.split(':')
        require(len(parts) in (1, 2, 3), 'unsupported container volume syntax')
        destination = parts[0] if len(parts) == 1 else parts[1]
        absolute(destination)
        require(not any(overlaps(destination, path) for path in protected),
                'existing container volume conflicts with source layout: ' + destination)
    steps = spec.get('steps', [])
    require(isinstance(steps, list), 'workflow steps must be an array')
    for step in steps:
        if not isinstance(step, dict):
            raise Refused('workflow step must be a mapping')
        if str(step.get('uses', '')).lower().startswith('actions/checkout@'):
            checkout = step.get('with') or {}
            require(isinstance(checkout, dict), 'checkout inputs must be a mapping')
            for key in ('repository', 'ref', 'path'):
                value = checkout.get(key, '')
                expected = {'repository': '${{ github.repository }}', 'ref': '${{ github.ref }}', 'path': '.'}[key]
                require(value in ('', expected), 'checkout override can replace the admitted source: ' + key)
    return container

def plan(repo, workflow, job, checkouts, arguments, document):
    require(os.name == 'posix', 'pinned act source layouts require a Unix controller')
    root = Path(repo).resolve(strict=True)
    absolute(str(root))
    relative = PurePosixPath(workflow)
    require(not relative.is_absolute() and '..' not in relative.parts and str(relative) == workflow,
            'workflow must be a canonical path within the main repository')
    workflow_path = root / workflow
    require(root == workflow_path.resolve().parent or root in workflow_path.resolve().parents,
            'workflow escapes the repository')
    original = regular(workflow_path)
    require(isinstance(checkouts, list) and checkouts, 'missing pinned sibling source configuration')
    names = []
    for row in checkouts:
        require(isinstance(row, dict) and set(row) == {'relative_path', 'local_path', 'git_sha'},
                'invalid pinned sibling source description')
        name = row['relative_path']
        require(isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]*', name) and
                '..' not in name and name.lower() != root.name.lower(), 'sibling conflicts with the main source name')
        require(re.fullmatch(r'(?!0{40}$)[0-9a-f]{40}', row['git_sha']) is not None, 'sibling needs an exact commit')
        absolute(row['local_path'])
        names.append(name)
    require(len(set(name.lower() for name in names)) == len(names), 'duplicate sibling mount destination')
    require(isinstance(arguments, list) and all(isinstance(arg, str) for arg in arguments), 'invalid act argv')
    ambient, evidence = configuration()
    effective, platforms = act_options(ambient + arguments)
    selected = select_jobs(document, job)
    protected = [str(root)] + [str(root.parent / name) for name in names]
    containers = {name: check_job(document['jobs'][name], effective, protected, platforms) for name in selected}
    identity = dict(schema_version=1, workflow=workflow, workflow_sha256=digest(original), job=job,
                    jobs=selected, dependencies=[dict(relative_path=row['relative_path'], git_sha=row['git_sha'])
                        for row in checkouts], act_arguments_sha256=digest(canonical(ambient + arguments)),
                    container_config_sha256=digest(canonical(containers)))
    return dict(identity=identity, root=str(root), original_workflow=str(workflow_path),
                checkouts=checkouts, document=document, containers=containers, actrc=evidence)

def project_document(original, containers, mounts):
    document = copy.deepcopy(original)
    for name, container in containers.items():
        container = copy.deepcopy(container)
        container['volumes'] = container.get('volumes', []) + [
            row['source'] + ':' + row['destination'] + ':ro' for row in mounts]
        document['jobs'][name]['container'] = container
    return document

def project(value, dependencies, directory):
    directory = Path(directory)
    absolute(str(directory))
    require([dict(relative_path=row['relative_path'], git_sha=row['git_sha']) for row in dependencies] ==
            value['identity']['dependencies'], 'materialized sibling identities changed')
    mounts = []
    for row in dependencies:
        source = absolute(row['source_root'])
        require(Path(source) == directory / 'siblings' / row['relative_path'], 'private source root escaped attempt storage')
        destination = absolute(str(Path(value['root']).parent / row['relative_path']))
        mounts.append(dict(source=source, destination=destination, read_only=True))
        # Bind targets need to be readable by the configured container user.
        # Follow no links and preserve executability; never chmod the original.
        for current, dirs, files in os.walk(source, followlinks=False):
            for path in [Path(current)] + [Path(current) / name for name in files]:
                mode = path.lstat().st_mode
                if stat.S_ISDIR(mode):
                    path.chmod(stat.S_IMODE(mode) | 0o555)
                elif stat.S_ISREG(mode):
                    path.chmod(stat.S_IMODE(mode) | 0o444 | (0o111 if mode & 0o111 else 0))
    document = project_document(value['document'], value['containers'], mounts)
    projected = directory / 'workflow.yml'
    with projected.open('xb') as stream:
        stream.write(canonical(document))
    receipt = dict(schema_version=1, identity=value['identity'], root=value['root'],
                   original_workflow=value['original_workflow'], projected_workflow=str(projected),
                   projected_workflow_sha256=digest(projected.read_bytes()), actrc=value['actrc'],
                   dependencies=dependencies, mounts=mounts, containers=value['containers'])
    with (directory / 'source-layout.json').open('xb') as stream:
        stream.write(canonical(receipt))
    return receipt

def verify(receipt, original):
    require(receipt.get('schema_version') == 1, 'unsupported source layout receipt')
    identity = receipt['identity']
    require(digest(regular(Path(receipt['original_workflow']))) == identity['workflow_sha256'],
            'original workflow changed after source admission')
    projected = Path(receipt['projected_workflow'])
    require(digest(regular(projected)) == receipt['projected_workflow_sha256'], 'projected workflow bytes changed')
    require(json.loads(regular(projected.parent / 'source-layout.json')) == receipt, 'source layout receipt changed')
    _, current_config = configuration()
    require(current_config == receipt['actrc'], 'act configuration changed after source admission')
    require([dict(relative_path=row['relative_path'], git_sha=row['git_sha']) for row in receipt['dependencies']] ==
            identity['dependencies'], 'source layout dependencies differ from admitted pins')
    document = json.loads(regular(projected))
    require(digest(canonical(receipt['containers'])) == identity['container_config_sha256'],
            'effective container configuration changed after task admission')
    require(sorted(receipt['containers']) == identity['jobs'], 'projection job ownership changed')
    require(document == project_document(original, receipt['containers'], receipt['mounts']),
            'projected workflow no longer preserves the original workflow and admitted container layout')
    require(len(receipt['mounts']) == len(receipt['dependencies']), 'source layout has incomplete mounts')
    for row, mount in zip(receipt['dependencies'], receipt['mounts']):
        require(mount == dict(source=row['source_root'], destination=str(Path(receipt['root']).parent / row['relative_path']),
                             read_only=True), 'source mount identity changed')
        require(Path(row['source_root']) == projected.parent / 'siblings' / row['relative_path'],
                'source root is not private to this invocation')
        for name in identity['jobs']:
            require(mount['source'] + ':' + mount['destination'] + ':ro' in document['jobs'][name]['container']['volumes'],
                    'projected job is missing its read-only sibling mount')

try:
    with os.fdopen(3, 'rb') as stream:
        raw = stream.read()
    require(raw.endswith(b'\0'), 'truncated source layout input')
    operation, *args = [value.decode('utf-8') for value in raw[:-1].split(b'\0')]
    if operation == 'plan':
        result = plan(*args[:3], *map(json.loads, args[3:]))
    elif operation == 'project':
        result = project(json.loads(args[0]), json.loads(args[1]), args[2])
    elif operation == 'verify':
        verify(json.loads(args[0]), json.loads(args[1]))
        result = None
    else:
        raise Refused('unknown source layout operation')
    if result is not None:
        sys.stdout.buffer.write(canonical(result))
except (Refused, OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
    sys.stderr.write('[act] Pinned sibling source layout refused: ' + str(exc) + '\n')
    raise SystemExit(4)
PY
}

export -f _act_source_load_git act_source_plan act_source_materialize act_source_verify _act_source_python
