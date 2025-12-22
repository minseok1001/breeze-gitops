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
  log "ENABLE_HARBOR=false → Harbor 배포를 건너뜁니다. (ec2-setup/scripts/gitops/config.env에서 ENABLE_HARBOR=\"true\"로 변경)"
  exit 0
fi

require_cmd curl
require_cmd jq

if [[ -z "${SERVER_IP:-}" ]]; then
  SERVER_IP="$(detect_server_ip)"
fi
[[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP 감지 실패. config.env에 입력하세요."

DATA_DIR="${DATA_DIR:-/srv/gitops-lab}"
HARBOR_HTTP_PORT="${HARBOR_HTTP_PORT:-8084}"
HARBOR_URL="${HARBOR_API_URL:-http://${SERVER_IP}:${HARBOR_HTTP_PORT}}"
HARBOR_URL="$(normalize_url "$HARBOR_URL")"
HARBOR_REGISTRY_HOSTPORT="${HARBOR_REGISTRY_HOSTPORT:-${SERVER_IP}:${HARBOR_HTTP_PORT}}"
HARBOR_PROTOCOL="${HARBOR_PROTOCOL:-http}"
case "$HARBOR_PROTOCOL" in
  http|https) ;;
  *) die "HARBOR_PROTOCOL 값이 올바르지 않습니다: '${HARBOR_PROTOCOL}' (http 또는 https만 허용)" ;;
esac

log "Harbor URL: $HARBOR_URL"
log "Harbor Registry(host:port): $HARBOR_REGISTRY_HOSTPORT"
log "Harbor protocol(설치 설정): $HARBOR_PROTOCOL"

log "기존 Harbor 확인(ping)"
existing_ping="$(curl -fsS "$HARBOR_URL/api/v2.0/ping" 2>/dev/null | tr -d '\r\n' || true)"
if [[ "${existing_ping,,}" == "pong" || "${existing_ping,,}" == "\"pong\"" ]]; then
  log "Harbor가 이미 동작 중입니다. 설치를 스킵합니다."
  exit 0
fi

require_cmd docker
require_cmd tar
require_cmd sudo
require_cmd awk

HARBOR_OFFLINE_TGZ_URL="${HARBOR_OFFLINE_TGZ_URL:-https://github.com/goharbor/harbor/releases/download/v2.14.1/harbor-offline-installer-v2.14.1.tgz}"
HARBOR_OFFLINE_TGZ_PATH="${HARBOR_OFFLINE_TGZ_PATH:-}"

