#!/usr/bin/env bash
set -euo pipefail

# 07) Git 저장소 준비(선택: GitLab 사용 시)
# - GitLab에 GitOps 데모 리포지토리를 생성하고, 매니페스트를 시드(seed)합니다.
# - ENABLE_GITLAB=true && GITLAB_TOKEN 설정이 필요합니다.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
load_config

LOG_FILE="$SCRIPT_DIR/.logs/07_bootstrap_git_repo_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

if [[ "${ENABLE_GITLAB:-false}" != "true" ]]; then
  log "ENABLE_GITLAB=false → Git 저장소 준비를 건너뜁니다."
  exit 0
fi

if [[ -z "${GITLAB_TOKEN:-}" ]]; then
  warn "GITLAB_TOKEN이 비어 있어 자동 생성/시드를 할 수 없습니다. (GitLab에서 수동으로 리포를 만들고 다음 단계로 진행하세요)"
  exit 0
fi

require_cmd curl
require_cmd jq

if [[ -z "${SERVER_IP:-}" ]]; then
  SERVER_IP="$(detect_server_ip)"
fi
[[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP 감지 실패. config.env에 입력하세요."

log "GitLab API 연결 확인"
gitlab_api GET "/user" | jq -r '"user: \(.username) (id=\(.id))"'

namespace_id=""
namespace_path=""

user_json="$(gitlab_api GET "/user")"
user_name="$(echo "$user_json" | jq -r '.username')"
[[ -n "$user_name" && "$user_name" != "null" ]] || die "GitLab 사용자 정보를 가져오지 못했습니다."

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

project_full_path="${namespace_path}/${GITLAB_PROJECT_PATH}"
project_path_enc="$(urlencode "$project_full_path")"

log "프로젝트 확인/생성: $project_full_path"
if project_json="$(gitlab_api GET "/projects/$project_path_enc" 2>/dev/null)"; then
  project_id="$(echo "$project_json" | jq -r '.id')"
else
  if [[ -n "$namespace_id" ]]; then
    project_json="$(gitlab_api POST "/projects" \
      --data-urlencode "name=$GITLAB_PROJECT_NAME" \
      --data-urlencode "path=$GITLAB_PROJECT_PATH" \
      --data-urlencode "namespace_id=$namespace_id" \
      --data-urlencode "initialize_with_readme=true" \
      --data-urlencode "visibility=private")"
  else
    project_json="$(gitlab_api POST "/projects" \
      --data-urlencode "name=$GITLAB_PROJECT_NAME" \
      --data-urlencode "path=$GITLAB_PROJECT_PATH" \
      --data-urlencode "initialize_with_readme=true" \
      --data-urlencode "visibility=private")"
  fi
  project_id="$(echo "$project_json" | jq -r '.id')"
fi

[[ -n "${project_id:-}" && "$project_id" != "null" ]] || die "프로젝트 ID를 확인할 수 없습니다."

echo "$project_json" > "$SCRIPT_DIR/.state/gitlab_project.json"
chmod 600 "$SCRIPT_DIR/.state/gitlab_project.json" || true

base_branch="$(echo "$project_json" | jq -r '.default_branch')"
[[ -n "$base_branch" && "$base_branch" != "null" ]] || base_branch="master"

target_branch="${GITLAB_DEFAULT_BRANCH:-main}"

log "브랜치 준비: base=$base_branch target=$target_branch"
if ! gitlab_api GET "/projects/${project_id}/repository/branches/$(urlencode "$target_branch")" >/dev/null 2>&1; then
  gitlab_api POST "/projects/${project_id}/repository/branches" \
    --data-urlencode "branch=$target_branch" \
    --data-urlencode "ref=$base_branch" >/dev/null
fi

log "프로젝트 기본 브랜치 설정: $target_branch"
gitlab_api PUT "/projects/${project_id}" --data-urlencode "default_branch=$target_branch" >/dev/null || true

log "데모 매니페스트 커밋"

deployment_yaml="apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
    spec:
      containers:
        - name: demo-app
          image: ${DEMO_IMAGE}
          ports:
            - containerPort: 80
"

service_yaml="apiVersion: v1
kind: Service
metadata:
  name: demo-app
spec:
  selector:
    app: demo-app
  ports:
    - name: http
      port: 80
      targetPort: 80
"

kustomization_yaml="resources:
  - deployment.yaml
  - service.yaml
"

repo_readme="# GitOps Demo\n\n- Argo CD가 이 리포의 \`apps/demo-app\`를 바라보도록 구성합니다.\n"

declare -a files
files+=("README.md")
files+=("apps/demo-app/deployment.yaml")
files+=("apps/demo-app/service.yaml")
files+=("apps/demo-app/kustomization.yaml")

content_for() {
  local p="$1"
  case "$p" in
    "README.md") echo "$repo_readme" ;;
    "apps/demo-app/deployment.yaml") echo "$deployment_yaml" ;;
    "apps/demo-app/service.yaml") echo "$service_yaml" ;;
    "apps/demo-app/kustomization.yaml") echo "$kustomization_yaml" ;;
    *) die "알 수 없는 파일: $p" ;;
  esac
}

actions='[]'
for p in "${files[@]}"; do
  enc="$(urlencode "$p")"
  status="$(curl -s -o /dev/null -w "%{http_code}" -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "http://${SERVER_IP}:${GITLAB_HTTP_PORT}/api/v4/projects/${project_id}/repository/files/${enc}?ref=$(urlencode "$target_branch")")"
  action="create"
  if [[ "$status" == "200" ]]; then
    action="update"
  fi
  content="$(content_for "$p")"
  actions="$(echo "$actions" | jq --arg a "$action" --arg p "$p" --arg c "$content" '. + [{action:$a,file_path:$p,content:$c}]')"
done

commit_body="$(jq -n \
  --arg branch "$target_branch" \
  --arg msg "chore: seed gitops demo manifests" \
  --argjson actions "$actions" \
  '{branch:$branch, commit_message:$msg, actions:$actions}')"

gitlab_api POST "/projects/${project_id}/repository/commits" \
  -H "Content-Type: application/json" \
  -d "$commit_body" >/dev/null

log "완료"
log "프로젝트: $(echo "$project_json" | jq -r '.web_url')"
log "상태 파일: scripts/gitops/.state/gitlab_project.json"

