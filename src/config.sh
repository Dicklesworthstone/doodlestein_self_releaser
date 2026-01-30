#!/usr/bin/env bash
# config.sh - Configuration management for dsr
#
# Usage:
#   source config.sh
#   config_init
#   config_load
#   config_get <key>
#   config_set <key> <value>
#
# XDG Layout:
#   ~/.config/dsr/config.yaml    - Main configuration
#   ~/.config/dsr/repos.yaml     - Repository/tool registry
#   ~/.config/dsr/hosts.yaml     - Build host definitions
#   ~/.cache/dsr/                - API cache, downloads
#   ~/.local/state/dsr/          - Logs, state, run history

set -uo pipefail

# XDG directories with defaults
DSR_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dsr"
DSR_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dsr"
DSR_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dsr"

# Config file paths
DSR_CONFIG_FILE="${DSR_CONFIG_FILE:-$DSR_CONFIG_DIR/config.yaml}"
DSR_REPOS_FILE="${DSR_REPOS_FILE:-$DSR_CONFIG_DIR/repos.yaml}"
DSR_HOSTS_FILE="${DSR_HOSTS_FILE:-$DSR_CONFIG_DIR/hosts.yaml}"

# Current schema version
DSR_SCHEMA_VERSION="1.0.0"

# Loaded config values (associative array)
declare -gA DSR_CONFIG

# Colors for output (if not disabled)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _CFG_RED=$'\033[0;31m'
    _CFG_GREEN=$'\033[0;32m'
    _CFG_YELLOW=$'\033[0;33m'
    _CFG_BLUE=$'\033[0;34m'
    _CFG_NC=$'\033[0m'
else
    _CFG_RED='' _CFG_GREEN='' _CFG_YELLOW='' _CFG_BLUE='' _CFG_NC=''
fi

_cfg_log_info()  { echo "${_CFG_BLUE}[config]${_CFG_NC} $*" >&2; }
_cfg_log_ok()    { echo "${_CFG_GREEN}[config]${_CFG_NC} $*" >&2; }
_cfg_log_warn()  { echo "${_CFG_YELLOW}[config]${_CFG_NC} $*" >&2; }
_cfg_log_error() { echo "${_CFG_RED}[config]${_CFG_NC} $*" >&2; }

# Initialize config directories and default files
# Usage: config_init [--force]
config_init() {
    local force=false
    [[ "${1:-}" == "--force" ]] && force=true

    _cfg_log_info "Initializing dsr configuration..."

    # Create directories
    mkdir -p "$DSR_CONFIG_DIR" "$DSR_CACHE_DIR" "$DSR_STATE_DIR"
    mkdir -p "$DSR_STATE_DIR/logs" "$DSR_STATE_DIR/artifacts" "$DSR_STATE_DIR/manifests"
    mkdir -p "$DSR_CACHE_DIR/act" "$DSR_CACHE_DIR/builds"

    # Create default config.yaml if not exists or force
    if [[ ! -f "$DSR_CONFIG_FILE" ]] || $force; then
        cat > "$DSR_CONFIG_FILE" << 'EOF'
# dsr configuration
# See docs/CLI_CONTRACT.md for full specification

schema_version: "1.0.0"

# Default queue time threshold for throttle detection (seconds)
threshold_seconds: 600

# Default build targets
default_targets:
  - linux/amd64
  - darwin/arm64
  - windows/amd64

# Artifact signing
signing:
  enabled: true
  tool: minisign
  # key_path: ~/.config/dsr/minisign.key

# Logging
log_level: info

# Notifications (optional)
# notifications:
#   slack_webhook: ""
#   discord_webhook: ""
EOF
        _cfg_log_ok "Created $DSR_CONFIG_FILE"
    fi

    # Create default hosts.yaml if not exists or force
    if [[ ! -f "$DSR_HOSTS_FILE" ]] || $force; then
        cat > "$DSR_HOSTS_FILE" << 'EOF'
# dsr build hosts configuration
# Define your build machines here

schema_version: "1.0.0"

hosts:
  trj:
    platform: linux/amd64
    connection: local
    capabilities:
      - rust
      - go
      - node
      - bun
      - docker
      - act
    concurrency: 4
    description: "Threadripper workstation (local)"

  mmini:
    platform: darwin/arm64
    connection: ssh
    ssh_host: mmini
    ssh_timeout: 15
    capabilities:
      - rust
      - go
      - node
      - bun
    concurrency: 2
    description: "Mac Mini M1 via Tailscale"

  wlap:
    platform: windows/amd64
    connection: ssh
    ssh_host: wlap
    ssh_timeout: 15
    capabilities:
      - rust
      - go
      - node
      - bun
    concurrency: 2
    description: "Windows Surface Book via Tailscale"

# Platform to host mapping for builds
platform_mapping:
  linux/amd64: trj
  linux/arm64: trj  # via act/QEMU
  darwin/arm64: mmini
  darwin/amd64: mmini  # Rosetta
  windows/amd64: wlap
EOF
        _cfg_log_ok "Created $DSR_HOSTS_FILE"
    fi

    # Create default repos.yaml if not exists or force
    if [[ ! -f "$DSR_REPOS_FILE" ]] || $force; then
        cat > "$DSR_REPOS_FILE" << 'EOF'
# dsr repository/tool registry
# Define tools to build and release

schema_version: "1.0.0"

# Example tool entry (uncomment and customize)
# tools:
#   ntm:
#     repo: dicklesworthstone/ntm
#     local_path: /data/projects/ntm
#     language: go
#     build_cmd: go build -ldflags="-s -w" -o ntm ./cmd/ntm
#     binary_name: ntm
#     targets:
#       - linux/amd64
#       - darwin/arm64
#       - windows/amd64
#     workflow: .github/workflows/release.yml
#     act_job_map:
#       linux/amd64: build-linux
#       darwin/arm64: null  # native on mmini
#       windows/amd64: null  # native on wlap
#     checks:
#       - go test ./...
#       - go vet ./...
#     artifact_naming: "${name}-${version}-${os}-${arch}"
#     archive_format: tar.gz  # or zip for windows

tools: {}
EOF
        _cfg_log_ok "Created $DSR_REPOS_FILE"
    fi

    _cfg_log_ok "Configuration initialized in $DSR_CONFIG_DIR"
    return 0
}

