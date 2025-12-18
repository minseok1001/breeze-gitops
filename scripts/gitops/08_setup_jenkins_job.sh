#!/usr/bin/env bash
set -euo pipefail

# 08) Jenkins 잡/크리덴셜 자동 구성(파이프라인용)
# - Jenkins에 Harbor 로봇 계정 credential을 등록하고,
# - GitLab 리포(Jenkinsfile) 기반 Pipeline Job을 생성/갱신합니다.
#
# 필요:
# - ENABLE_JENKINS=true
# - JENKINS_USER / JENKINS_API_TOKEN
# - ENABLE_GITLAB=true + GITLAB_TOKEN(리포 정보 확인용)
# - 06_setup_harbor_project.sh 실행(로봇 계정 파일 생성)
# - 07_seed_demo_app_repo.sh 실행(프로젝트 상태 파일 생성)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs

LOG_FILE="$SCRIPT_DIR/.logs/08_setup_jenkins_job_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

load_config
validate_bool "ENABLE_JENKINS" "${ENABLE_JENKINS:-false}"

if [[ "${ENABLE_JENKINS:-false}" != "true" ]]; then
  log "ENABLE_JENKINS=false → Jenkins 잡 구성을 건너뜁니다."
  exit 0
fi

require_cmd curl
require_cmd jq
require_cmd base64

if [[ -z "${SERVER_IP:-}" ]]; then
  SERVER_IP="$(detect_server_ip)"
