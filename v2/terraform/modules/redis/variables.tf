variable "name_prefix" {
  description = "환경별 리소스 이름 접두사"
  type        = string
}

variable "env" {
  description = "환경 이름"
  type        = string
}

variable "region" {
  description = "Parameter Store를 조회할 AWS 리전"
  type        = string
}

variable "vpc_id" {
  description = "Redis 보안 그룹을 만들 VPC ID"
  type        = string
}

variable "subnet_id" {
  description = "공인 IP 없이 사용할 환경 전용 private 서브넷 ID"
  type        = string
}

variable "private_ip" {
  description = "BE가 접속할 고정 사설 IP"
  type        = string
}

variable "be_security_group_id" {
  description = "Redis 접속을 허용할 환경별 BE 보안 그룹 ID"
  type        = string
}

variable "ami_id" {
  description = "Redis 이미지와 아키텍처가 맞는 AMI ID"
  type        = string
}

variable "instance_type" {
  description = "Redis 전용 EC2 인스턴스 타입"
  type        = string
}

variable "root_volume_size" {
  description = "Redis 설정·AOF와 Docker를 저장할 암호화 루트 볼륨 크기(GB)"
  type        = number
}

variable "redis_image" {
  description = "기존 서버와 동일한 버전의 Redis 이미지"
  type        = string
}

variable "maxmemory_mb" {
  description = "Redis 데이터 메모리 상한(MB). OS·연결 버퍼·AOF 재작성 여유는 별도다"
  type        = number

  validation {
    condition     = var.maxmemory_mb >= 64 && floor(var.maxmemory_mb) == var.maxmemory_mb
    error_message = "Redis maxmemory_mb는 64 이상의 정수여야 한다."
  }
}

variable "password_parameter_arn" {
  description = "기존 Redis와 공유하는 비밀번호 파라미터 ARN. 값은 Terraform이 읽지 않는다"
  type        = string
}

variable "ssm_kms_key_arn" {
  description = "Parameter Store SecureString 복호화용 KMS 키 ARN"
  type        = string
}

variable "volume_tags" {
  description = "provider 기본 태그가 자동 적용되지 않는 루트 볼륨용 태그"
  type        = map(string)
}
