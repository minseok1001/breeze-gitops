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
validate_bool "ENABLE_GITLAB" "${ENABLE_GITLAB:-false}"

log "설정 파일: ${LOADED_CONFIG_FILE:-unknown}"
log "ENABLE_GITLAB=${ENABLE_GITLAB:-false}"

if ! is_true "${ENABLE_GITLAB:-false}"; then
  log "ENABLE_GITLAB=false → GitLab 배포를 건너뜁니다. (ec2-setup/scripts/gitops/config.env에서 ENABLE_GITLAB=\"true\"로 변경)"
  exit 0
fi

require_cmd docker
require_cmd curl
require_cmd base64

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
GITLAB_SHM_SIZE="${GITLAB_SHM_SIZE:-1g}"

log "GitLab 배포 시작"
log "DATA_DIR=$DATA_DIR"

GITLAB_PERSIST_DATA="${GITLAB_PERSIST_DATA:-false}"
GITLAB_APPLY_OMNIBUS_CONFIG="${GITLAB_APPLY_OMNIBUS_CONFIG:-false}"
validate_bool "GITLAB_PERSIST_DATA" "$GITLAB_PERSIST_DATA"
validate_bool "GITLAB_APPLY_OMNIBUS_CONFIG" "$GITLAB_APPLY_OMNIBUS_CONFIG"

set_gitlab_root_password() {
  local pw="$1"
  local pw_b64
  pw_b64="$(printf '%s' "$pw" | base64 | tr -d '\n')"
  docker exec -e "PW_B64=${pw_b64}" gitlab gitlab-rails runner \
    "require 'base64'; pw=Base64.decode64(ENV['PW_B64'] || ''); u=User.find_by_username('root'); u.password=pw; u.password_confirmation=pw; u.save!"
}

pw_file="$SCRIPT_DIR/.secrets/gitlab_root_password"
if [[ -n "${GITLAB_ROOT_PASSWORD:-}" ]]; then
  log "GITLAB_ROOT_PASSWORD가 설정되어 있습니다."
elif [[ -f "$pw_file" ]]; then
  log "기존 GitLab root 비밀번호 파일이 있습니다: ec2-setup/scripts/gitops/.secrets/gitlab_root_password"
fi

if [[ "$GITLAB_PERSIST_DATA" == "true" ]]; then
  log "GitLab 볼륨 모드: ON (DATA_DIR에 데이터 유지)"
  sudo mkdir -p "$DATA_DIR/gitlab/config" "$DATA_DIR/gitlab/logs" "$DATA_DIR/gitlab/data"
  sudo chown -R "$TARGET_USER":"$TARGET_USER" "$DATA_DIR/gitlab" || true
else
  log "GitLab 볼륨 모드: OFF (최소 구성, 컨테이너 재생성 시 데이터 유실 가능)"
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
EOF

need_env="false"
if [[ -n "${GITLAB_ROOT_PASSWORD:-}" ]]; then
  need_env="true"
fi
if [[ "$GITLAB_APPLY_OMNIBUS_CONFIG" == "true" ]]; then
  need_env="true"
fi

