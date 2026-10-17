# 자격 증명은 환경 변수로 주입한다 (README 참고).
provider "aws" {
  region = var.region

  # 모든 리소스에 붙는 공통 태그. 콘솔과 비용 화면에서 V1/V2, 환경을 구분하는 기준이다.
  default_tags {
    tags = {
      Service   = "meety"
      Project   = var.project
      Version   = "v2"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}
