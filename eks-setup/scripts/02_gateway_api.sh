#!/usr/bin/env bash
set -euo pipefail

# 02) Gateway API 설치/확인
# - CRD가 이미 있으면 스킵합니다.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
load_config
validate_bool "ENABLE_GATEWAY_API" "${ENABLE_GATEWAY_API:-true}"

LOG_FILE="$SCRIPT_DIR/.logs/02_gateway_api_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

if [[ "${ENABLE_GATEWAY_API:-true}" != "true" ]]; then
  log "ENABLE_GATEWAY_API=false → Gateway API 설치를 건너뜁니다."
  exit 0
fi

require_cmd kubectl

if [[ -n "${KUBECONFIG:-}" && ! -f "${KUBECONFIG}" ]]; then
  die "KUBECONFIG 파일이 없습니다: $KUBECONFIG"
fi

# 필수 CRD 최소 세트만 확인
required_crds=(
  "gatewayclasses.gateway.networking.k8s.io"
  "gateways.gateway.networking.k8s.io"
  "httproutes.gateway.networking.k8s.io"
)

missing=()
for crd in "${required_crds[@]}"; do
  if ! kubectl_cmd get crd "$crd" >/dev/null 2>&1; then
    missing+=("$crd")
  fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
  log "Gateway API CRD가 이미 설치되어 있습니다. (필수 CRD 확인 완료)"
  exit 0
fi

log "Gateway API CRD가 부족합니다: ${missing[*]}"

manifest_path="${GATEWAY_API_MANIFEST_PATH:-}"
manifest_url="${GATEWAY_API_MANIFEST_URL:-}"
version="${GATEWAY_API_VERSION:-v1.1.0}"

if [[ -n "${manifest_path:-}" ]]; then
  [[ -f "$manifest_path" ]] || die "GATEWAY_API_MANIFEST_PATH 파일이 없습니다: $manifest_path"
  log "Gateway API 설치(로컬 파일): $manifest_path"
  kubectl_cmd apply -f "$manifest_path"
else
  if [[ -z "${manifest_url:-}" ]]; then
    manifest_url="https://github.com/kubernetes-sigs/gateway-api/releases/download/${version}/standard-install.yaml"
  fi
  log "Gateway API 설치(URL): $manifest_url"
  kubectl_cmd apply -f "$manifest_url"
fi

log "설치 확인"
for crd in "${required_crds[@]}"; do
  kubectl_cmd get crd "$crd" >/dev/null 2>&1 || die "CRD 확인 실패: $crd"
done

log "Gateway API 설치 완료 (로그: $LOG_FILE)"