if [[ "$need_env" == "true" ]]; then
  {
    echo "    environment:"
    if [[ -n "${GITLAB_ROOT_PASSWORD:-}" ]]; then
      echo "      GITLAB_ROOT_PASSWORD: \"${GITLAB_ROOT_PASSWORD}\""
    fi
    if [[ "$GITLAB_APPLY_OMNIBUS_CONFIG" == "true" ]]; then
      external_url="${GITLAB_EXTERNAL_URL:-}"
      if [[ -z "$external_url" ]]; then
        external_url="http://${SERVER_IP}:${GITLAB_HTTP_PORT}"
      fi
      external_url="$(normalize_url "$external_url")"
      cat <<EOF
      GITLAB_OMNIBUS_CONFIG: |
        external_url '${external_url}'
        gitlab_rails['gitlab_shell_ssh_port'] = ${GITLAB_SSH_PORT}
EOF
      # ALB가 HTTPS를 종료(terminate)하고 GitLab은 HTTP(80)로 받는 구성을 안전하게 지원
      # - external_url을 https로 두되, 내부 nginx는 80/http로 유지
      if [[ "$external_url" == https://* ]]; then
        cat <<'EOF'
        nginx['listen_port'] = 80
        nginx['listen_https'] = false
        nginx['proxy_set_headers'] = {
          'X-Forwarded-Proto' => 'https',
          'X-Forwarded-Ssl' => 'on'
        }
        letsencrypt['enable'] = false
EOF
      fi
    fi
  } >> "$COMPOSE_FILE"
fi

cat >> "$COMPOSE_FILE" <<EOF
    ports:
      - "${GITLAB_HTTP_PORT}:80"
      - "${GITLAB_SSH_PORT}:22"
EOF

if [[ "$GITLAB_PERSIST_DATA" == "true" ]]; then
  cat >> "$COMPOSE_FILE" <<EOF
    volumes:
      - "${DATA_DIR}/gitlab/config:/etc/gitlab"
      - "${DATA_DIR}/gitlab/logs:/var/log/gitlab"
      - "${DATA_DIR}/gitlab/data:/var/opt/gitlab"
EOF
fi

log "docker compose up -d"
"${COMPOSE[@]}" -p gitops-gitlab -f "$COMPOSE_FILE" up -d

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
  warn "  docker inspect -f '{{json .State.Health}}' gitlab"
  warn "  docker exec -it gitlab gitlab-ctl status"
  warn "  docker exec -it gitlab gitlab-ctl tail puma --lines 200"
  warn "  docker exec -it gitlab gitlab-ctl tail postgresql --lines 200"
  warn "  sudo dmesg -T | tail -n 200 | grep -i oom || true"
  warn "최근 로그(200줄)를 출력합니다:"
  docker logs --tail 200 gitlab || true
  die "GitLab 기동 실패 또는 매우 지연됨"
fi

if [[ -n "${GITLAB_ROOT_PASSWORD:-}" ]]; then
  log "GITLAB_ROOT_PASSWORD가 설정되어 있어 root 비밀번호를 동기화합니다."
  if set_gitlab_root_password "$GITLAB_ROOT_PASSWORD" >/dev/null 2>&1; then
    log "root 비밀번호를 동기화했습니다."
  else
    warn "root 비밀번호 동기화에 실패했습니다. (현재 비밀번호가 다를 수 있습니다)"
  fi
  write_secret_file "$pw_file" "$GITLAB_ROOT_PASSWORD"
  log "GitLab root 비밀번호를 저장했습니다: ec2-setup/scripts/gitops/.secrets/gitlab_root_password"
fi

if [[ ! -s "$pw_file" ]]; then
  log "GitLab 초기 root 비밀번호 추출 시도(출력 금지)"
  extracted_pw="$(docker exec gitlab bash -lc "awk -F': ' '/Password:/{print \$2; exit}' /etc/gitlab/initial_root_password 2>/dev/null || true" 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "${extracted_pw:-}" ]]; then
    write_secret_file "$pw_file" "$extracted_pw"
    log "GitLab root 비밀번호를 저장했습니다: ec2-setup/scripts/gitops/.secrets/gitlab_root_password"
  else
    warn "root 비밀번호를 자동으로 추출하지 못했습니다."
    warn "GITLAB_ROOT_PASSWORD가 비어 있어 root 비밀번호 재설정을 시도합니다."
    if ! command -v openssl >/dev/null 2>&1; then
      warn "openssl이 없어 root 비밀번호 재설정을 진행할 수 없습니다."
      warn "GITLAB_ROOT_PASSWORD를 config.env에 설정한 뒤 다시 실행하세요."
    else
      reset_pw="$(random_password)"
      if set_gitlab_root_password "$reset_pw" >/dev/null 2>&1; then
        write_secret_file "$pw_file" "$reset_pw"
        log "root 비밀번호를 재설정하고 저장했습니다: ec2-setup/scripts/gitops/.secrets/gitlab_root_password"
      else
        warn "root 비밀번호 재설정에 실패했습니다."
        warn "필요 시 다음으로 확인하세요:"
        warn "  docker exec -it gitlab bash -lc 'cat /etc/gitlab/initial_root_password'"
      fi
    fi
  fi
fi

# 능동적 자동화: GitLab PAT 자동 생성
if [[ -z "${GITLAB_TOKEN:-}" && -s "$pw_file" ]]; then
  log "GitLab PAT 자동 생성 시도"
  root_pw="$(cat "$pw_file")"
  gitlab_api_url="${GITLAB_API_URL:-http://127.0.0.1:${GITLAB_HTTP_PORT}}"
  token_response="$(curl -s -X POST "${gitlab_api_url}/api/v4/users/1/personal_access_tokens" \
    -H "Content-Type: application/json" \
    -u "root:${root_pw}" \
    -d '{"name":"bootstrap","scopes":["api"],"expires_at":"'"$(date -d '+1 year' +%Y-%m-%d)"'"}' || true)"
  generated_token="$(echo "$token_response" | jq -r '.token // empty' 2>/dev/null || true)"
  if [[ -n "${generated_token:-}" ]]; then
    echo "GITLAB_TOKEN=\"$generated_token\"" >> "$SCRIPT_DIR/config.env"
    log "GitLab PAT를 생성하여 config.env에 추가했습니다."
  else
    warn "GitLab PAT 자동 생성 실패. 수동 생성 필요."
  fi
fi

log "GitLab URL: http://${SERVER_IP}:${GITLAB_HTTP_PORT}"
if [[ -s "$pw_file" ]]; then
  log "root 비밀번호 파일: ec2-setup/scripts/gitops/.secrets/gitlab_root_password"
fi
log "완료 (로그: $LOG_FILE)"
