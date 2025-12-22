#!/usr/bin/env bash
set -euo pipefail

# 10) 검증(Verify) - EC2 DevOps 체인
# - GitLab / Harbor / Jenkins 기본 응답 확인
# - (선택) Jenkins 빌드 트리거 및 결과 확인
# - (선택) Harbor에 이미지가 생성됐는지 확인

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
load_config

LOG_FILE="$SCRIPT_DIR/.logs/10_verify_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

require_cmd curl

if [[ -z "${SERVER_IP:-}" ]]; then
  SERVER_IP="$(detect_server_ip)"
fi
[[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP 감지 실패. config.env에 입력하세요."

ENABLE_GITLAB="${ENABLE_GITLAB:-false}"
ENABLE_HARBOR="${ENABLE_HARBOR:-false}"
ENABLE_JENKINS="${ENABLE_JENKINS:-false}"

log "검증 시작"

if command -v docker >/dev/null 2>&1; then
  log "docker: $(docker --version)"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}' || true
else
  warn "docker가 없어 컨테이너 상태 출력은 건너뜁니다."
fi

gitlab_url="${GITLAB_EXTERNAL_URL:-}"
if [[ -z "${gitlab_url:-}" ]]; then
  gitlab_url="http://${SERVER_IP}:${GITLAB_HTTP_PORT:-8080}"
fi
gitlab_url="$(normalize_url "$gitlab_url")"

harbor_url="${HARBOR_EXTERNAL_URL:-}"
if [[ -z "${harbor_url:-}" ]]; then
  harbor_url="http://${SERVER_IP}:${HARBOR_HTTP_PORT:-8084}"
fi
harbor_url="$(normalize_url "$harbor_url")"

jenkins_url="${JENKINS_EXTERNAL_URL:-}"
if [[ -z "${jenkins_url:-}" ]]; then
  jenkins_url="http://${SERVER_IP}:${JENKINS_HTTP_PORT:-8081}"
fi
jenkins_url="$(normalize_url "$jenkins_url")"

if [[ "$ENABLE_GITLAB" == "true" ]]; then
  code="$(curl -s -o /dev/null -w "%{http_code}" "${gitlab_url}/users/sign_in" || true)"
  log "GitLab HTTP: $code (${gitlab_url})"
fi

if [[ "$ENABLE_HARBOR" == "true" ]]; then
  code="$(curl -s -o /dev/null -w "%{http_code}" "${harbor_url}/api/v2.0/ping" || true)"
  log "Harbor HTTP: $code (${harbor_url})"
fi

if [[ "$ENABLE_JENKINS" == "true" ]]; then
  code="$(curl -s -o /dev/null -w "%{http_code}" "${jenkins_url}/login" || true)"
  log "Jenkins HTTP: $code (${jenkins_url})"
fi

# 상태 파일/시크릿 체크(있으면 연동이 더 쉬움)
if [[ -f "$SCRIPT_DIR/.state/gitlab_demo_app_project.json" ]]; then
  log "GitLab 데모 프로젝트 상태 파일: ec2-setup/scripts/gitops/.state/gitlab_demo_app_project.json"
fi
if [[ -f "$SCRIPT_DIR/.secrets/harbor_robot.json" ]]; then
  log "Harbor 로봇 계정 파일: ec2-setup/scripts/gitops/.secrets/harbor_robot.json"
fi
if [[ -f "$SCRIPT_DIR/.secrets/jenkins_job_token" ]]; then
  log "Jenkins 잡 토큰 파일: ec2-setup/scripts/gitops/.secrets/jenkins_job_token"
fi

VERIFY_TRIGGER_BUILD="${VERIFY_TRIGGER_BUILD:-false}"
if [[ "$VERIFY_TRIGGER_BUILD" == "true" ]]; then
  require_cmd jq

  job_name="${JENKINS_JOB_NAME:-demo-app}"
  [[ -f "$SCRIPT_DIR/.secrets/jenkins_job_token" ]] || die "jenkins_job_token 파일이 없습니다. (08/09 스크립트를 먼저 실행)"
  job_token="$(cat "$SCRIPT_DIR/.secrets/jenkins_job_token")"

  # Jenkins 보안 설정(anonymous 권한/CSRF)에 따라 토큰 URL이 403이 날 수 있어,
  # 가능하면 Jenkins API Token으로 “정식 API 트리거”를 우선 사용합니다.
  if [[ -n "${JENKINS_USER:-}" && -n "${JENKINS_API_TOKEN:-}" ]]; then
    japi="${JENKINS_API_URL:-$jenkins_url}"
    japi="$(normalize_url "$japi")"
    log "빌드 트리거(Jenkins API): ${japi}/job/${job_name}/build"

    crumb_header=""
    if crumb_json="$(curl -fsS -u "${JENKINS_USER}:${JENKINS_API_TOKEN}" "${japi}/crumbIssuer/api/json" 2>/dev/null || true)"; then
      crumb_field="$(echo "$crumb_json" | jq -r '.crumbRequestField // empty' 2>/dev/null || true)"
      crumb_value="$(echo "$crumb_json" | jq -r '.crumb // empty' 2>/dev/null || true)"
      if [[ -n "${crumb_field:-}" && -n "${crumb_value:-}" && "$crumb_field" != "null" && "$crumb_value" != "null" ]]; then
        crumb_header="${crumb_field}: ${crumb_value}"
      fi
    fi

    curl_args=( -sS -o /dev/null -w "%{http_code}" -u "${JENKINS_USER}:${JENKINS_API_TOKEN}" -X POST )
    if [[ -n "${crumb_header:-}" ]]; then
      curl_args+=( -H "$crumb_header" )
    fi
    tcode="$(curl "${curl_args[@]}" "${japi}/job/${job_name}/build" || true)"
    log "트리거 HTTP: $tcode"
  else
    trigger_url="${jenkins_url}/job/${job_name}/build?token=${job_token}"
    log "빌드 트리거(토큰 URL): $trigger_url"
    tcode="$(curl -s -o /dev/null -w "%{http_code}" "$trigger_url" || true)"
    log "트리거 HTTP: $tcode"
  fi

  # 빌드 결과 확인은 Jenkins 인증이 필요할 수 있음
  if [[ -n "${JENKINS_USER:-}" && -n "${JENKINS_API_TOKEN:-}" ]]; then
    japi="${JENKINS_API_URL:-$jenkins_url}"
    japi="$(normalize_url "$japi")"
    log "Jenkins API로 빌드 상태 확인: $japi"

    # lastBuild가 생성될 때까지 잠깐 대기
    sleep 3
    deadline=$(( $(date +%s) + 600 ))
    while [[ $(date +%s) -lt $deadline ]]; do
      build_json="$(curl -fsS -u "${JENKINS_USER}:${JENKINS_API_TOKEN}" "${japi}/job/${job_name}/lastBuild/api/json" 2>/dev/null || true)"
      building="$(echo "$build_json" | jq -r '.building // empty' 2>/dev/null || true)"
      result="$(echo "$build_json" | jq -r '.result // empty' 2>/dev/null || true)"
      number="$(echo "$build_json" | jq -r '.number // empty' 2>/dev/null || true)"
      if [[ -n "${number:-}" ]]; then
        log "빌드 #${number} building=${building} result=${result}"
      fi
      # Jenkins/플러그인/보안 설정에 따라 building 값이 비어있게 내려오는 케이스가 있어,
      # result가 잡히면(=빌드가 끝났다고 판단) 결과를 우선 처리합니다.
      if [[ -n "${result:-}" && "$result" != "null" ]]; then
        if [[ "$result" != "SUCCESS" ]]; then
          warn "빌드가 SUCCESS가 아닙니다. Jenkins 콘솔 로그(마지막 120줄)를 출력합니다."
          curl -fsS -u "${JENKINS_USER}:${JENKINS_API_TOKEN}" "${japi}/job/${job_name}/lastBuild/consoleText" 2>/dev/null | tail -n 120 || true
          warn "자주 원인:"
          warn "  - Jenkins에 Git 플러그인/git 실행파일이 없어 checkout 실패"
          warn "  - Docker 소켓 권한 문제로 docker build/login/push 실패"
          warn "  - Harbor 로그인/프로젝트 권한(로봇 계정) 문제"
        fi
        break
      fi
      sleep 5
    done
  else
    warn "JENKINS_USER/JENKINS_API_TOKEN이 없어 빌드 결과 확인은 건너뜁니다."
  fi

  # Harbor에 이미지가 올라갔는지 확인(관리자 계정 필요할 수 있음)
  if [[ "$ENABLE_HARBOR" == "true" ]]; then
    admin_user="${HARBOR_ADMIN_USER:-admin}"
    admin_pass="${HARBOR_ADMIN_PASSWORD:-}"
    if [[ -z "${admin_pass:-}" && -f "$SCRIPT_DIR/.secrets/harbor_admin_password" ]]; then
      admin_pass="$(cat "$SCRIPT_DIR/.secrets/harbor_admin_password")"
    fi

    if [[ -n "${admin_pass:-}" ]]; then
      base="$(harbor_api_base_url)"
      project="${HARBOR_PROJECT_NAME:-demo}"
      app="${PIPELINE_APP_NAME:-demo-app}"
      # repositories API는 환경/권한에 따라 다를 수 있어, 존재 여부만 느슨하게 확인합니다.
      repo_list="$(curl -fsS -u "${admin_user}:${admin_pass}" "${base}/api/v2.0/projects/${project}/repositories" 2>/dev/null || true)"
      if echo "$repo_list" | grep -q "\"name\".*${project}/${app}\""; then
        log "Harbor repo 확인: ${project}/${app}"
      else
        warn "Harbor repo를 확인하지 못했습니다(아직 push 중이거나 API 권한/엔드포인트 차이일 수 있음)."
      fi
    else
      warn "HARBOR_ADMIN_PASSWORD가 없어 Harbor repo 확인은 건너뜁니다."
    fi
  fi
fi

log "검증 완료 (로그: $LOG_FILE)"
