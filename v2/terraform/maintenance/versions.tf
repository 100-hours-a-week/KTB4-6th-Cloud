terraform {
  required_version = ">= 1.16"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# 점검 전용 state로 분리해 점검 전환 시 서비스 배포 리소스가 함께 변경되지 않게 한다.
provider "aws" {
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Service   = "meety"
      Project   = "meety"
      Version   = "v2"
      Env       = "maintenance"
      ManagedBy = "terraform"
    }
  }
}

# CloudFront의 사용자 HTTPS 인증서는 버지니아 북부 리전에 발급한다.
provider "aws" {
  alias  = "certificate"
  region = "us-east-1"

  default_tags {
    tags = {
      Service   = "meety"
      Env       = "maintenance"
      ManagedBy = "terraform"
    }
  }
}
