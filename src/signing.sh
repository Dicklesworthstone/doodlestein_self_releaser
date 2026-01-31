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
                trusted_comment="$2"
                shift 2
                ;;
            --untrusted-comment|-c)
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

    if [[ ! -f "$file" ]]; then
        _sign_log_error "File not found: $file"
        return 4
    fi

    signing_require_minisign || return 3

    if [[ ! -f "$SIGNING_PRIVATE_KEY" ]]; then
        _sign_log_error "Private key not found: $SIGNING_PRIVATE_KEY"
        _sign_log_info "Run: dsr signing init"
        return 3
    fi

    # Build minisign command
    local minisign_args=(-S -s "$SIGNING_PRIVATE_KEY" -m "$file")

    if [[ -n "$trusted_comment" ]]; then
        minisign_args+=(-t "$trusted_comment")
    fi

    if [[ -n "$untrusted_comment" ]]; then
        minisign_args+=(-c "$untrusted_comment")
    fi

    _sign_log_info "Signing: $file"
    _sign_log_info "You may be prompted for your key password."

    if ! minisign "${minisign_args[@]}"; then
        _sign_log_error "Failed to sign file"
        return 1
    fi

    _sign_log_ok "Signature created: ${file}.minisig"
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

    if ! minisign -V -p "$public_key" -m "$file"; then
        _sign_log_error "Signature verification FAILED"
        return 1
    fi

    _sign_log_ok "Signature verified successfully"
    return 0
}

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

# Sign multiple files (batch signing)
# Usage: signing_sign_batch <file1> [file2] [file3] ...
signing_sign_batch() {
    if [[ $# -eq 0 ]]; then
        _sign_log_error "Usage: signing_sign_batch <file1> [file2] ..."
        return 4
    fi

    signing_require_minisign || return 3

    if [[ ! -f "$SIGNING_PRIVATE_KEY" ]]; then
        _sign_log_error "Private key not found: $SIGNING_PRIVATE_KEY"
        return 3
    fi

    local total=$#
    local success=0
    local failed=0

    _sign_log_info "Signing $total file(s)..."
    _sign_log_info "You may be prompted for your key password multiple times."
    echo ""

    for file in "$@"; do
        if [[ ! -f "$file" ]]; then
            _sign_log_warn "Skipping (not found): $file"
            ((failed++))
            continue
        fi

        if signing_sign "$file" 2>/dev/null; then
            ((success++))
        else
            _sign_log_error "Failed to sign: $file"
            ((failed++))
        fi
    done

    echo ""
    _sign_log_info "Batch signing complete: $success succeeded, $failed failed"

    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Export functions for use by other scripts
export -f signing_require_minisign signing_check signing_init signing_fix_permissions
export -f signing_sign signing_verify signing_get_public_key signing_sign_batch