# Load configuration with precedence: CLI > ENV > config > defaults
# Usage: config_load
config_load() {
    # Reset config
    DSR_CONFIG=()

    # 1. Load defaults
    DSR_CONFIG[threshold_seconds]=600
    DSR_CONFIG[log_level]="info"
    DSR_CONFIG[signing_enabled]="true"
    DSR_CONFIG[signing_tool]="minisign"
    DSR_CONFIG[schema_version]="$DSR_SCHEMA_VERSION"

    # 2. Load from config file (if exists)
    if [[ -f "$DSR_CONFIG_FILE" ]]; then
        _config_load_yaml "$DSR_CONFIG_FILE"
    fi

    # 3. Override with environment variables (DSR_*)
    [[ -n "${DSR_THRESHOLD:-}" ]] && DSR_CONFIG[threshold_seconds]="$DSR_THRESHOLD"
    [[ -n "${DSR_LOG_LEVEL:-}" ]] && DSR_CONFIG[log_level]="$DSR_LOG_LEVEL"
    [[ -n "${DSR_NO_SIGN:-}" ]] && DSR_CONFIG[signing_enabled]="false"
    [[ -n "${DSR_MINISIGN_KEY:-}" ]] && DSR_CONFIG[signing_key_path]="$DSR_MINISIGN_KEY"

    return 0
}

# Internal: Load YAML config file into DSR_CONFIG
# This is a simplified loader - for complex YAML, use yq
_config_load_yaml() {
    local file="$1"

    if ! command -v yq &>/dev/null; then
        # Fallback: simple key: value parsing (top-level only)
        # NOTE: This does NOT handle nested structures, lists, or multi-line values
        local line key value
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Skip empty lines
            [[ -z "$line" ]] && continue
            # Skip comments
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            # Skip indented lines (nested keys, list items)
            [[ "$line" =~ ^[[:space:]] ]] && continue
            # Skip list items at root level (shouldn't happen in well-formed YAML)
            [[ "$line" =~ ^- ]] && continue
            # Match "key: value" pattern - must have colon followed by space or end
            if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*):\ *(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"
                value="${BASH_REMATCH[2]}"
                # Remove quotes from value
                value="${value#\"}"
                value="${value%\"}"
                value="${value#\'}"
                value="${value%\'}"
                # Skip if value is empty or starts nested block
                [[ -z "$value" || "$value" == "{" || "$value" == "[" ]] && continue
                # Store the value
                DSR_CONFIG["$key"]="$value"
            fi
        done < "$file"
    else
        # Use yq for proper YAML parsing
        local line key value
        while IFS= read -r line; do
            # yq props format: key = value (with spaces around =)
            # Handle keys with dots by taking everything before last " = "
            if [[ "$line" =~ ^(.+)\ =\ (.*)$ ]]; then
                key="${BASH_REMATCH[1]}"
                value="${BASH_REMATCH[2]}"
                [[ -n "$key" && -n "$value" ]] && DSR_CONFIG["$key"]="$value"
            fi
        done < <(yq -o=props "$file" 2>/dev/null | grep -v '^#')
    fi
}

