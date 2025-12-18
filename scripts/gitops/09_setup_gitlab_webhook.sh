#!/usr/bin/env bash
set -euo pipefail

# 09) GitLab Webhook → Jenkins 트리거 연결
# - GitLab push 이벤트가 발생하면 Jenkins Job을 자동으로 실행하도록 Webhook을 등록합니다.
#
# 필요:
# - ENABLE_GITLAB=true + GITLAB_TOKEN
# - ENABLE_JENKINS=true
# - 07_seed_demo_app_repo.sh 실행(프로젝트 상태 파일)
# - 08_setup_jenkins_job.sh 실행(잡 토큰 파일)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs

LOG_FILE="$SCRIPT_DIR/.logs/09_setup_gitlab_webhook_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

load_config
validate_bool "ENABLE_GITLAB" "${ENABLE_GITLAB:-false}"
validate_bool "ENABLE_JENKINS" "${ENABLE_JENKINS:-false}"

if [[ "${ENABLE_GITLAB:-false}" != "true" ]]; then
  log "ENABLE_GITLAB=false → Webhook 등록을 건너뜁니다."
  exit 0
fi
if [[ "${ENABLE_JENKINS:-false}" != "true" ]]; then
  log "ENABLE_JENKINS=false → Webhook 등록을 건너뜁니다."
  exit 0
fi

[[ -n "${GITLAB_TOKEN:-}" ]] || die "GITLAB_TOKEN이 비어 있습니다."

require_cmd curl
require_cmd jq

if [[ -z "${SERVER_IP:-}" ]]; then
  SERVER_IP="$(detect_server_ip)"
fi
[[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP 감지 실패. config.env에 입력하세요."

gitlab_state="$SCRIPT_DIR/.state/gitlab_demo_app_project.json"
[[ -f "$gitlab_state" ]] || die "GitLab 프로젝트 상태 파일이 없습니다: scripts/gitops/.state/gitlab_demo_app_project.json (07_seed_demo_app_repo.sh를 먼저 실행)"

project_id="$(jq -r '.id // empty' "$gitlab_state")"
[[ -n "${project_id:-}" && "$project_id" != "null" ]] || die "프로젝트 ID를 읽지 못했습니다: $gitlab_state"

job_name="${JENKINS_JOB_NAME:-demo-app}"
branch="${PIPELINE_DEFAULT_BRANCH:-main}"

job_token_file="$SCRIPT_DIR/.secrets/jenkins_job_token"
[[ -f "$job_token_file" ]] || die "Jenkins 잡 토큰 파일이 없습니다: scripts/gitops/.secrets/jenkins_job_token (08_setup_jenkins_job.sh를 먼저 실행)"
job_token="$(cat "$job_token_file")"
[[ -n "${job_token:-}" ]] || die "jenkins_job_token 파일이 비어 있습니다."

jenkins_external="${JENKINS_EXTERNAL_URL:-}"
if [[ -z "${jenkins_external:-}" ]]; then
  # 외부 URL이 없으면 내부 URL로라도 연결(단, GitLab이 같은 네트워크에서 접근 가능해야 함)
  JENKINS_HTTP_PORT="${JENKINS_HTTP_PORT:-8081}"
  jenkins_external="$(jenkins_api_base_url)"
fi
jenkins_external="$(normalize_url "$jenkins_external")"

# Jenkins는 보안 설정(anonymous 권한/CSRF)에 따라 token URL이 403을 반환할 수 있습니다.
# - GitLab은 2xx가 아니면 Webhook을 실패로 기록하므로, 필요하면 Basic Auth를 URL에 포함시켜야 합니다.
#   (PoC 용도에서만 권장)
#
# 옵션:
# - JENKINS_WEBHOOK_USE_BUILD_BY_TOKEN=true  : /buildByToken/build 사용(플러그인 필요)
# - JENKINS_WEBHOOK_USE_BASIC_AUTH=true     : https://user:apitoken@... 형태로 인증 포함
#
# 기본은 /job/<job>/build?token=... 입니다.
use_build_by_token="${JENKINS_WEBHOOK_USE_BUILD_BY_TOKEN:-false}"
use_basic_auth="${JENKINS_WEBHOOK_USE_BASIC_AUTH:-false}"

validate_bool "JENKINS_WEBHOOK_USE_BUILD_BY_TOKEN" "$use_build_by_token"
validate_bool "JENKINS_WEBHOOK_USE_BASIC_AUTH" "$use_basic_auth"

if [[ "$use_build_by_token" == "true" ]]; then
  webhook_url="${jenkins_external}/buildByToken/build?job=$(urlencode "$job_name")&token=$(urlencode "$job_token")"
else
  webhook_url="${jenkins_external}/job/${job_name}/build?token=${job_token}"
fi

if [[ "$use_basic_auth" == "true" ]]; then
  auth_user="${JENKINS_WEBHOOK_USER:-${JENKINS_USER:-}}"
  auth_pass="${JENKINS_WEBHOOK_PASS:-${JENKINS_API_TOKEN:-}}"
  [[ -n "${auth_user:-}" ]] || die "JENKINS_WEBHOOK_USE_BASIC_AUTH=true 인데 JENKINS_WEBHOOK_USER/JENKINS_USER가 비어 있습니다."
  [[ -n "${auth_pass:-}" ]] || die "JENKINS_WEBHOOK_USE_BASIC_AUTH=true 인데 JENKINS_WEBHOOK_PASS/JENKINS_API_TOKEN이 비어 있습니다."

  # URL에 user:pass를 포함할 때는 특수문자 때문에 component encoding이 필요합니다.
  scheme=""
  rest=""
  if [[ "$jenkins_external" == https://* ]]; then
    scheme="https"
    rest="${jenkins_external#https://}"
  elif [[ "$jenkins_external" == http://* ]]; then
    scheme="http"
    rest="${jenkins_external#http://}"
  else
    die "JENKINS_EXTERNAL_URL 형식이 올바르지 않습니다: $jenkins_external"
  fi

  enc_user="$(urlencode "$auth_user")"
  enc_pass="$(urlencode "$auth_pass")"
  authed_base="${scheme}://${enc_user}:${enc_pass}@${rest}"

  if [[ "$use_build_by_token" == "true" ]]; then
    webhook_url="${authed_base}/buildByToken/build?job=$(urlencode "$job_name")&token=$(urlencode "$job_token")"
  else
    webhook_url="${authed_base}/job/${job_name}/build?token=${job_token}"
  fi
fi

log "Webhook URL: $webhook_url"

log "기존 Webhook 확인"
hooks="$(gitlab_api GET "/projects/${project_id}/hooks" | jq -r '.[].url')"
if echo "$hooks" | grep -Fxq "$webhook_url"; then
  log "이미 동일한 Webhook이 존재합니다. 스킵합니다."
  exit 0
fi

log "Webhook 생성(push events: branch=$branch)"
gitlab_api POST "/projects/${project_id}/hooks" \
  --data-urlencode "url=${webhook_url}" \
  --data-urlencode "push_events=true" \
  --data-urlencode "push_events_branch_filter=${branch}" \
  --data-urlencode "enable_ssl_verification=${GITLAB_WEBHOOK_ENABLE_SSL_VERIFICATION:-true}" >/dev/null

log "완료 (로그: $LOG_FILE)"
