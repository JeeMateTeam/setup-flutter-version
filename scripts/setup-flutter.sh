#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[setup-flutter-version] $*"
}

fail() {
  echo "::error::$1" >&2
  exit 1
}

is_true() {
  case "${1,,}" in
    true | 1 | yes) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_path() {
  local path="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$path"
  else
    echo "$path"
  fi
}

path_has_flutter() {
  local root="$1"
  [[ -n "$root" && -x "$root/bin/flutter" ]]
}

validate_git_clone() {
  local root="$1"
  if [[ ! -d "$root/.git" ]]; then
    fail "Flutter SDK at '$root' is not a git clone (.git directory missing). Install Flutter via git clone. See: https://github.com/${GITHUB_REPOSITORY:-your-org/setup-flutter-version}#prerequisites"
  fi
}

detect_flutter_root() {
  local candidate=""

  if [[ -n "${INPUT_FLUTTER_ROOT:-}" ]]; then
    candidate="${INPUT_FLUTTER_ROOT}"
    path_has_flutter "$candidate" || fail "Input flutter-root '$candidate' is invalid (bin/flutter not found)."
    validate_git_clone "$candidate"
    echo "$candidate"
    return
  fi

  if [[ -n "${FLUTTER_ROOT:-}" ]]; then
    candidate="${FLUTTER_ROOT}"
    if path_has_flutter "$candidate"; then
      validate_git_clone "$candidate"
      echo "$candidate"
      return
    fi
  fi

  if command -v flutter >/dev/null 2>&1; then
    local flutter_bin
    flutter_bin="$(command -v flutter)"
    candidate="$(cd "$(dirname "$flutter_bin")/.." && pwd)"
    if path_has_flutter "$candidate"; then
      validate_git_clone "$candidate"
      echo "$candidate"
      return
    fi
  fi

  if [[ "$(uname -s)" == "Linux" && -d /opt/flutter && -x /opt/flutter/bin/flutter ]]; then
    candidate="/opt/flutter"
    validate_git_clone "$candidate"
    echo "$candidate"
    return
  fi

  for candidate in "$HOME/flutter" "$HOME/development/flutter" "/usr/local/flutter"; do
    if path_has_flutter "$candidate"; then
      validate_git_clone "$candidate"
      echo "$candidate"
      return
    fi
  done

  if [[ "$(uname -s)" == "MINGW"* || "$(uname -s)" == "MSYS"* || "$(uname -s)" == "CYGWIN"* ]]; then
    for candidate in "${LOCALAPPDATA}/flutter" "/c/flutter" "C:/flutter"; do
      if path_has_flutter "$candidate"; then
        validate_git_clone "$candidate"
        echo "$candidate"
        return
      fi
    done
  fi

  fail "No Flutter git SDK found. Set flutter-root or FLUTTER_ROOT, or install Flutter via git clone. See README prerequisites."
}

ensure_safe_directory() {
  local root="$1"
  git config --global --add safe.directory "$root" >/dev/null 2>&1 || true
}

current_revision() {
  local root="$1"
  git -C "$root" rev-parse HEAD
}

normalize_version() {
  echo "$1" | sed -E 's/-.*$//'
}

verify_flutter_version() {
  local flutter_bin="$1"
  local expected="$2"
  local machine_json actual normalized_expected normalized_actual

  machine_json="$("$flutter_bin" --version --machine 2>/dev/null || true)"
  if [[ -z "$machine_json" ]]; then
    fail "Unable to read Flutter version via 'flutter --version --machine'."
  fi

  if command -v jq >/dev/null 2>&1; then
    actual="$(echo "$machine_json" | jq -r '.frameworkVersion // empty')"
  else
    actual="$(echo "$machine_json" | sed -n 's/.*"frameworkVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  fi

  if [[ "$expected" == *-* ]]; then
    if [[ "$actual" != "$expected" ]]; then
      fail "Flutter version mismatch after switch. Expected '${expected}', got '${actual}'."
    fi
    return
  fi

  normalized_expected="$(normalize_version "$expected")"
  normalized_actual="$(normalize_version "$actual")"

  if [[ "$normalized_actual" != "$normalized_expected" ]]; then
    fail "Flutter version mismatch after switch. Expected '${expected}', got '${actual}'."
  fi
}