# Get a config value
# Usage: config_get <key> [default]
config_get() {
    local key="$1"
    local default="${2:-}"

    if [[ -v "DSR_CONFIG[$key]" ]]; then
        echo "${DSR_CONFIG[$key]}"
    else
        echo "$default"
    fi
}

# Set a config value (in memory and optionally persist)
# Usage: config_set <key> <value> [--persist]
config_set() {
    local key="$1"
    local value="$2"
    local persist=false
    [[ "${3:-}" == "--persist" ]] && persist=true

    DSR_CONFIG["$key"]="$value"

    if $persist && command -v yq &>/dev/null; then
        yq -i ".$key = \"$value\"" "$DSR_CONFIG_FILE"
        _cfg_log_ok "Set $key = $value (persisted)"
    else
        _cfg_log_info "Set $key = $value (in memory)"
    fi
}

# Validate configuration
# Usage: config_validate
# Returns: 0 if valid, 4 if invalid
config_validate() {
    local errors=0

    # Check schema version
    local schema_version
    schema_version=$(config_get "schema_version" "")
    if [[ -z "$schema_version" ]]; then
        _cfg_log_error "Missing schema_version in config"
        ((errors++))
    fi

    # Check required directories exist
    if [[ ! -d "$DSR_CONFIG_DIR" ]]; then
        _cfg_log_error "Config directory missing: $DSR_CONFIG_DIR"
        _cfg_log_info "Run: dsr config init"
        ((errors++))
    fi

    # Check hosts.yaml if exists
    if [[ -f "$DSR_HOSTS_FILE" ]]; then
        if command -v yq &>/dev/null; then
            if ! yq '.' "$DSR_HOSTS_FILE" &>/dev/null; then
                _cfg_log_error "Invalid YAML in hosts.yaml"
                ((errors++))
            fi
        fi
    fi

    # Check repos.yaml if exists
    if [[ -f "$DSR_REPOS_FILE" ]]; then
        if command -v yq &>/dev/null; then
            if ! yq '.' "$DSR_REPOS_FILE" &>/dev/null; then
                _cfg_log_error "Invalid YAML in repos.yaml"
                ((errors++))
            fi
        fi
    fi

    if [[ $errors -eq 0 ]]; then
        _cfg_log_ok "Configuration valid"
        return 0
    else
        _cfg_log_error "Configuration has $errors error(s)"
        return 4
    fi
}

# Show configuration (human-readable or JSON)
# Usage: config_show [--json] [key] OR config_show [key] [--json]
config_show() {
    local key=""
    local json_mode=false

    # Parse arguments - handle --json in any position
    for arg in "$@"; do
        if [[ "$arg" == "--json" ]]; then
            json_mode=true
        elif [[ -z "$key" ]]; then
            key="$arg"
        fi
    done

    config_load

    if $json_mode; then
        # JSON output
        echo "{"
        echo "  \"config_dir\": \"$DSR_CONFIG_DIR\","
        echo "  \"cache_dir\": \"$DSR_CACHE_DIR\","
        echo "  \"state_dir\": \"$DSR_STATE_DIR\","
        echo "  \"config_file\": \"$DSR_CONFIG_FILE\","
        echo "  \"hosts_file\": \"$DSR_HOSTS_FILE\","
        echo "  \"repos_file\": \"$DSR_REPOS_FILE\","
        echo "  \"values\": {"

        local first=true
        for k in "${!DSR_CONFIG[@]}"; do
            if [[ -z "$key" || "$k" == "$key" ]]; then
                $first || echo ","
                first=false
                printf '    "%s": "%s"' "$k" "${DSR_CONFIG[$k]}"
            fi
        done
        echo ""
        echo "  }"
        echo "}"
    else
        # Human-readable output
        echo "dsr Configuration"
        echo "================="
        echo ""
        echo "Directories:"
        echo "  config: $DSR_CONFIG_DIR"
        echo "  cache:  $DSR_CACHE_DIR"
        echo "  state:  $DSR_STATE_DIR"
        echo ""
        echo "Files:"
        echo "  config.yaml: $DSR_CONFIG_FILE"
        echo "  hosts.yaml:  $DSR_HOSTS_FILE"
        echo "  repos.yaml:  $DSR_REPOS_FILE"
        echo ""
        echo "Values:"
        for k in "${!DSR_CONFIG[@]}"; do
            if [[ -z "$key" || "$k" == "$key" ]]; then
                printf "  %-20s = %s\n" "$k" "${DSR_CONFIG[$k]}"
            fi
        done
    fi
}

