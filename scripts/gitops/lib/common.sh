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
  # shellcheck disable=SC1090
  source "$config_file"
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

gitlab_api() {
  local method="$1"; shift
  local path="$1"; shift
  local url="http://${SERVER_IP}:${GITLAB_HTTP_PORT}/api/v4${path}"
  curl -fsS -X "$method" -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "$@" "$url"
}

