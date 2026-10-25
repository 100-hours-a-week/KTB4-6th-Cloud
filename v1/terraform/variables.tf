variable "v2_vpc_cidr" {
  description = "V2(서울) VPC 대역. 피어링 경로의 목적지로 쓴다"
  type        = string
  default     = "10.1.0.0/16"
}

variable "migration_rehearsal_enabled" {
  description = "서울 임시 DB의 원본 복제 접근 허용. 리허설을 재개할 때만 활성화한다"
  type        = bool
  default     = false
}

variable "ssh_allowed_cidr" {
  description = "SSH(22) 접속을 허용할 CIDR"
  type        = string
}
