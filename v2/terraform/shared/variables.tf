variable "project" {
  description = "리소스 이름과 태그에 쓰는 프로젝트 이름"
  type        = string
  default     = "meety"
}

variable "region" {
  description = "V2 리전 (V1은 us-east-2)"
  type        = string
  default     = "ap-northeast-2"
}

variable "vpc_cidr" {
  description = "V2 VPC 대역. V1(10.0.0.0/16)과 겹치지 않아야 리전 간 연결이 가능하다"
  type        = string
  default     = "10.1.0.0/16"
}

variable "v1_region" {
  description = "V1 리전. V1 VPC와 피어링할 때 쓴다"
  type        = string
  default     = "us-east-2"
}

variable "v1_vpc_id" {
  description = "V1 VPC ID. V1에서 V2로 DB를 복제하기 위해 피어링한다"
  type        = string
  default     = "vpc-0cd787f082879815e"
}

variable "azs" {
  description = "서브넷을 만들 가용 영역. ALB는 2개 이상이 필요하다"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "staging_domains" {
  description = "V2 staging 인증서에 넣을 도메인. 첫 번째가 대표 이름이다 (BE, FE 순서)"
  type        = list(string)
  default     = ["api-staging.meety.io.kr", "staging.meety.io.kr"]
}

variable "prod_domains" {
  description = "V2 prod 인증서에 넣을 도메인. 첫 번째가 대표 이름이다 (BE, FE 순서)"
  type        = list(string)
  default     = ["api.meety.io.kr", "meety.io.kr"]
}

variable "monitoring_domains" {
  description = "Grafana 인증서에 넣을 도메인 (staging, prod). prod Grafana를 만들 때 인증서를 다시 발급하지 않도록 함께 넣는다"
  type        = list(string)
  default     = ["grafana-staging.meety.io.kr", "grafana.meety.io.kr"]
}

variable "dev_domains" {
  description = "V1 dev 이전 리허설 인증서에 넣을 도메인. 첫 번째가 대표 이름이다 (BE, FE 순서)"
  type        = list(string)
  default     = ["api-dev.meety.io.kr", "dev.meety.io.kr"]
}
