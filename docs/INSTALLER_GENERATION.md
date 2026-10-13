# Ordinary installer generation

The sourced `install_gen_create` API generates the ordinary per-tool Bash
installer. This is separate from the pinned, authenticated installer generator
in `install_gen_release.sh`.

```bash
source src/install_gen.sh
install_gen_create ntm --config-dir "$HOME/.config/dsr"
```

The explicit configuration root selects `DIR/repos.d/TOOL.yaml` with no
fallback. Without it, generation retains the existing current-directory-first
configuration lookup and logs the selected file. Set `DSR_INSTALLER_DIR` before
sourcing the module to select an output root; the default is `./installers`.
Success prints only the generated installer path to stdout. Diagnostics and
retained-history paths go to stderr.

## Publication, failure and concurrent generation

Generation validates the tool identifier before constructing configuration
paths and the configured tool/repository/binary identities before rendering.
It observes the selected output ancestry and any existing `install.sh` before
rendering starts. It then renders the complete installer in memory and checks
its Bash syntax without executing it. Rendering, help-text and skill-archive
failures stop generation; they cannot publish a truncated or incomplete script.

A POSIX Python 3 publisher stages the candidate on the destination filesystem,
checks the observed file and directory identities again, and activates it with
one atomic replacement. Existing readers retain the old complete inode; new
readers see the complete replacement. The published mode is `0755`.
An identical, already-executable installer is retained without changing its
inode, timestamps or history. ShellCheck, when installed, remains an advisory
check; Bash syntax validation is mandatory before publication.

Every output path component must be a real directory, not a symbolic link.
Relative roots, spaces, `.` and missing parents are supported; `..` components
are refused. Use a physical path for deliberately symlinked locations, such as
macOS temporary-directory aliases. A linked, hardlinked, directory or special
file at the `install.sh` destination is refused without following or modifying
its target. These rules also apply to the publisher's lock file.

The persistent `.install-gen.lock` serializes cooperating publishers. It is
released by the kernel when a process exits; do not delete it to recover a
failed invocation. Concurrent generators that observed the same prior version
cannot silently overwrite each other: a changed output/ancestry or busy lock
returns a conflict (exit 2). Regenerate against the current state after inspecting
that conflict. Do not reuse a private output-observation token to authorize a
later unrelated generation.

Each changed publication retains `.install-gen.<unique-id>/` under the tool's
output directory. It contains the original observation and candidate digest in
`selection.json`, a private byte-for-byte `previous.sh` when a prior installer
existed, and `completed.json` after successful publication. An interrupted or
failed staging write can leave `candidate.sh` there. Generation does not delete
this history or roll it back automatically. The original mode is recorded in
`selection.json`; the backup is deliberately stored privately as `0600`.
These runtime files are ignored by the repository's Git rules. Distribute the
selected `install.sh`, not a recursive copy of its private history directory.

A failure before replacement leaves the existing installer unchanged. A failure
after replacement, including failure to persist completion evidence, returns
nonzero and explicitly reports that replacement already occurred. It does not
claim rollback or overwrite an externally changed file to manufacture success.
An identical retry rechecks the actual installed bytes rather than inferring
completion from a previous receipt.

This is atomic local publication, not a filesystem power-loss durability
promise or a sandbox against a malicious privileged/same-user writer. Directory
handles prevent symlink redirection and repeated observations reject detected
changes; observations and replacement are not an atomic compare-and-swap with
arbitrary writers that ignore the lock. Generated content is bounded to 64 MiB,
and each syntax-validation subprocess is bounded to 30 seconds. This dependency
is on the generator host; the ordinary generated release installer has no new
Python requirement. No download, installation or compiler runs during generation.

## Regression coverage

```bash
bash scripts/tests/test_install_gen_publication.sh
bash scripts/tests/test_install_gen_identity.sh
```

The publication suite uses the complete generator, simple YAML configuration,
real POSIX files, locks, processes and an actual kernel file-size limit. Controlled
renderer barriers exercise competing writers and edits during rendering. A
clearly labelled interpreter-boundary adapter applies the write limit only after
Bash has delivered its here-document, so the test reaches the real staging write.
Generated scripts are syntax-checked, and only their `--help` path is executed.
All test files and failed-generation evidence are retained.

The optional identity-suite `--parser-fixture` adds typed-parser transport checks
using PyYAML; it does not qualify native yq interoperability. These focused
checks do not qualify a public installer, Windows generation, live downloads,
GNU/musl acquisition, or native builds. Existing committed installers are not
regenerated by this change.
