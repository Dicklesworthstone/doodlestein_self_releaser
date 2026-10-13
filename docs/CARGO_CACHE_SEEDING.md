# Private Cargo cache seeding

`cargo_cache.sh` prepares independent cache inodes for native Unix builds. The
existing ordinary runner ships `_cargo_cache_run` itself to the build host;
this function remains self-contained. No compiler, Git command, network request,
or downloaded script runs during an unscoped snapshot.

## Ordinary seeds

```bash
bash src/cargo_cache.sh snapshot /home/builder/.cargo /srv/build/cargo-home
```

Without a lockfile, the snapshot copies the complete `registry/` tree and the
`git/db/` database store. It does **not** enumerate or copy `git/checkouts/` or
other entries beside `git/db/`. Cargo reconstructs its Git working copies from
those databases. In particular, an unrelated checkout's symlinked `LICENSE`
no longer aborts seed preparation (the failure reported in issue #39).

Registry contents, including extracted `registry/src/` and source-only caches,
retain their existing behavior. This matters when copying already-prepared
private registry sources. This change is deliberately not a switch to a
registry-download-only policy and is not lockfile-scoped minimization: every
ordinary Git database is still copied. Unrelated damage inside a selected
registry or database can still refuse a seed. Passing the source lockfile in
all ordinary orchestration paths remains a separate part of issue #39.

A successful snapshot means the selected bytes were copied and independently
inventoried. It does not mean the cache contains every dependency required for
an offline build. When `git/db/` is absent, an extracted checkout is not used
as a fallback source or a replacement database; the seed can be incomplete.
The caller's existing dependency-resolution and build checks remain required.
The source cache is never repaired or modified by selection.

## Lockfile-scoped seeds

```bash
bash src/cargo_cache.sh snapshot /home/builder/.cargo /srv/build/cargo-home \
  /srv/source/Cargo.lock
```

This existing path is unchanged. It selects matching registry archives and
indexes plus Git databases containing locked revisions. It excludes extracted
registry and Git sources and binds the lockfile digest in the selection receipt.
A missing or incorrect download is not silently replaced with untrusted
extracted source bytes. The caller's locked/offline metadata gate determines
whether the resulting seed is complete before release compilation.

## Integrity and later materialization

All selected cache roots and entries still refuse symlinks, special files and
external Git storage pointers. Ordinary selection holds root/database identities
through the copy and rechecks them before publishing a seed receipt. Selected
files are copied to fresh inodes and rehashed; ambient hardlinks never become
shared private files. New or replaced database roots during preparation are a
refusal, not permission to accept a different cache silently.

The exclusion applies only to **seed selection**. `inventory` and `verify`
continue to cover the complete private `registry/` and `git/` trees, including
Git checkouts recreated during resolution or compilation. Their existing
content, mode, membership, symlink and external-hardlink checks are unchanged.
Existing receipts with materialized Git checkouts can still be verified against
those exact retained files; verification does not rewrite them into new seeds.

The [Cargo home documentation](https://doc.rust-lang.org/cargo/guide/cargo-home.html)
describes `git/db`, `git/checkouts`, and reconstruction from cached inputs.

## Regression and limits

Run `bash scripts/tests/test_cargo_cache.sh`. The suite exercises the complete
cache module with real filesystem operations, Git databases, copies, object
checks and reconstructed working trees. It covers an unrelated linked LICENSE,
a 32 MiB unselected checkout file, selected-input refusal, existing lockfile
selection and whole-private-cache verification. One deterministic change at the
real inventory-return boundary tests a database replacement after copying.

When Cargo and rustc are installed, the additional local `file://` dependency
test runs an actual locked/offline Cargo build after both the original cache
and dependency repository have been moved away. It does not install a toolchain;
without those dependencies it reports an explicit skip. Git object reconstruction
alone is not claimed as native compiler, complete DSR orchestration, or public
release qualification. Windows has its separate cache backend and is unchanged.
No fleet performance improvement or exact dependency-minimality is claimed.
