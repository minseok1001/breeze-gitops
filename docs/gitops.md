# EC2 DevOps 체인 부트스트랩 (GitLab → Jenkins → Harbor)

목표: **EKS(GitOps/Argo CD)는 나중에** 붙이고, 지금은 EC2에서

- GitLab(소스/매니페스트 저장소)
- Jenkins(CI)
- Harbor(레지스트리)

까지 “한 줄(연동)”을 먼저 완성한다.

> 이미 GitLab/Harbor/Jenkins를 EC2에 설치했고, Route53 + ALB(호스트 기반)까지 구성했다면  
> 이 문서/스크립트는 “재설치”가 아니라 **연동 자동화**에 초점을 둡니다.

---

## 0) 준비(필수)

- Ubuntu 24.04 EC2
- `sudo` 가능
- 스크립트는 기본적으로 “서비스가 설치된 EC2에서 실행”을 가정합니다. (기본 `*_API_URL=http://127.0.0.1:<port>`)  
  다른 곳에서 실행하면 `scripts/gitops/config.env`의 `*_API_URL`을 외부 도메인으로 바꿔야 합니다.
- (권장) Route53 + ALB 도메인
  - `gitops-gitlab.breezelab.io`
  - `gitops-harbor.breezelab.io`
  - `gitops-jenkins.breezelab.io`

---

## 1) 실행 순서(번호 순서 고정)

1) 설정 파일 생성/수정

```bash
cp scripts/gitops/config.env.example scripts/gitops/config.env
vi scripts/gitops/config.env
```

2) 사전 점검(필수 패키지 자동 설치 포함)

```bash
bash scripts/gitops/01_preflight.sh
```

3) Docker 설치(EC2에 Docker가 없으면)

```bash
bash scripts/gitops/02_install_docker.sh
```

4) (선택) 서비스 배포(이미 설치되어 있으면 스킵 가능)

```bash
bash scripts/gitops/03_deploy_gitlab.sh
bash scripts/gitops/04_deploy_harbor.sh
bash scripts/gitops/05_deploy_jenkins.sh
```

> `04_deploy_harbor.sh`는 기본값으로 Harbor 오프라인 installer(v2.14.1)를 GitHub에서 다운로드해 설치합니다.  
> 폐쇄망이면 `scripts/gitops/config.env`의 `HARBOR_OFFLINE_TGZ_PATH`에 tgz 파일 경로를 직접 지정하세요.

5) 파이프라인 연동(핵심)

```bash
bash scripts/gitops/06_setup_harbor_project.sh   # Harbor 프로젝트 + robot 생성
bash scripts/gitops/07_seed_demo_app_repo.sh     # GitLab 데모 리포 생성/시드(Dockerfile/Jenkinsfile)
bash scripts/gitops/08_setup_jenkins_job.sh      # Jenkins 크리덴셜 + 파이프라인 Job 생성
bash scripts/gitops/09_setup_gitlab_webhook.sh   # GitLab Webhook → Jenkins 트리거 연결
```

6) 검증

```bash
bash scripts/gitops/10_verify.sh
```

---

## 2) Jenkins 인증 정보는 어디서 구하나?

- `08_setup_jenkins_job.sh`는 Jenkins API 호출이 필요해서 `JENKINS_USER`/`JENKINS_API_TOKEN`이 필요합니다.
- Jenkins UI → 사용자 → `Configure` → `API Token`에서 생성 후 `scripts/gitops/config.env`에 입력하세요.

---

## 3) 자주 막히는 지점(짧게)

- GitLab Webhook이 Jenkins에 도달 못함
  - ALB Target Group 헬스체크/포트(예: 8081) 확인
  - EC2 보안그룹: **ALB 보안그룹 → EC2 인스턴스 포트** 인바운드 허용 필요
- Jenkins가 Docker 빌드를 못함
  - Jenkins가 호스트 Docker를 쓸 수 있어야 함(`/var/run/docker.sock` 권한)
  - Docker로 Jenkins를 띄우는 경우 `05_deploy_jenkins.sh` 옵션(`JENKINS_ENABLE_DOCKER_SOCKET=true`) 사용
- Harbor push 실패
  - ALB가 HTTPS로 노출되어 있지 않으면 Docker에서 insecure registry 설정이 필요할 수 있음

---

## 4) 다음 단계(나중에)

- EKS 생성/접속 구성
- EKS에 Argo CD 설치
- Jenkins 결과물(Harbor 이미지)을 GitOps 리포(매니페스트)로 연결
