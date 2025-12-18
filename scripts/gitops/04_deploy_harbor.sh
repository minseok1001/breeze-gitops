#!/usr/bin/env bash
set -euo pipefail

# 04) Harbor 배포(선택)
# - ENABLE_HARBOR=true 인 경우에만 동작합니다.
# - Harbor가 이미 떠 있으면(핑 OK) 설치는 스킵합니다.
# - 기본값으로 GitHub 릴리즈(오프라인 installer tgz)를 다운로드해서 설치합니다.
#   (폐쇄망이면 다운로드가 실패할 수 있으니, tgz를 수동 반입 후 HARBOR_OFFLINE_TGZ_PATH만 지정하세요.)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
LOG_FILE="$SCRIPT_DIR/.logs/04_deploy_harbor_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

load_config
validate_bool "ENABLE_HARBOR" "${ENABLE_HARBOR:-false}"

log "설정 파일: ${LOADED_CONFIG_FILE:-unknown}"
log "ENABLE_HARBOR=${ENABLE_HARBOR:-false}"

if ! is_true "${ENABLE_HARBOR:-false}"; then
  log "ENABLE_HARBOR=false → Harbor 배포를 건너뜁니다. (scripts/gitops/config.env에서 ENABLE_HARBOR=\"true\"로 변경)"
  exit 0
fi

require_cmd curl
require_cmd jq

if [[ -z "${SERVER_IP:-}" ]]; then
  SERVER_IP="$(detect_server_ip)"
