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
