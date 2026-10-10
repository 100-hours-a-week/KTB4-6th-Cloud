# shared/가 만든 공용 리소스(VPC, 서브넷, ALB)의 값을 읽어 온다.
# state를 S3로 옮기면(10/15) backend와 config만 바꾼다.
data "terraform_remote_state" "shared" {
  backend = "local"

  config = {
    path = "${path.module}/../shared/terraform.tfstate"
  }
}

locals {
  shared = data.terraform_remote_state.shared.outputs
}

# IAM 정책에서 Parameter Store 경로의 ARN을 만들 때 계정 ID를 코드에 쓰지 않기 위해 조회한다
data "aws_caller_identity" "current" {}

# SecureString 기본 암호화 키(AWS 관리형). DB 인스턴스와 ECS가 비밀값을 복호화할 때 쓴다
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}
