terraform {
  required_version = ">= 1.16"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # state는 로컬 파일로 시작한다. V2 prod 구성(10/15) 전에 S3 backend로 옮긴다.
}
