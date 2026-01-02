#!/usr/bin/env bash
set -euo pipefail

# 01) 사전 점검(EKS)
# - kubectl/컨텍스트/클러스터 접근을 확인합니다.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
load_config
validate_bool "ENABLE_GATEWAY_API" "${ENABLE_GATEWAY_API:-true}"
validate_bool "ENABLE_ARGOCD" "${ENABLE_ARGOCD:-true}"
validate_bool "ARGOCD_WAIT" "${ARGOCD_WAIT:-true}"

LOG_FILE="$SCRIPT_DIR/.logs/01_preflight_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

require_cmd kubectl

if [[ -n "${KUBECONFIG:-}" && ! -f "${KUBECONFIG}" ]]; then
  die "KUBECONFIG 파일이 없습니다: $KUBECONFIG"
fi

# 능동적 자동화: EKS 클러스터 kubeconfig 자동 설정
if [[ -n "${EKS_CLUSTER_NAME:-}" ]]; then
  require_cmd aws
  log "EKS 클러스터 kubeconfig 자동 업데이트: $EKS_CLUSTER_NAME"
  aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "${AWS_REGION:-us-east-1}" || warn "EKS kubeconfig 업데이트 실패. 수동 설정 필요."
fi

# Kubernetes 프로바이더 자동 감지 함수
detect_provider() {
  log "Kubernetes 프로바이더 자동 감지 중..."
  local provider_id
  provider_id=$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || echo "")

  if [[ "$provider_id" =~ ^aws ]]; then
    echo "aws"
  elif [[ "$provider_id" =~ ^gce ]]; then
    echo "gcp"
  elif [[ "$provider_id" =~ ^azure ]]; then
    echo "azure"
  else
    echo "generic"
  fi
}

log "사전 점검 시작"
log "설정 파일: ${LOADED_CONFIG_FILE:-unknown}"
log "KUBECONFIG=${KUBECONFIG:-<default>}"
log "KUBE_CONTEXT=${KUBE_CONTEXT:-<current>}"

# 프로바이더 감지 및 설정
KUBERNETES_PROVIDER="${KUBERNETES_PROVIDER:-$(detect_provider)}"
log "감지된 프로바이더: $KUBERNETES_PROVIDER"

# config.env에 저장 (기존 값 덮어쓰기 또는 추가)
if grep -q "^KUBERNETES_PROVIDER=" "$LOADED_CONFIG_FILE" 2>/dev/null; then
  sed -i "s/^KUBERNETES_PROVIDER=.*/KUBERNETES_PROVIDER=\"$KUBERNETES_PROVIDER\"/" "$LOADED_CONFIG_FILE"
else
  echo "KUBERNETES_PROVIDER=\"$KUBERNETES_PROVIDER\"" >> "$LOADED_CONFIG_FILE"
fi

log "kubectl 버전 확인"
kubectl version --client --short 2>/dev/null || kubectl version --client || true

log "현재 컨텍스트 확인"
if ! kubectl_cmd config current-context >/dev/null 2>&1; then
  warn "현재 컨텍스트를 확인하지 못했습니다. KUBECONFIG/KUBE_CONTEXT를 확인하세요."
else
  log "현재 컨텍스트: $(kubectl_cmd config current-context)"
fi

log "클러스터 접근 확인(get nodes)"
if ! kubectl_cmd get nodes >/dev/null 2>&1; then
  die "클러스터 접근 실패. kubeconfig/권한/네트워크를 확인하세요."
fi

log "사전 점검 완료 (로그: $LOG_FILE)"
