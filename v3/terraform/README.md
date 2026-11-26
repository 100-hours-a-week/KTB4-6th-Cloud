# V3 Terraform

서울 리전(ap-northeast-2)의 V3(EKS) 인프라 중 AWS 쪽 리소스를 관리한다. 클러스터 안의 컨트롤러와 워크로드는 Argo CD가 `v3/deploy/`로 관리한다(5단계 8번 배포 설계 7.1절).

## 폴더 구조

| 폴더 | 관리 대상 | state |
| --- | --- | --- |
| `cluster/` | EKS 전용 서브넷과 라우팅, AZ별 NAT 인스턴스, S3 게이트웨이 엔드포인트, 접속용 EC2, EKS 클러스터, `platform` 노드 그룹, 애드온, Pod Identity 연결, Karpenter의 AWS 쪽 리소스 | `cluster/terraform.tfstate` (로컬) |

- V2 VPC와 퍼블릭 서브넷은 `v2/terraform/shared`가 관리한다. 이 폴더는 data source로 조회만 한다.
- 폴더가 늘어나면 이 표에 추가한다.

## 자격 증명

V2와 같다(`v2/terraform/README.md`의 자격 증명 절).

```bash
aws login --profile meety-admin        # 세션이 만료됐을 때만
unset AWS_PROFILE
eval "$(aws configure export-credentials --profile meety-admin --format env)"
aws sts get-caller-identity --query Arn --output text
```

## 작업 방법

```bash
cd v3/terraform/cluster
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan      # 바뀔 내용 확인
terraform apply tfplan          # 확인한 plan만 반영
```

- apply 전에 plan의 `destroy`와 `must be replaced`를 반드시 확인한다.
- V2 리소스(`meety-v2-*`)가 plan에 나오면 멈추고 원인을 확인한다.

## 클러스터 접속

API는 비공개라 접속용 EC2(`meety-v3-bastion`)를 SSM으로 거친다. 접속 명령은 `terraform output -raw bastion_connect`로 본다.

```bash
# 접속용 EC2 안에서
bash -l                     # 로그인 셸로 열어 /etc/profile.d 설정을 읽는다
kubeconfig-v3               # aws eks update-kubeconfig 별칭
kubectl get nodes
```

## state 관리

- 지금은 로컬 파일이다. public 저장소라 Git에 올리지 않는다(`.gitignore`로 제외).
- S3 backend 도입은 1단계(클러스터 apply 전)에서 다시 검토한다.

## 기본 태그

provider의 `default_tags`로 모든 리소스에 붙는다. `Service = meety`는 반드시 유지한다.

| 태그 | 값 |
| --- | --- |
| `Service` | `meety` |
| `Project` | `meety` |
| `Version` | `v3` |
| `Env` | `shared` (환경별 리소스는 리소스에서 덮어쓴다) |
| `ManagedBy` | `terraform` |
