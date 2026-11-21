#!/usr/bin/env bash
# Literal configured environment through real strict Cargo metadata and builds.
# Private cache preparation, source authentication, Cargo and rustc are real.
# The remote case uses a local SSH executable boundary and the real zsh parser;
# this does not claim native host admission, scheduling or release qualification.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
MODULE=${DSR_TEST_ACT_RUNNER:-$ROOT/src/act_runner.sh}
for dependency in bash cargo rustc jq yq python3 cmp; do
    command -v "$dependency" >/dev/null 2>&1 || {
        printf 'Missing native environment test dependency: %s\n' "$dependency" >&2
        exit 3
    }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsr-native-env.XXXXXXXX") || exit 1
printf 'Retained native environment fixtures: %s\n' "$WORK"
mkdir -p "$WORK/config/repos.d" "$WORK/bin" "$WORK/ambient" "$WORK/template/src" || exit 1
export DSR_CONFIG_DIR="$WORK/config" DSR_HOSTS_FILE="$WORK/config/hosts.yaml"
export CARGO_HOME="$WORK/ambient" DSR_ENV_AMBIENT=must-not-expand
export PATH="$WORK/bin:$PATH"
# shellcheck source=../../src/act_runner.sh
source "$MODULE" || exit 3

case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:amd64) PLATFORM=linux/amd64 ;;
    Linux:aarch64|Linux:arm64) PLATFORM=linux/arm64 ;;
    Darwin:x86_64) PLATFORM=darwin/amd64 ;;
    Darwin:arm64) PLATFORM=darwin/arm64 ;;
    *) printf 'Unsupported native fixture platform\n' >&2; exit 3 ;;
esac
jq -n --arg platform "$PLATFORM" \
    '{hosts:{"literal-remote":{platform:$platform,connection:"ssh"}}}' > "$DSR_HOSTS_FILE" || exit 1
cat > "$WORK/bin/ssh" <<'SH'
#!/usr/bin/env bash
# Only transport is controlled: the receiving login-shell parser and complete
# emitted metadata/private-cache/compiler program execute normally on stdin.
exec "$SHELL" -c "${!#}"
SH
chmod +x "$WORK/bin/ssh" || exit 1

cat > "$WORK/template/Cargo.toml" <<'TOML'
[package]
name = "native_env_probe"
version = "0.1.0"
edition = "2021"
TOML
cat > "$WORK/template/src/main.rs" <<'RS'
fn main() {
    assert!(cfg!(dsr_build = "release"));
    print!("{}|{}", env!("DSR_ENV_LITERAL"), env!("DSR_ENV_EMPTY"));
}
RS
cargo generate-lockfile --offline --manifest-path "$WORK/template/Cargo.toml" \
    > "$WORK/lock.stdout" 2> "$WORK/lock.stderr" || exit 1

PASS=0 FAIL=0
check() {
    local label="$1"; shift
    if "$@"; then
        PASS=$((PASS + 1)); printf 'PASS: %s\n' "$label"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$label" >&2
    fi
}

# Exercise all four characters that have meaning inside a double-quoted shell
# word, plus spaces, an equals sign, an empty override and a non-ASCII value.
# The apparent substitutions print only inert text if the incumbent evaluates
# them; the actual compiled bytes must retain the literal expressions.
literal='  $DSR_ENV_AMBIENT "quoted" \slash `printf backtick-expanded` $(printf command-expanded) = café  '
printf '%s|' "$literal" > "$WORK/expected.stdout"
for transport in local-bash ssh-zsh; do
    host=act
    receiver_shell=$(command -v bash) || exit 3
    if [[ "$transport" == ssh-zsh ]]; then
        if ! receiver_shell=$(command -v zsh); then
            printf 'SKIP: zsh receiver is unavailable; local Bash remains exercised\n'
            continue
        fi
        host='literal-remote'
    fi
    for flags in RUSTFLAGS CARGO_ENCODED_RUSTFLAGS; do
        label="$transport-$flags"
        case_root="$WORK/$label"
        mkdir -p "$case_root/source/src" || exit 1
        cp "$WORK/template/Cargo.toml" "$WORK/template/Cargo.lock" "$case_root/source/" || exit 1
        cp "$WORK/template/src/main.rs" "$case_root/source/src/" || exit 1
        flag_value='--cfg dsr_build="release" -Aunexpected_cfgs'
        [[ "$flags" != CARGO_ENCODED_RUSTFLAGS ]] || \
            flag_value=$'--cfg\x1fdsr_build="release"\x1f-Aunexpected_cfgs'
        jq -n --arg platform "$PLATFORM" --arg literal "$literal" \
            --arg source "$case_root/source" --arg output "$case_root/target" \
            --arg path "$PATH" --arg flags "$flags" --arg value "$flag_value" '{
                language:"rust",derive_cargo_build_target:false,local_path:$source,
                build_cmd:"cargo build --offline --locked --quiet",
                env:({PATH:$path,CARGO_TARGET_DIR:$output,DSR_ENV_LITERAL:$literal,
                      DSR_ENV_EMPTY:"global"} + {($flags):$value}),
                cross_compile:{($platform):{env:{DSR_ENV_EMPTY:""}}}
            }' > "$ACT_REPOS_DIR/literal.yaml" || exit 1
        environment=$(act_get_build_env literal "$PLATFORM") || exit 1
        command=$(act_get_build_cmd literal "$PLATFORM") || exit 1

        metadata_status=0
        SHELL="$receiver_shell" _act_strict_cargo_metadata_json \
            "$host" "$case_root/source" "$command" "$environment" \
            > "$case_root/metadata.json" 2> "$case_root/metadata.stderr" || metadata_status=$?
        printf '%s\n' "$metadata_status" > "$case_root/metadata.status"
        check "$label strict metadata accepts the quoted compiler flag" test "$metadata_status" -eq 0
        check "$label metadata retains the actual workspace" jq -se --arg root "$case_root/source" \
            'length == 1 and .[0].source_root == $root and any(.[0].metadata.packages[]; .name == "native_env_probe")' \
            "$case_root/metadata.json"

        # Reuse the production metadata environment in an independently fresh
        # private cache, then invoke the actual configured compiler command.
        # No native disk-admission checks are disabled or substituted here.
        program=$(_act_unix_private_cargo_home_script "$case_root/source" literal-build) || exit 1
        body=$(_act_unix_cargo_metadata_body "$command" "$environment") || exit 1
        program+=$'\n'"$body"$'\n'"$command"$'\n''"$CARGO_TARGET_DIR/debug/native_env_probe"'
        printf '%s\n' "$program" > "$case_root/build-program.sh"
        build_status=0
        SHELL="$receiver_shell" _act_ssh_exec "$host" "$program" 90 \
            > "$case_root/build.stdout" 2> "$case_root/build.stderr" || build_status=$?
        printf '%s\n' "$build_status" > "$case_root/build.status"
        check "$label compiles and executes with the selected cfg value" test "$build_status" -eq 0
        check "$label executable retains exact configured input bytes" \
            cmp -s "$WORK/expected.stdout" "$case_root/build.stdout"
        if [[ "$metadata_status" -ne 0 || "$build_status" -ne 0 ]]; then
            cat "$case_root/metadata.stderr" "$case_root/build.stderr" >&2
        fi
    done
done
printf 'Native environment literals: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
