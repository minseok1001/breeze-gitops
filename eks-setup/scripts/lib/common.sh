#!/usr/bin/env bash
set -euo pipefail

# EKS 스크립트 공통 라이브러리

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*"; }
warn() { printf "[%s] WARN: %s\n" "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf "[%s] ERROR: %s\n" "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "필수 명령이 없습니다: $cmd"
}

ensure_dirs() {
  mkdir -p "$SCRIPT_DIR/.secrets" "$SCRIPT_DIR/.state" "$SCRIPT_DIR/.logs"
  chmod 700 "$SCRIPT_DIR/.secrets" "$SCRIPT_DIR/.state" 2>/dev/null || true
}

load_config() {
  local config_file="${1:-$SCRIPT_DIR/config.env}"
  [[ -f "$config_file" ]] || die "설정 파일이 없습니다: $config_file (config.env.example를 복사해서 생성하세요)"
  export LOADED_CONFIG_FILE="$config_file"
  # CRLF 체크
  if LC_ALL=C grep -q $'\r' "$config_file" 2>/dev/null; then
    warn "설정 파일에 CRLF(\\r) 문자가 있습니다: $config_file (LF로 변환 권장)"
  fi
  # shellcheck disable=SC1090
  source "$config_file"
}

validate_bool() {
  local name="$1"
  local value="${2:-}"
  case "$value" in
    true|false) return 0 ;;
    *) die "${name} 값이 올바르지 않습니다: '${value}' (true 또는 false만 허용)" ;;
  esac
}

normalize_url() {
  local url="$1"
  echo "${url%/}"
}

write_secret_file() {
  local file_path="$1"
  local content="$2"
  umask 077
  printf "%s" "$content" > "$file_path"
  chmod 600 "$file_path" || true
}

kubectl_cmd() {
  local args=()
  if [[ -n "${KUBECONFIG:-}" ]]; then
    args+=(--kubeconfig "$KUBECONFIG")
  fi
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    args+=(--context "$KUBE_CONTEXT")
  fi
  kubectl "${args[@]}" "$@"
}
