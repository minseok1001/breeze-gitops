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

webhook_url="${jenkins_external}/job/${job_name}/build?token=${job_token}"
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
  --data-urlencode "enable_ssl_verification=true" >/dev/null

log "완료 (로그: $LOG_FILE)"
