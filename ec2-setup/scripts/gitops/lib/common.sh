#!/usr/bin/env bash
set -euo pipefail

# 공통 라이브러리(모든 스크립트가 사용)

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
  # CRLF로 저장되면 bash가 변수 파싱을 엉뚱하게 할 수 있습니다.
  if LC_ALL=C grep -q $'\r' "$config_file" 2>/dev/null; then
    warn "설정 파일에 CRLF(\\r) 문자가 있습니다: $config_file (LF로 변환 권장)"
  fi
  # shellcheck disable=SC1090
  source "$config_file"
}

is_true() {
  [[ "${1:-}" == "true" ]]
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

detect_server_ip() {
  # cloud-init 환경에서도 보통 hostname -I가 동작
  hostname -I 2>/dev/null | awk '{print $1}' | tr -d '\r' | head -n 1
}

random_password() {
  # base64는 +/=가 섞일 수 있어, 서비스에 따라 불편할 수 있음. 여기서는 간단히 hex로 생성.
  require_cmd openssl
  openssl rand -hex 16
}

write_secret_file() {
  local file_path="$1"
  local content="$2"
  umask 077
  printf "%s" "$content" > "$file_path"
  chmod 600 "$file_path" || true
}

urlencode() {
  local raw="$1"
  require_cmd jq
  jq -nr --arg v "$raw" '$v|@uri'
}

gitlab_api_base_url() {
  local base="${GITLAB_API_URL:-}"
  if [[ -z "${base:-}" ]]; then
    [[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP가 비어 있습니다. (gitlab api url 구성 실패)"
    base="http://${SERVER_IP}:${GITLAB_HTTP_PORT}"
  fi
  normalize_url "$base"
}

gitlab_api() {
  local method="$1"; shift
  local path="$1"; shift
  local base
  base="$(gitlab_api_base_url)"
  local url="${base}/api/v4${path}"
  curl -fsS -X "$method" -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "$@" "$url"
}

harbor_api_base_url() {
  local base="${HARBOR_API_URL:-}"
  if [[ -z "${base:-}" ]]; then
    [[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP가 비어 있습니다. (harbor api url 구성 실패)"
    base="http://${SERVER_IP}:${HARBOR_HTTP_PORT}"
  fi
  normalize_url "$base"
}

jenkins_api_base_url() {
  local base="${JENKINS_API_URL:-}"
  if [[ -z "${base:-}" ]]; then
    [[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP가 비어 있습니다. (jenkins api url 구성 실패)"
    base="http://${SERVER_IP}:${JENKINS_HTTP_PORT}"
  fi
  normalize_url "$base"
}
