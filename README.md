# GitOps Lab (최소 구성)

이 저장소는 “올인원 DevOps 실험실”에서 **GitOps에 필요한 것만** 빠르게 구성하기 위한 문서/스크립트를 제공합니다.

## 구성(필수/선택)

- 필수: `k3s`(단일 노드 Kubernetes) + `Argo CD`
- 선택: `GitLab`(Git 저장소) / `Harbor`(이미지 레지스트리)

## 빠른 시작

1) 설정 파일 작성

```bash
cp scripts/gitops/config.env.example scripts/gitops/config.env
vi scripts/gitops/config.env
```

2) 스크립트 순서대로 실행(번호 순)

```bash
bash scripts/gitops/01_preflight.sh
bash scripts/gitops/02_install_docker.sh
bash scripts/gitops/03_deploy_gitlab.sh     # 선택
bash scripts/gitops/04_deploy_harbor.sh     # 선택
bash scripts/gitops/05_install_k3s.sh
bash scripts/gitops/06_install_argocd.sh
bash scripts/gitops/07_bootstrap_git_repo.sh # 선택( GitLab 사용 시 )
bash scripts/gitops/08_bootstrap_argocd.sh
bash scripts/gitops/09_verify.sh
```

## 신규 인스턴스(깨끗한 Ubuntu)에서 주의

- `scripts/gitops/01_preflight.sh`는 기본값으로 필수 패키지(`curl/jq/openssl/git` 등)를 `apt-get`으로 설치하려고 시도합니다.
- 폐쇄망이면 `scripts/gitops/config.env`에서 `AUTO_INSTALL_PREREQS=false`로 두고, 필요한 패키지를 수동 설치 후 진행하세요.
- Ubuntu 24.04에서는 `docker-compose-plugin` 패키지가 없을 수 있어, `scripts/gitops/02_install_docker.sh`가 `docker-compose-v2`를 우선 사용합니다.
- GitLab은 초기 기동이 오래 걸리고(10~30분+), 최소 4GB RAM(권장 8GB+)이 필요합니다.

## 문서

- `docs/gitops.md` : 전체 실행 가이드(짧게)
- `scripts/gitops/README.md` : 스크립트 설명/주의사항