fi
[[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP 감지 실패. config.env에 입력하세요."

JENKINS_HTTP_PORT="${JENKINS_HTTP_PORT:-8081}"
jenkins_base="$(jenkins_api_base_url)"

jenkins_user="${JENKINS_USER:-}"
jenkins_token="${JENKINS_API_TOKEN:-}"
[[ -n "${jenkins_user:-}" ]] || die "JENKINS_USER가 비어 있습니다."
[[ -n "${jenkins_token:-}" ]] || die "JENKINS_API_TOKEN이 비어 있습니다. (Jenkins에서 API Token을 생성해 config.env에 입력하세요)"

log "Jenkins API Base URL: $jenkins_base"

robot_file="$SCRIPT_DIR/.secrets/harbor_robot.json"
[[ -f "$robot_file" ]] || die "Harbor 로봇 계정 파일이 없습니다: scripts/gitops/.secrets/harbor_robot.json (06_setup_harbor_project.sh를 먼저 실행)"

harbor_robot_user="$(jq -r '.username // empty' "$robot_file")"
harbor_robot_pass="$(jq -r '.password // empty' "$robot_file")"
harbor_project="$(jq -r '.project // empty' "$robot_file")"
[[ -n "${harbor_robot_user:-}" && -n "${harbor_robot_pass:-}" ]] || die "harbor_robot.json에서 username/password를 읽지 못했습니다."

gitlab_state="$SCRIPT_DIR/.state/gitlab_demo_app_project.json"
[[ -f "$gitlab_state" ]] || die "GitLab 프로젝트 상태 파일이 없습니다: scripts/gitops/.state/gitlab_demo_app_project.json (07_seed_demo_app_repo.sh를 먼저 실행)"

repo_url="$(jq -r '.http_url_to_repo // empty' "$gitlab_state")"
[[ -n "${repo_url:-}" ]] || die "gitlab_demo_app_project.json에서 repo URL을 읽지 못했습니다."

branch="${PIPELINE_DEFAULT_BRANCH:-main}"
job_name="${JENKINS_JOB_NAME:-demo-app}"

git_cred_id="${JENKINS_GITLAB_CRED_ID:-gitlab-pat}"
git_user="${GITLAB_CI_USER:-oauth2}"
git_pass="${GITLAB_CI_TOKEN:-${GITLAB_TOKEN:-}}"
[[ -n "${git_pass:-}" ]] || die "GITLAB_TOKEN이 비어 있어 Jenkins Git 크리덴셜을 만들 수 없습니다."

harbor_cred_id="${JENKINS_HARBOR_CRED_ID:-harbor-robot}"

# 잡 원격 트리거 토큰(웹훅용) - 재실행 시 재사용
job_token_file="$SCRIPT_DIR/.secrets/jenkins_job_token"
job_token="${JENKINS_JOB_TOKEN:-}"
if [[ -z "${job_token:-}" ]]; then
  if [[ -f "$job_token_file" ]]; then
    job_token="$(cat "$job_token_file")"
  else
    job_token="$(random_password)"
    write_secret_file "$job_token_file" "$job_token"
  fi
fi

log "Jenkins 잡 생성/갱신: $job_name (branch=$branch)"

# Crumb(있으면 사용, 없으면 CSRF가 꺼진 것으로 가정)
crumb_header=""
if crumb_json="$(curl -fsS -u "${jenkins_user}:${jenkins_token}" "${jenkins_base}/crumbIssuer/api/json" 2>/dev/null)"; then
  crumb_field="$(echo "$crumb_json" | jq -r '.crumbRequestField // empty')"
  crumb_value="$(echo "$crumb_json" | jq -r '.crumb // empty')"
  if [[ -n "${crumb_field:-}" && -n "${crumb_value:-}" && "$crumb_field" != "null" && "$crumb_value" != "null" ]]; then
    crumb_header="${crumb_field}: ${crumb_value}"
  fi
else
  warn "crumbIssuer를 읽지 못했습니다. (CSRF 보호가 꺼져있다면 무시 가능)"
fi

# Jenkins Script Console로 크리덴셜/잡을 생성합니다.
# - 보안상 Script Console을 막아둔 환경이면, Jenkins UI에서 수동으로 생성해야 합니다.
base64_oneline() { printf '%s' "$1" | base64 | tr -d '\n'; }

b64_job_name="$(base64_oneline "$job_name")"
b64_repo_url="$(base64_oneline "$repo_url")"
b64_branch="$(base64_oneline "$branch")"
b64_job_token="$(base64_oneline "$job_token")"

b64_git_cred_id="$(base64_oneline "$git_cred_id")"
b64_git_user="$(base64_oneline "$git_user")"
b64_git_pass="$(base64_oneline "$git_pass")"

b64_harbor_cred_id="$(base64_oneline "$harbor_cred_id")"
b64_harbor_user="$(base64_oneline "$harbor_robot_user")"
b64_harbor_pass="$(base64_oneline "$harbor_robot_pass")"

groovy_script="$(cat <<GROOVY
import jenkins.model.Jenkins
import hudson.plugins.git.*
import org.jenkinsci.plugins.workflow.job.WorkflowJob
import org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.*
import com.cloudbees.plugins.credentials.impl.*
import com.cloudbees.plugins.credentials.SystemCredentialsProvider

def decode = { String s -> new String(s.decodeBase64(), "UTF-8") }

def jobName    = decode("${b64_job_name}")
def repoUrl    = decode("${b64_repo_url}")
def branchName = decode("${b64_branch}")
def jobToken   = decode("${b64_job_token}")

def gitCredId  = decode("${b64_git_cred_id}")
def gitUser    = decode("${b64_git_user}")
def gitPass    = decode("${b64_git_pass}")

def harborCredId = decode("${b64_harbor_cred_id}")
def harborUser   = decode("${b64_harbor_user}")
def harborPass   = decode("${b64_harbor_pass}")

def j = Jenkins.get()

def provider = j.getExtensionList(SystemCredentialsProvider.class)[0]
def store = provider.getStore()

def upsertUserPassCred = { String id, String desc, String u, String p ->
  def existing = store.getCredentials(Domain.global()).find { it.id == id }
  def updated = new UsernamePasswordCredentialsImpl(CredentialsScope.GLOBAL, id, desc, u, p)
  if (existing == null) {
    store.addCredentials(Domain.global(), updated)
    return "created"
  }
  store.updateCredentials(Domain.global(), existing, updated)
  return "updated"
}

def gitStatus = upsertUserPassCred(gitCredId, "gitlab pat (oauth2)", gitUser, gitPass)
def harborStatus = upsertUserPassCred(harborCredId, "harbor robot (push/pull)", harborUser, harborPass)

def job = j.getItem(jobName)
if (job == null) {
  job = j.createProject(WorkflowJob.class, jobName)
}

def remote = new UserRemoteConfig(repoUrl, null, null, gitCredId)
def scm = new GitSCM([remote], [new BranchSpec("*/" + branchName)], false, [], null, null, [])
def defn = new CpsScmFlowDefinition(scm, "Jenkinsfile")
defn.setLightweight(true)
job.setDefinition(defn)

// “Trigger builds remotely” 토큰(웹훅용)
try {
  job.setAuthToken(jobToken)
} catch (Throwable t) {
  // Jenkins/플러그인 버전에 따라 메서드가 없을 수 있음
  println("WARN: setAuthToken 실패(수동 설정 필요): " + t.toString())
}

job.save()
j.save()

println("OK job=" + jobName + " gitCred=" + gitStatus + " harborCred=" + harborStatus)
GROOVY
)"

curl_args=( -fsS -u "${jenkins_user}:${jenkins_token}" )
if [[ -n "${crumb_header:-}" ]]; then
  curl_args+=( -H "$crumb_header" )
fi

log "Jenkins에 크리덴셜/잡을 적용합니다(출력에 비밀번호는 포함되지 않음)."
resp="$(curl "${curl_args[@]}" --data-urlencode "script=${groovy_script}" "${jenkins_base}/scriptText" 2>&1 || true)"

if echo "$resp" | grep -q "^OK "; then
  log "$resp"
else
  warn "Jenkins scriptText 응답:"
  echo "$resp"
  die "Jenkins 잡/크리덴셜 자동 구성이 실패했습니다. (Jenkins에서 Script Console 허용 여부/플러그인 설치 상태를 확인하세요)"
fi

jenkins_external="${JENKINS_EXTERNAL_URL:-}"
if [[ -z "${jenkins_external:-}" ]]; then
  jenkins_external="$jenkins_base"
fi
jenkins_external="$(normalize_url "$jenkins_external")"

log "웹훅 URL(다음 단계에서 GitLab에 등록): ${jenkins_external}/job/${job_name}/build?token=<stored>"
log "잡 토큰 파일: scripts/gitops/.secrets/jenkins_job_token"
log "완료 (로그: $LOG_FILE)"
