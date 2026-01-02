#!/usr/bin/env bash
set -euo pipefail

# 01) 사전 점검(K8s)
# - kubectl/컨텍스트/클러스터 접근을 확인합니다.
# - 프로바이더 자동 감지 + kubeconfig 자동 연결을 시도합니다.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
load_config
validate_bool "ENABLE_GATEWAY_API" "${ENABLE_GATEWAY_API:-true}"
validate_bool "ENABLE_ARGOCD" "${ENABLE_ARGOCD:-true}"
validate_bool "ARGOCD_WAIT" "${ARGOCD_WAIT:-true}"
validate_bool "AUTO_CONNECT_K8S" "${AUTO_CONNECT_K8S:-true}"

LOG_FILE="$SCRIPT_DIR/.logs/01_preflight_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

require_cmd kubectl

if [[ -n "${KUBECONFIG:-}" && ! -f "${KUBECONFIG}" ]]; then
  die "KUBECONFIG 파일이 없습니다: $KUBECONFIG"
fi

save_config_kv() {
  local key="$1"
  local value="$2"
  local file="${LOADED_CONFIG_FILE:-}"
  [[ -n "$file" ]] || return 0
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$file"
  else
    printf '%s="%s"\n' "$key" "$value" >> "$file"
  fi
}

detect_provider_from_cluster() {
  local provider_id
  provider_id=$(kubectl_cmd get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || echo "")

  if [[ "$provider_id" =~ ^aws ]]; then
    echo "aws"
  elif [[ "$provider_id" =~ ^gce ]]; then
    echo "gcp"
  elif [[ "$provider_id" =~ ^azure ]]; then
    echo "azure"
  else
    echo ""
  fi
}

aws_metadata_document() {
  command -v curl >/dev/null 2>&1 || return 0
  local token
  token="$(curl -sS --connect-timeout 1 --max-time 2 -X PUT \
    "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"

  if [[ -n "$token" ]]; then
    curl -sS --connect-timeout 1 --max-time 2 \
      -H "X-aws-ec2-metadata-token: $token" \
      "http://169.254.169.254/latest/dynamic/instance-identity/document" 2>/dev/null || true
  else
    curl -sS --connect-timeout 1 --max-time 2 \
      "http://169.254.169.254/latest/dynamic/instance-identity/document" 2>/dev/null || true
  fi
}

detect_provider_from_metadata() {
  local aws_doc
  aws_doc="$(aws_metadata_document)"
  if [[ -n "$aws_doc" ]]; then
    echo "aws"
    return 0
  fi

  if command -v curl >/dev/null 2>&1; then
    if curl -sS --connect-timeout 1 --max-time 2 \
      -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/instance/id" >/dev/null 2>&1; then
      echo "gcp"
      return 0
    fi

    if curl -sS --connect-timeout 1 --max-time 2 \
      -H "Metadata: true" \
      "http://169.254.169.254/metadata/instance?api-version=2021-02-01" >/dev/null 2>&1; then
      echo "azure"
      return 0
    fi
  fi

  echo ""
}

aws_region_from_metadata() {
  local doc region
  doc="$(aws_metadata_document)"
  region="$(echo "$doc" | sed -n 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  echo "$region"
}

get_aws_region() {
  local region="${AWS_REGION:-}"
  if [[ -z "$region" ]] && command -v aws >/dev/null 2>&1; then
    region="$(aws configure get region 2>/dev/null || true)"
  fi
  if [[ -z "$region" ]]; then
    region="$(aws_region_from_metadata)"
  fi
  echo "${region:-us-east-1}"
}

