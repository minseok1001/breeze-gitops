#!/usr/bin/env bash
set -euo pipefail

# 00) 전체 실행 스크립트
# - 지금까지 만든 스크립트를 “순서대로 한 번에” 실행합니다.
# - 각 단계는 내부에서 ENABLE_* 값을 확인해 자동 스킵됩니다.
#
# 사용:
#   sudo bash scripts/gitops/00_run_all.sh
#
# 주의:
# - GitLab/Harbor/Jenkins가 이미 설치된 환경이면 03~05 단계가 스킵되도록 ENABLE_* 또는 각 스크립트 내 체크에 맡깁니다.
# - 실행 중 실패하면 즉시 중단됩니다(원인 로그 확인).

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
run_step "02_install_docker" bash "$SCRIPT_DIR/02_install_docker.sh"
run_step "03_deploy_gitlab" bash "$SCRIPT_DIR/03_deploy_gitlab.sh"
run_step "04_deploy_harbor" bash "$SCRIPT_DIR/04_deploy_harbor.sh"
run_step "05_deploy_jenkins" bash "$SCRIPT_DIR/05_deploy_jenkins.sh"
run_step "06_setup_harbor_project" bash "$SCRIPT_DIR/06_setup_harbor_project.sh"
run_step "07_seed_demo_app_repo" bash "$SCRIPT_DIR/07_seed_demo_app_repo.sh"
run_step "08_setup_jenkins_job" bash "$SCRIPT_DIR/08_setup_jenkins_job.sh"
run_step "09_setup_gitlab_webhook" bash "$SCRIPT_DIR/09_setup_gitlab_webhook.sh"
run_step "10_verify" bash "$SCRIPT_DIR/10_verify.sh"

log "전체 실행 완료 (로그: $LOG_FILE)"
