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

## 3) 실행 순서(가장 중요)

1. `scripts/gitops/config.env` 작성
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

- preflight에서 apt 설치가 실패함
  - 기본은 `AUTO_INSTALL_PREREQS=true`로 `apt-get install`을 시도합니다(온라인 필요).
  - 폐쇄망이면 `AUTO_INSTALL_PREREQS=false`로 두고, 필요한 패키지를 수동으로 설치한 뒤 진행하세요.
- Argo CD가 외부에서 접속 안됨
  - 보안그룹/방화벽에서 NodePort(기본 30443) 허용 확인
- GitLab이 “기동은 되는데 매우 느림”
  - 디스크/메모리 부족이 가장 흔함(특히 t3.small 급)
- Harbor가 HTTP인 경우 이미지 push/pull 실패
  - Docker(호스트) 및 k3s(containerd)에 insecure registry 설정이 필요할 수 있음