ensure_eks_kubeconfig() {
  if ! command -v aws >/dev/null 2>&1; then
    warn "aws CLI가 없어 EKS 자동 연결을 건너뜁니다."
    return 0
  fi

  local region cluster clusters count
  region="$(get_aws_region)"
  cluster="${EKS_CLUSTER_NAME:-}"

  if [[ -z "$cluster" ]]; then
    log "EKS 클러스터 이름이 지정되지 않았습니다. 자동 탐색을 시도합니다."
    clusters="$(aws eks list-clusters --region "$region" --query 'clusters' --output text 2>/dev/null || true)"
    count=0
    if [[ -n "$clusters" ]]; then
      count=$(wc -w <<< "$clusters" | tr -d ' ')
    fi
    if [[ "$count" -eq 1 ]]; then
      cluster="$clusters"
    elif [[ "$count" -gt 1 ]]; then
      warn "다수의 EKS 클러스터가 발견되었습니다: $clusters"
    fi
  fi

  if [[ -z "$cluster" ]]; then
    warn "EKS 클러스터 이름을 찾지 못했습니다. EKS_CLUSTER_NAME를 설정하세요."
    return 0
  fi

  log "EKS kubeconfig 자동 업데이트: $cluster (region=$region)"
  aws eks update-kubeconfig --name "$cluster" --region "$region" || warn "EKS kubeconfig 업데이트 실패. 수동 설정 필요."
}

ensure_gke_kubeconfig() {
  if ! command -v gcloud >/dev/null 2>&1; then
    warn "gcloud CLI가 없어 GKE 자동 연결을 건너뜁니다."
    return 0
  fi

  local project cluster location location_type info count location_flag
  local project_args=()
  project="${GKE_PROJECT:-}"
  if [[ -z "$project" ]]; then
    project="$(gcloud config get-value project 2>/dev/null || true)"
  fi
  if [[ -n "$project" ]]; then
    project_args=(--project "$project")
  fi

  cluster="${GKE_CLUSTER_NAME:-}"
  location="${GKE_LOCATION:-}"
  location_type="${GKE_LOCATION_TYPE:-}"

  if [[ -n "$cluster" && -z "$location" ]]; then
    info="$(gcloud container clusters list "${project_args[@]}" --filter="name=$cluster" \
      --format="value(location,locationType)" 2>/dev/null | head -n1 || true)"
    if [[ -n "$info" ]]; then
      location="$(awk '{print $1}' <<< "$info")"
      location_type="$(awk '{print $2}' <<< "$info")"
    fi
  fi

  if [[ -z "$cluster" ]]; then
    info="$(gcloud container clusters list "${project_args[@]}" \
      --format="value(name,location,locationType)" 2>/dev/null || true)"
    count=0
    if [[ -n "$info" ]]; then
      count=$(printf '%s\n' "$info" | sed '/^$/d' | wc -l | tr -d ' ')
    fi
    if [[ "$count" -eq 1 ]]; then
      read -r cluster location location_type <<< "$info"
    elif [[ "$count" -gt 1 ]]; then
      warn "다수의 GKE 클러스터가 발견되었습니다. GKE_CLUSTER_NAME를 설정하세요."
    fi
  fi

  if [[ -z "$cluster" || -z "$location" ]]; then
    warn "GKE 클러스터 정보를 찾지 못했습니다. GKE_CLUSTER_NAME/GKE_LOCATION를 설정하세요."
    return 0
  fi

  location_flag="--region"
  case "${location_type^^}" in
    ZONAL|ZONE) location_flag="--zone" ;;
    REGIONAL|REGION) location_flag="--region" ;;
    *)
      if [[ "$location" =~ -[a-z]$ ]]; then
        location_flag="--zone"
      fi
      ;;
  esac

  if [[ -n "$project" ]]; then
    log "GKE kubeconfig 자동 업데이트: $cluster ($location_flag=$location, project=$project)"
    gcloud container clusters get-credentials "$cluster" "${project_args[@]}" "$location_flag" "$location" || \
      warn "GKE kubeconfig 업데이트 실패. 수동 설정 필요."
  else
    log "GKE kubeconfig 자동 업데이트: $cluster ($location_flag=$location)"
    gcloud container clusters get-credentials "$cluster" "$location_flag" "$location" || \
      warn "GKE kubeconfig 업데이트 실패. 수동 설정 필요."
  fi
}

