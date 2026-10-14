# Private Cargo cache seeding

`cargo_cache.sh` prepares independent cache inodes for native Unix builds. The
existing ordinary runner ships `_cargo_cache_run` itself to the build host;
this function remains self-contained. No compiler, Git command, network request,
or downloaded script runs during an unscoped snapshot.

## Ordinary seeds

```bash
bash src/cargo_cache.sh snapshot /home/builder/.cargo /srv/build/cargo-home
```

Without a lockfile, the snapshot copies registry downloads/indexes, source-only
registry packages, and the `git/db/` database store. It does **not** enumerate or copy `git/checkouts/` or
other entries beside `git/db/`. Cargo reconstructs its Git working copies from
those databases. In particular, an unrelated checkout's symlinked `LICENSE`
no longer aborts seed preparation (the failure reported in issue #39).

For an ambient home, an extracted `registry/src/REGISTRY/PACKAGE-VERSION` is
omitted when the **same registry** has a nonempty regular
`registry/cache/REGISTRY/PACKAGE-VERSION.crate`. Cargo recreates that expansion
from its cached archive. The expanded tree is not opened or walked: modifications,
symlinks, FIFOs, and large redundant source files inside it do not enter the seed.
Different versions and registries never substitute for the selected archive.

Packages without that download, including source-only registries and empty
archive files, retain their full materialized source trees. Unknown registry
metadata retains its original copying policy. A nonempty archive is not an
authentication proof: the ordinary snapshot does not assert that it is a valid
package or matches a release lockfile. Cargo and the caller's existing dependency
checks remain responsible for actual consumption and admission. Corrupt archives
are not a reason to import an otherwise omitted, potentially modified source.

**Copying an already-prepared DSR seed preserves materialized registry sources.**
Its existing `.dsr-cache-seed.json` marker conservatively disables only this
registry optimization, because source-authentication receipts may name those
paths. The marker is never followed, copied, or accepted as proof that the source
is trustworthy. A linked or forged marker cannot make a linked source pass the
ordinary inventory checks. Marker changes during preparation are refused.

This is not lockfile-scoped minimization: every ordinary registry download and
Git database is still copied. Unrelated damage inside selected downloads,
source-only packages, indexes, or databases can still refuse a seed. Passing the
source lockfile in all ordinary orchestration paths remains a separate part of
issue #39.

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

Lockfile-scoped selection retains matching registry archives and indexes plus
Git databases containing locked revisions. It excludes extracted registry and
Git sources and binds the lockfile digest in the selection receipt.
A missing or incorrect download is not silently replaced with untrusted
extracted source bytes. The caller's locked/offline metadata gate determines
whether the resulting seed is complete before release compilation.

## Relocated ambient cache roots

An operator may store `$CARGO_HOME/registry` or `$CARGO_HOME/git` on another
volume using an absolute or relative directory symlink. Snapshot preparation
now supports these two layout links for both ordinary and lockfile-scoped
seeds. The source Cargo home itself must remain a real directory; pass its
physical path when the home is relocated. No extra opt-in flag is required.

Only the two top-level cache roots receive this exception. Selected routing
directories, archives, source files and Git storage below them still use
no-follow reads. Broken links, links to files, overlapping physical cache
roots, and destinations inside a relocated source root are refused. An unused
root is not opened: a registry-only lockfile can ignore an unrelated broken
`git` alias, and a Git-only lockfile can ignore an unrelated `registry` alias.

The copier holds each selected physical root descriptor across selection and
copying. It checks the logical link, physical directory, source home and
preparation-marker identities before publishing a receipt and again afterward.
A retargeted link or replaced directory is a refusal, even if the new location
contains identical bytes. Ordinary unrelated cache-directory activity does not
invalidate a stable selected root. These checks detect persistent concurrent
changes; they are not a filesystem transaction against a privileged adversary.

**The destination contains real directories and fresh, independent file
inodes, never the source aliases.** Removing or writing the ambient cache after
successful preparation cannot change its private copy. The receipt format,
lockfile selection policy and later source authentication are unchanged.

A source containing `.dsr-cache-seed.json` is an already-prepared private home:
its roots may not become aliases. The marker is an optimization/alias opt-out,
not a source authentication proof. `inventory` and `verify` never enable the
ambient-layout exception, including for a previously successful private copy.

## Integrity and later materialization

Apart from the two ambient root aliases described above, selected cache entries
still refuse symlinks, special files and external Git storage pointers.
Ordinary selection holds root/database identities through the copy and rechecks
them before publishing a seed receipt. It also
binds every archive that authorizes omission of an extracted registry package,
refusing archive replacement, removal, or byte changes detected after copying.
Newly selected source-only packages similarly stop receipt publication. Selected
files are copied to fresh inodes and rehashed; ambient hardlinks never become
shared private files. New or replaced database roots during preparation are a
refusal, not permission to accept a different cache silently.

The exclusion applies only to **seed selection**. `inventory` and `verify`
continue to cover the complete private `registry/` and `git/` trees, including
Git checkouts and registry source trees recreated during resolution or compilation. Their existing
content, mode, membership, symlink and external-hardlink checks are unchanged.
Existing receipts with materialized Git checkouts can still be verified against
those exact retained files; verification does not rewrite them into new seeds.

The [Cargo home documentation](https://doc.rust-lang.org/cargo/guide/cargo-home.html)
describes `git/db`, `git/checkouts`, and reconstruction from cached inputs.

## Regression and limits

Run `bash scripts/tests/test_cargo_cache_roots.sh` for the relocated-root
regressions. They execute the complete cache CLI and the actual sourceable
function carried to native hosts, with real archives, local Git databases and
independent copies. Separate direct tests of the production descriptor guard
change actual links/directories to exercise held-root refusal. These are Unix
filesystem and cache tests, not native macOS or compiler qualification.

Run `bash scripts/tests/test_cargo_cache.sh`. The suite exercises the complete
cache module with real filesystem operations, Git databases, copies, object
checks and reconstructed working trees. It covers an unrelated linked LICENSE,
a 32 MiB unselected checkout file, a 64 MiB omitted registry expansion,
same-registry/version routing, source-only compatibility, copied prepared seeds,
selected-input refusal, existing lockfile selection and whole-private-cache
verification. Real tar bytes reconstruct the original package after the ambient
tree is moved away, without importing altered extracted sources. Deterministic
changes at the real inventory-return boundary exercise late database/archive
replacement and changed source selection; they are not live race benchmarks.

When Cargo and rustc are installed, the local `file://` Git dependency test runs
an actual locked/offline Cargo build after both the original cache and dependency
repository have been moved away. A second test uses a tiny registry served on
loopback, stops its server, moves the ambient cache away, and requires genuine
locked/offline Cargo to reconstruct and compile authentic archived source rather
than a modified working copy. Neither test installs a toolchain or uses public
network services; without the dependencies each reports an explicit skip. Git/tar reconstruction
alone is not claimed as native compiler, complete DSR orchestration, or public
release qualification. Windows has its separate cache backend and is unchanged.
No fleet performance improvement or exact dependency-minimality is claimed.
