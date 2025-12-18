# EC2 DevOps 체인 부트스트랩 (GitLab → Jenkins → Harbor)

목표: **EKS(GitOps/Argo CD)는 나중에** 붙이고, 지금은 EC2에서

- GitLab(소스/매니페스트 저장소)
- Jenkins(CI)
- Harbor(레지스트리)

까지 “한 줄(연동)”을 먼저 완성합니다.

이 문서가 끝났을 때 기대하는 상태는 아래처럼 딱 한 가지입니다.

- 개발자가 GitLab에 푸시한다
- GitLab Webhook이 Jenkins Job을 트리거한다
- Jenkins가 Docker 이미지를 빌드하고 Harbor로 push 한다
- Harbor에 결과 이미지가 남는다(= 다음 단계로 EKS/Argo CD가 받아먹을 준비 완료)

> 이미 GitLab/Harbor/Jenkins를 EC2에 설치했고, Route53 + ALB(호스트 기반)까지 구성했다면  
> 이 문서/스크립트는 “재설치”가 아니라 **연동 자동화**에 초점을 둡니다.

---

## 0) 준비(필수)

- Ubuntu 24.04 EC2
- `sudo` 가능
- 스크립트는 기본적으로 “서비스가 설치된 EC2에서 실행”을 가정합니다. (기본 `*_API_URL=http://127.0.0.1:<port>`)  
  다른 곳(로컬 PC 등)에서 실행하면 `scripts/gitops/config.env`의 `*_API_URL`을 외부 도메인으로 바꿔야 합니다.
- (권장) Route53 + ALB 도메인
  - `gitops-gitlab.breezelab.io`
  - `gitops-harbor.breezelab.io`
  - `gitops-jenkins.breezelab.io`
- (중요) `ENABLE_*` 값은 “배포 여부”가 아니라 “이 체인에서 사용할지 여부”로 생각해 주세요.  
  예) GitLab을 이미 수동 설치했어도 **파이프라인 연동(07/09)을 하려면 `ENABLE_GITLAB=true`**가 필요합니다.
- (중요) `*_EXTERNAL_URL` vs `*_API_URL`
  - `*_EXTERNAL_URL` : 사람이 브라우저로 접속하는 주소, GitLab Webhook이 호출하는 주소(= 도메인/ALB)
  - `*_API_URL` : 스크립트가 API 호출할 주소(= 같은 EC2에서 실행이면 `127.0.0.1`가 가장 단순)

### (참고) AWS 보안그룹 인바운드(자주 막히는 포인트)

ALB를 쓰는 구조라면 **인터넷 → EC2 포트(8080/8081/8084)를 직접 열기보다**, 아래처럼 “ALB → EC2”만 열어두는 게 일반적으로 안전합니다.

- ALB 보안그룹(Inbound)
  - `HTTPS 443` : `0.0.0.0/0` (또는 사내/내 IP 대역)
- EC2 인스턴스 보안그룹(Inbound)
  - `Custom TCP 8080` : **Source = ALB 보안그룹**
  - `Custom TCP 8081` : **Source = ALB 보안그룹**
  - `Custom TCP 8084` : **Source = ALB 보안그룹**
  - (선택) `Custom TCP 2222` : Source = 내 공인 IP(`/32`) (GitLab SSH를 쓸 때만)

AWS 콘솔에서 설정하는 위치:

- `EC2` → `Security Groups` → (대상 SG 선택) → `Inbound rules` → `Edit inbound rules` → `Add rule`

---

## 1) 실행 순서(번호 순서 고정)

1) 설정 파일 생성/수정

```bash
cp scripts/gitops/config.env.example scripts/gitops/config.env
vi scripts/gitops/config.env
```

설정에서 “최소로 꼭 채워야 하는 값”만 뽑으면 보통 아래입니다.

- GitLab: `ENABLE_GITLAB=true`, `GITLAB_TOKEN`(api scope), `GITLAB_API_URL`
- Harbor: `ENABLE_HARBOR=true`, `HARBOR_ADMIN_PASSWORD`, `HARBOR_REGISTRY_HOSTPORT`, `HARBOR_API_URL`
- Jenkins: `ENABLE_JENKINS=true`, `JENKINS_USER`, `JENKINS_API_TOKEN`, `JENKINS_API_URL`

2) 사전 점검(필수 패키지 자동 설치 포함)

```bash
bash scripts/gitops/01_preflight.sh
```

3) Docker 설치(EC2에 Docker가 없으면)

```bash
bash scripts/gitops/02_install_docker.sh
```

4) (선택) 서비스 배포(“스크립트로 새로 설치”할 때만)

이미 GitLab/Harbor/Jenkins를 EC2에 설치해둔 상태라면 **이 단계는 건너뛰는 걸 권장**합니다.  
특히 다른 방식으로 설치해둔 서비스가 있으면, 여기서 Docker/설정이 덮여 충돌할 수 있습니다.

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

