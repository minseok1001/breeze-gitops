# EKS Gateway API + Argo CD 설치 가이드

목표: EKS 클러스터에 **Gateway API CRD**를 설치하고, **Argo CD**를 배포합니다.

---

## 0) 준비 사항

- `kubectl` 설치
- kubeconfig 설정(기본: `~/.kube/config`)
- EKS 클러스터 접근 권한

---

## 1) 설정 파일

기본 설정 파일은 이미 제공됩니다.

```bash
vi eks-setup/scripts/config.env
```

필요하면 예시 파일로 “초기화”할 수 있습니다.

```bash
cp eks-setup/scripts/config.env.example eks-setup/scripts/config.env
```

주요 값(필요 시만 변경):

- `KUBECONFIG`, `KUBE_CONTEXT`
- `GATEWAY_API_VERSION`, `GATEWAY_API_MANIFEST_PATH/URL`
- `ARGOCD_VERSION`, `ARGOCD_NAMESPACE`, `ARGOCD_MANIFEST_PATH/URL`

---

## 2) 실행 순서

순서대로 실행:

```bash
bash eks-setup/scripts/01_preflight.sh
bash eks-setup/scripts/02_gateway_api.sh
bash eks-setup/scripts/03_install_argocd.sh
```

한 번에 실행:

```bash
sudo bash eks-setup/scripts/00_run_all.sh
```

---

## 3) 설치 확인

Gateway API CRD 확인:

```bash
kubectl get crd gatewayclasses.gateway.networking.k8s.io
kubectl get crd gateways.gateway.networking.k8s.io
kubectl get crd httproutes.gateway.networking.k8s.io
```

Argo CD 상태 확인:

```bash
kubectl -n argocd get pods
kubectl -n argocd get svc argocd-server
```

초기 admin 비밀번호는 아래 파일에 저장됩니다.

- `eks-setup/scripts/.secrets/argocd_initial_admin_password`

---

## 4) 참고 사항

- Gateway API는 **CRD 설치만** 수행합니다. 실제 트래픽 처리는 **Gateway API 컨트롤러**가 필요합니다.  
  (예: AWS Gateway API Controller)
- 폐쇄망이면 `GATEWAY_API_MANIFEST_PATH`, `ARGOCD_MANIFEST_PATH`에 로컬 파일 경로를 지정하세요.
