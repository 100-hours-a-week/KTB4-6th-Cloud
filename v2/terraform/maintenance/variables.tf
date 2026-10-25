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

variable "maintenance_allowed_cidrs" {
  description = "점검 중 실제 서비스 이용을 허용할 공인 IP. 실시간 규칙의 조건 개수 제한으로 현재 CIDR 1개를 지원한다"
  type        = list(string)
  default     = ["211.244.225.164/32"]

  validation {
    condition     = length(var.maintenance_allowed_cidrs) == 1 && alltrue([for cidr in var.maintenance_allowed_cidrs : can(cidrhost(cidr, 0)) && !endswith(cidr, "/0")])
    error_message = "공인 IP의 CIDR 1개를 지정하세요. 전체 주소 허용(/0)은 사용할 수 없습니다."
  }
}
