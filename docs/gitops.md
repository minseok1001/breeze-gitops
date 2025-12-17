# GitOps 최소 구성 가이드 (Ubuntu 24.04 단일 서버)

목표: **k3s + Argo CD**를 기준으로 GitOps 배포가 가능한 최소 구성을 만든다.  
선택적으로 **GitLab(코드/매니페스트 저장소)**, **Harbor(레지스트리)**까지 같은 서버에 올릴 수 있다.

## 0) 전제

- OS: Ubuntu 24.04 (EC2 등)
- 권한: sudo 가능
- 네트워크:
  - 온라인 설치면 패키지/설치 스크립트 다운로드가 필요
  - 폐쇄망이면 Docker/k3s/Argo CD 설치 파일을 별도로 준비해야 함(이 문서는 온라인 기준)

## 1) 설치/배포되는 것(최소)

- Kubernetes: k3s (단일 노드)
- GitOps: Argo CD (k3s 내부에 설치)

## 2) 선택 구성

- Git 저장소: GitLab (Docker 컨테이너)
- 레지스트리: Harbor (오프라인 installer 기반 설치 권장)

## 2.1) GitLab 리소스 가이드(중요)

- GitLab은 초기 설치/DB 마이그레이션 때문에 **처음 기동이 오래 걸릴 수 있습니다(10~30분+)**.
- 최소 4GB RAM, 권장 8GB+ 입니다. 메모리가 작으면 `unhealthy/502`가 반복될 수 있습니다.

## 2.2) GitLab 배포 모드(중요)

- 기본은 “최소 구성”으로 띄웁니다(볼륨/추가 설정 최소화 → 실패 확률 낮음).
- 데이터 유지가 필요하면 `scripts/gitops/config.env`에서 `GITLAB_PERSIST_DATA=true`로 켜세요.
- GitLab 링크/클론 URL이 이상하면 `GITLAB_APPLY_OMNIBUS_CONFIG=true`로 켜고, 필요 시 `GITLAB_EXTERNAL_URL`에 공인 IP/도메인을 넣으세요.

## 3) 실행 순서(가장 중요)

1. `scripts/gitops/config.env` 작성 (`config.env.example`를 수정하는 게 아니라, 꼭 `config.env`를 생성/수정)
2. `01_preflight.sh` (환경 점검 + 신규 인스턴스 필수 패키지 설치 점검)
3. `02_install_docker.sh` (Docker 없으면 설치)
4. `03_deploy_gitlab.sh` (선택)
5. `04_deploy_harbor.sh` (선택)
6. `05_install_k3s.sh`
7. `06_install_argocd.sh`
8. `07_bootstrap_git_repo.sh` (선택: GitLab에 데모 GitOps 리포 생성/시드)
9. `08_bootstrap_argocd.sh` (Argo CD에 리포 등록 + Application 생성)
10. `09_verify.sh`

## 4) 접속/확인 포인트

- Argo CD:
  - 기본은 NodePort로 노출(예: `https://<SERVER_IP>:30443`)
  - 초기 비밀번호는 스크립트가 `scripts/gitops/.secrets/`에 저장(터미널 출력 최소화)
- k3s:
  - `kubectl get nodes` 로 노드 Ready 확인
- GitLab/Harbor(선택):
  - 포트/URL은 `config.env`에서 변경 가능

## 5) 가장 흔한 이슈

- GitLab이 `unhealthy`이고 502(badgateway)가 계속 뜸
  - 대부분 메모리 부족/초기 마이그레이션 지연입니다. 먼저 `free -h`로 메모리 확인 후 충분히 기다려보세요.
  - 계속 실패하면 `docker exec -it gitlab gitlab-ctl status` 및 `gitlab-ctl tail puma`로 원인 확인이 필요합니다.
  - PostgreSQL이 shared memory 관련으로 죽는 경우가 있어, `GITLAB_SHM_SIZE=1g` 이상으로 올려 재시도해볼 수 있습니다.
  - 이전 데이터(볼륨)가 꼬인 경우, `GITLAB_PERSIST_DATA=false`(최소 구성)로 먼저 확인하거나 `DATA_DIR/gitlab` 초기화가 필요할 수 있습니다.
- Docker 설치에서 `docker-compose-plugin`을 찾지 못함
  - Ubuntu 24.04에서 흔한 케이스이며, 스크립트는 `docker-compose-v2`를 우선 설치하도록 되어 있습니다.
- preflight에서 apt 설치가 실패함
  - 기본은 `AUTO_INSTALL_PREREQS=true`로 `apt-get install`을 시도합니다(온라인 필요).
  - 폐쇄망이면 `AUTO_INSTALL_PREREQS=false`로 두고, 필요한 패키지를 수동으로 설치한 뒤 진행하세요.
- Argo CD가 외부에서 접속 안됨
  - 보안그룹/방화벽에서 NodePort(기본 30443) 허용 확인
- GitLab이 “기동은 되는데 매우 느림”
  - 디스크/메모리 부족이 가장 흔함(특히 t3.small 급)
- Harbor가 HTTP인 경우 이미지 push/pull 실패
  - Docker(호스트) 및 k3s(containerd)에 insecure registry 설정이 필요할 수 있음
