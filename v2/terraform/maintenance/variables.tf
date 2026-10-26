variable "maintenance_enabled" {
  description = "운영 전체 점검 여부. false일 때는 미리보기 헤더가 있는 요청에만 점검 규칙을 적용한다"
  type        = bool
  default     = false
}

variable "maintenance_domain" {
  description = "FE·BE 배포와 독립적으로 점검 화면을 제공할 도메인"
  type        = string
  default     = "maintenance.meety.io.kr"
}
