# Kubernetes Gateway API + Argo CD 설치 가이드

목표: Kubernetes 클러스터에 **Gateway API CRD**를 설치하고, **Argo CD**를 배포합니다.

---

## 0) 준비 사항

- `kubectl` 설치
- 클러스터 접근 권한
- 자동 연결을 쓸 경우: `aws`(EKS) / `gcloud`(GKE) / `az`(AKS) CLI 준비

---

## 1) 설정 파일

기본 설정 파일은 이미 제공됩니다.

```bash
vi k8s-setup/scripts/config.env
```

필요하면 예시 파일로 “초기화”할 수 있습니다.

```bash
cp k8s-setup/scripts/config.env.example k8s-setup/scripts/config.env
```

주요 값(필요 시만 변경):

- `AUTO_CONNECT_K8S`, `KUBECONFIG`, `KUBE_CONTEXT`, `KUBERNETES_PROVIDER`
- `EKS_CLUSTER_NAME`, `AWS_REGION`
- `GKE_CLUSTER_NAME`, `GKE_PROJECT`, `GKE_LOCATION`, `GKE_LOCATION_TYPE`
- `AKS_CLUSTER_NAME`, `AKS_RESOURCE_GROUP`, `AZURE_SUBSCRIPTION_ID`
- `GATEWAY_API_VERSION`, `GATEWAY_API_MANIFEST_PATH/URL`
- `ARGOCD_VERSION`, `ARGOCD_NAMESPACE`, `ARGOCD_MANIFEST_PATH/URL`

---

## 2) 실행 순서

순서대로 실행:

```bash
bash k8s-setup/scripts/01_preflight.sh
bash k8s-setup/scripts/02_gateway_api.sh
bash k8s-setup/scripts/03_install_argocd.sh
```

한 번에 실행:

```bash
sudo bash k8s-setup/scripts/00_run_all.sh
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

- `k8s-setup/scripts/.secrets/argocd_initial_admin_password`

---

## 4) 참고 사항

- Gateway API는 **CRD 설치만** 수행합니다. 실제 트래픽 처리는 **Gateway API 컨트롤러**가 필요합니다.
  (예: AWS Gateway API Controller)
- 폐쇄망이면 `GATEWAY_API_MANIFEST_PATH`, `ARGOCD_MANIFEST_PATH`에 로컬 파일 경로를 지정하세요.
- 자동 연결은 실행 VM의 클라우드 메타데이터로 프로바이더를 감지합니다. 클러스터가 여러 개면
  `*_CLUSTER_NAME` 값을 반드시 지정하세요.
