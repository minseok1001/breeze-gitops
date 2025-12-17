#!/usr/bin/env bash
set -euo pipefail

# 03) GitLab 배포(선택)
# - GitOps에서 “Git 저장소”가 필요할 때 사용합니다.
# - ENABLE_GITLAB=true 인 경우에만 동작합니다.
# - GitLab은 초기 설치/마이그레이션으로 10~30분 이상 걸릴 수 있습니다.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
LOG_FILE="$SCRIPT_DIR/.logs/03_deploy_gitlab_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

load_config
validate_bool "ENABLE_GITLAB" "${ENABLE_GITLAB:-}"

log "설정 파일: ${LOADED_CONFIG_FILE:-unknown}"
log "ENABLE_GITLAB=${ENABLE_GITLAB:-}"

if ! is_true "${ENABLE_GITLAB:-false}"; then
  log "ENABLE_GITLAB=false → GitLab 배포를 건너뜁니다. (scripts/gitops/config.env에서 ENABLE_GITLAB=\"true\"로 변경)"
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
TARGET_USER="${SUDO_USER:-$USER}"
GITLAB_SHM_SIZE="${GITLAB_SHM_SIZE:-1g}"

log "GitLab 배포 시작"
log "DATA_DIR=$DATA_DIR"

# 루트 비밀번호 준비(출력 금지, 재실행 시 기존 값 재사용)
pw_file="$SCRIPT_DIR/.secrets/gitlab_root_password"
if [[ -z "${GITLAB_ROOT_PASSWORD:-}" ]]; then
  if [[ -f "$pw_file" ]]; then
    GITLAB_ROOT_PASSWORD="$(cat "$pw_file")"
    log "기존 GitLab root 비밀번호 파일을 재사용합니다: scripts/gitops/.secrets/gitlab_root_password"
  else
    GITLAB_ROOT_PASSWORD="$(random_password)"
    write_secret_file "$pw_file" "$GITLAB_ROOT_PASSWORD"
    log "GitLab root 비밀번호를 생성하여 저장했습니다: scripts/gitops/.secrets/gitlab_root_password"
  fi
else
  write_secret_file "$pw_file" "$GITLAB_ROOT_PASSWORD"
  log "GitLab root 비밀번호를 저장했습니다: scripts/gitops/.secrets/gitlab_root_password"
fi

sudo mkdir -p "$DATA_DIR/gitlab/config" "$DATA_DIR/gitlab/logs" "$DATA_DIR/gitlab/data"
sudo chown -R "$TARGET_USER":"$TARGET_USER" "$DATA_DIR/gitlab" || true

# 리소스가 작은 인스턴스에서는 Puma 워커를 줄여야 Rails가 덜 죽습니다.
extra_omnibus_config=""
if command -v free >/dev/null 2>&1; then
  mem_mb="$(free -m | awk '/Mem:/{print $2}' | tr -d '\r')"
  if [[ -n "${mem_mb:-}" && "$mem_mb" =~ ^[0-9]+$ ]]; then
    if (( mem_mb < 8192 )); then
      extra_omnibus_config=$'puma[\'worker_processes\'] = 0\n'
      log "메모리 ${mem_mb}MB 감지 → GitLab Puma 워커를 0(싱글 모드)으로 튜닝합니다."
    fi
  fi
fi

COMPOSE_FILE="$SCRIPT_DIR/.state/gitlab.compose.yml"
cat > "$COMPOSE_FILE" <<EOF
services:
  gitlab:
    image: ${GITLAB_IMAGE}
    container_name: gitlab
    hostname: gitlab
    shm_size: "${GITLAB_SHM_SIZE}"
    restart: unless-stopped
    environment:
      GITLAB_ROOT_PASSWORD: "${GITLAB_ROOT_PASSWORD}"
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://${SERVER_IP}:${GITLAB_HTTP_PORT}'
        gitlab_rails['gitlab_shell_ssh_port'] = ${GITLAB_SSH_PORT}
        ${extra_omnibus_config}
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

timeout_sec="${GITLAB_STARTUP_TIMEOUT_SEC:-1800}"
log "기동 확인(최대 ${timeout_sec}초 대기)"
deadline=$(( $(date +%s) + timeout_sec ))
while [[ $(date +%s) -lt $deadline ]]; do
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' gitlab 2>/dev/null || true)"
  code="$(curl -s -o /dev/null -w "%{http_code}" "http://${SERVER_IP}:${GITLAB_HTTP_PORT}/-/readiness" || true)"
  if [[ "$code" == "404" ]]; then
    code="$(curl -s -o /dev/null -w "%{http_code}" "http://${SERVER_IP}:${GITLAB_HTTP_PORT}/users/sign_in" || true)"
  fi
  if [[ "$code" =~ ^2|^3 ]] && [[ "$health" != "unhealthy" ]]; then
    log "GitLab 준비 완료 (HTTP $code, health=$health)"
    break
  fi
  log "대기중... (HTTP $code, health=$health)"
  sleep 10
done

final_health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' gitlab 2>/dev/null || true)"
final_code="$(curl -s -o /dev/null -w "%{http_code}" "http://${SERVER_IP}:${GITLAB_HTTP_PORT}/-/readiness" || true)"
if [[ "$final_code" == "404" ]]; then
  final_code="$(curl -s -o /dev/null -w "%{http_code}" "http://${SERVER_IP}:${GITLAB_HTTP_PORT}/users/sign_in" || true)"
fi

if ! [[ "$final_code" =~ ^2|^3 ]]; then
  warn "GitLab이 준비 상태가 아닙니다. (HTTP $final_code, health=$final_health)"
  warn "아래 명령으로 원인 확인을 권장합니다:"
  warn "  docker inspect -f '{{json .State.Health}}' gitlab | jq"
  warn "  docker exec -it gitlab gitlab-ctl status"
  warn "  docker exec -it gitlab gitlab-ctl tail puma --lines 200"
  warn "  docker exec -it gitlab gitlab-ctl tail postgresql --lines 200"
  warn "  sudo dmesg -T | tail -n 200 | grep -i oom || true"
  warn "최근 로그(200줄)를 출력합니다:"
  docker logs --tail 200 gitlab || true
  die "GitLab 기동 실패 또는 매우 지연됨"
fi

log "GitLab URL: http://${SERVER_IP}:${GITLAB_HTTP_PORT}"
log "root 비밀번호 파일: scripts/gitops/.secrets/gitlab_root_password"
log "완료 (로그: $LOG_FILE)"
