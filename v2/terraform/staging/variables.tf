variable "project" {
  description = "리소스 이름과 태그에 쓰는 프로젝트 이름"
  type        = string
  default     = "meety"
}

variable "env" {
  description = "환경 이름. prod 폴더에서는 prod로 바꾼다"
  type        = string
  default     = "staging"
}

variable "region" {
  description = "V2 리전 (V1은 us-east-2)"
  type        = string
  default     = "ap-northeast-2"
}

variable "be_domain" {
  description = "staging BE 도메인. ALB에서 이 도메인으로 온 요청을 BE 서비스로 보낸다"
  type        = string
  default     = "api-staging.meety.io.kr"
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

variable "fe_ami_id" {
  description = "FE 인스턴스 AMI. Ubuntu 26.04 amd64 (Canonical, 20261003). 새 AMI로 바꾸면 인스턴스가 교체된다"
  type        = string
  default     = "ami-0e677ebf2c8434c2a"
}

variable "fe_instance_type" {
  description = "FE 인스턴스 타입. NAT를 겸하며, 처리 용량은 검증 전 초기값이다"
  type        = string
  default     = "t3.micro"
}

variable "fe_root_volume_size" {
  description = "FE 인스턴스 루트 볼륨 크기(GB). FE 앱(Docker, nginx)을 올릴 여유를 둔다"
  type        = number
  default     = 20
}

variable "db_ami_id" {
  description = "DB 인스턴스 AMI. Ubuntu 26.04 arm64 (Canonical, 20261003). 새 AMI로 바꾸면 인스턴스가 교체된다"
  type        = string
  default     = "ami-01e3230cee0cae555"
}

variable "db_instance_type" {
  description = "DB 인스턴스 타입. DB 사이징 설계의 초기값(t4g.small)이며, 처리 용량은 실측 전이다"
  type        = string
  default     = "t4g.small"
}

variable "db_root_volume_size" {
  description = "DB 인스턴스 루트 볼륨 크기(GB). DB 사이징 설계의 비용 산정 기준(노드당 30GB)"
  type        = number
  default     = 30
}

variable "db_mysql_image" {
  description = "MySQL 컨테이너 이미지. V1과 같은 8.4 계열을 패치 버전까지 고정한다"
  type        = string
  default     = "mysql:8.4.11"
}

variable "db_redis_image" {
  description = "Redis 컨테이너 이미지. BE의 SSE Pub/Sub 용도"
  type        = string
  default     = "redis:8.10.2"
}

variable "fe_allowed_origins" {
  description = "staging FE 주소(origin) 목록. 파일 버킷 CORS에 쓴다. 로컬 FE에서 staging BE를 붙여 시험할 수 있게 localhost도 둔다"
  type        = list(string)
  default     = ["https://staging.meety.io.kr", "http://localhost:3000", "http://localhost:5173", "http://127.0.0.1:3000"]
}
