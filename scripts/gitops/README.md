# EC2 DevOps 체인 스크립트 묶음

목표: 단일 EC2에서 **GitLab → Jenkins → Harbor**를 올리고, 파이프라인(웹훅/크리덴셜/데모 리포)까지 연결합니다.

## GitLab 주의(중요)

- GitLab은 초기 설치/마이그레이션으로 **10~30분 이상** 걸릴 수 있습니다.
- 최소 4GB RAM(권장 8GB+)을 권장합니다. 메모리가 작으면 `unhealthy/502`가 반복될 수 있습니다.
- 기본 배포는 “최소 구성”입니다(볼륨/추가 설정 최소화). 데이터 유지를 원하면 `GITLAB_PERSIST_DATA=true`를 사용하세요.

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
bash 05_deploy_jenkins.sh
bash 06_setup_harbor_project.sh
bash 07_seed_demo_app_repo.sh
bash 08_setup_jenkins_job.sh
bash 09_setup_gitlab_webhook.sh
bash 10_verify.sh
```

## 2) 파일/디렉토리 설명

- `config.env` : 사용자 설정(커밋 금지)
- `.secrets/` : 비밀번호/토큰 등 비밀(커밋 금지)
- `.state/` : 생성된 리소스 ID/URL 등 상태 파일
- `.logs/` : 실행 로그

## 3) Docker 설치 관련(자주 발생)

- Ubuntu 24.04에서는 `docker-compose-plugin` 패키지가 없을 수 있어 `docker-compose-v2`를 우선 설치합니다.
- `02_install_docker.sh`는 “ubuntu 패키지 설치 실패” 시 Docker 공식 APT repo 설치를 자동으로 재시도합니다.
- Docker 설치 직후에는 현재 세션에 `docker` 그룹이 반영되지 않아 `docker ps`가 실패할 수 있습니다.
  - 해결: **SSH 재접속(권장)** 또는 `newgrp docker` 후 다시 시도하세요.

## 4) Jenkins 관련(자주 발생)

- `08_setup_jenkins_job.sh`는 Jenkins API Token이 필요합니다(`config.env`의 `JENKINS_USER/JENKINS_API_TOKEN`).
- Jenkins가 Docker 빌드를 못하면(권한 문제) `05_deploy_jenkins.sh`의 소켓 마운트 옵션 및 docker 그룹 권한을 확인하세요.
