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

variable "be_domain" {
  description = "dev BE 도메인. ALB에서 이 도메인으로 온 요청을 BE 서비스로 보낸다"
  type        = string
  default     = "v2-api-dev.meety.io.kr"
}

# 아래 값은 오늘 테스트 컨테이너(nginx) 기준이다. BE를 배포할 때(10/10) BE 값으로 바꾼다.
variable "be_image" {
  description = "BE 컨테이너 이미지 (지금은 경로 검증용 nginx)"
  type        = string
  default     = "nginx:1.29.1-alpine"
}

variable "be_container_port" {
  description = "컨테이너가 요청을 받는 포트 (nginx 80, BE는 배포 시 변경)"
  type        = number
  default     = 80
}

variable "be_cpu" {
  description = "태스크 CPU 단위 (1024 = 1 vCPU). 테스트는 최소값, BE는 설계값 1024"
  type        = number
  default     = 256
}

variable "be_memory" {
  description = "태스크 메모리 MiB. 테스트는 최소값, BE는 설계값 2048"
  type        = number
  default     = 512
}

variable "be_health_check_path" {
  description = "ALB가 태스크 상태를 확인하는 경로"
  type        = string
  default     = "/"
}

variable "log_retention_days" {
  description = "CloudWatch 로그 보존 기간(일)"
  type        = number
  default     = 14
}
