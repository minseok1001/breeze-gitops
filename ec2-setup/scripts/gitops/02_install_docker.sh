#!/usr/bin/env bash
set -euo pipefail

# 02) Docker 설치
# - GitLab/Harbor(선택) 및 각종 컨테이너 실행에 필요합니다.
# - 이미 설치되어 있으면 스킵합니다.
# - Ubuntu 24.04에서는 `docker-compose-plugin` 패키지가 없을 수 있어 `docker-compose-v2`를 우선 사용합니다.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
load_config

LOG_FILE="$SCRIPT_DIR/.logs/02_install_docker_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log "Docker 설치 시작"

if ! command -v apt-get >/dev/null 2>&1; then
  die "apt-get이 없습니다. Ubuntu 환경에서 실행하세요."
fi

TARGET_USER="${SUDO_USER:-$USER}"

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

install_compose_v2_ubuntu() {
  # Ubuntu 계열에서 compose v2 패키지명이 배포판마다 다를 수 있어 순서대로 시도합니다.
  if sudo apt-get install -y docker-compose-v2; then
    return 0
  fi
  if sudo apt-get install -y docker-compose-plugin; then
    return 0
  fi
  return 1
}

install_docker_ubuntu() {
  # 가능한 한 한 번에 설치(의존성 해결 포함)
  if sudo apt-get install -y docker.io docker-compose-v2; then
    return 0
  fi
  if sudo apt-get install -y docker.io docker-compose-plugin; then
    return 0
  fi
  # docker.io만 설치되고 compose가 없을 수 있으므로 분리 설치도 시도
  if sudo apt-get install -y docker.io; then
    install_compose_v2_ubuntu
    return $?
  fi
  return 1
}

install_docker_docker_repo() {
  # Ubuntu repo에 compose v2 패키지가 없을 때의 최후 수단: Docker 공식 APT repo 사용
  log "Docker 공식 APT repo로 설치를 시도합니다."
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  [[ -n "$codename" ]] || die "Ubuntu codename을 확인할 수 없습니다(/etc/os-release)."

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

if command -v docker >/dev/null 2>&1; then
  log "Docker가 이미 설치되어 있습니다: $(docker --version)"
  if docker compose version >/dev/null 2>&1; then
    log "docker compose 사용 가능: $(docker compose version 2>/dev/null || true)"
  else
    warn "docker compose를 찾지 못했습니다. Compose v2 설치를 시도합니다."
    if ! install_compose_v2_ubuntu; then
      warn "Ubuntu 패키지로 Compose v2 설치 실패 → Docker 공식 repo 방식은 기존 Docker와 충돌할 수 있어 자동 전환은 중단합니다."
      die "docker compose 설치가 필요합니다. (수동으로 docker-compose-v2 또는 docker-compose-plugin 설치)"
    fi
  fi
else
  log "Docker 설치(ubuntu 패키지 우선: docker.io + compose v2)"
  if ! install_docker_ubuntu; then
    warn "Ubuntu 패키지로 설치 실패 → Docker 공식 repo로 재시도"
    install_docker_docker_repo
  fi
fi

log "Docker 서비스 활성화"
sudo systemctl enable --now docker

# docker 그룹이 없거나, docker.sock이 root:root로 잡히면 일반 사용자 실행이 막힐 수 있습니다.
# - docker.io / docker-ce 모두 기본 그룹은 "docker" 입니다.
# - 그룹이 없으면 만들고, 소켓 그룹이 docker가 아니면 재시작으로 재생성되게 합니다.
if ! getent group docker >/dev/null 2>&1; then
  log "docker 그룹이 없어 생성합니다."
  sudo groupadd docker || true
fi

if [[ -S /var/run/docker.sock ]]; then
  sock_group="$(stat -c '%G' /var/run/docker.sock 2>/dev/null || true)"
  if [[ -n "${sock_group:-}" && "$sock_group" != "docker" ]]; then
    warn "docker.sock 그룹이 '${sock_group}' 입니다. docker 그룹으로 맞추기 위해 Docker를 재시작합니다."
    sudo systemctl restart docker
  fi
fi

log "현재 사용자 docker 그룹 추가(재로그인 필요할 수 있음): $TARGET_USER"
sudo usermod -aG docker "$TARGET_USER" || true

log "Docker 설치 완료: $(docker --version)"
log "docker compose 확인: $(docker compose version 2>/dev/null || true)"
log "주의: 그룹 변경은 현재 세션에 즉시 반영되지 않을 수 있습니다."
log "  - SSH 재접속(권장) 또는 'newgrp docker' 실행 후 docker 명령을 테스트하세요."
log "로그: $LOG_FILE"
