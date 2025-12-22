# GitOps Bootstrap

이 저장소는 다음 두 흐름을 분리해서 제공합니다.

- **EC2 DevOps 체인**: GitLab → Jenkins → Harbor (연동까지 자동화)
- **EKS 설치**: Gateway API CRD + Argo CD

## 디렉토리 구조

- `ec2-setup/` : EC2 DevOps 체인 스크립트/문서
- `eks-setup/` : EKS Gateway API + Argo CD 스크립트/문서

## EC2 빠른 시작

1) 설정 파일 작성

```bash
vi ec2-setup/scripts/gitops/config.env
```

> `ec2-setup/scripts/gitops/config.env`는 기본으로 제공되며(gitignore 대상), 필요한 값만 채워서 사용합니다.  
> 예시 파일로 “초기화”하고 싶으면 아래를 실행하세요.
>
> ```bash
> cp ec2-setup/scripts/gitops/config.env.example ec2-setup/scripts/gitops/config.env
> ```

2) 스크립트 순서대로 실행(번호 순, Jenkins까지)

```bash
bash ec2-setup/scripts/gitops/01_preflight.sh
bash ec2-setup/scripts/gitops/02_install_docker.sh
bash ec2-setup/scripts/gitops/03_deploy_gitlab.sh          # 선택(이미 설치돼 있으면 스킵 가능)
bash ec2-setup/scripts/gitops/04_deploy_harbor.sh          # 선택(이미 설치돼 있으면 스킵 가능)
bash ec2-setup/scripts/gitops/05_deploy_jenkins.sh         # 선택(이미 설치돼 있으면 스킵 가능)
bash ec2-setup/scripts/gitops/06_setup_harbor_project.sh   # Harbor 프로젝트 + robot 생성
bash ec2-setup/scripts/gitops/07_seed_demo_app_repo.sh     # GitLab 데모 리포 생성/시드
bash ec2-setup/scripts/gitops/08_setup_jenkins_job.sh      # Jenkins 크리덴셜 + 파이프라인 Job 생성
bash ec2-setup/scripts/gitops/09_setup_gitlab_webhook.sh   # GitLab Webhook → Jenkins 트리거 연결
bash ec2-setup/scripts/gitops/10_verify.sh
```

또는 한 번에 실행:

```bash
sudo bash ec2-setup/scripts/gitops/00_run_all.sh
```

> GitLab/Harbor/Jenkins는 기본값이 활성화되어 있습니다. 끄려면 `ec2-setup/scripts/gitops/config.env`에서 `ENABLE_*="false"`로 변경하세요.

## 신규 인스턴스(깨끗한 Ubuntu)에서 주의

- `ec2-setup/scripts/gitops/01_preflight.sh`는 기본값으로 필수 패키지(`curl/jq/openssl/git` 등)를 `apt-get`으로 설치하려고 시도합니다.
- 폐쇄망이면 `ec2-setup/scripts/gitops/config.env`에서 `AUTO_INSTALL_PREREQS=false`로 두고, 필요한 패키지를 수동 설치 후 진행하세요.
- Ubuntu 24.04에서는 `docker-compose-plugin` 패키지가 없을 수 있어, `ec2-setup/scripts/gitops/02_install_docker.sh`가 `docker-compose-v2`를 우선 사용합니다.
- GitLab은 초기 기동이 오래 걸리고(10~30분+), 최소 4GB RAM(권장 8GB+)이 필요합니다.
- `08_setup_jenkins_job.sh`는 Jenkins API Token이 필요합니다(`ec2-setup/scripts/gitops/config.env`의 `JENKINS_USER/JENKINS_API_TOKEN`).

## 문서

- `ec2-setup/docs/gitops.md` : 전체 실행 가이드(짧게)
- `ec2-setup/scripts/gitops/README.md` : 스크립트 설명/주의사항

## EKS 빠른 시작

```bash
vi eks-setup/scripts/config.env
sudo bash eks-setup/scripts/00_run_all.sh
```

## EKS 문서

- `eks-setup/docs/eks.md`