build_precache_flags() {
  local platforms="${INPUT_PRECACHE_PLATFORMS:-android,ios,web}"
  local flags=()
  local platform

  IFS=',' read -ra platform_list <<< "$platforms"
  for platform in "${platform_list[@]}"; do
    platform="$(echo "$platform" | xargs | tr '[:upper:]' '[:lower:]')"
    case "$platform" in
      android) flags+=("--android") ;;
      ios)
        if [[ "$(uname -s)" == "Darwin" ]]; then
          flags+=("--ios")
        fi
        ;;
      web) flags+=("--web") ;;
      windows)
        if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* || "${RUNNER_OS:-}" == "Windows" ]]; then
          flags+=("--windows")
        fi
        ;;
      linux)
        if [[ "$(uname -s)" == "Linux" ]]; then
          flags+=("--linux")
        fi
        ;;
      macos)
        if [[ "$(uname -s)" == "Darwin" ]]; then
          flags+=("--macos")
        fi
        ;;
      *)
        log "Ignoring unknown precache platform: $platform"
        ;;
    esac
  done

  echo "${flags[@]}"
}

switch_channel_if_needed() {
  local flutter_bin="$1"
  local channel="$2"
  local current_channel=""

  current_channel="$("$flutter_bin" --version --machine 2>/dev/null | sed -n 's/.*"channel"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 || true)"
  if [[ "$current_channel" == "$channel" ]]; then
    log "Already on channel '$channel'."
    return
  fi

  log "Switching Flutter channel to '$channel'..."
  "$flutter_bin" channel "$channel" --cache-artifacts=false
}

switch_version() {
  local root="$1"
  local flutter_bin="$2"
  local target_hash="$3"
  local target_version="$4"
  local is_channel_head="$5"
  local current_hash=""

  current_hash="$(current_revision "$root")"
  if [[ "$current_hash" == "$target_hash" ]]; then
    log "Already on target revision ${target_hash:0:12} (${target_version})."
    return
  fi

  switch_channel_if_needed "$flutter_bin" "${RESOLVED_CHANNEL}"

  if is_true "$is_channel_head"; then
    log "Target is channel head; running flutter upgrade..."
    "$flutter_bin" upgrade --force
    return
  fi

  log "Checking out Flutter ${target_version} (${target_hash:0:12})..."
  git -C "$root" fetch --tags --force
  if ! git -C "$root" checkout "$target_hash" -f; then
    log "Hash checkout failed; trying tag ${target_version}..."
    git -C "$root" checkout "tags/${target_version}" -f || fail "Failed to checkout Flutter version ${target_version}."
  fi
}

main() {
  local flutter_root flutter_bin precache_flags

  : "${RESOLVED_VERSION:?RESOLVED_VERSION is required}"
  : "${RESOLVED_HASH:?RESOLVED_HASH is required}"
  : "${RESOLVED_CHANNEL:?RESOLVED_CHANNEL is required}"
  : "${RESOLVED_IS_CHANNEL_HEAD:=false}"

  flutter_root="$(detect_flutter_root)"
  flutter_root="$(cd "$flutter_root" && pwd)"
  flutter_bin="$flutter_root/bin/flutter"

  log "Using Flutter SDK at $flutter_root"
  ensure_safe_directory "$flutter_root"

  switch_version "$flutter_root" "$flutter_bin" "$RESOLVED_HASH" "$RESOLVED_VERSION" "$RESOLVED_IS_CHANNEL_HEAD"

  log "Running flutter doctor..."
  "$flutter_bin" doctor --suppress-analytics

  verify_flutter_version "$flutter_bin" "$RESOLVED_VERSION"

  if is_true "${INPUT_PRECACHE:-true}"; then
    read -r -a precache_flags <<< "$(build_precache_flags)"
    if ((${#precache_flags[@]} > 0)); then
      log "Running flutter precache ${precache_flags[*]}..."
      "$flutter_bin" precache --suppress-analytics "${precache_flags[@]}"
    else
      log "No precache platforms applicable on this OS; skipping precache."
    fi
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "flutter-root=$flutter_root" >> "$GITHUB_OUTPUT"
  fi

  log "Flutter ${RESOLVED_VERSION} is ready at ${flutter_root}"
}

main "$@"
