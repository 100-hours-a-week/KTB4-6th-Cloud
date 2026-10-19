variable "v2_vpc_cidr" {
  description = "V2(서울) VPC 대역. 피어링 경로의 목적지로 쓴다"
  type        = string
  default     = "10.1.0.0/16"
}

variable "ssh_allowed_cidr" {
  description = "SSH(22) 접속을 허용할 CIDR"
  type        = string
}
