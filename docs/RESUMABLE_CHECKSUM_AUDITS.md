# Resume complete checksum audits

A failed download near the end of a release no longer requires downloading
all earlier verified payloads again. Select a previous audit with
`--resume-from` and a **new** output directory:

```bash
bash src/release_checksums.sh --repo owner/tool --tag v1.2.3 \
  --resume-from /srv/audits/first-attempt --output-dir /srv/audits/retry
```

The auditor reads the current complete release inventory and reacquires every
selected checksum aggregate or sidecar. Only previously verified payloads are
eligible for reuse. Each retained file is checked against the fresh checksum,
size, and available API digest, copied without hardlinks, and checked again.
Unverified partial files are downloaded anew. Altered previously verified files
are errors, not permission to silently replace earlier evidence.

The same release ID, complete inventory, and checksum policy must still match.
Replacing an asset, changing the selected aggregate, switching aggregate/sidecar
mode, or changing metadata inclusion requires a fresh audit. The original
attempt, including failures and partial downloads, is never rewritten. Output
and wrapper workspace paths must not overlap the retained audit directory.

Results distinguish `verified_count` from `resume.reused_count` and retain
`resume.reused_checksums` and `resume.reused_bytes`. Reuse does not bypass the
whole-release byte limits, final inventory check, or final proof/payload hashes.
A completed audit can also be reused, but checksum evidence is still fetched
again. Neither cached nor downloaded checksums authenticate the publisher.

`--preflight` validates local options, paths, dependencies, and retained selection
metadata without downloading or claiming that cached payloads have been checked.
The source directory must contain a valid `selection.json` and `result.json`
from a resumable audit. Older directories without those records are refused.
SIGKILL/power-loss recovery without a valid result is not promised.

Run `bash scripts/tests/test_release_checksum_resume.sh` for the focused
recovery regression. It executes the production auditor and checksum parser
with owned files and an explicit HTTP acquisition fixture. This is not live
GitHub or publisher-signature qualification.

## Release CLI and downstream synchronization

The regular CLI retains its original manifest and strict-release checks on both
sides of a resumed audit:

```bash
dsr --json release verify tool 1.2.3 --checksums \
  --checksum-resume-from /srv/audits/first-attempt \
  --checksum-output-dir /srv/audits/retry-cli
```

Use the audit directory reported as `details.checksums.evidence_dir`, not the
outer CLI workspace. The `checksums.resume` result records actual reuse.
`--fix` cannot be combined with resume, even under `--dry-run`: repair can
change the pinned inventory. Repair separately, then start a fresh audit.
Ordinary dry-run still checks downloaded bytes but prevents repair writes.

Audited downstream sync accepts the retained selection only with
`--verify-release`:

```bash
bash src/checksum_sync.sh sync tool 1.2.3 --repo owner/tool \
  --target-repo owner/installers --verify-release \
  --audit-resume-from /srv/audits/first-attempt --dry-run --json
```

The complete fresh audit and retained-proof/payload checks must pass before
any downstream clone, commit, issue, or push. Local manifests and artifact
caches cannot substitute for the audit. Removing `--dry-run` creates retained
local commits; pushing still requires explicit `--push`. Cancellation forwards
to owned download processes and cannot turn partial reuse into success.

The focused regression also exercises production command registration and the
CLI/sync handoffs. Its original metadata/repair command and HTTP acquisition are
explicit fixtures; full original-root startup and live release repair are not
qualified by that test. The broader retained validation suite separately tests
real Git operations against isolated local repositories and real curl with a
local TLS server.
