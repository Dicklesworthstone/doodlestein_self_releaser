#!/usr/bin/env bash
# signing.sh - Minisign key management and artifact signing for dsr
#
# Usage:
#   source signing.sh
#   signing_init           # Generate new keypair (interactive)
#   signing_check          # Verify keypair is configured
#   signing_sign <file>    # Sign a file
#   signing_verify <file>  # Verify a signature
#
# Storage:
#   Private key: ~/.config/dsr/secrets/minisign.key (chmod 600)
#   Public key:  ~/.config/dsr/minisign.pub

set -uo pipefail

# Key paths (relative to DSR_CONFIG_DIR)
SIGNING_SECRETS_DIR="${DSR_CONFIG_DIR:-$HOME/.config/dsr}/secrets"
SIGNING_PRIVATE_KEY="${DSR_MINISIGN_KEY:-$SIGNING_SECRETS_DIR/minisign.key}"
SIGNING_PUBLIC_KEY="${DSR_CONFIG_DIR:-$HOME/.config/dsr}/minisign.pub"

# Colors for output (if not disabled)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _SIGN_RED=$'\033[0;31m'
    _SIGN_GREEN=$'\033[0;32m'
    _SIGN_YELLOW=$'\033[0;33m'
    _SIGN_BLUE=$'\033[0;34m'
    _SIGN_NC=$'\033[0m'
else
    _SIGN_RED='' _SIGN_GREEN='' _SIGN_YELLOW='' _SIGN_BLUE='' _SIGN_NC=''
fi

_sign_log_info()  { echo "${_SIGN_BLUE}[signing]${_SIGN_NC} $*" >&2; }
_sign_log_ok()    { echo "${_SIGN_GREEN}[signing]${_SIGN_NC} $*" >&2; }
_sign_log_warn()  { echo "${_SIGN_YELLOW}[signing]${_SIGN_NC} $*" >&2; }
_sign_log_error() { echo "${_SIGN_RED}[signing]${_SIGN_NC} $*" >&2; }

# Check if minisign is installed
# Returns: 0 if installed, 3 if not
signing_require_minisign() {
    if ! command -v minisign &>/dev/null; then
        _sign_log_error "minisign not found."
        _sign_log_info "Install: brew install minisign (macOS) or apt install minisign (Ubuntu)"
        _sign_log_info "Or: cargo install minisign"
        return 3
    fi
    return 0
}

# Check if signing is properly configured
# Usage: signing_check [--json]
# Returns: 0 if valid keypair exists, 3 if not
# shellcheck disable=SC2120  # CLI dispatcher passes optional --json from dsr.
signing_check() {
    local json_mode=false
    [[ "${1:-}" == "--json" ]] && json_mode=true

    signing_require_minisign || return 3

    local private_exists=false
    local public_exists=false
    local private_perms=""
    local valid=false

    # Check private key
    if [[ -f "$SIGNING_PRIVATE_KEY" ]]; then
        private_exists=true
        private_perms=$(stat -c '%a' "$SIGNING_PRIVATE_KEY" 2>/dev/null || stat -f '%Lp' "$SIGNING_PRIVATE_KEY" 2>/dev/null)
    fi

    # Check public key
    if [[ -f "$SIGNING_PUBLIC_KEY" ]]; then
        public_exists=true
    fi

    # Valid if both exist and private key has correct permissions
    if $private_exists && $public_exists && [[ "$private_perms" == "600" ]]; then
        valid=true
    fi

    if $json_mode; then
        jq -nc \
            --argjson valid "$valid" \
            --arg private_path "$SIGNING_PRIVATE_KEY" \
            --argjson private_exists "$private_exists" \
            --arg private_perms "$private_perms" \
            --arg public_path "$SIGNING_PUBLIC_KEY" \
            --argjson public_exists "$public_exists" \
            '{
                valid: $valid,
                private_key: {
                    path: $private_path,
                    exists: $private_exists,
                    permissions: $private_perms
                },
                public_key: {
                    path: $public_path,
                    exists: $public_exists
                }
            }'
    else
        _sign_log_info "Private key: $SIGNING_PRIVATE_KEY"
        if $private_exists; then
            if [[ "$private_perms" == "600" ]]; then
                _sign_log_ok "  Status: exists (permissions: $private_perms)"
            else
                _sign_log_warn "  Status: exists (permissions: $private_perms - should be 600)"
            fi
        else
            _sign_log_warn "  Status: not found"
        fi

        _sign_log_info "Public key: $SIGNING_PUBLIC_KEY"
        if $public_exists; then
            _sign_log_ok "  Status: exists"
        else
            _sign_log_warn "  Status: not found"
        fi
    fi

    $valid && return 0 || return 3
}

