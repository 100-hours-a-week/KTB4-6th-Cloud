variable "project" {
  description = "리소스 이름과 태그에 쓰는 프로젝트 이름"
  type        = string
  default     = "meety"
}

variable "region" {
  description = "V3 리전. V2와 같은 서울 리전의 VPC를 함께 쓴다"
  type        = string
  default     = "ap-northeast-2"
}

variable "azs" {
  description = "클러스터가 쓰는 가용 영역. V2 VPC의 퍼블릭 서브넷이 있는 2개와 같아야 한다 (5단계 4번 네트워크 설계 4장)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}
