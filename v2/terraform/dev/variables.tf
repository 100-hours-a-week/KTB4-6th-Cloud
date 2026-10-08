variable "project" {
  description = "리소스 이름과 태그에 쓰는 프로젝트 이름"
  type        = string
  default     = "meety"
}

variable "env" {
  description = "환경 이름. prod 폴더에서는 prod로 바꾼다"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "V2 리전 (V1은 us-east-2)"
  type        = string
  default     = "ap-northeast-2"
}
