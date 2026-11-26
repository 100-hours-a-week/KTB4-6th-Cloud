terraform {
  required_version = ">= 1.16"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # 0단계는 로컬 state로 시작한다. S3 backend 도입은 1단계(클러스터 apply 전)에서 다시 검토한다.
}
