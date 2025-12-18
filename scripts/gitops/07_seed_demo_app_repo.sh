#!/usr/bin/env bash
set -euo pipefail

# 07) 데모 앱 Git 리포 생성/시드(파이프라인용)
# - GitLab에 데모 앱 리포를 만들고(Dockerfile/Jenkinsfile 포함) 커밋합니다.
# - 이후 Jenkins가 이 리포를 빌드하여 Harbor로 push 하는 흐름을 만듭니다.
#
# 필요:
# - ENABLE_GITLAB=true
# - GITLAB_TOKEN (api scope)
# - Harbor 레지스트리 정보(HARBOR_REGISTRY_HOSTPORT + HARBOR_PROJECT_NAME)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs

LOG_FILE="$SCRIPT_DIR/.logs/07_seed_demo_app_repo_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

load_config
validate_bool "ENABLE_GITLAB" "${ENABLE_GITLAB:-false}"

if [[ "${ENABLE_GITLAB:-false}" != "true" ]]; then
  log "ENABLE_GITLAB=false → 데모 리포 생성을 건너뜁니다."
  exit 0
fi

require_cmd curl
require_cmd jq

if [[ -z "${SERVER_IP:-}" ]]; then
  SERVER_IP="$(detect_server_ip)"
fi
[[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP 감지 실패. config.env에 입력하세요."

if [[ -z "${GITLAB_TOKEN:-}" ]]; then
  # 토큰 생성 페이지(힌트) 출력용
  hint_base="${GITLAB_EXTERNAL_URL:-}"
  if [[ -z "${hint_base:-}" ]]; then
    hint_base="${GITLAB_API_URL:-}"
  fi
  if [[ -z "${hint_base:-}" ]]; then
    hint_base="http://${SERVER_IP}:${GITLAB_HTTP_PORT:-8080}"
  fi
  hint_base="$(normalize_url "$hint_base")"
  die "GITLAB_TOKEN이 비어 있습니다. GitLab Personal Access Token(api scope)을 생성해 scripts/gitops/config.env에 입력하세요.\n예) ${hint_base}/-/user_settings/personal_access_tokens"
fi

harbor_registry="${HARBOR_REGISTRY_HOSTPORT:-}"
if [[ -z "${harbor_registry:-}" && -n "${HARBOR_EXTERNAL_URL:-}" ]]; then
  harbor_registry="${HARBOR_EXTERNAL_URL#http://}"
  harbor_registry="${harbor_registry#https://}"
  harbor_registry="${harbor_registry%%/*}"
fi
harbor_project="${HARBOR_PROJECT_NAME:-demo}"

[[ -n "${harbor_registry:-}" ]] || die "HARBOR_REGISTRY_HOSTPORT가 비어 있습니다. (예: gitops-harbor.breezelab.io)"
[[ -n "${harbor_project:-}" ]] || die "HARBOR_PROJECT_NAME가 비어 있습니다."

log "Harbor Registry: $harbor_registry"
log "Harbor Project: $harbor_project"

log "GitLab API 연결 확인"
gitlab_api GET "/user" | jq -r '"user: \(.username) (id=\(.id))"'

user_json="$(gitlab_api GET "/user")"
user_name="$(echo "$user_json" | jq -r '.username')"
[[ -n "$user_name" && "$user_name" != "null" ]] || die "GitLab 사용자 정보를 가져오지 못했습니다."

namespace_id=""
namespace_path="$user_name"

if [[ -n "${GITLAB_GROUP_PATH:-}" ]]; then
  log "그룹 확인/생성: $GITLAB_GROUP_PATH"
  group_path_enc="$(urlencode "$GITLAB_GROUP_PATH")"
  if group_json="$(gitlab_api GET "/groups/$group_path_enc" 2>/dev/null)"; then
    namespace_id="$(echo "$group_json" | jq -r '.id')"
    namespace_path="$(echo "$group_json" | jq -r '.full_path')"
  else
    group_create_resp="$(gitlab_api POST "/groups" \
      --data-urlencode "name=$GITLAB_GROUP_PATH" \
      --data-urlencode "path=$GITLAB_GROUP_PATH")"
    namespace_id="$(echo "$group_create_resp" | jq -r '.id')"
    namespace_path="$(echo "$group_create_resp" | jq -r '.full_path')"
  fi
fi

project_name="${PIPELINE_REPO_NAME:-demo-app}"
project_path="${PIPELINE_REPO_PATH:-demo-app}"
default_branch="${PIPELINE_DEFAULT_BRANCH:-main}"

project_full_path="${namespace_path}/${project_path}"
project_path_enc="$(urlencode "$project_full_path")"

log "프로젝트 확인/생성: $project_full_path"
if project_json="$(gitlab_api GET "/projects/$project_path_enc" 2>/dev/null)"; then
  project_id="$(echo "$project_json" | jq -r '.id')"
else
  if [[ -n "$namespace_id" ]]; then
    project_json="$(gitlab_api POST "/projects" \
      --data-urlencode "name=$project_name" \
      --data-urlencode "path=$project_path" \
      --data-urlencode "namespace_id=$namespace_id" \
      --data-urlencode "initialize_with_readme=true" \
      --data-urlencode "visibility=private")"
  else
    project_json="$(gitlab_api POST "/projects" \
      --data-urlencode "name=$project_name" \
      --data-urlencode "path=$project_path" \
      --data-urlencode "initialize_with_readme=true" \
      --data-urlencode "visibility=private")"
  fi
  project_id="$(echo "$project_json" | jq -r '.id')"
fi

[[ -n "${project_id:-}" && "$project_id" != "null" ]] || die "프로젝트 ID를 확인할 수 없습니다."

STATE_FILE="$SCRIPT_DIR/.state/gitlab_demo_app_project.json"
echo "$project_json" > "$STATE_FILE"
chmod 600 "$STATE_FILE" || true

base_branch="$(echo "$project_json" | jq -r '.default_branch')"
[[ -n "$base_branch" && "$base_branch" != "null" ]] || base_branch="master"

log "브랜치 준비: base=$base_branch target=$default_branch"
if ! gitlab_api GET "/projects/${project_id}/repository/branches/$(urlencode "$default_branch")" >/dev/null 2>&1; then
  gitlab_api POST "/projects/${project_id}/repository/branches" \
    --data-urlencode "branch=$default_branch" \
    --data-urlencode "ref=$base_branch" >/dev/null
fi

log "프로젝트 기본 브랜치 설정: $default_branch"
gitlab_api PUT "/projects/${project_id}" --data-urlencode "default_branch=$default_branch" >/dev/null || true

app_name="${PIPELINE_APP_NAME:-demo-app}"
base_image="${PIPELINE_BASE_IMAGE:-nginx:1.29.4-alpine}"
image_repo="${harbor_registry}/${harbor_project}/${app_name}"

repo_readme="# Demo App (Jenkins → Harbor)\n\n- Jenkins가 이 리포의 \`Jenkinsfile\`을 실행해 이미지를 빌드/푸시합니다.\n- 이미지: \`${image_repo}:<tag>\`\n"

dockerfile="FROM ${base_image}\nCOPY index.html /usr/share/nginx/html/index.html\n"

index_html="<!doctype html>\n<html>\n  <head><meta charset=\"utf-8\" /><title>demo-app</title></head>\n  <body>\n    <h1>demo-app</h1>\n    <p>Built by Jenkins, pushed to Harbor.</p>\n  </body>\n</html>\n"

jenkinsfile="pipeline {\n  agent any\n  environment {\n    REGISTRY = '${harbor_registry}'\n    PROJECT  = '${harbor_project}'\n    IMAGE    = '${app_name}'\n  }\n  stages {\n    stage('Build') {\n      steps {\n        script {\n          // Jenkins 환경변수(GIT_COMMIT)를 활용해 tag를 만들면, 컨트롤러에 git CLI가 없어도 동작합니다.\n          def sha = env.GIT_COMMIT ?: ''\n          env.TAG = sha ? sha.take(8) : 'build-' + env.BUILD_NUMBER\n        }\n        sh \"docker build -t \\\"\\${REGISTRY}/\\${PROJECT}/\\${IMAGE}:\\${TAG}\\\" .\"\n      }\n    }\n    stage('Login & Push') {\n      steps {\n        withCredentials([usernamePassword(credentialsId: 'harbor-robot', usernameVariable: 'HARBOR_USER', passwordVariable: 'HARBOR_PASS')]) {\n          sh '''\n            set -e\n            echo \"$HARBOR_PASS\" | docker login \"$REGISTRY\" -u \"$HARBOR_USER\" --password-stdin\n            docker push \"$REGISTRY/$PROJECT/$IMAGE:$TAG\"\n            docker logout \"$REGISTRY\" || true\n          '''\n        }\n      }\n    }\n  }\n}\n"

dockerignore=".git\n.gitlab-ci.yml\n"

declare -a files
files+=("README.md")
files+=("Dockerfile")
files+=("index.html")
files+=("Jenkinsfile")
files+=(".dockerignore")

content_for() {
  local p="$1"
  case "$p" in
    "README.md") echo -e "$repo_readme" ;;
    "Dockerfile") echo -e "$dockerfile" ;;
    "index.html") echo -e "$index_html" ;;
    "Jenkinsfile") echo -e "$jenkinsfile" ;;
    ".dockerignore") echo -e "$dockerignore" ;;
    *) die "알 수 없는 파일: $p" ;;
  esac
}

log "데모 파일 커밋"
actions='[]'
for p in "${files[@]}"; do
  enc="$(urlencode "$p")"
  status="$(curl -s -o /dev/null -w "%{http_code}" -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "$(gitlab_api_base_url)/api/v4/projects/${project_id}/repository/files/${enc}?ref=$(urlencode "$default_branch")")"
  action="create"
  if [[ "$status" == "200" ]]; then
    action="update"
  fi
  content="$(content_for "$p")"
  actions="$(echo "$actions" | jq --arg a "$action" --arg p "$p" --arg c "$content" '. + [{action:$a,file_path:$p,content:$c}]')"
done

commit_body="$(jq -n \
  --arg branch "$default_branch" \
  --arg msg "chore: seed demo app for jenkins->harbor" \
  --argjson actions "$actions" \
  '{branch:$branch, commit_message:$msg, actions:$actions}')"

gitlab_api POST "/projects/${project_id}/repository/commits" \
  -H "Content-Type: application/json" \
  -d "$commit_body" >/dev/null

log "완료"
log "프로젝트: $(echo "$project_json" | jq -r '.web_url')"
log "상태 파일: scripts/gitops/.state/gitlab_demo_app_project.json"
log "완료 (로그: $LOG_FILE)"
