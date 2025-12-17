#!/usr/bin/env bash
set -euo pipefail

# 08) Argo CD 부트스트랩
# - Argo CD에 Git 리포를 등록(필요 시 인증 포함)하고,
# - 데모 Application을 생성하여 자동 동기화(옵션)합니다.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
load_config

LOG_FILE="$SCRIPT_DIR/.logs/08_bootstrap_argocd_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

require_cmd kubectl
require_cmd jq

repo_url="${GITOPS_REPO_URL:-}"

STATE_FILE="$SCRIPT_DIR/.state/gitlab_project.json"
if [[ -z "$repo_url" && -f "$STATE_FILE" ]]; then
  repo_url="$(jq -r '.http_url_to_repo // empty' "$STATE_FILE")"
fi

[[ -n "${repo_url:-}" ]] || die "GITOPS_REPO_URL이 비어 있습니다. (GitLab 자동 생성(07)을 했거나, config.env에 직접 입력하세요)"

target_rev="${GITOPS_TARGET_REVISION:-main}"
repo_path="${GITOPS_REPO_PATH:-apps/demo-app}"

repo_user="${GITOPS_REPO_USERNAME:-}"
repo_pass="${GITOPS_REPO_PASSWORD:-}"

# GitLab을 쓴다면, 기본값으로 PAT를 repo secret에 넣는 방식(간단)
if [[ -z "$repo_user" && -z "$repo_pass" && "${ENABLE_GITLAB:-false}" == "true" && -n "${GITLAB_TOKEN:-}" ]]; then
  repo_user="oauth2"
  repo_pass="$GITLAB_TOKEN"
fi

log "Argo CD namespace 확인"
kubectl get ns argocd >/dev/null 2>&1 || die "argocd 네임스페이스가 없습니다. 06_install_argocd.sh를 먼저 실행하세요."

if [[ -n "$repo_user" && -n "$repo_pass" ]]; then
  log "Git 리포 인증 Secret 생성/갱신(출력 금지)"
  kubectl -n argocd apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-credentials
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  url: "$repo_url"
  username: "$repo_user"
  password: "$repo_pass"
EOF
else
  log "리포 인증 정보가 없어 repo secret 생성은 건너뜁니다(리포가 public인 경우 OK)."
fi

if [[ "${ENABLE_DEMO_APP:-true}" != "true" ]]; then
  log "ENABLE_DEMO_APP=false → Application 생성은 건너뜁니다."
  exit 0
fi

log "Application 생성/갱신: $ARGOCD_APP_NAME"
kubectl -n argocd apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${ARGOCD_APP_NAME}
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "$repo_url"
    targetRevision: "$target_rev"
    path: "$repo_path"
  destination:
    server: https://kubernetes.default.svc
    namespace: ${DEMO_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

log "생성 확인"
kubectl -n argocd get applications.argoproj.io "${ARGOCD_APP_NAME}" -o wide || true

log "완료 (로그: $LOG_FILE)"

