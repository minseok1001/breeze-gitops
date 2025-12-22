#!/usr/bin/env bash
set -euo pipefail

# 00) 전체 실행 스크립트(EKS)
# - Gateway API + Argo CD 설치를 한 번에 수행합니다.
#
# 사용:
#   sudo bash eks-setup/scripts/00_run_all.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
load_config

LOG_FILE="$SCRIPT_DIR/.logs/00_run_all_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

run_step() {
  local name="$1"
  shift
  log "========================================"
  log "STEP: $name"
  log "CMD : $*"
  "$@"
}

log "전체 실행 시작"
log "설정 파일: ${LOADED_CONFIG_FILE:-unknown}"

run_step "01_preflight" bash "$SCRIPT_DIR/01_preflight.sh"
run_step "02_gateway_api" bash "$SCRIPT_DIR/02_gateway_api.sh"
run_step "03_install_argocd" bash "$SCRIPT_DIR/03_install_argocd.sh"

log "전체 실행 완료 (로그: $LOG_FILE)"
