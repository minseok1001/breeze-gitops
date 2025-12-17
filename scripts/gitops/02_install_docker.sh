#!/usr/bin/env bash
set -euo pipefail

# 02) Docker 설치
# - GitLab/Harbor(선택) 및 각종 컨테이너 실행에 필요합니다.
# - 이미 설치되어 있으면 스킵합니다.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
load_config

LOG_FILE="$SCRIPT_DIR/.logs/02_install_docker_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log "Docker 설치 시작"

if command -v docker >/dev/null 2>&1; then
  log "Docker가 이미 설치되어 있습니다: $(docker --version)"
  exit 0
fi

if ! command -v apt-get >/dev/null 2>&1; then
  die "apt-get이 없습니다. Ubuntu 환경에서 실행하세요."
fi

log "필수 패키지 설치"
sudo apt-get update
sudo apt-get install -y \
  ca-certificates \
  curl \
  jq \
  openssl \
  git \
  gnupg \
  lsb-release

log "Docker 설치(ubuntu 패키지: docker.io, docker-compose-plugin)"
sudo apt-get install -y docker.io docker-compose-plugin

log "Docker 서비스 활성화"
sudo systemctl enable --now docker

log "현재 사용자 docker 그룹 추가(재로그인 필요할 수 있음): $USER"
sudo usermod -aG docker "$USER" || true

log "Docker 설치 완료: $(docker --version)"
log "docker compose 확인: $(docker compose version 2>/dev/null || true)"
log "로그: $LOG_FILE"

