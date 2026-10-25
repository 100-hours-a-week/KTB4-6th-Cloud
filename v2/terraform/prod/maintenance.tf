# 빈 목록이면 평상시 라우팅을 유지한다. 점검 제어 스크립트가 점검 중에만 허용 IP를 적용한다.
variable "maintenance_allowed_cidrs" {
  description = "점검 중 기존 FE·API·실시간 규칙의 이용을 허용할 IP. 빈 목록이면 제한하지 않는다"
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.maintenance_allowed_cidrs) <= 1 && alltrue([for cidr in var.maintenance_allowed_cidrs : can(cidrhost(cidr, 0)) && !endswith(cidr, "/0")])
    error_message = "빈 목록 또는 CIDR 1개만 지정하세요. 전체 주소 허용(/0)은 사용할 수 없습니다."
  }
}

output "maintenance_allowed_cidrs" {
  description = "기존 운영 라우팅 규칙에 기록된 점검 허용 IP"
  value       = var.maintenance_allowed_cidrs
}
