# 자격 증명은 환경 변수로 주입한다.
#   eval "$(aws configure export-credentials --profile meety-ro --format env)"
provider "aws" {
  region = "us-east-2"
}
