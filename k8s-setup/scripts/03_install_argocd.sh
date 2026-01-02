#!/usr/bin/env bash
set -euo pipefail

# 03) Argo CD 설치/확인
# - 이미 설치되어 있으면 스킵합니다.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
load_config
validate_bool "ENABLE_ARGOCD" "${ENABLE_ARGOCD:-true}"
validate_bool "ARGOCD_WAIT" "${ARGOCD_WAIT:-true}"

LOG_FILE="$SCRIPT_DIR/.logs/03_install_argocd_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

if [[ "${ENABLE_ARGOCD:-true}" != "true" ]]; then
  log "ENABLE_ARGOCD=false → Argo CD 설치를 건너뜁니다."
  exit 0
fi

require_cmd kubectl
require_cmd base64

if [[ -n "${KUBECONFIG:-}" && ! -f "${KUBECONFIG}" ]]; then
  die "KUBECONFIG 파일이 없습니다: $KUBECONFIG"
fi

# 능동적 자동화: Argo CD CLI 설치 (없으면)
if ! command -v argocd >/dev/null 2>&1; then
  log "Argo CD CLI 자동 설치"
  curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 && chmod +x /tmp/argocd && sudo mv /tmp/argocd /usr/local/bin/ || warn "Argo CD CLI 설치 실패."
fi

ns="${ARGOCD_NAMESPACE:-argocd}"
version="${ARGOCD_VERSION:-v2.12.6}"
manifest_path="${ARGOCD_MANIFEST_PATH:-}"
manifest_url="${ARGOCD_MANIFEST_URL:-}"

log "Argo CD namespace: $ns"

if ! kubectl_cmd get ns "$ns" >/dev/null 2>&1; then
  log "네임스페이스 생성: $ns"
  kubectl_cmd create ns "$ns"
fi

if kubectl_cmd -n "$ns" get deploy argocd-server >/dev/null 2>&1; then
  log "Argo CD가 이미 설치되어 있습니다. (argocd-server 존재)"
  exit 0
fi

if [[ -n "${manifest_path:-}" ]]; then
  [[ -f "$manifest_path" ]] || die "ARGOCD_MANIFEST_PATH 파일이 없습니다: $manifest_path"
  log "Argo CD 설치(로컬 파일): $manifest_path"
  kubectl_cmd -n "$ns" apply -f "$manifest_path"
else
  if [[ -z "${manifest_url:-}" ]]; then
    manifest_url="https://raw.githubusercontent.com/argoproj/argo-cd/${version}/manifests/install.yaml"
  fi
  log "Argo CD 설치(URL): $manifest_url"
  kubectl_cmd -n "$ns" apply -f "$manifest_url"
fi

if [[ "${ARGOCD_WAIT:-true}" == "true" ]]; then
  log "Argo CD 주요 디플로이 대기"
  deployments=(argocd-server argocd-repo-server argocd-application-controller)
  for deploy in "${deployments[@]}"; do
    kubectl_cmd -n "$ns" rollout status "deploy/${deploy}" --timeout=5m || true
  done
fi

# 초기 admin 비밀번호 저장(출력 금지)
if kubectl_cmd -n "$ns" get secret argocd-initial-admin-secret >/dev/null 2>&1; then
  pw="$(kubectl_cmd -n "$ns" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
  if [[ -n "${pw:-}" ]]; then
    write_secret_file "$SCRIPT_DIR/.secrets/argocd_initial_admin_password" "$pw"
    log "초기 admin 비밀번호를 저장했습니다: k8s-setup/scripts/.secrets/argocd_initial_admin_password"
  else
    warn "초기 admin 비밀번호 추출에 실패했습니다."
  fi
else
  warn "argocd-initial-admin-secret을 찾지 못했습니다."
fi

# 능동적 자동화: Argo CD 초기 로그인
if command -v argocd >/dev/null 2>&1 && [[ -f "$SCRIPT_DIR/.secrets/argocd_initial_admin_password" ]]; then
  log "Argo CD 초기 로그인 시도"
  argocd login "$(kubectl_cmd -n "$ns" get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "localhost:8080")" --username admin --password "$(cat "$SCRIPT_DIR/.secrets/argocd_initial_admin_password")" --insecure || warn "Argo CD 로그인 실패."
fi

log "Argo CD 설치 완료 (로그: $LOG_FILE)"
