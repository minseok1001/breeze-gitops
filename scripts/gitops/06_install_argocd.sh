#!/usr/bin/env bash
set -euo pipefail

# 06) Argo CD 설치(필수)
# - k3s 클러스터에 Argo CD를 설치합니다.
# - 외부 접속은 NodePort(기본 30443)로 노출합니다.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
load_config

LOG_FILE="$SCRIPT_DIR/.logs/06_install_argocd_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

require_cmd kubectl
require_cmd curl
require_cmd sudo

if [[ -z "${SERVER_IP:-}" ]]; then
  SERVER_IP="$(detect_server_ip)"
fi
[[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP 감지 실패. config.env에 입력하세요."

if [[ "$ARGOCD_NODEPORT_HTTPS" -lt 30000 || "$ARGOCD_NODEPORT_HTTPS" -gt 32767 ]]; then
  die "ARGOCD_NODEPORT_HTTPS는 30000~32767 범위여야 합니다. 현재: $ARGOCD_NODEPORT_HTTPS"
fi

log "Argo CD 설치 시작 (버전: $ARGOCD_VERSION)"
kubectl create namespace argocd >/dev/null 2>&1 || true

if [[ -n "${ARGOCD_MANIFEST_PATH:-}" ]]; then
  [[ -f "$ARGOCD_MANIFEST_PATH" ]] || die "ARGOCD_MANIFEST_PATH 파일이 없습니다: $ARGOCD_MANIFEST_PATH"
  log "로컬 manifest로 설치: $ARGOCD_MANIFEST_PATH"
  kubectl apply -n argocd -f "$ARGOCD_MANIFEST_PATH"
else
  install_url="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
  log "원격 manifest로 설치: $install_url"
  kubectl apply -n argocd -f "$install_url"
fi

log "핵심 디플로이먼트 준비 대기"
kubectl -n argocd rollout status deploy/argocd-server --timeout=900s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=900s
kubectl -n argocd rollout status deploy/argocd-application-controller --timeout=900s

log "argocd-server 서비스 NodePort 노출(HTTPS 고정)"
kubectl -n argocd patch svc argocd-server --type merge -p "{
  \"spec\": {
    \"type\": \"NodePort\",
    \"ports\": [
      {\"name\":\"http\",\"port\":80,\"protocol\":\"TCP\",\"targetPort\":8080},
      {\"name\":\"https\",\"port\":443,\"protocol\":\"TCP\",\"targetPort\":8080,\"nodePort\":${ARGOCD_NODEPORT_HTTPS}}
    ]
  }
}" >/dev/null

log "초기 admin 비밀번호 저장(출력 금지)"
deadline=$(( $(date +%s) + 300 ))
while [[ $(date +%s) -lt $deadline ]]; do
  if kubectl -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; then
    break
  fi
  sleep 3
done
password="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || true)"
[[ -n "${password:-}" ]] || warn "초기 비밀번호를 읽지 못했습니다. (argocd-initial-admin-secret 확인 필요)"
write_secret_file "$SCRIPT_DIR/.secrets/argocd_admin_password" "$password"

log "Argo CD URL: https://${SERVER_IP}:${ARGOCD_NODEPORT_HTTPS}"
log "admin 비밀번호 파일: scripts/gitops/.secrets/argocd_admin_password"
log "완료 (로그: $LOG_FILE)"

