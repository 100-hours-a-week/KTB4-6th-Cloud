variable "v2_migration_db_ip" {
  description = "V2 서울의 DB 이전 리허설용 MySQL 사설 IP. dev MySQL 3306 접근(덤프, 복제)을 이 주소에만 허용한다. 인스턴스를 교체하면 바꾼다"
  type        = string
  default     = "10.1.10.140"
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
