#!/usr/bin/env bash
set -euo pipefail

# 01) 사전 점검(Preflight)
# - OS/권한/리소스/포트 충돌을 빠르게 확인합니다.
# - 신규 인스턴스에서도 바로 진행할 수 있도록, 필요한 패키지 설치를 점검/수행합니다(옵션).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
load_config
validate_bool "AUTO_INSTALL_PREREQS" "${AUTO_INSTALL_PREREQS:-}"
validate_bool "ENABLE_GITLAB" "${ENABLE_GITLAB:-false}"
validate_bool "ENABLE_HARBOR" "${ENABLE_HARBOR:-false}"
validate_bool "ENABLE_DEMO_APP" "${ENABLE_DEMO_APP:-true}"

LOG_FILE="$SCRIPT_DIR/.logs/01_preflight_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

require_cmd uname
require_cmd awk
require_cmd sudo

if [[ -z "${SERVER_IP:-}" ]]; then
  SERVER_IP="$(detect_server_ip)"
fi
[[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP를 감지하지 못했습니다. scripts/gitops/config.env에 직접 입력하세요."

log "사전 점검 시작"
log "설정 파일: ${LOADED_CONFIG_FILE:-unknown}"
log "SERVER_IP=$SERVER_IP"

log "OS/커널 정보"
cat /etc/os-release 2>/dev/null || true
uname -a || true

log "권한 확인(sudo)"
if sudo -n true 2>/dev/null; then
  log "sudo: OK"
else
  warn "sudo 비밀번호 입력이 필요할 수 있습니다(대화형)."
fi

# -----------------------------------------
# 신규 인스턴스용 기본 패키지 설치 점검
# -----------------------------------------
# 이 프로젝트의 스크립트들은 다음 명령을 사용합니다:
# - curl/jq : API 호출 및 JSON 파싱
# - openssl : 랜덤 비밀번호 생성
# - git     : (선택) Git 리포 연동 시 필요
AUTO_INSTALL_PREREQS="${AUTO_INSTALL_PREREQS:-true}"

missing_cmds=()
for c in curl jq openssl git tar; do
  command -v "$c" >/dev/null 2>&1 || missing_cmds+=("$c")
done

if [[ ${#missing_cmds[@]} -gt 0 ]]; then
  warn "필수 명령이 일부 없습니다: ${missing_cmds[*]}"
  if [[ "$AUTO_INSTALL_PREREQS" == "true" ]]; then
    if ! command -v apt-get >/dev/null 2>&1; then
      die "apt-get이 없습니다. Ubuntu 환경에서 실행하거나, 필요한 패키지를 수동 설치하세요."
    fi
    log "필수 패키지 설치를 시도합니다(apt-get)."
    log "설치 대상: ca-certificates curl jq openssl git tar iproute2 procps"
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl jq openssl git tar iproute2 procps
  else
    warn "AUTO_INSTALL_PREREQS=false → 수동 설치 후 다시 실행하세요."
    warn "예) sudo apt-get update && sudo apt-get install -y ca-certificates curl jq openssl git tar iproute2 procps"
    die "필수 패키지가 누락되어 중단합니다."
  fi
fi

log "리소스 확인"
df -h / || true
free -h || true
nproc 2>/dev/null || true

# GitLab은 매우 무겁습니다. (최소 4GB, 권장 8GB+)
if [[ "${ENABLE_GITLAB:-false}" == "true" ]] && command -v free >/dev/null 2>&1; then
  mem_mb="$(free -m | awk '/Mem:/{print $2}' | tr -d '\r')"
  if [[ -n "${mem_mb:-}" ]]; then
    if (( mem_mb < 4096 )); then
      warn "메모리가 ${mem_mb}MB 입니다. GitLab은 최소 4GB 이상을 권장합니다(부팅이 매우 느리거나 unhealthy가 날 수 있음)."
      warn "가능하면 인스턴스 스펙 업그레이드 또는 swap 구성 후 진행하세요."
    elif (( mem_mb < 8192 )); then
      warn "메모리가 ${mem_mb}MB 입니다. GitLab은 8GB 이상이 더 안정적입니다."
    fi
  fi
fi

log "포트 점유 확인"
if command -v ss >/dev/null 2>&1; then
  sudo ss -lntup | egrep ":${GITLAB_HTTP_PORT}|:${HARBOR_HTTP_PORT}|:${ARGOCD_NODEPORT_HTTPS}|:6443" || true
else
  warn "ss 명령이 없어 포트 점유 확인을 건너뜁니다."
fi

log "필수 명령 최종 확인"
for c in curl jq openssl git tar; do
  require_cmd "$c"
done

log "사전 점검 완료 (로그: $LOG_FILE)"
