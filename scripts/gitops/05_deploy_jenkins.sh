#!/usr/bin/env bash
set -euo pipefail

# 05) Jenkins 배포(선택)
# - CI 엔진(Jenkins)을 Docker로 최소 구성 배포합니다.
# - ENABLE_JENKINS=true 인 경우에만 동작합니다.
# - 이미 Jenkins가 동작 중이면(HTTP 응답) 설치는 스킵합니다.
#
# 주의:
# - Jenkins에서 Docker 빌드를 하려면 Docker 소켓 접근이 필요합니다.
#   (옵션) JENKINS_ENABLE_DOCKER_SOCKET=true 로 소켓 마운트 + docker 그룹을 맞춥니다.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
LOG_FILE="$SCRIPT_DIR/.logs/05_deploy_jenkins_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

load_config
validate_bool "ENABLE_JENKINS" "${ENABLE_JENKINS:-false}"

log "설정 파일: ${LOADED_CONFIG_FILE:-unknown}"
log "ENABLE_JENKINS=${ENABLE_JENKINS:-false}"

if ! is_true "${ENABLE_JENKINS:-false}"; then
  log "ENABLE_JENKINS=false → Jenkins 배포를 건너뜁니다. (scripts/gitops/config.env에서 ENABLE_JENKINS=\"true\"로 변경)"
  exit 0
fi

require_cmd docker
require_cmd curl
require_cmd sudo

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  die "docker compose를 찾지 못했습니다. (02_install_docker.sh를 먼저 실행하세요)"
fi

if [[ -z "${SERVER_IP:-}" ]]; then
  SERVER_IP="$(detect_server_ip)"
fi
[[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP 감지 실패. config.env에 입력하세요."

DATA_DIR="${DATA_DIR:-/srv/gitops-lab}"
TARGET_USER="${SUDO_USER:-$USER}"

JENKINS_HTTP_PORT="${JENKINS_HTTP_PORT:-8081}"
JENKINS_IMAGE="${JENKINS_IMAGE:-jenkins/jenkins:2.479.3-lts-jdk17}"
JENKINS_PERSIST_DATA="${JENKINS_PERSIST_DATA:-true}"
JENKINS_ENABLE_DOCKER_SOCKET="${JENKINS_ENABLE_DOCKER_SOCKET:-true}"

validate_bool "JENKINS_PERSIST_DATA" "$JENKINS_PERSIST_DATA"
validate_bool "JENKINS_ENABLE_DOCKER_SOCKET" "$JENKINS_ENABLE_DOCKER_SOCKET"

JENKINS_URL="http://${SERVER_IP}:${JENKINS_HTTP_PORT}"
log "Jenkins URL(내부 확인용): $JENKINS_URL"

log "기존 Jenkins 확인"
code="$(curl -s -o /dev/null -w "%{http_code}" "${JENKINS_URL}/login" || true)"
if [[ "$code" =~ ^2|^3|^4 ]]; then
  log "Jenkins가 이미 응답합니다(HTTP $code). 배포를 스킵합니다."
  exit 0
fi

if [[ "$JENKINS_PERSIST_DATA" == "true" ]]; then
  log "Jenkins 볼륨 모드: ON (DATA_DIR에 데이터 유지)"
  sudo mkdir -p "$DATA_DIR/jenkins"
  sudo chown -R "$TARGET_USER":"$TARGET_USER" "$DATA_DIR/jenkins" || true
else
  log "Jenkins 볼륨 모드: OFF (최소 구성, 컨테이너 재생성 시 데이터 유실 가능)"
fi

# Jenkins가 host Docker 소켓을 쓰게 할 때, docker 그룹 GID를 맞추면 권한 이슈가 줄어듭니다.
docker_gid=""
if getent group docker >/dev/null 2>&1; then
  docker_gid="$(getent group docker | awk -F: '{print $3}' | tr -d '\r')"
fi

COMPOSE_FILE="$SCRIPT_DIR/.state/jenkins.compose.yml"
cat > "$COMPOSE_FILE" <<EOF
services:
  jenkins:
    image: ${JENKINS_IMAGE}
    container_name: jenkins
    restart: unless-stopped
    ports:
      - "${JENKINS_HTTP_PORT}:8080"
EOF

if [[ "$JENKINS_PERSIST_DATA" == "true" || "$JENKINS_ENABLE_DOCKER_SOCKET" == "true" ]]; then
  echo "    volumes:" >> "$COMPOSE_FILE"
  if [[ "$JENKINS_PERSIST_DATA" == "true" ]]; then
    echo "      - \"${DATA_DIR}/jenkins:/var/jenkins_home\"" >> "$COMPOSE_FILE"
  fi
  if [[ "$JENKINS_ENABLE_DOCKER_SOCKET" == "true" ]]; then
    echo "      - \"/var/run/docker.sock:/var/run/docker.sock\"" >> "$COMPOSE_FILE"
    # host의 docker CLI를 컨테이너에 마운트(환경에 따라 경로가 다를 수 있음)
    if [[ -x /usr/bin/docker ]]; then
      echo "      - \"/usr/bin/docker:/usr/bin/docker:ro\"" >> "$COMPOSE_FILE"
    else
      warn "/usr/bin/docker 경로가 없어 docker CLI 마운트를 건너뜁니다(컨테이너 내부에 docker CLI가 없으면 빌드가 실패할 수 있음)."
    fi
  fi
fi

if [[ "$JENKINS_ENABLE_DOCKER_SOCKET" == "true" && -n "${docker_gid:-}" ]]; then
  cat >> "$COMPOSE_FILE" <<EOF
    group_add:
      - "${docker_gid}"
EOF
fi

log "docker compose up -d"
"${COMPOSE[@]}" -p gitops-jenkins -f "$COMPOSE_FILE" up -d

log "기동 확인(최대 5분 대기)"
deadline=$(( $(date +%s) + 300 ))
while [[ $(date +%s) -lt $deadline ]]; do
  code="$(curl -s -o /dev/null -w "%{http_code}" "${JENKINS_URL}/login" || true)"
  if [[ "$code" =~ ^2|^3|^4 ]]; then
    log "Jenkins 응답 확인(HTTP $code)"
    break
  fi
  log "대기중... (HTTP $code)"
  sleep 5
done

pw_file="$SCRIPT_DIR/.secrets/jenkins_initial_admin_password"
if [[ ! -s "$pw_file" ]]; then
  log "Jenkins 초기 admin 비밀번호 추출 시도(출력 금지)"
  extracted_pw="$(docker exec jenkins bash -lc "cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null || true" 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "${extracted_pw:-}" ]]; then
    write_secret_file "$pw_file" "$extracted_pw"
    log "초기 admin 비밀번호를 저장했습니다: scripts/gitops/.secrets/jenkins_initial_admin_password"
  else
    warn "초기 admin 비밀번호를 자동으로 추출하지 못했습니다."
    warn "필요 시 다음으로 확인하세요:"
    warn "  docker exec -it jenkins bash -lc 'cat /var/jenkins_home/secrets/initialAdminPassword'"
  fi
fi

log "Jenkins URL: $JENKINS_URL"
log "완료 (로그: $LOG_FILE)"