ensure_aks_kubeconfig() {
  if ! command -v az >/dev/null 2>&1; then
    warn "az CLI가 없어 AKS 자동 연결을 건너뜁니다."
    return 0
  fi

  if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
    az account set --subscription "$AZURE_SUBSCRIPTION_ID" >/dev/null 2>&1 || \
      warn "Azure 구독 설정 실패. az login/권한을 확인하세요."
  fi

  local cluster group info count
  cluster="${AKS_CLUSTER_NAME:-}"
  group="${AKS_RESOURCE_GROUP:-}"

  if [[ -z "$cluster" || -z "$group" ]]; then
    info="$(az aks list --query "[].{name:name,rg:resourceGroup}" -o tsv 2>/dev/null || true)"
    count=0
    if [[ -n "$info" ]]; then
      count=$(printf '%s\n' "$info" | sed '/^$/d' | wc -l | tr -d ' ')
    fi
    if [[ "$count" -eq 1 ]]; then
      read -r cluster group <<< "$info"
    elif [[ "$count" -gt 1 ]]; then
      warn "다수의 AKS 클러스터가 발견되었습니다. AKS_CLUSTER_NAME/AKS_RESOURCE_GROUP를 설정하세요."
    fi
  fi

  if [[ -z "$cluster" || -z "$group" ]]; then
    warn "AKS 클러스터 정보를 찾지 못했습니다. AKS_CLUSTER_NAME/AKS_RESOURCE_GROUP를 설정하세요."
    return 0
  fi

  log "AKS kubeconfig 자동 업데이트: $cluster (rg=$group)"
  az aks get-credentials --resource-group "$group" --name "$cluster" --overwrite-existing || \
    warn "AKS kubeconfig 업데이트 실패. 수동 설정 필요."
}

auto_connect_k8s() {
  local provider="$1"
  if [[ "${AUTO_CONNECT_K8S:-true}" != "true" ]]; then
    return 0
  fi

  if kubectl_cmd config current-context >/dev/null 2>&1; then
    log "현재 컨텍스트가 이미 설정되어 있습니다. 자동 연결을 건너뜁니다."
    return 0
  fi

  log "Kubernetes 자동 연결 시도 (provider=${provider:-unknown})"
  case "$provider" in
    aws|eks) ensure_eks_kubeconfig ;;
    gcp|gke) ensure_gke_kubeconfig ;;
    azure|aks) ensure_aks_kubeconfig ;;
    *)
      warn "알 수 없는 프로바이더입니다. KUBERNETES_PROVIDER를 설정하세요."
      ;;
  esac
}

log "사전 점검 시작"
log "설정 파일: ${LOADED_CONFIG_FILE:-unknown}"
log "KUBECONFIG=${KUBECONFIG:-<default>}"
log "KUBE_CONTEXT=${KUBE_CONTEXT:-<current>}"
log "AUTO_CONNECT_K8S=${AUTO_CONNECT_K8S:-true}"

provider_hint=""
if [[ -z "${KUBERNETES_PROVIDER:-}" ]]; then
  provider_hint="$(detect_provider_from_metadata)"
fi

if [[ -z "$provider_hint" ]]; then
  if [[ -n "${EKS_CLUSTER_NAME:-}" ]]; then
    provider_hint="aws"
  elif [[ -n "${GKE_CLUSTER_NAME:-}" ]]; then
    provider_hint="gcp"
  elif [[ -n "${AKS_CLUSTER_NAME:-}" ]]; then
    provider_hint="azure"
  fi
fi

provider_for_autoconnect="${KUBERNETES_PROVIDER:-$provider_hint}"
if [[ -n "$provider_for_autoconnect" && "${AUTO_CONNECT_K8S:-true}" == "true" ]]; then
  auto_connect_k8s "$provider_for_autoconnect"
elif [[ "${AUTO_CONNECT_K8S:-true}" == "true" ]]; then
  warn "프로바이더를 감지하지 못했습니다. 자동 연결을 건너뜁니다."
fi

if [[ -z "${KUBERNETES_PROVIDER:-}" ]]; then
  provider_cluster="$(detect_provider_from_cluster)"
  if [[ -n "$provider_cluster" ]]; then
    KUBERNETES_PROVIDER="$provider_cluster"
  elif [[ -n "$provider_hint" ]]; then
    KUBERNETES_PROVIDER="$provider_hint"
  else
    KUBERNETES_PROVIDER="generic"
  fi
  save_config_kv "KUBERNETES_PROVIDER" "$KUBERNETES_PROVIDER"
fi

log "감지된 프로바이더: $KUBERNETES_PROVIDER"

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