# Get host configuration
# Usage: config_get_host <hostname>
# Returns: JSON object with host config
config_get_host() {
    local hostname="$1"

    if [[ ! -f "$DSR_HOSTS_FILE" ]]; then
        _cfg_log_error "Hosts file not found: $DSR_HOSTS_FILE"
        return 4
    fi

    if command -v yq &>/dev/null; then
        yq ".hosts.$hostname" "$DSR_HOSTS_FILE"
    else
        _cfg_log_error "yq required for host configuration"
        return 3
    fi
}

# Get tool configuration
# Usage: config_get_tool <toolname>
# Returns: JSON object with tool config
config_get_tool() {
    local toolname="$1"

    if [[ ! -f "$DSR_REPOS_FILE" ]]; then
        _cfg_log_error "Repos file not found: $DSR_REPOS_FILE"
        return 4
    fi

    if command -v yq &>/dev/null; then
        yq ".tools.$toolname" "$DSR_REPOS_FILE"
    else
        _cfg_log_error "yq required for tool configuration"
        return 3
    fi
}

# List configured hosts
# Usage: config_list_hosts [--json]
config_list_hosts() {
    local json_mode=false
    [[ "${1:-}" == "--json" ]] && json_mode=true

    if [[ ! -f "$DSR_HOSTS_FILE" ]]; then
        _cfg_log_error "Hosts file not found: $DSR_HOSTS_FILE"
        return 4
    fi

    if command -v yq &>/dev/null; then
        if $json_mode; then
            yq '.hosts | keys' "$DSR_HOSTS_FILE"
        else
            yq '.hosts | keys | .[]' "$DSR_HOSTS_FILE"
        fi
    else
        _cfg_log_error "yq required for host listing"
        return 3
    fi
}

# List configured tools
# Usage: config_list_tools [--json]
config_list_tools() {
    local json_mode=false
    [[ "${1:-}" == "--json" ]] && json_mode=true

    if [[ ! -f "$DSR_REPOS_FILE" ]]; then
        _cfg_log_error "Repos file not found: $DSR_REPOS_FILE"
        return 4
    fi

    if command -v yq &>/dev/null; then
        if $json_mode; then
            yq '.tools | keys' "$DSR_REPOS_FILE"
        else
            yq '.tools | keys | .[]' "$DSR_REPOS_FILE"
        fi
    else
        _cfg_log_error "yq required for tool listing"
        return 3
    fi
}

# Get host for a given platform
# Usage: config_get_host_for_platform <platform>
# Returns: hostname
config_get_host_for_platform() {
    local platform="$1"

    if [[ ! -f "$DSR_HOSTS_FILE" ]]; then
        _cfg_log_error "Hosts file not found"
        return 4
    fi

    if command -v yq &>/dev/null; then
        yq ".platform_mapping.\"$platform\" // \"\"" "$DSR_HOSTS_FILE"
    else
        # Fallback to hardcoded defaults
        case "$platform" in
            linux/*) echo "trj" ;;
            darwin/*) echo "mmini" ;;
            windows/*) echo "wlap" ;;
            *) echo "" ;;
        esac
    fi
}

# Export functions for use by other scripts
export -f config_init config_load config_get config_set config_validate config_show
export -f config_get_host config_get_tool config_list_hosts config_list_tools
export -f config_get_host_for_platform
