variable "v2_staging_db_ip" {
  description = "V2 staging DB 인스턴스 사설 IP. dev MySQL 3306 접근을 이 주소에만 허용한다. 인스턴스를 교체하면 바꾼다"
  type        = string
  default     = "10.1.10.132"
}

variable "v2_vpc_cidr" {
  description = "V2(서울) VPC 대역. 피어링 경로의 목적지로 쓴다"
  type        = string
  default     = "10.1.0.0/16"
}

variable "ssh_allowed_cidr" {
  description = "SSH(22) 접속을 허용할 CIDR"
  type        = string
}