fi
[[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP 감지 실패. config.env에 입력하세요."

DATA_DIR="${DATA_DIR:-/srv/gitops-lab}"
HARBOR_URL="http://${SERVER_IP}:${HARBOR_HTTP_PORT}"
HARBOR_REGISTRY_HOSTPORT="${HARBOR_REGISTRY_HOSTPORT:-${SERVER_IP}:${HARBOR_HTTP_PORT}}"

log "Harbor URL: $HARBOR_URL"
log "Harbor Registry(host:port): $HARBOR_REGISTRY_HOSTPORT"

log "기존 Harbor 확인(ping)"
if curl -fsS "$HARBOR_URL/api/v2.0/ping" | jq -e . >/dev/null 2>&1; then
  log "Harbor가 이미 동작 중입니다. 설치를 스킵합니다."
  exit 0
fi

require_cmd docker
require_cmd tar
require_cmd sudo

HARBOR_OFFLINE_TGZ_URL="${HARBOR_OFFLINE_TGZ_URL:-https://github.com/goharbor/harbor/releases/download/v2.14.1/harbor-offline-installer-v2.14.1.tgz}"
HARBOR_OFFLINE_TGZ_PATH="${HARBOR_OFFLINE_TGZ_PATH:-}"

if [[ -z "${HARBOR_OFFLINE_TGZ_PATH:-}" ]]; then
  file_name="$(basename "$HARBOR_OFFLINE_TGZ_URL")"
  HARBOR_OFFLINE_TGZ_PATH="$SCRIPT_DIR/.state/$file_name"
  log "HARBOR_OFFLINE_TGZ_PATH가 비어 있어 기본 경로를 사용합니다: $HARBOR_OFFLINE_TGZ_PATH"
fi

if [[ ! -f "$HARBOR_OFFLINE_TGZ_PATH" ]]; then
  log "Harbor 오프라인 installer 다운로드"
  log "URL: $HARBOR_OFFLINE_TGZ_URL"
  log "DEST: $HARBOR_OFFLINE_TGZ_PATH"
  if ! curl -fL --retry 3 --retry-delay 2 -o "$HARBOR_OFFLINE_TGZ_PATH" "$HARBOR_OFFLINE_TGZ_URL"; then
    warn "다운로드에 실패했습니다. (폐쇄망/방화벽/프록시 이슈일 수 있음)"
    warn "대안:"
    warn "  1) 다른 곳에서 tgz를 다운로드하여 서버로 복사"
    warn "  2) scripts/gitops/config.env에 HARBOR_OFFLINE_TGZ_PATH로 로컬 파일 경로 지정"
    die "Harbor 오프라인 installer 다운로드 실패"
  fi
fi

[[ -f "$HARBOR_OFFLINE_TGZ_PATH" ]] || die "Harbor tgz 파일이 없습니다: $HARBOR_OFFLINE_TGZ_PATH"

# 관리자 비밀번호 준비(출력 금지)
if [[ -z "${HARBOR_ADMIN_PASSWORD:-}" ]]; then
  HARBOR_ADMIN_PASSWORD="$(random_password)"
  write_secret_file "$SCRIPT_DIR/.secrets/harbor_admin_password" "$HARBOR_ADMIN_PASSWORD"
  log "Harbor admin 비밀번호를 생성하여 저장했습니다: scripts/gitops/.secrets/harbor_admin_password"
else
  write_secret_file "$SCRIPT_DIR/.secrets/harbor_admin_password" "$HARBOR_ADMIN_PASSWORD"
  log "Harbor admin 비밀번호를 저장했습니다: scripts/gitops/.secrets/harbor_admin_password"
fi

log "데이터 디렉토리 준비: $DATA_DIR/harbor"
sudo mkdir -p "$DATA_DIR/harbor"

HARBOR_DIR="/opt/harbor"
log "Harbor 설치 디렉토리 준비: $HARBOR_DIR"
sudo rm -rf "$HARBOR_DIR"
sudo mkdir -p "$HARBOR_DIR"
sudo tar xzf "$HARBOR_OFFLINE_TGZ_PATH" -C "$HARBOR_DIR" --strip-components=1

log "harbor.yml 생성"
sudo tee "$HARBOR_DIR/harbor.yml" >/dev/null <<EOF
hostname: ${SERVER_IP}

http:
  port: ${HARBOR_HTTP_PORT}

harbor_admin_password: ${HARBOR_ADMIN_PASSWORD}

database:
  password: ${HARBOR_ADMIN_PASSWORD}

data_volume: ${DATA_DIR}/harbor

log:
  level: info
  local:
    rotate_count: 50
    rotate_size: 200M
    location: /var/log/harbor
EOF

log "Harbor 설치 실행(최소 구성)"
cd "$HARBOR_DIR"
sudo ./install.sh

# Docker가 HTTP Harbor로 push할 수 있도록 insecure-registries 설정(필요 시)
DAEMON_JSON="/etc/docker/daemon.json"
BACKUP="$SCRIPT_DIR/.state/daemon.json.bak_$(date +%Y%m%d_%H%M%S)"
log "Docker insecure registry 설정 추가: $HARBOR_REGISTRY_HOSTPORT"
if [[ -f "$DAEMON_JSON" ]]; then
  sudo cp -a "$DAEMON_JSON" "$BACKUP"
  sudo jq --arg reg "$HARBOR_REGISTRY_HOSTPORT" '
    .["insecure-registries"] = ((.["insecure-registries"] // []) + [$reg] | unique)
  ' "$DAEMON_JSON" > "$SCRIPT_DIR/.state/daemon.json.tmp"
else
  cat > "$SCRIPT_DIR/.state/daemon.json.tmp" <<JSON
{
  "insecure-registries": ["$HARBOR_REGISTRY_HOSTPORT"]
}
JSON
fi
sudo install -m 0644 "$SCRIPT_DIR/.state/daemon.json.tmp" "$DAEMON_JSON"
rm -f "$SCRIPT_DIR/.state/daemon.json.tmp"
sudo systemctl restart docker

# systemd 등록(재부팅 시 자동 시작)
DOCKER_BIN="$(command -v docker)"
SERVICE_FILE="/etc/systemd/system/harbor.service"
log "systemd 서비스 등록: $SERVICE_FILE"
sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=Harbor Container Registry
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$HARBOR_DIR
ExecStart=$DOCKER_BIN compose up -d
ExecStop=$DOCKER_BIN compose down

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now harbor.service

log "Harbor 기동 확인(최대 5분 대기)"
deadline=$(( $(date +%s) + 300 ))
while [[ $(date +%s) -lt $deadline ]]; do
  if curl -fsS "$HARBOR_URL/api/v2.0/ping" | jq -e . >/dev/null 2>&1; then
    log "Harbor ping OK"
    break
  fi
  log "대기중..."
  sleep 5
done

log "Harbor URL: $HARBOR_URL"
log "admin 비밀번호 파일: scripts/gitops/.secrets/harbor_admin_password"
log "완료 (로그: $LOG_FILE)"