if [[ -z "${HARBOR_OFFLINE_TGZ_PATH:-}" ]]; then
  # 1) 우선 .state에 이미 내려받은(또는 수동 반입한) tgz가 있는지 먼저 확인
  log ".state 디렉토리에서 Harbor 오프라인 installer(tgz) 존재 여부 확인"
  shopt -s nullglob
  candidates=("$SCRIPT_DIR/.state/harbor-offline-installer-"*.tgz)
  shopt -u nullglob
  if (( ${#candidates[@]} > 0 )); then
    # 여러 개면 가장 최신(수정시간 기준)을 사용
    HARBOR_OFFLINE_TGZ_PATH="$(ls -t "${candidates[@]}" 2>/dev/null | head -n 1)"
    log "기존 tgz를 발견하여 재사용합니다: $HARBOR_OFFLINE_TGZ_PATH"
  else
    # 2) 없으면 URL 파일명으로 기본 경로를 잡고, 필요 시 다운로드
    file_name="$(basename "$HARBOR_OFFLINE_TGZ_URL")"
    HARBOR_OFFLINE_TGZ_PATH="$SCRIPT_DIR/.state/$file_name"
    log "HARBOR_OFFLINE_TGZ_PATH가 비어 있어 기본 경로를 사용합니다: $HARBOR_OFFLINE_TGZ_PATH"
  fi
fi

if [[ ! -f "$HARBOR_OFFLINE_TGZ_PATH" ]]; then
  log "Harbor 오프라인 installer 다운로드"
  log "URL: $HARBOR_OFFLINE_TGZ_URL"
  log "DEST: $HARBOR_OFFLINE_TGZ_PATH"
  if ! curl -fL --retry 3 --retry-delay 2 -o "$HARBOR_OFFLINE_TGZ_PATH" "$HARBOR_OFFLINE_TGZ_URL"; then
    warn "다운로드에 실패했습니다. (폐쇄망/방화벽/프록시 이슈일 수 있음)"
    warn "대안:"
    warn "  1) 다른 곳에서 tgz를 다운로드하여 서버로 복사"
    warn "  2) ec2-setup/scripts/gitops/config.env에 HARBOR_OFFLINE_TGZ_PATH로 로컬 파일 경로 지정"
    die "Harbor 오프라인 installer 다운로드 실패"
  fi
fi

[[ -f "$HARBOR_OFFLINE_TGZ_PATH" ]] || die "Harbor tgz 파일이 없습니다: $HARBOR_OFFLINE_TGZ_PATH"

# 관리자 비밀번호 준비(출력 금지)
if [[ -z "${HARBOR_ADMIN_PASSWORD:-}" ]]; then
  HARBOR_ADMIN_PASSWORD="$(random_password)"
  write_secret_file "$SCRIPT_DIR/.secrets/harbor_admin_password" "$HARBOR_ADMIN_PASSWORD"
  log "Harbor admin 비밀번호를 생성하여 저장했습니다: ec2-setup/scripts/gitops/.secrets/harbor_admin_password"
else
  write_secret_file "$SCRIPT_DIR/.secrets/harbor_admin_password" "$HARBOR_ADMIN_PASSWORD"
  log "Harbor admin 비밀번호를 저장했습니다: ec2-setup/scripts/gitops/.secrets/harbor_admin_password"
fi

log "데이터 디렉토리 준비: $DATA_DIR/harbor"
sudo mkdir -p "$DATA_DIR/harbor"

HARBOR_DIR="/opt/harbor"
log "Harbor 설치 디렉토리 준비: $HARBOR_DIR"

# 이전 실패/재설치 상황에서 컨테이너가 남아있으면 install.sh가 꼬일 수 있어,
# 가능한 범위에서 먼저 정리합니다.
if [[ -d "$HARBOR_DIR" ]]; then
  log "기존 Harbor 설치 흔적 정리 시도"
  if docker compose version >/dev/null 2>&1 && [[ -f "$HARBOR_DIR/docker-compose.yml" ]]; then
    sudo docker compose -f "$HARBOR_DIR/docker-compose.yml" down || true
  elif command -v docker-compose >/dev/null 2>&1 && [[ -f "$HARBOR_DIR/docker-compose.yml" ]]; then
    sudo docker-compose -f "$HARBOR_DIR/docker-compose.yml" down || true
  fi
  # harbor 관련 컨테이너가 남아있으면 강제 제거(최소 범위: 이름에 harbor 포함)
  if docker ps -a --format '{{.Names}}' | grep -qi '^harbor'; then
    sudo docker rm -f $(docker ps -a --format '{{.Names}}' | grep -i '^harbor' | tr '\n' ' ') || true
  fi
fi

sudo rm -rf "$HARBOR_DIR"
sudo mkdir -p "$HARBOR_DIR"
sudo tar xzf "$HARBOR_OFFLINE_TGZ_PATH" -C "$HARBOR_DIR" --strip-components=1

harbor_hostname="${SERVER_IP}"
if [[ -n "${HARBOR_EXTERNAL_URL:-}" ]]; then
  harbor_hostname="${HARBOR_EXTERNAL_URL#http://}"
  harbor_hostname="${harbor_hostname#https://}"
  harbor_hostname="${harbor_hostname%%/*}"
  harbor_hostname="${harbor_hostname%%:*}"
elif [[ -n "${HARBOR_REGISTRY_HOSTPORT:-}" ]]; then
  harbor_hostname="$(printf '%s' "$HARBOR_REGISTRY_HOSTPORT" | awk -F: '{print $1}')"
fi
[[ -n "${harbor_hostname:-}" ]] || harbor_hostname="${SERVER_IP}"

log "harbor.yml 생성(최소 구성)"
# Harbor v2.14.x에서는 harbor.yml이 너무 최소이면 prepare 단계에서 KeyError가 날 수 있어,
# 기본적으로 아래 필드들은 반드시 포함합니다.
# - harbor_admin_password / database.password / data_volume
# - jobservice.max_job_workers / jobservice.job_loggers 등
#
# https 모드는 인증서(ssl_cert/ssl_cert_key)가 필수라서, 여기서는 명시적으로 값이 없으면 중단합니다.
if [[ "$HARBOR_PROTOCOL" == "https" ]]; then
  HARBOR_HTTPS_PORT="${HARBOR_HTTPS_PORT:-443}"
  HARBOR_SSL_CERT_PATH="${HARBOR_SSL_CERT_PATH:-}"
  HARBOR_SSL_KEY_PATH="${HARBOR_SSL_KEY_PATH:-}"
  [[ -n "${HARBOR_SSL_CERT_PATH:-}" ]] || die "HARBOR_PROTOCOL=https 인데 HARBOR_SSL_CERT_PATH가 비어 있습니다. (ALB에서 TLS를 종료한다면 HARBOR_PROTOCOL=http 권장)"
  [[ -n "${HARBOR_SSL_KEY_PATH:-}" ]] || die "HARBOR_PROTOCOL=https 인데 HARBOR_SSL_KEY_PATH가 비어 있습니다. (ALB에서 TLS를 종료한다면 HARBOR_PROTOCOL=http 권장)"
  sudo tee "$HARBOR_DIR/harbor.yml" >/dev/null <<EOF
hostname: ${harbor_hostname}

http:
  port: ${HARBOR_HTTP_PORT}

https:
  port: ${HARBOR_HTTPS_PORT}
  certificate: ${HARBOR_SSL_CERT_PATH}
  private_key: ${HARBOR_SSL_KEY_PATH}

harbor_admin_password: ${HARBOR_ADMIN_PASSWORD}

database:
  password: ${HARBOR_ADMIN_PASSWORD}

data_volume: ${DATA_DIR}/harbor

trivy:
  ignore_unfixed: false
  skip_update: false
  offline_scan: false
  security_check: vuln
  insecure: false
  timeout: 5m0s

jobservice:
  max_job_workers: 10
  max_job_duration_hours: 24
  job_loggers:
    - STD_OUTPUT
    - FILE
  logger_sweeper_duration: 1 #days

notification:
  webhook_job_max_retry: 3
  webhook_job_http_client_timeout: 3 #seconds

log:
  level: info
  local:
    rotate_count: 50
    rotate_size: 200M
    location: /var/log/harbor

_version: 2.14.0
EOF
else
  sudo tee "$HARBOR_DIR/harbor.yml" >/dev/null <<EOF
hostname: ${harbor_hostname}

http:
  port: ${HARBOR_HTTP_PORT}

harbor_admin_password: ${HARBOR_ADMIN_PASSWORD}

database:
  password: ${HARBOR_ADMIN_PASSWORD}

data_volume: ${DATA_DIR}/harbor

trivy:
  ignore_unfixed: false
  skip_update: false
  offline_scan: false
  security_check: vuln
  insecure: false
  timeout: 5m0s

jobservice:
  max_job_workers: 10
  max_job_duration_hours: 24
  job_loggers:
    - STD_OUTPUT
    - FILE
  logger_sweeper_duration: 1 #days

notification:
  webhook_job_max_retry: 3
  webhook_job_http_client_timeout: 3 #seconds

log:
  level: info
  local:
    rotate_count: 50
    rotate_size: 200M
    location: /var/log/harbor

_version: 2.14.0
EOF
fi

log "Harbor 설치 실행(최소 구성)"
cd "$HARBOR_DIR"
sudo ./install.sh

# Docker가 HTTP Harbor로 push할 수 있도록 insecure-registries 설정(필요 시)
DAEMON_JSON="/etc/docker/daemon.json"
BACKUP="$SCRIPT_DIR/.state/daemon.json.bak_$(date +%Y%m%d_%H%M%S)"

should_insecure="false"
if [[ -n "${HARBOR_EXTERNAL_URL:-}" ]]; then
  if [[ "$HARBOR_EXTERNAL_URL" == http://* ]]; then
    should_insecure="true"
  fi
else
  # host:port 형태이고, 포트가 443이 아니면 HTTP일 가능성이 높습니다.
  if [[ "${HARBOR_REGISTRY_HOSTPORT:-}" == *:* ]]; then
    reg_port="${HARBOR_REGISTRY_HOSTPORT##*:}"
    if [[ "$reg_port" != "443" ]]; then
      should_insecure="true"
    fi
  fi
fi

if [[ "$should_insecure" == "true" ]]; then
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
else
  log "HTTPS(또는 ALB) 구성이면 insecure registry 설정은 보통 불필요하여 건너뜁니다."
fi

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
  ping="$(curl -fsS "$HARBOR_URL/api/v2.0/ping" 2>/dev/null | tr -d '\r\n' || true)"
  if [[ "${ping,,}" == "pong" || "${ping,,}" == "\"pong\"" ]]; then
    log "Harbor ping OK"
    break
  fi
  log "대기중..."
  sleep 5
done

log "Harbor URL: $HARBOR_URL"
log "admin 비밀번호 파일: ec2-setup/scripts/gitops/.secrets/harbor_admin_password"
log "완료 (로그: $LOG_FILE)"
