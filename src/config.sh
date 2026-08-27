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

# XDG directories with defaults (respect existing env vars for testing)
DSR_CONFIG_DIR="${DSR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dsr}"
DSR_CACHE_DIR="${DSR_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/dsr}"
DSR_STATE_DIR="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}"

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
    # Optional: disk-backed root for release snapshots and isolated Rust
    # builds (default /var/tmp on Linux, /private/tmp on macOS; never /tmp).
    # build_root: /var/tmp/dsr-builds

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
  windows/arm64: wlap
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

    # Use ${var+x} pattern for Bash 4.0+ compatibility (avoids -v operator from 4.3+)
    if [[ -n "${DSR_CONFIG[$key]+x}" ]]; then
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
        # Only accept dotted-path keys built from identifier characters —
        # anything else could inject yq expression syntax (e.g. quotes or
        # arithmetic) through the unquoted interpolation below.
        if [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)*$ ]]; then
            _cfg_log_error "Refusing to persist key with unsafe characters: $key"
            return 4
        fi

        # yq (Mike Farah Go version) does NOT accept jq-style --arg flags;
        # pass the value through the environment and read it back with
        # strenv() inside the expression so the YAML string escaping is
        # handled by yq itself. Check the exit code so we surface errors
        # instead of claiming success when persistence actually failed.
        if DSR_SET_VALUE="$value" yq -i ".$key = strenv(DSR_SET_VALUE)" "$DSR_CONFIG_FILE" 2>/dev/null; then
            _cfg_log_ok "Set $key = $value (persisted)"
        else
            _cfg_log_error "Failed to persist $key to $DSR_CONFIG_FILE"
            return 1
        fi
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

    # Parse repos.yaml with the same single-document and duplicate-key rules
    # used for release decisions, then retain it for registry contract checks.
    local registry_json=""
    if [[ -f "$DSR_REPOS_FILE" ]]; then
        if ! command -v yq &>/dev/null || ! command -v jq &>/dev/null; then
            _cfg_log_error "yq and jq are required to validate repos.yaml"
            ((errors++))
        elif ! registry_json=$(_config_read_single_mapping_json "$DSR_REPOS_FILE"); then
            _cfg_log_error "Invalid YAML in repos.yaml"
            ((errors++))
        elif ! printf '%s\n' "$registry_json" | jq -e '
            ((.tools | type) == "object") and all(.tools[]; type == "object")
        ' >/dev/null; then
            _cfg_log_error "repos.yaml must contain a tools mapping of tool mappings"
            registry_json=""
            ((errors++))
        fi
    fi

    # Validate every opt-in per-repository release contract through the same
    # fail-closed parser used by build and release. A green `config validate`
    # must not disagree with the command that will publish assets.
    local repos_dir="$DSR_CONFIG_DIR/repos.d"
    if [[ -d "$repos_dir" ]]; then
        local had_nullglob=false
        shopt -q nullglob && had_nullglob=true
        shopt -s nullglob
        local repo_configs=("$repos_dir"/*.yaml)
        $had_nullglob || shopt -u nullglob

        local repo_config toolname
        for repo_config in "${repo_configs[@]}"; do
            toolname=$(basename "$repo_config" .yaml)
            if ! config_validate_release_contract "$toolname"; then
                _cfg_log_error "Invalid repository configuration: $repo_config"
                ((errors++))
            fi
        done
    fi

    # Registry-only tools have no repos.d file to drive the loop above.
    if [[ -n "$registry_json" ]]; then
        while IFS= read -r toolname; do
            [[ -n "$toolname" ]] || continue
            if ! config_validate_release_contract "$toolname"; then
                _cfg_log_error "Invalid registry configuration for tool: $toolname"
                ((errors++))
            fi
        done < <(printf '%s\n' "$registry_json" | jq -r \
            'if (.tools | type) == "object" then .tools | keys[] else empty end')
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
                # Escape value for JSON (backslashes, quotes, newlines)
                local escaped_val="${DSR_CONFIG[$k]}"
                escaped_val="${escaped_val//\\/\\\\}"
                escaped_val="${escaped_val//\"/\\\"}"
                escaped_val="${escaped_val//$'\n'/\\n}"
                escaped_val="${escaped_val//$'\r'/\\r}"
                escaped_val="${escaped_val//$'\t'/\\t}"
                printf '    "%s": "%s"' "$k" "$escaped_val"
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

# Get a specific field from tool configuration
# Usage: config_get_tool_field <toolname> <field> [default]
# Returns: Field value or default (or empty if not found)
config_get_tool_field() {
    local toolname="$1"
    local field="$2"
    local default="${3:-}"

    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local tool_config="$config_dir/repos.d/${toolname}.yaml"

    if [[ -f "$tool_config" ]] && command -v yq &>/dev/null; then
        local value
        value=$(yq -r ".$field" "$tool_config" 2>/dev/null)
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
            return 0
        fi
    fi

    # Fallback to repos.yaml
    if [[ -f "$DSR_REPOS_FILE" ]] && command -v yq &>/dev/null; then
        local value
        value=$(yq -r ".tools.$toolname.$field" "$DSR_REPOS_FILE" 2>/dev/null)
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
            return 0
        fi
    fi

    echo "$default"
}

# Parse exactly one YAML mapping document and reject duplicate mapping keys at
# every depth before jq can collapse them with last-key-wins semantics.
_config_read_single_mapping_json() {
    local config_file="$1"
    local docs_json canonical

    if [[ ! -f "$config_file" ]]; then
        _cfg_log_error "Configuration file not found: $config_file"
        return 4
    fi

    if ! yq -e \
        '[.. | select(tag == "!!map") | ((keys | length) == (keys | unique | length))] | all' \
        "$config_file" >/dev/null 2>&1; then
        _cfg_log_error "Duplicate YAML mapping key in: $config_file"
        return 4
    fi

    if ! docs_json=$(yq ea -o=json -I=0 '[.]' "$config_file" 2>/dev/null); then
        _cfg_log_error "Invalid YAML in: $config_file"
        return 4
    fi
    if ! canonical=$(printf '%s\n' "$docs_json" | jq -ce \
        'if length == 1 and (.[0] | type == "object") then .[0]
         else error("configuration must contain exactly one mapping document") end' \
        2>/dev/null); then
        _cfg_log_error "Configuration must contain exactly one YAML mapping document: $config_file"
        return 4
    fi

    printf '%s\n' "$canonical"
}

# Canonicalize a parsed release contract. A present contract must be an object;
# null is the opt-out used by legacy tool configurations.
_config_canonicalize_release_contract_json() {
    local raw_json="$1"

    if [[ "$raw_json" == "null" ]]; then
        printf 'null\n'
        return 0
    fi

    local canonical
    if ! canonical=$(printf '%s\n' "$raw_json" | jq -ceS \
        'if type == "object" then . else error("release_contract must be an object or null") end' 2>/dev/null); then
        _cfg_log_error "release_contract must be a YAML mapping or null"
        return 4
    fi

    printf '%s\n' "$canonical"
}

# Compare a tool's registry entry (repos.yaml) with its per-tool build config
# (repos.d/<tool>.yaml). The two files historically drifted apart silently:
# repos.yaml drives `dsr repos list/info/check` and the quality gates while
# the build runner reads only repos.d — so on divergence the tool you inspect
# is not the tool you build, which has produced wrong-target releases
# (issues #12/#13).
#
# Precedence contract (documented in README "Config precedence"):
#   - repos.d/<tool>.yaml is the build authority: build/release read it
#     exclusively for build-affecting keys.
#   - repos.yaml is the registry: list/info/check/quality read it.
#   - Any key present in both files must be identical.
#
# Usage: config_registry_divergence_json <toolname>
# stdout: compact JSON:
#   {registry: bool,                 # tool present in repos.yaml
#    repo_config: bool,              # repos.d/<tool>.yaml exists
#    tool_name: string|null,         # tool_name declared inside repos.d file
#    mismatched_keys: [key, ...],    # present in both files, values differ
#    registry_only_build_keys: [..]} # build-affecting keys only in repos.yaml
# rc: 0 with JSON on stdout; 3 when yq/jq missing; 4 on parse failure.
config_registry_divergence_json() {
    local toolname="${1:-}"
    if [[ -z "$toolname" ]]; then
        _cfg_log_error "Tool name required for registry divergence check"
        return 4
    fi
    if ! command -v yq &>/dev/null || ! command -v jq &>/dev/null; then
        _cfg_log_error "yq and jq are required for registry divergence checks"
        return 3
    fi

    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local tool_config="$config_dir/repos.d/${toolname}.yaml"
    local registry_json="null" repo_json="null"

    if [[ -f "$DSR_REPOS_FILE" ]]; then
        registry_json=$(_config_read_single_mapping_json "$DSR_REPOS_FILE" | \
            jq -c --arg tool "$toolname" '.tools[$tool] // null' 2>/dev/null) || return 4
        [[ -n "$registry_json" ]] || return 4
    fi
    if [[ -f "$tool_config" ]]; then
        repo_json=$(_config_read_single_mapping_json "$tool_config") || return 4
    fi

    jq -nc --argjson registry "$registry_json" --argjson repo "$repo_json" '
        def build_keys: ["repo", "local_path", "language", "binary_name",
            "main_package", "workspace_binaries", "build_cmd", "build_profile",
            "targets", "target_triples", "cross_compile", "host_paths", "env",
            "artifact_naming", "install_script_compat", "install_script_path",
            "archive_format", "include_files", "sibling_crates",
            "release_contract", "act_job_map", "workflow", "linux_glibc_floor",
            "derive_cargo_build_target"];
        {
            registry: ($registry != null),
            repo_config: ($repo != null),
            tool_name: (if $repo == null then null else ($repo.tool_name // null) end),
            mismatched_keys: (
                if $registry == null or $repo == null then []
                else [ ($registry | keys[]) as $k
                       | select(($repo | has($k)) and ($registry[$k] != $repo[$k]))
                       | $k ]
                     | sort
                end),
            registry_only_build_keys: (
                if $registry == null or $repo == null then []
                else [ build_keys[] as $k
                       | select(($registry | has($k)) and (($repo | has($k)) | not))
                       | $k ]
                end)
        }'
}

# Report Windows-host source-root problems for a tool (issue #8): every
# native windows/* target must resolve to a Windows host with a
# drive-qualified host_paths entry (C:/... or /c/...). A POSIX root can never
# work there — rsync targets the wrong location and the build-step validator
# rejects the path mid-build. One problem per line on stdout; empty when OK.
config_windows_host_path_problems() {
    local toolname="${1:-}"
    [[ -n "$toolname" ]] || return 0
    command -v yq &>/dev/null || return 0

    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local tool_config="$config_dir/repos.d/${toolname}.yaml"
    [[ -f "$tool_config" ]] || return 0

    local target host host_platform host_path act_job
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        act_job=$(TARGET="$target" yq -r '.act_job_map[env(TARGET)] // ""' "$tool_config" 2>/dev/null)
        [[ "$act_job" == "null" ]] && act_job=""
        [[ -z "$act_job" ]] || continue

        host=$(TARGET="$target" yq -r '.cross_compile[env(TARGET)].host // ""' "$tool_config" 2>/dev/null)
        [[ "$host" == "null" ]] && host=""
        if [[ -z "$host" && -f "${DSR_HOSTS_FILE:-}" ]]; then
            host=$(TARGET="$target" yq -r '.platform_mapping[env(TARGET)] // ""' "$DSR_HOSTS_FILE" 2>/dev/null)
            [[ "$host" == "null" ]] && host=""
        fi
        [[ -n "$host" ]] || continue

        host_platform=""
        if [[ -f "${DSR_HOSTS_FILE:-}" ]]; then
            host_platform=$(HOST="$host" yq -r '.hosts[env(HOST)].platform // ""' "$DSR_HOSTS_FILE" 2>/dev/null)
            [[ "$host_platform" == "null" ]] && host_platform=""
        fi
        case "$host_platform" in
            windows/*) ;;
            "") [[ "$target" == windows/* ]] || continue ;;
            *) continue ;;
        esac

        host_path=$(HOST="$host" yq -r '.host_paths[env(HOST)] // ""' "$tool_config" 2>/dev/null)
        [[ "$host_path" == "null" ]] && host_path=""
        case "$host_path" in
            [A-Za-z]:[\\/]*|/[A-Za-z]/*) ;;
            "")
                printf 'target %s builds on Windows host %s but repos.d/%s.yaml has no host_paths.%s (needs a drive-qualified path, e.g. C:/Users/<user>/%s)\n' \
                    "$target" "$host" "$toolname" "$host" "$toolname"
                ;;
            *)
                printf 'target %s: host_paths.%s is not drive-qualified for Windows host %s (got %s; use C:/... or /c/...)\n' \
                    "$target" "$host" "$host" "$host_path"
                ;;
        esac
    done < <(yq -r '.targets[]?' "$tool_config" 2>/dev/null)
}

# Get the opt-in release contract for a tool as compact, canonical JSON.
# Per-tool repos.d configuration takes precedence over the registry file.
# Usage: config_get_release_contract_json <toolname>
# Returns: Canonical JSON object, or literal null when no contract is configured.
config_get_release_contract_json() {
    local toolname="${1:-}"

    if [[ -z "$toolname" ]]; then
        _cfg_log_error "Tool name required for release contract lookup"
        return 4
    fi
    if ! command -v yq &>/dev/null || ! command -v jq &>/dev/null; then
        _cfg_log_error "yq and jq are required for release contract parsing"
        return 3
    fi

    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local tool_config="$config_dir/repos.d/${toolname}.yaml"
    local tool_json has_contract raw_json

    if [[ -f "$tool_config" ]]; then
        tool_json=$(_config_read_single_mapping_json "$tool_config") || return $?
        has_contract=$(printf '%s\n' "$tool_json" | jq -r 'has("release_contract")') || return 4
        if [[ "$has_contract" == "true" ]]; then
            if ! raw_json=$(printf '%s\n' "$tool_json" | jq -c '.release_contract'); then
                _cfg_log_error "Could not parse release_contract for $toolname"
                return 4
            fi
            _config_canonicalize_release_contract_json "$raw_json"
            return $?
        fi
    fi

    if [[ -f "$DSR_REPOS_FILE" ]]; then
        local registry_json
        registry_json=$(_config_read_single_mapping_json "$DSR_REPOS_FILE") || return $?
        if ! raw_json=$(printf '%s\n' "$registry_json" | jq -c --arg tool "$toolname" '
            if (.tools | type) != "object" then
                error("tools must be an object")
            elif (.tools | has($tool)) and ((.tools[$tool] | type) != "object") then
                error("tool entry must be an object")
            elif (.tools | has($tool)) and (.tools[$tool] | has("release_contract")) then
                .tools[$tool].release_contract
            else
                null
            end' 2>/dev/null); then
            _cfg_log_error "Could not parse release_contract for $toolname"
            return 4
        fi
    else
        raw_json="null"
    fi

    _config_canonicalize_release_contract_json "$raw_json"
}

# Canonicalize pinned sibling-crate checkouts for build-host validation. The
# public manifest projection below deliberately omits machine-local paths.
_config_canonicalize_release_source_dependency_checkouts_json() {
    local raw_json="$1"

    [[ "$raw_json" == "null" ]] && raw_json="[]"

    local canonical
    if ! canonical=$(printf '%s\n' "$raw_json" | jq -ceS '
        def safe_relative_path:
            type == "string" and
            length > 0 and
            test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and
            (contains("..") | not) and
            (endswith(".") | not) and
            ((ascii_downcase | test("^(con|prn|aux|nul|com[1-9]|lpt[1-9])($|\\.)")) | not);
        def exact_git_sha:
            type == "string" and
            test("^[0-9a-f]{40}$") and
            . != "0000000000000000000000000000000000000000";

        if type != "array" then
            error("sibling_crates must be an array or null")
        elif ([.[] |
            type == "object" and
            has("local_path") and (.local_path | type == "string" and startswith("/") and length > 1) and
            has("relative_path") and (.relative_path | safe_relative_path) and
            has("revision") and (.revision | exact_git_sha)
        ] | all | not) then
            error("each sibling_crates entry requires local_path, safe relative_path, and exact revision")
        elif ([.[].relative_path | ascii_downcase] | unique | length) != length then
            error("sibling_crates relative_path values must be portable and case-insensitively unique")
        else
            map({relative_path, local_path, git_sha: .revision}) | sort_by(.relative_path)
        end
    ' 2>/dev/null); then
        _cfg_log_error "Invalid pinned sibling_crates configuration"
        return 4
    fi

    printf '%s\n' "$canonical"
}

# Internal: get machine-local pinned checkout descriptions. Per-tool repos.d
# configuration takes precedence over repos.yaml.
_config_get_release_source_dependency_checkouts_json() {
    local toolname="${1:-}"

    if [[ -z "$toolname" ]]; then
        _cfg_log_error "Tool name required for release source dependency lookup"
        return 4
    fi
    if ! command -v yq &>/dev/null || ! command -v jq &>/dev/null; then
        _cfg_log_error "yq and jq are required for release source dependency parsing"
        return 3
    fi

    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local tool_config="$config_dir/repos.d/${toolname}.yaml"
    local tool_json has_siblings raw_json

    if [[ -f "$tool_config" ]]; then
        tool_json=$(_config_read_single_mapping_json "$tool_config") || return $?
        has_siblings=$(printf '%s\n' "$tool_json" | jq -r 'has("sibling_crates")') || return 4
        if [[ "$has_siblings" == "true" ]]; then
            raw_json=$(printf '%s\n' "$tool_json" | jq -c '.sibling_crates') || return 4
            _config_canonicalize_release_source_dependency_checkouts_json "$raw_json"
            return $?
        fi
    fi

    if [[ -f "$DSR_REPOS_FILE" ]]; then
        local registry_json
        registry_json=$(_config_read_single_mapping_json "$DSR_REPOS_FILE") || return $?
        if ! raw_json=$(printf '%s\n' "$registry_json" | jq -c --arg tool "$toolname" '
            if (.tools | type) != "object" then
                error("tools must be an object")
            elif (.tools | has($tool)) and ((.tools[$tool] | type) != "object") then
                error("tool entry must be an object")
            elif (.tools | has($tool)) and (.tools[$tool] | has("sibling_crates")) then
                .tools[$tool].sibling_crates
            else
                null
            end' 2>/dev/null); then
            _cfg_log_error "Could not parse sibling_crates for $toolname"
            return 4
        fi
    else
        raw_json="null"
    fi

    _config_canonicalize_release_source_dependency_checkouts_json "$raw_json"
}

# Get the exact source-dependency identities that a strict release manifest
# must record, excluding host-local checkout paths.
# Usage: config_get_release_source_dependencies_json <toolname>
# Returns: Compact canonical JSON array sorted by relative_path.
config_get_release_source_dependencies_json() {
    local toolname="${1:-}"
    local checkouts_json

    checkouts_json=$(_config_get_release_source_dependency_checkouts_json "$toolname") || return $?
    printf '%s\n' "$checkouts_json" | jq -ceS \
        'map({relative_path, git_sha}) | sort_by(.relative_path)' 2>/dev/null
}

# Internal: get configured targets using the same per-tool precedence as the
# release contract lookup. The raw array shape is validated by the caller.
_config_get_tool_targets_json() {
    local toolname="$1"
    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local tool_config="$config_dir/repos.d/${toolname}.yaml"
    local tool_json has_targets raw_json

    if [[ -f "$tool_config" ]]; then
        tool_json=$(_config_read_single_mapping_json "$tool_config") || return $?
        has_targets=$(printf '%s\n' "$tool_json" | jq -r 'has("targets")') || return 4
        if [[ "$has_targets" == "true" ]]; then
            raw_json=$(printf '%s\n' "$tool_json" | jq -c '.targets') || return 4
            printf '%s\n' "$raw_json" | jq -c . 2>/dev/null
            return $?
        fi
    fi

    if [[ -f "$DSR_REPOS_FILE" ]]; then
        local registry_json
        registry_json=$(_config_read_single_mapping_json "$DSR_REPOS_FILE") || return $?
        raw_json=$(printf '%s\n' "$registry_json" | jq -c --arg tool "$toolname" '
            if (.tools | type) != "object" then
                error("tools must be an object")
            elif (.tools | has($tool)) and ((.tools[$tool] | type) != "object") then
                error("tool entry must be an object")
            elif (.tools | has($tool)) and (.tools[$tool] | has("targets")) then
                .tools[$tool].targets
            else
                null
            end' 2>/dev/null) || return 4
    else
        raw_json="null"
    fi
    printf '%s\n' "$raw_json" | jq -c . 2>/dev/null
}

# Validate an opt-in exact release asset contract.
# Usage: config_validate_release_contract <toolname>
# Returns: 0 for a valid contract or no contract, 4 for an invalid contract.
config_validate_release_contract() {
    local toolname="${1:-}"
    local contract_json targets_json

    contract_json=$(config_get_release_contract_json "$toolname") || return $?
    [[ "$contract_json" == "null" ]] && return 0

    if ! targets_json=$(_config_get_tool_targets_json "$toolname"); then
        _cfg_log_error "Could not parse configured targets for $toolname"
        return 4
    fi

    if jq -en \
        --argjson contract "$contract_json" \
        --argjson targets "$targets_json" '
        def safe_name:
            if type != "string" then false
            else
                length > 0 and
                test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and
                (contains("/") | not) and
                (contains("..") | not)
            end;
        def safe_path_component:
            type == "string" and
            length > 0 and
            test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and
            . != "." and
            . != "..";
        def safe_project_path:
            type == "string" and
            length > 0 and
            (startswith("/") | not) and
            (contains("\\") | not) and
            (split("/") | all(.[]; safe_path_component));
        def safe_primary:
            safe_name and
            (ascii_downcase | endswith(".sha256") | not) and
            (ascii_downcase | endswith(".minisig") | not);

        if ($contract | type) != "object" then false
        elif ($targets | type) != "array" then false
        elif (($contract | has("checksum_sidecar")) | not) then false
        elif (($contract | has("exact_primary_assets")) | not) then false
        elif (($contract | keys) - [
            "checksum_sidecar",
            "exact_additional_assets",
            "exact_primary_assets",
            "minisign_public_key_file"
        ] | length) != 0 then false
        elif $contract.checksum_sidecar != "sha256" then false
        elif ($contract.exact_primary_assets | type) != "object" then false
        elif (($contract.exact_additional_assets // []) | type) != "array" then false
        elif ($contract | has("minisign_public_key_file")) and
             (($contract.minisign_public_key_file | safe_project_path) | not) then false
        elif ($targets | length) == 0 then false
        elif ([$targets[] | if type == "string" then length > 0 else false end] | all | not) then false
        elif (($targets | unique | length) != ($targets | length)) then false
        else
            ($contract.exact_primary_assets | [.[]]) as $primaries |
            ($contract |
                if has("exact_additional_assets")
                then .exact_additional_assets
                else []
                end) as $additional |
            ($contract |
                if has("minisign_public_key_file")
                then ($primaries | map(. + ".minisig"))
                else []
                end) as $signatures |
            ($primaries + ($primaries | map(. + ".sha256")) + $signatures + $additional) as $all_assets |
            (($contract.exact_primary_assets | keys | sort) == ($targets | sort)) and
            ([$contract.exact_primary_assets[] | safe_primary] | all) and
            ([$additional[] | safe_name] | all) and
            (($contract.exact_primary_assets | [.[]] | unique | length) ==
             ($contract.exact_primary_assets | length)) and
            (($all_assets | map(ascii_downcase) | unique | length) == ($all_assets | length))
        end
    ' >/dev/null 2>&1; then
        if ! config_get_release_source_dependencies_json "$toolname" >/dev/null; then
            _cfg_log_error "Invalid release source dependencies for $toolname"
            return 4
        fi
        return 0
    fi

    _cfg_log_error "Invalid release_contract for $toolname"
    return 4
}

# Get install_script_compat pattern for a tool
# This is the naming pattern expected by install.sh scripts
# Usage: config_get_install_script_compat <toolname>
# Returns: Compat pattern (e.g., "${name}-${os}-${arch}") or empty
config_get_install_script_compat() {
    local toolname="$1"
    config_get_tool_field "$toolname" "install_script_compat" ""
}

# Get install_script_path for a tool
# When set, dsr parses this script to auto-detect the expected naming pattern
# Usage: config_get_install_script_path <toolname>
# Returns: Path to install.sh (relative to repo root) or empty
config_get_install_script_path() {
    local toolname="$1"
    config_get_tool_field "$toolname" "install_script_path" ""
}

# Get artifact naming pattern for a tool
# Usage: config_get_artifact_naming <toolname>
# Returns: Naming pattern (e.g., "${name}-${version}-${os}-${arch}") or empty
config_get_artifact_naming() {
    local toolname="$1"
    config_get_tool_field "$toolname" "artifact_naming" ""
}

# Get target triple override for a tool/platform
# Usage: config_get_target_triple <toolname> <platform>
# Returns: Target triple (e.g., "x86_64-unknown-linux-gnu") or empty
config_get_target_triple() {
    local toolname="$1"
    local platform="$2"

    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local tool_config="$config_dir/repos.d/${toolname}.yaml"

    if [[ -f "$tool_config" ]] && command -v yq &>/dev/null; then
        local value
        value=$(yq -r ".target_triples.\"$platform\" // \"\"" "$tool_config" 2>/dev/null)
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
            return 0
        fi
    fi

    if [[ -f "$DSR_REPOS_FILE" ]] && command -v yq &>/dev/null; then
        local value
        value=$(yq -r ".tools.$toolname.target_triples.\"$platform\" // \"\"" "$DSR_REPOS_FILE" 2>/dev/null)
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
            return 0
        fi
    fi

    echo ""
}

# Get arch alias override for a tool/arch
# Usage: config_get_arch_alias <toolname> <arch>
# Returns: Alias (e.g., "x86_64") or empty
config_get_arch_alias() {
    local toolname="$1"
    local arch="$2"

    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local tool_config="$config_dir/repos.d/${toolname}.yaml"

    if [[ -f "$tool_config" ]] && command -v yq &>/dev/null; then
        local value
        value=$(yq -r ".arch_aliases.\"$arch\" // \"\"" "$tool_config" 2>/dev/null)
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
            return 0
        fi
    fi

    if [[ -f "$DSR_REPOS_FILE" ]] && command -v yq &>/dev/null; then
        local value
        value=$(yq -r ".tools.$toolname.arch_aliases.\"$arch\" // \"\"" "$DSR_REPOS_FILE" 2>/dev/null)
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
            return 0
        fi
    fi

    echo ""
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
        local -a hosts=()
        while IFS= read -r host; do
            [[ -z "$host" || "$host" == "null" ]] && continue
            local enabled
            enabled=$(HOST="$host" yq -r '.hosts[env(HOST)].enabled' "$DSR_HOSTS_FILE" 2>/dev/null || echo null)
            [[ "$enabled" == "null" ]] && enabled=true
            [[ "$enabled" == "true" ]] && hosts+=("$host")
        done < <(yq -r '.hosts | keys | .[]' "$DSR_HOSTS_FILE")

        if $json_mode; then
            for host in "${hosts[@]}"; do
                echo "$host"
            done | jq -R -s 'split("
") | map(select(length > 0))'
        else
            for host in "${hosts[@]}"; do
                echo "$host"
            done
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
        local host
        host=$(PLATFORM="$platform" yq -r '.platform_mapping[env(PLATFORM)] // ""' "$DSR_HOSTS_FILE" 2>/dev/null || echo "")
        if [[ -z "$host" || "$host" == "null" ]]; then
            echo ""
            return 0
        fi

        local enabled
        enabled=$(HOST="$host" yq -r '.hosts[env(HOST)].enabled' "$DSR_HOSTS_FILE" 2>/dev/null || echo null)
        [[ "$enabled" == "null" ]] && enabled=true
        if [[ "$enabled" == "true" ]]; then
            echo "$host"
        else
            echo ""
        fi
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
export -f config_get_tool_field config_get_install_script_compat config_get_install_script_path
export -f config_get_artifact_naming config_get_target_triple config_get_arch_alias
export -f config_get_release_contract_json config_validate_release_contract
export -f config_get_release_source_dependencies_json
