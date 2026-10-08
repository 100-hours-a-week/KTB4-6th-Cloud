# V2 Terraform

서울 리전(ap-northeast-2)의 V2 인프라를 관리한다. V1(오하이오, `v1/terraform`)과 코드와 state가 완전히 분리되어 있어서, 이 폴더의 작업은 V1 리소스를 변경할 수 없다.

## 폴더 구조

| 폴더 | 관리 대상 | state |
| --- | --- | --- |
| `shared/` | staging과 prod가 같이 쓰는 리소스: VPC, 서브넷, ALB, ACM 인증서 | `shared/terraform.tfstate` |
| `staging/` | V2 staging 전용 리소스: ECS 클러스터와 서비스, DB, Parameter Store, 보안 그룹 | `staging/terraform.tfstate` |
| `prod/` | V2 prod 전용 리소스. 10/15에 `staging/`을 바탕으로 만든다 | `prod/terraform.tfstate` |

폴더마다 state가 따로라서 `staging/`에서 apply해도 `shared/`와 `prod/`는 바뀌지 않는다. 공통 코드는 `prod/`를 만들 때 모듈로 정리한다.

**실행 순서:** `shared/` → `staging/` (`staging/`은 `shared/`가 만든 VPC와 ALB를 사용한다)

## 자격 증명

V2는 리소스를 새로 만들기 때문에 쓰기 권한(`meety-admin`)이 필요하다. V1 import 때 쓴 `meety-ro`(읽기 전용)로는 apply가 거부된다.

```bash
aws login --profile meety-admin        # 세션이 만료됐을 때만
unset AWS_PROFILE
eval "$(aws configure export-credentials --profile meety-admin --format env)"
aws sts get-caller-identity --query Arn --output text
```

`AWS_PROFILE`이 남아 있으면 Terraform이 환경 변수 대신 프로필을 쓰려다 실패하므로 먼저 `unset`한다. 임시 자격 증명은 1시간 정도 지나면 만료되니, `ExpiredToken` 오류가 나면 `eval` 줄을 다시 실행한다.

## 작업 방법

```bash
cd v2/terraform/shared          # 또는 staging
terraform init                  # 처음 한 번, provider 버전을 바꿨을 때
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan      # 바뀔 내용 확인
terraform apply tfplan          # 확인한 plan만 반영
```

- apply 전에 plan의 `destroy`와 `must be replaced`를 반드시 확인한다.
- plan 결과의 리전이 `ap-northeast-2`인지 확인한다.

## state 관리

- state는 로컬 파일이다. **V2 prod 구성(10/15) 전에 S3 backend로 옮긴다.**
- public 저장소라 state를 Git에 올릴 수 없다(`.gitignore`로 제외). 로컬 파일이 사라지면 리소스를 다시 import해야 하므로, **apply한 뒤에는 `terraform.tfstate`를 Git이 아닌 개인 저장소에 복사해 둔다.**

## 기본 태그

provider의 `default_tags`로 모든 리소스에 아래 태그가 붙는다. `Service = meety`는 V1부터 쓰던 태그라 반드시 유지한다.

`default_tags`가 자동으로 붙지 않는 경우가 있어서, 해당 리소스를 만들 때 따로 설정한다.

- ECS 서비스가 띄우는 태스크: 서비스에 `propagate_tags` 설정
- EC2가 함께 만드는 루트 볼륨: `volume_tags` 또는 `root_block_device`의 태그 설정

| 태그 | 값 |
| --- | --- |
| `Service` | `meety` |
| `Project` | `meety` |
| `Version` | `v2` |
| `Env` | `shared`, `staging`, `prod` |
| `ManagedBy` | `terraform` |