# Initialize signing keys - generate a new keypair
# Usage: signing_init [--force] [--no-password]
# Returns: 0 on success, 1 on failure, 4 on invalid args
signing_init() {
    local force=false
    local no_password=false

    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            --no-password) no_password=true ;;
            --help|-h)
                cat << 'EOF'
Usage: signing_init [--force] [--no-password]

Generate a new minisign keypair for artifact signing.

Options:
  --force        Overwrite existing keys
  --no-password  Create unprotected key (NOT RECOMMENDED)

The private key will be stored in:
  ~/.config/dsr/secrets/minisign.key (chmod 600)

The public key will be stored in:
  ~/.config/dsr/minisign.pub
EOF
                return 0
                ;;
            *)
                _sign_log_error "Unknown option: $arg"
                return 4
                ;;
        esac
    done

    signing_require_minisign || return 3

    # Check if keys already exist
    if [[ -f "$SIGNING_PRIVATE_KEY" ]] && ! $force; then
        _sign_log_error "Private key already exists: $SIGNING_PRIVATE_KEY"
        _sign_log_info "Use --force to overwrite"
        return 1
    fi

    if [[ -f "$SIGNING_PUBLIC_KEY" ]] && ! $force; then
        _sign_log_error "Public key already exists: $SIGNING_PUBLIC_KEY"
        _sign_log_info "Use --force to overwrite"
        return 1
    fi

    # Create secrets directory with restricted permissions
    _sign_log_info "Creating secrets directory: $SIGNING_SECRETS_DIR"
    mkdir -p "$SIGNING_SECRETS_DIR"
    chmod 700 "$SIGNING_SECRETS_DIR"

    # Generate keypair
    _sign_log_info "Generating minisign keypair..."
    _sign_log_warn "You will be prompted to enter a password to protect the private key."
    _sign_log_warn "This password will be required whenever you sign artifacts."
    echo ""

    local minisign_args=(-G -p "$SIGNING_PUBLIC_KEY" -s "$SIGNING_PRIVATE_KEY")
    if $no_password; then
        _sign_log_warn "WARNING: Creating unprotected key (--no-password)"
        minisign_args+=(-W)
    fi

    if ! minisign "${minisign_args[@]}"; then
        _sign_log_error "Failed to generate keypair"
        return 1
    fi

    # Set strict permissions on private key
    chmod 600 "$SIGNING_PRIVATE_KEY"
    _sign_log_ok "Private key created: $SIGNING_PRIVATE_KEY (mode 600)"

    _sign_log_ok "Public key created: $SIGNING_PUBLIC_KEY"

    # Show public key for embedding
    echo ""
    _sign_log_info "Public key (for embedding in installers and docs):"
    echo ""
    cat "$SIGNING_PUBLIC_KEY"
    echo ""

    _sign_log_ok "Keypair generation complete!"
    _sign_log_info "Remember to:"
    _sign_log_info "  1. Back up your private key securely"
    _sign_log_info "  2. Add the public key to your README"
    _sign_log_info "  3. Never commit the private key to version control"

    return 0
}

