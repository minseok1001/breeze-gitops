#!/usr/bin/env bash
set -euo pipefail

# 06) Harbor 프로젝트/로봇 계정 준비(파이프라인용)
# - Jenkins가 이미지를 push/pull 할 Harbor 프로젝트와 로봇 계정을 생성합니다.
# - ENABLE_HARBOR=true 인 경우에만 동작합니다. (배포 여부와 무관하게 “Harbor를 쓸 거면 true”)
#
# 산출물:
# - scripts/gitops/.secrets/harbor_robot.json  (username/password 포함, 커밋 금지)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
LOG_FILE="$SCRIPT_DIR/.logs/06_setup_harbor_project_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

load_config
validate_bool "ENABLE_HARBOR" "${ENABLE_HARBOR:-false}"

log "설정 파일: ${LOADED_CONFIG_FILE:-unknown}"
log "ENABLE_HARBOR=${ENABLE_HARBOR:-false}"

if ! is_true "${ENABLE_HARBOR:-false}"; then
  log "ENABLE_HARBOR=false → Harbor 설정을 건너뜁니다."
  exit 0
fi

require_cmd curl
require_cmd jq

if [[ -z "${SERVER_IP:-}" ]]; then
  SERVER_IP="$(detect_server_ip)"
fi
[[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP 감지 실패. config.env에 입력하세요."

admin_user="${HARBOR_ADMIN_USER:-admin}"
admin_pass="${HARBOR_ADMIN_PASSWORD:-}"
if [[ -z "${admin_pass:-}" && -f "$SCRIPT_DIR/.secrets/harbor_admin_password" ]]; then
  admin_pass="$(cat "$SCRIPT_DIR/.secrets/harbor_admin_password")"
fi
[[ -n "${admin_pass:-}" ]] || die "HARBOR_ADMIN_PASSWORD가 비어 있습니다. (scripts/gitops/config.env에 입력하거나 scripts/gitops/.secrets/harbor_admin_password를 준비하세요)"

base="$(harbor_api_base_url)"
log "Harbor API Base URL: $base"

log "Harbor ping 확인"
curl -fsS "${base}/api/v2.0/ping" | jq -e . >/dev/null

project="${HARBOR_PROJECT_NAME:-demo}"
robot_base_name="${HARBOR_ROBOT_NAME:-jenkins}"

robot_file="$SCRIPT_DIR/.secrets/harbor_robot.json"
if [[ -f "$robot_file" ]]; then
  existing_project="$(jq -r '.project // empty' "$robot_file" 2>/dev/null || true)"
  existing_user="$(jq -r '.username // empty' "$robot_file" 2>/dev/null || true)"
  if [[ -n "${existing_project:-}" && "$existing_project" == "$project" && -n "${existing_user:-}" ]]; then
    log "기존 로봇 계정 정보를 재사용합니다: scripts/gitops/.secrets/harbor_robot.json"
    log "완료 (로그: $LOG_FILE)"
    exit 0
  fi
  warn "기존 harbor_robot.json이 있지만(project 불일치 등) 재사용하지 않습니다: $robot_file"
fi

log "프로젝트 확인/생성: $project"
projects_json="$(curl -fsS -u "${admin_user}:${admin_pass}" "${base}/api/v2.0/projects?name=$(urlencode "$project")")"
project_id="$(echo "$projects_json" | jq -r '.[0].project_id // empty')"

if [[ -z "${project_id:-}" ]]; then
  create_body="$(jq -n --arg name "$project" '{project_name:$name, metadata:{public:"true"}}')"
  http_code="$(curl -sS -o /tmp/harbor_project_create.json -w "%{http_code}" \
    -u "${admin_user}:${admin_pass}" \
    -H "Content-Type: application/json" \
    -d "$create_body" \
    "${base}/api/v2.0/projects" || true)"
  if [[ "$http_code" != "201" && "$http_code" != "409" ]]; then
    warn "프로젝트 생성 실패(HTTP $http_code). 응답:"
    cat /tmp/harbor_project_create.json || true
    die "Harbor 프로젝트 생성 실패"
  fi
  projects_json="$(curl -fsS -u "${admin_user}:${admin_pass}" "${base}/api/v2.0/projects?name=$(urlencode "$project")")"
  project_id="$(echo "$projects_json" | jq -r '.[0].project_id // empty')"
fi

[[ -n "${project_id:-}" ]] || die "Harbor 프로젝트 ID를 확인하지 못했습니다: $project"
log "프로젝트 OK (id=$project_id)"

log "로봇 계정 생성: ${project}/${robot_base_name}"
# 로봇 계정 이름이 이미 존재할 수 있어, 충돌을 피하려고 suffix를 붙입니다.
robot_name="${robot_base_name}-$(date +%Y%m%d%H%M%S)"

robot_body="$(jq -n \
  --arg name "$robot_name" \
  --arg ns "$project" \
  '{
    name: $name,
    description: "jenkins push/pull",
    duration: -1,
    level: "project",
    permissions: [
      {
        kind: "project",
        namespace: $ns,
        access: [
          {resource: "repository", action: "push"},
          {resource: "repository", action: "pull"}
        ]
      }
    ]
  }')"

robot_resp_file="/tmp/harbor_robot_create.json"
robot_http="$(curl -sS -o "$robot_resp_file" -w "%{http_code}" \
  -u "${admin_user}:${admin_pass}" \
  -H "Content-Type: application/json" \
  -d "$robot_body" \
  "${base}/api/v2.0/robots" || true)"

if [[ "$robot_http" != "201" ]]; then
  warn "로봇 계정 생성 실패(HTTP $robot_http). 다른 엔드포인트로 재시도합니다."
  robot_http="$(curl -sS -o "$robot_resp_file" -w "%{http_code}" \
    -u "${admin_user}:${admin_pass}" \
    -H "Content-Type: application/json" \
    -d "$robot_body" \
    "${base}/api/v2.0/projects/${project}/robots" || true)"
fi

if [[ "$robot_http" != "201" ]]; then
  warn "로봇 계정 생성 최종 실패(HTTP $robot_http). 응답:"
  cat "$robot_resp_file" || true
  die "Harbor 로봇 계정 생성 실패"
fi

robot_username="$(jq -r '.name // empty' "$robot_resp_file")"
robot_password="$(jq -r '.secret // empty' "$robot_resp_file")"
[[ -n "${robot_username:-}" && -n "${robot_password:-}" ]] || die "로봇 계정 응답에서 username/secret을 찾지 못했습니다. 응답: $robot_resp_file"

robot_json="$(jq -n --arg project "$project" --arg u "$robot_username" --arg p "$robot_password" '{project:$project, username:$u, password:$p}')"
write_secret_file "$robot_file" "$robot_json"

log "로봇 계정 저장 완료: scripts/gitops/.secrets/harbor_robot.json"
log "완료 (로그: $LOG_FILE)"

