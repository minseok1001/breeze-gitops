# GitOps 스크립트 묶음

목표: 단일 서버에서 **GitOps에 필요한 최소 구성(k3s + Argo CD)**만 빠르게 올립니다.  
필요하면 GitLab/Harbor도 같이 올릴 수 있습니다(옵션).

## GitLab 주의(중요)

- GitLab은 초기 설치/마이그레이션으로 **10~30분 이상** 걸릴 수 있습니다.
- 최소 4GB RAM(권장 8GB+)을 권장합니다. 메모리가 작으면 `unhealthy/502`가 반복될 수 있습니다.

## 0) 설정

```bash
cp config.env.example config.env
vi config.env
```

### 신규 인스턴스에서 필수 패키지 자동 설치

- 기본값은 `AUTO_INSTALL_PREREQS=true`이며, `01_preflight.sh`에서 `apt-get install`을 시도합니다(온라인 필요).
- 폐쇄망이면 `AUTO_INSTALL_PREREQS=false`로 두고, `curl/jq/openssl/git` 등을 수동 설치한 뒤 진행하세요.

## 1) 실행 순서(번호 순서 고정)

```bash
bash 01_preflight.sh
bash 02_install_docker.sh
bash 03_deploy_gitlab.sh
bash 04_deploy_harbor.sh
bash 05_install_k3s.sh
bash 06_install_argocd.sh
bash 07_bootstrap_git_repo.sh
bash 08_bootstrap_argocd.sh
bash 09_verify.sh
```

## 2) 파일/디렉토리 설명

- `config.env` : 사용자 설정(커밋 금지)
- `.secrets/` : 비밀번호/토큰 등 비밀(커밋 금지)
- `.state/` : 생성된 리소스 ID/URL 등 상태 파일
- `.logs/` : 실행 로그

## 3) Docker 설치 관련(자주 발생)

- Ubuntu 24.04에서는 `docker-compose-plugin` 패키지가 없을 수 있어 `docker-compose-v2`를 우선 설치합니다.
- `02_install_docker.sh`는 “ubuntu 패키지 설치 실패” 시 Docker 공식 APT repo 설치를 자동으로 재시도합니다.