# Fix permissions on private key
# Usage: signing_fix_permissions
signing_fix_permissions() {
    if [[ ! -f "$SIGNING_PRIVATE_KEY" ]]; then
        _sign_log_error "Private key not found: $SIGNING_PRIVATE_KEY"
        return 1
    fi

    _sign_log_info "Setting permissions on $SIGNING_PRIVATE_KEY"
    chmod 600 "$SIGNING_PRIVATE_KEY"
    _sign_log_ok "Permissions set to 600"

    # Also fix secrets directory
    if [[ -d "$SIGNING_SECRETS_DIR" ]]; then
        chmod 700 "$SIGNING_SECRETS_DIR"
        _sign_log_ok "Secrets directory permissions set to 700"
    fi

    return 0
}

# Sign a file with minisign
# Usage: signing_sign <file> [--trusted-comment "comment"]
# Creates: <file>.minisig
signing_sign() {
    local file=""
    local trusted_comment=""
    local untrusted_comment=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --trusted-comment|-t)
                [[ $# -ge 2 && -n "$2" ]] || return 4
                trusted_comment="$2"
                shift 2
                ;;
            --untrusted-comment|-c)
                [[ $# -ge 2 && -n "$2" ]] || return 4
                untrusted_comment="$2"
                shift 2
                ;;
            --help|-h)
                cat << 'EOF'
Usage: signing_sign <file> [options]

Sign a file with minisign. Creates <file>.minisig alongside the original.

Options:
  -t, --trusted-comment    Trusted comment (verified with signature)
  -c, --untrusted-comment  Untrusted comment (not verified)

Example:
  signing_sign ntm-v1.2.3-linux-amd64.tar.gz -t "ntm v1.2.3 linux/amd64"
EOF
                return 0
                ;;
            -*)
                _sign_log_error "Unknown option: $1"
                return 4
                ;;
            *)
                if [[ -n "$file" ]]; then
                    _sign_log_error "Multiple files specified. Use signing_sign_batch for multiple files."
                    return 4
                fi
                file="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$file" ]]; then
        _sign_log_error "Usage: signing_sign <file>"
        return 4
    fi

    if [[ ! -f "$file" || -L "$file" || "$file" == *[[:cntrl:]]* ||
          "$trusted_comment" == *[[:cntrl:]]* || "$untrusted_comment" == *[[:cntrl:]]* ]]; then
        _sign_log_error "Signing requires a regular file and single-line comments: $file"
        return 4
    fi

    signing_require_minisign || return 3

    # Freeze the configured trust key before invoking the signer. A successful
    # minisign exit alone is not proof that the correct key or bytes were used.
    local token digest signature="${file}.minisig"
    token=$(signing_public_key_token "$SIGNING_PUBLIC_KEY") || return 3
    digest=$(_signing_sha256 "$file") || return $?
    if [[ -e "$signature" || -L "$signature" ]]; then
        _signing_reuse "$file" "$signature" "$token" "$digest" \
            "$trusted_comment" "$untrusted_comment" || return $?
        _sign_log_ok "Retained verified signature: $signature"
        return 0
    fi
    [[ -n "$trusted_comment" ]] || trusted_comment="dsr artifact ${file##*/} sha256:$digest"
    _sign_log_info "Signing and verifying: $file"
    signing_sign_exact "$file" "$signature" "$SIGNING_PRIVATE_KEY" "$token" \
        "$trusted_comment" "$digest" "$untrusted_comment" || return $?
    _sign_log_ok "Verified signature created: $signature"
    return 0
}

