#!/usr/bin/env bash
set -euo pipefail

# 03) GitLab 배포(선택)
# - GitOps에서 “Git 저장소”가 필요할 때 사용합니다.
# - ENABLE_GITLAB=true 인 경우에만 동작합니다.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
load_config

LOG_FILE="$SCRIPT_DIR/.logs/03_deploy_gitlab_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

if [[ "${ENABLE_GITLAB:-false}" != "true" ]]; then
  log "ENABLE_GITLAB=false → GitLab 배포를 건너뜁니다."
  exit 0
fi

require_cmd docker
require_cmd curl
require_cmd jq

if [[ -z "${SERVER_IP:-}" ]]; then
  SERVER_IP="$(detect_server_ip)"
fi
[[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP 감지 실패. config.env에 입력하세요."

DATA_DIR="${DATA_DIR:-/srv/gitops-lab}"

log "GitLab 배포 시작"
log "DATA_DIR=$DATA_DIR"

# 루트 비밀번호 준비(출력 금지)
if [[ -z "${GITLAB_ROOT_PASSWORD:-}" ]]; then
  GITLAB_ROOT_PASSWORD="$(random_password)"
  write_secret_file "$SCRIPT_DIR/.secrets/gitlab_root_password" "$GITLAB_ROOT_PASSWORD"
  log "GitLab root 비밀번호를 생성하여 저장했습니다: scripts/gitops/.secrets/gitlab_root_password"
else
  write_secret_file "$SCRIPT_DIR/.secrets/gitlab_root_password" "$GITLAB_ROOT_PASSWORD"
  log "GitLab root 비밀번호를 저장했습니다: scripts/gitops/.secrets/gitlab_root_password"
fi

sudo mkdir -p "$DATA_DIR/gitlab/config" "$DATA_DIR/gitlab/logs" "$DATA_DIR/gitlab/data"
sudo chown -R "$USER":"$USER" "$DATA_DIR/gitlab" || true

COMPOSE_FILE="$SCRIPT_DIR/.state/gitlab.compose.yml"
cat > "$COMPOSE_FILE" <<EOF
services:
  gitlab:
    image: ${GITLAB_IMAGE}
    container_name: gitlab
    hostname: gitlab
    shm_size: "256m"
    restart: unless-stopped
    environment:
      GITLAB_ROOT_PASSWORD: "${GITLAB_ROOT_PASSWORD}"
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://${SERVER_IP}:${GITLAB_HTTP_PORT}'
        gitlab_rails['gitlab_shell_ssh_port'] = ${GITLAB_SSH_PORT}
    ports:
      - "${GITLAB_HTTP_PORT}:80"
      - "${GITLAB_SSH_PORT}:22"
    volumes:
      - "${DATA_DIR}/gitlab/config:/etc/gitlab"
      - "${DATA_DIR}/gitlab/logs:/var/log/gitlab"
      - "${DATA_DIR}/gitlab/data:/var/opt/gitlab"
EOF

log "docker compose up -d"
docker compose -p gitops-gitlab -f "$COMPOSE_FILE" up -d

log "기동 확인(최대 20분 대기)"
deadline=$(( $(date +%s) + 1200 ))
while [[ $(date +%s) -lt $deadline ]]; do
  code="$(curl -s -o /dev/null -w "%{http_code}" "http://${SERVER_IP}:${GITLAB_HTTP_PORT}/users/sign_in" || true)"
  if [[ "$code" =~ ^2|^3 ]]; then
    log "GitLab 응답 확인 OK (HTTP $code)"
    break
  fi
  log "대기중... (HTTP $code)"
  sleep 10
done

log "GitLab URL: http://${SERVER_IP}:${GITLAB_HTTP_PORT}"
log "root 비밀번호 파일: scripts/gitops/.secrets/gitlab_root_password"
log "완료 (로그: $LOG_FILE)"

