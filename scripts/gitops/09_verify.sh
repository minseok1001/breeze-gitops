#!/usr/bin/env bash
set -euo pipefail

# 09) 검증(Verify)
# - 설치/연동이 정상인지 빠르게 확인합니다.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
load_config

LOG_FILE="$SCRIPT_DIR/.logs/09_verify_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

require_cmd curl

if [[ -z "${SERVER_IP:-}" ]]; then
  SERVER_IP="$(detect_server_ip)"
fi
[[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP 감지 실패. config.env에 입력하세요."

log "검증 시작"

if command -v docker >/dev/null 2>&1; then
  log "docker: $(docker --version)"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}' || true
else
  warn "docker가 없어 컨테이너 상태 검증은 건너뜁니다."
fi

if [[ "${ENABLE_GITLAB:-false}" == "true" ]]; then
  code="$(curl -s -o /dev/null -w "%{http_code}" "http://${SERVER_IP}:${GITLAB_HTTP_PORT}/users/sign_in" || true)"
  log "GitLab HTTP: $code (http://${SERVER_IP}:${GITLAB_HTTP_PORT})"
fi

if [[ "${ENABLE_HARBOR:-false}" == "true" ]]; then
  code="$(curl -s -o /dev/null -w "%{http_code}" "http://${SERVER_IP}:${HARBOR_HTTP_PORT}/api/v2.0/ping" || true)"
  log "Harbor HTTP: $code (http://${SERVER_IP}:${HARBOR_HTTP_PORT})"
fi

if command -v kubectl >/dev/null 2>&1; then
  log "Kubernetes 노드"
  kubectl get nodes -o wide || true

  log "Argo CD 파드"
  kubectl -n argocd get pods -o wide || true

  if [[ "${ENABLE_DEMO_APP:-true}" == "true" ]]; then
    log "데모 앱 네임스페이스/파드"
    kubectl get ns "$DEMO_NAMESPACE" >/dev/null 2>&1 && kubectl -n "$DEMO_NAMESPACE" get pods -o wide || true
  fi
else
  warn "kubectl이 없어 k3s/Argo CD 검증은 건너뜁니다."
fi

log "Argo CD 접속 정보"
log "URL: https://${SERVER_IP}:${ARGOCD_NODEPORT_HTTPS}"
log "admin 비밀번호 파일: scripts/gitops/.secrets/argocd_admin_password"

if [[ "${ENABLE_GITLAB:-false}" == "true" ]]; then
  log "GitLab root 비밀번호 파일: scripts/gitops/.secrets/gitlab_root_password"
fi
if [[ "${ENABLE_HARBOR:-false}" == "true" ]]; then
  log "Harbor admin 비밀번호 파일: scripts/gitops/.secrets/harbor_admin_password"
fi

log "검증 완료 (로그: $LOG_FILE)"