# Verify a file signature
# Usage: signing_verify <file> [--public-key <path>]
signing_verify() {
    local file=""
    local public_key="$SIGNING_PUBLIC_KEY"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --public-key|-p)
                [[ $# -ge 2 && -n "$2" ]] || return 4
                public_key="$2"
                shift 2
                ;;
            --help|-h)
                cat << 'EOF'
Usage: signing_verify <file> [--public-key <path>]

Verify a file's minisign signature. Expects <file>.minisig to exist.

Options:
  -p, --public-key    Path to public key (default: ~/.config/dsr/minisign.pub)
EOF
                return 0
                ;;
            -*)
                _sign_log_error "Unknown option: $1"
                return 4
                ;;
            *)
                if [[ -n "$file" ]]; then
                    _sign_log_error "Multiple files specified. Verify files one at a time."
                    return 4
                fi
                file="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$file" ]]; then
        _sign_log_error "Usage: signing_verify <file>"
        return 4
    fi

    if [[ ! -f "$file" ]]; then
        _sign_log_error "File not found: $file"
        return 4
    fi

    local sig_file="${file}.minisig"
    if [[ ! -f "$sig_file" ]]; then
        _sign_log_error "Signature file not found: $sig_file"
        return 4
    fi

    if [[ ! -f "$public_key" ]]; then
        _sign_log_error "Public key not found: $public_key"
        return 3
    fi

    signing_require_minisign || return 3

    _sign_log_info "Verifying: $file"

    local token status=0
    token=$(signing_public_key_token "$public_key") || return 3
    signing_verify_exact "$file" "$sig_file" "$token" || status=$?
    if [[ "$status" != 0 ]]; then
        _sign_log_error "Signature verification FAILED"
        return "$status"
    fi

    _sign_log_ok "Signature verified successfully"
    return 0
}

# Read the inline Minisign public-key token from a regular public-key file.
# The token is safe to freeze into a release plan and pass to `minisign -P`,
# avoiding any later dependence on mutable worktree key bytes.
signing_public_key_token() {
    local public_key_file="$1"
    local public_key_token=""

    if [[ ! -f "$public_key_file" || -L "$public_key_file" ]]; then
        _sign_log_error "Public key must be a regular non-symlink file: $public_key_file"
        return 4
    fi

    public_key_token=$(sed -n '2{s/\r$//;p;}' "$public_key_file") || return 4
    if [[ ! "$public_key_token" =~ ^[A-Za-z0-9+/]{40,}={0,2}$ ]]; then
        _sign_log_error "Public key file does not contain a valid Minisign token: $public_key_file"
        return 4
    fi

    printf '%s\n' "$public_key_token"
}