> `07_seed_demo_app_repo.sh`가 만드는 `Jenkinsfile`은 `git rev-parse` 같은 git CLI를 쓰지 않고, Jenkins가 제공하는 `GIT_COMMIT` 환경변수로 이미지 태그를 만듭니다.  
> 그래서 Jenkins 컨테이너에 git 패키지가 없어도(최소 설치) 파이프라인이 동작하는 쪽으로 맞춰져 있습니다.

각 단계가 만들어내는 “산출물”을 알고 있으면 재실행/복구가 쉬워집니다.

- 06 실행 후: `scripts/gitops/.secrets/harbor_robot.json` (Harbor robot 계정)
- 07 실행 후: `scripts/gitops/.state/gitlab_demo_app_project.json` (데모 리포 정보)
- 08 실행 후: `scripts/gitops/.secrets/jenkins_job_token` (Webhook 트리거 토큰)

6) 검증

```bash
bash scripts/gitops/10_verify.sh
```

---

## 2) GitLab 토큰은 어디서 구하나?

- `07_seed_demo_app_repo.sh`/`09_setup_gitlab_webhook.sh`는 GitLab API 호출이 필요해서 `GITLAB_TOKEN`이 필요합니다.
- GitLab에서 Personal Access Token(PAT)을 만들고, `scripts/gitops/config.env`에 넣어주시면 됩니다.

1) GitLab 토큰 생성 페이지로 이동

- 예) `https://gitops-gitlab.breezelab.io/-/user_settings/personal_access_tokens`

2) 아래처럼 생성(권장)

- Name: `bootstrap`
- Scopes: `api` (필수)

3) 생성된 토큰을 `scripts/gitops/config.env`에 입력

```bash
GITLAB_TOKEN="glpat-xxxxxxxxxxxxxxxx"
```

> 토큰은 생성 직후 1번만 보여주는 경우가 많습니다. 복사해두지 않으면 다시 볼 수 없으니 바로 저장해 주세요.

---

## 3) Jenkins 인증 정보는 어디서 구하나?

- `08_setup_jenkins_job.sh`는 Jenkins API 호출이 필요해서 `JENKINS_USER`/`JENKINS_API_TOKEN`이 필요합니다.
- Jenkins UI에서 최초 1회 설정이 안 끝났다면, 먼저 웹에서 초기 설정을 완료해 주세요(플러그인 포함).
- Jenkins UI → 사용자 → `Configure` → `API Token`에서 생성 후 `scripts/gitops/config.env`에 입력하세요.

추가로, `08_setup_jenkins_job.sh`는 자동화를 위해 Jenkins Script Console(`.../script`)을 사용합니다.  
보안 정책상 Script Console이 막혀있는 Jenkins라면 이 단계는 실패할 수 있고, 그 경우엔 UI에서 수동으로 Job/크리덴셜을 만들어야 합니다.

---

## 4) 자주 막히는 지점(짧게)

- GitLab Webhook이 Jenkins에 도달 못함
  - ALB Target Group 헬스체크/포트(예: 8081) 확인
  - EC2 보안그룹: **ALB 보안그룹 → EC2 인스턴스 포트** 인바운드 허용 필요
  - GitLab 프로젝트 → Settings → Webhooks 에서 “Test”로 바로 확인 가능
- Jenkins가 Docker 빌드를 못함
  - Jenkins가 호스트 Docker를 쓸 수 있어야 함(`/var/run/docker.sock` 권한)
  - Docker로 Jenkins를 띄우는 경우 `05_deploy_jenkins.sh` 옵션(`JENKINS_ENABLE_DOCKER_SOCKET=true`) 사용
- Harbor push 실패
  - ALB가 HTTPS로 노출되어 있지 않으면 Docker에서 insecure registry 설정이 필요할 수 있음
  - Jenkins 노드(=빌드가 실행되는 곳)에서 `docker login <HARBOR_REGISTRY_HOSTPORT>`가 되는지 먼저 확인하면 빠릅니다.
- Harbor 설치 중 `KeyError: 'max_job_workers'`로 실패
  - `harbor.yml`에 `jobservice.max_job_workers`가 없을 때 발생할 수 있습니다.
  - 현재 스크립트(`04_deploy_harbor.sh`)는 `harbor.yml`을 “최소 구성”으로 직접 생성하며, `jobservice.max_job_workers`를 기본 포함합니다.
- Harbor 설치 중 `The protocol is https but attribute ssl_cert is not set`
  - `HARBOR_PROTOCOL=https`인데 인증서 경로(`HARBOR_SSL_CERT_PATH/HARBOR_SSL_KEY_PATH`)가 비어 있으면 발생합니다.
  - ALB에서 TLS(HTTPS)를 종료하는 구조라면 보통 `HARBOR_PROTOCOL=http`가 더 단순합니다.

---

## 5) 다음 단계(나중에)

- EKS 생성/접속 구성
- EKS에 Argo CD 설치
- Jenkins 결과물(Harbor 이미지)을 GitOps 리포(매니페스트)로 연결
