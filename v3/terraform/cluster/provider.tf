# 자격 증명은 환경 변수로 주입한다 (v3/terraform/README.md 참고).
provider "aws" {
  region = var.region

  # 모든 리소스에 붙는 공통 태그. V2와 같은 키를 쓰고 Version만 v3로 구분한다.
  # default_tags가 붙지 않는 리소스(EKS 노드의 EC2와 볼륨 등)는 만들 때 따로 지정한다.
  default_tags {
    tags = {
      Service   = "meety"
      Project   = var.project
      Version   = "v3"
      Env       = "shared"
      ManagedBy = "terraform"
    }
  }
}
