#!/usr/bin/env bash
set -euo pipefail

# 05) k3s 설치(필수)
# - 단일 서버에 Kubernetes(k3s)를 설치합니다.
# - 이미 설치되어 있으면 스킵하고, kubeconfig/레지스트리 설정만 보완합니다.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ensure_dirs
load_config

LOG_FILE="$SCRIPT_DIR/.logs/05_install_k3s_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

require_cmd curl
require_cmd sudo

if [[ -z "${SERVER_IP:-}" ]]; then
  SERVER_IP="$(detect_server_ip)"
fi
[[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP 감지 실패. config.env에 입력하세요."

install_k3s() {
  log "k3s 설치 시작 (버전: $K3S_VERSION)"
  curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC="server --write-kubeconfig-mode=644" sh -
  sudo systemctl enable --now k3s
}

if command -v k3s >/dev/null 2>&1; then
  log "k3s가 이미 설치되어 있습니다: $(k3s --version | head -n 1 || true)"
else
  install_k3s
fi

log "kubectl 래퍼 설치(없으면 생성)"
if ! command -v kubectl >/dev/null 2>&1; then
  sudo tee /usr/local/bin/kubectl >/dev/null <<'EOF'
#!/usr/bin/env bash
# kubectl이 따로 설치되지 않은 환경에서 k3s kubectl을 대신 호출합니다.
exec k3s kubectl "$@"
EOF
  sudo chmod +x /usr/local/bin/kubectl
fi

log "kubeconfig 사용자 홈에 복사(~/.kube/config)"
mkdir -p "$HOME/.kube"
chmod 700 "$HOME/.kube"
if [[ -f "$HOME/.kube/config" ]]; then
  cp -a "$HOME/.kube/config" "$HOME/.kube/config.bak_$(date +%Y%m%d_%H%M%S)" || true
fi
sudo cp -a /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
sudo chown "$USER":"$USER" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

log "Harbor 레지스트리 설정(선택)"
HARBOR_REGISTRY_HOSTPORT="${HARBOR_REGISTRY_HOSTPORT:-}"
if [[ -z "$HARBOR_REGISTRY_HOSTPORT" && "${ENABLE_HARBOR:-false}" == "true" ]]; then
  HARBOR_REGISTRY_HOSTPORT="${SERVER_IP}:${HARBOR_HTTP_PORT}"
fi

if [[ -n "$HARBOR_REGISTRY_HOSTPORT" ]]; then
  REG_FILE="/etc/rancher/k3s/registries.yaml"
  BACKUP="$SCRIPT_DIR/.state/registries.yaml.bak_$(date +%Y%m%d_%H%M%S)"
  if [[ -f "$REG_FILE" ]]; then
    sudo cp -a "$REG_FILE" "$BACKUP"
    log "기존 registries.yaml 백업: $BACKUP"
  fi
  log "k3s(containerd)에서 HTTP 레지스트리 허용: $HARBOR_REGISTRY_HOSTPORT"
  sudo tee "$REG_FILE" >/dev/null <<EOF
mirrors:
  "$HARBOR_REGISTRY_HOSTPORT":
    endpoint:
      - "http://$HARBOR_REGISTRY_HOSTPORT"
EOF
  sudo systemctl restart k3s
else
  log "HARBOR_REGISTRY_HOSTPORT가 비어 있어 레지스트리 설정을 건너뜁니다."
fi

log "k3s 상태 확인"
kubectl get nodes -o wide || true

log "완료 (로그: $LOG_FILE)"

