variable "name_prefix" {
  description = "환경별 리소스 이름 접두사"
  type        = string
}

variable "region" {
  description = "CloudWatch Logs 수집 리전"
  type        = string
}

variable "instance_role_name" {
  description = "AI EC2에 연결된 IAM 역할 이름"
  type        = string
}

variable "instance_ids" {
  description = "live와 analysis 전용 EC2 ID"
  type = object({
    live     = string
    analysis = string
  })
}

variable "retention_in_days" {
  description = "AI 로그 보존 기간. 환경의 기존 로그 보존 정책을 따른다"
  type        = number
}