# Verify an explicit detached signature with an inline, already-pinned public
# key. `-H` rejects the legacy non-prehashed signature format.
signing_verify_exact() {
    [[ $# -eq 3 ]] || return 4
    local file="$1"
    local signature="$2"
    local public_key_token="$3"

    signing_require_minisign || return 3
    if [[ ! -f "$file" || -L "$file" ]]; then
        _sign_log_error "Signed input must be a regular non-symlink file: $file"
        return 4
    fi
    if [[ ! -f "$signature" || -L "$signature" || ! -s "$signature" ]]; then
        _sign_log_error "Signature must be a regular non-symlink file: $signature"
        return 4
    fi
    if [[ ! "$public_key_token" =~ ^[A-Za-z0-9+/]{40,}={0,2}$ ]]; then
        _sign_log_error "Invalid inline Minisign public key"
        return 4
    fi

    local before signature_before status=0
    before=$(_signing_sha256 "$file") || return $?
    signature_before=$(_signing_sha256 "$signature") || return $?
    minisign -V -H -q -P "$public_key_token" \
        -m "$file" -x "$signature" >/dev/null 2>&1 || status=$?
    [[ "$status" == 0 ]] || return "$status"
    [[ "$(_signing_sha256 "$file")" == "$before" &&
       "$(_signing_sha256 "$signature")" == "$signature_before" ]] || {
        _sign_log_error "Artifact or signature changed during verification: $file"
        return 4
    }
}

_signing_sha256() {
    local file="$1" digest
    [[ -f "$file" && ! -L "$file" ]] || return 4
    if command -v sha256sum &>/dev/null; then
        digest=$(sha256sum < "$file") || return 4
    elif command -v shasum &>/dev/null; then
        digest=$(shasum -a 256 < "$file") || return 4
    else
        return 3
    fi
    digest="${digest%% *}"
    [[ "$digest" =~ ^[0-9a-f]{64}$ && -f "$file" && ! -L "$file" ]] || return 4
    printf '%s\n' "$digest"
}

# Resume is verification, never re-signing. Preserve existing bytes even on a
# conflict: changing a timestamp/comment breaks content-verified upload resume.
_signing_reuse() {
    local file="$1" signature="$2" token="$3" digest="$4"
    local trusted="${5:-}" untrusted="${6:-}" signature_digest
    signature_digest=$(_signing_sha256 "$signature") || return $?
    if [[ -n "$trusted" && "$(sed -n '3{s/\r$//;p;}' "$signature")" != "trusted comment: $trusted" ]] ||
       [[ -n "$untrusted" && "$(sed -n '1{s/\r$//;p;}' "$signature")" != "untrusted comment: $untrusted" ]]; then
        _sign_log_error "Existing signature has different requested comments: $signature"
        return 4
    fi
    signing_verify_exact "$file" "$signature" "$token" || return $?
    [[ "$(_signing_sha256 "$file")" == "$digest" &&
       "$(_signing_sha256 "$signature")" == "$signature_digest" ]] || return 4
}

# Create one exact detached signature without ever overwriting an existing
# sidecar. The candidate signature is staged beside its destination, verified
# with the pinned public key, and only then published with an atomic hard link.
# Once published, a late failure never unlinks the shared destination pathname;
# Bash cannot atomically prove inode ownership and unlink it without a race.
signing_sign_exact() (
    [[ $# -ge 5 && $# -le 7 ]] || return 4
    local file="$1"
    local signature="$2"
    local private_key="$3"
    local public_key_token="$4"
    local trusted_comment="$5"
    local expected_file_sha256="${6:-}"
    local untrusted_comment="${7:-}"
    local signature_parent signature_name staging_dir staged_signature snapshot cleanup
    local file_sha256_before="" file_sha256_after=""
    local status=0

    signing_require_minisign || return 3
    if [[ ! -f "$file" || -L "$file" ]]; then
        _sign_log_error "Signed input must be a regular non-symlink file: $file"
        return 4
    fi
    if [[ ! -f "$private_key" || -L "$private_key" || ! -s "$private_key" ]]; then
        _sign_log_error "Private key must be a regular non-symlink file: $private_key"
        return 3
    fi
    if [[ -e "$signature" || -L "$signature" ]]; then
        _sign_log_error "Refusing to overwrite existing signature: $signature"
        return 4
    fi
    if [[ ! "$public_key_token" =~ ^[A-Za-z0-9+/]{40,}={0,2}$ ||
          -z "$trusted_comment" || "$trusted_comment" == *[[:cntrl:]]* ||
          "$untrusted_comment" == *[[:cntrl:]]* ]]; then
        _sign_log_error "Trusted comment must be one non-empty line"
        return 4
    fi
    file_sha256_before=$(_signing_sha256 "$file") || {
        _sign_log_error "Could not hash input before signing: $file"
        return 4
    }
    if [[ ! "$file_sha256_before" =~ ^[0-9a-f]{64}$ || \
          ( -n "$expected_file_sha256" && \
            "$file_sha256_before" != "$expected_file_sha256" ) ]]; then
        _sign_log_error "Input digest does not match the frozen signing plan: $file"
        return 4
    fi

    signature_parent="${signature%/*}"
    [[ "$signature_parent" == "$signature" ]] && signature_parent="."
    signature_name="${signature##*/}"
    [[ -n "$signature_name" && "$signature_name" != . && "$signature_name" != .. &&
       "$signature_name" != *[[:cntrl:]]* && -d "$signature_parent" && ! -L "$signature_parent" ]] || return 4
    umask 077
    staging_dir=$(mktemp -d \
        "$signature_parent/.${signature_name}.dsr-signing.XXXXXX") || {
        _sign_log_error "Could not create an isolated signature staging directory"
        return 4
    }
    staged_signature="$staging_dir/$signature_name"
    snapshot="$staging_dir/payload"
    # The destination basename can be 'payload'; keep snapshot and signature
    # distinct without assuming a particular sidecar suffix.
    [[ "$snapshot" != "$staged_signature" ]] || snapshot="$staging_dir/input"
    printf -v cleanup 'rm -f -- %q %q; rmdir -- %q 2>/dev/null || true' \
        "$snapshot" "$staged_signature" "$staging_dir"
    # shellcheck disable=SC2064 # Freeze safely quoted local paths for EXIT.
    trap "$cleanup" EXIT
    trap 'exit 5' HUP INT TERM
    cp -- "$file" "$snapshot" || return 4
    chmod 400 "$snapshot" || return 4
    if [[ "$(_signing_sha256 "$snapshot")" != "$file_sha256_before" ||
          "$(_signing_sha256 "$file")" != "$file_sha256_before" ]]; then
        _sign_log_error "Input changed while freezing signing bytes: $file"
        return 4
    fi
    local minisign_args=(-S -s "$private_key" -m "$snapshot" -x "$staged_signature" -t "$trusted_comment")
    [[ -z "$untrusted_comment" ]] || minisign_args+=(-c "$untrusted_comment")

    if ! minisign "${minisign_args[@]}" >/dev/null 2>&1; then
        _sign_log_error "Could not create detached signature: $signature"
        status=4
    elif ! signing_verify_exact "$snapshot" "$staged_signature" "$public_key_token"; then
        _sign_log_error "Private key does not match the pinned public key"
        status=4
    elif ! file_sha256_after=$(_signing_sha256 "$file") || \
         [[ "$file_sha256_after" != "$file_sha256_before" ]]; then
        _sign_log_error "Input changed while its detached signature was staged: $file"
        status=4
    elif ! signing_verify_exact "$file" "$staged_signature" "$public_key_token"; then
        _sign_log_error "Staged signature does not verify against the original artifact"
        status=4
    elif ! ln -- "$staged_signature" "$signature"; then
        _sign_log_error "Could not atomically publish signature without clobbering: $signature"
        status=4
    elif [[ -L "$signature" || ! "$signature" -ef "$staged_signature" ]]; then
        _sign_log_error "Published signature path changed before verification: $signature"
        status=4
    elif ! signing_verify_exact "$file" "$signature" "$public_key_token"; then
        _sign_log_error "Published signature failed exact verification: $signature"
        _sign_log_error "Leaving the published path untouched because safe conditional unlink is not atomic"
        status=4
    elif ! file_sha256_after=$(_signing_sha256 "$file") || \
         [[ "$file_sha256_after" != "$file_sha256_before" ]]; then
        _sign_log_error "Input changed while its detached signature was published: $file"
        _sign_log_error "Leaving the published path untouched because safe conditional unlink is not atomic"
        status=4
    elif [[ -L "$signature" || ! "$signature" -ef "$staged_signature" ]]; then
        _sign_log_error "Published signature path changed during verification: $signature"
        status=4
    fi

    return "$status"
)

# Get the public key content for embedding
# Usage: signing_get_public_key [--oneline]
signing_get_public_key() {
    local oneline=false
    [[ "${1:-}" == "--oneline" ]] && oneline=true

    if [[ ! -f "$SIGNING_PUBLIC_KEY" ]]; then
        _sign_log_error "Public key not found: $SIGNING_PUBLIC_KEY"
        return 3
    fi

    if $oneline; then
        # Extract just the key line (second line of the file)
        sed -n '2p' "$SIGNING_PUBLIC_KEY"
    else
        cat "$SIGNING_PUBLIC_KEY"
    fi
}

# Sign a frozen set, not a sequence of independently changing file paths.
# Preflight every input/retained signature before invoking the private key;
# stage every missing signature before publishing any new public sidecar.
# Multi-file publication is not atomic. Late conflicts leave valid completed
# sidecars in place so the same batch can be verified and resumed safely.
# Usage: signing_sign_batch <file1> [file2] [file3] ...
signing_sign_batch() (
    if [[ $# -eq 0 ]]; then
        _sign_log_error "Usage: signing_sign_batch <file1> [file2] ..."
        return 4
    fi

    signing_require_minisign || return 3

    local token private_key="$SIGNING_PRIVATE_KEY" file parent name canonical prior duplicate
    local digest signature i stage piece cleanup='' pending=0 reused=0
    local -a files=() digests=() signature_digests=() staged=()
    token=$(signing_public_key_token "$SIGNING_PUBLIC_KEY") || return 3
    # Canonicalize path aliases, not hardlink aliases: distinct release names
    # (versioned and installer-compatible) must each get their own signature.
    for file in "$@"; do
        if [[ ! -f "$file" || -L "$file" || "$file" == *[[:cntrl:]]* ]]; then
            _sign_log_error "Invalid batch artifact: $file"
            return 4
        fi
        parent="${file%/*}"
        [[ "$parent" != "$file" ]] || parent=.
        name="${file##*/}"
        parent=$(cd "$parent" && pwd -P) || return 4
        canonical="$parent/$name"
        duplicate=false
        for prior in "${files[@]}"; do
            [[ "$prior" != "$canonical" ]] || duplicate=true
        done
        $duplicate && continue
        digest=$(_signing_sha256 "$canonical") || return $?
        files+=("$canonical")
        digests+=("$digest")
    done
    # Otherwise foo and foo.minisig could be both a planned input and output.
    for file in "${files[@]}"; do
        for prior in "${files[@]}"; do
            if [[ "$prior" == "$file.minisig" ]]; then
                _sign_log_error "Batch input overlaps a signature output: $prior"
                return 4
            fi
        done
    done
    for ((i=0; i<${#files[@]}; i++)); do
        file="${files[i]}" signature="${files[i]}.minisig"
        staged+=("")
        if [[ -e "$signature" || -L "$signature" ]]; then
            digest=$(_signing_sha256 "$signature") || return $?
            _signing_reuse "$file" "$signature" "$token" "${digests[i]}" || return $?
            [[ "$(_signing_sha256 "$signature")" == "$digest" ]] || return 4
            signature_digests+=("$digest")
            reused=$((reused + 1))
        else
            signature_digests+=("")
            pending=$((pending + 1))
        fi
    done
    if ((pending > 0)) && [[ ! -f "$private_key" || -L "$private_key" || ! -s "$private_key" ]]; then
        _sign_log_error "Private key is required for $pending unsigned artifact(s)"
        return 3
    fi
    _sign_log_info "Signing frozen batch: ${#files[@]} artifact(s), $pending new, $reused retained"
    umask 077
    trap 'exit 5' HUP INT TERM
    for ((i=0; i<${#files[@]}; i++)); do
        [[ -z "${signature_digests[i]}" ]] || continue
        file="${files[i]}"
        parent="${file%/*}" name="${file##*/}"
        stage=$(mktemp -d "$parent/.${name}.dsr-batch.XXXXXXXX") || return 4
        printf -v piece 'rm -f -- %q; rmdir -- %q 2>/dev/null || true;' "$stage/signature" "$stage"
        cleanup+="$piece"
        # shellcheck disable=SC2064 # Freeze only our private staging paths.
        trap "$cleanup" EXIT
        staged[i]="$stage/signature"
        signing_sign_exact "$file" "${staged[i]}" "$private_key" "$token" \
            "dsr artifact $name sha256:${digests[i]}" "${digests[i]}" || return $?
        signature_digests[i]=$(_signing_sha256 "${staged[i]}") || return $?
    done
    # The final staged signature could have been produced after an earlier
    # input/sidecar changed. Recheck the whole plan before exposing any output.
    for ((i=0; i<${#files[@]}; i++)); do
        file="${files[i]}" signature="${staged[i]:-${files[i]}.minisig}"
        _signing_reuse "$file" "$signature" "$token" "${digests[i]}" || return $?
        [[ "$(_signing_sha256 "$signature")" == "${signature_digests[i]}" ]] || return 4
    done
    for ((i=0; i<${#files[@]}; i++)); do
        [[ -n "${staged[i]}" ]] || continue
        signature="${files[i]}.minisig"
        if ! ln -- "${staged[i]}" "$signature"; then
            _sign_log_error "Signature publication conflict; completed sidecars retained: $signature"
            return 4
        fi
        [[ ! -L "$signature" && "$signature" -ef "${staged[i]}" ]] || return 4
    done
    # Success means complete coverage of the original frozen set, with no
    # changed inputs or replaced sidecars during staged publication.
    for ((i=0; i<${#files[@]}; i++)); do
        file="${files[i]}" signature="${files[i]}.minisig"
        _signing_reuse "$file" "$signature" "$token" "${digests[i]}" || return $?
        [[ "$(_signing_sha256 "$signature")" == "${signature_digests[i]}" ]] || return 4
    done
    _sign_log_ok "Verified complete signing batch: ${#files[@]} artifact(s)"
    return 0
)

# Predicate used by orchestrators to decide whether to call into the
# signing pipeline. Honors:
#   - DSR_NO_SIGN=1 / DSR_SIGNING_ENABLED=false to disable explicitly
#   - signing.enabled in DSR_CONFIG (loaded by config.sh) when present
#   - the presence of a usable keypair (signing_check) as the final gate
# Returns 0 if signing should run, 1 otherwise.
# Usage: signing_is_enabled
signing_is_enabled() {
    # Explicit env opt-out wins.
    if [[ "${DSR_NO_SIGN:-}" == "1" ]] || [[ "${DSR_NO_SIGN:-}" == "true" ]]; then
        return 1
    fi
    if [[ "${DSR_SIGNING_ENABLED:-}" == "false" ]] || [[ "${DSR_SIGNING_ENABLED:-}" == "0" ]]; then
        return 1
    fi
    # config.sh loaded? Honor signing_enabled in the in-memory config.
    if declare -p DSR_CONFIG &>/dev/null; then
        local cfg_value="${DSR_CONFIG[signing_enabled]:-true}"
        case "$cfg_value" in
            false|0|no|off) return 1 ;;
        esac
    fi
    # Final gate: only enabled if the keypair actually exists and is
    # usable. signing_check writes diagnostic logs to stderr; suppress
    # those here because callers use this as a "should I bother?" check.
    signing_check >/dev/null 2>&1
}

# Sign release payloads AND integrity/provenance documents matching a basename
# glob. Detached signatures themselves are the only excluded regular files.
# An empty selection or unsafe candidate is a failure, not completed signing.
# Usage: signing_sign_files <dir> <glob_pattern>
signing_sign_files() (
    local dir="${1:-}"
    local pattern="${2:-*}"

    if [[ -z "$dir" || ! -d "$dir" || -L "$dir" || -z "$pattern" || "$pattern" == */* ]]; then
        _sign_log_error "signing_sign_files: directory not found: $dir"
        return 4
    fi

    # Scope glob/IFS changes to this subshell and do not inherit exclusions or
    # disabled globbing from the calling shell. Quoted directory, data-only glob.
    local -a files=()
    local f
    local IFS=''
    unset GLOBIGNORE
    set +f
    shopt -s nullglob
    shopt -u failglob dotglob
    for f in "$dir"/$pattern; do
        [[ ! -d "$f" || -L "$f" ]] || continue
        case "${f##*/}" in
            *.minisig|*.sig|*.asc) continue ;;
        esac
        [[ -f "$f" && ! -L "$f" ]] || { _sign_log_error "Unsafe signing candidate: $f"; return 4; }
        files+=("$f")
    done

    if [[ ${#files[@]} -eq 0 ]]; then
        _sign_log_warn "signing_sign_files: no files match $dir/$pattern"
        return 4
    fi

    signing_sign_batch "${files[@]}"
)

# Export functions for use by other scripts
export -f signing_require_minisign signing_check signing_init signing_fix_permissions
export -f signing_sign signing_verify signing_get_public_key signing_sign_batch
export -f signing_public_key_token signing_verify_exact signing_sign_exact
export -f signing_is_enabled signing_sign_files
