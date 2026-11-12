# 0단계에서는 조회 결과가 기대한 V2 리소스인지 plan에서 확인하는 용도다.

output "account_id" {
  description = "Terraform을 실행한 AWS 계정"
  value       = data.aws_caller_identity.current.account_id
}

output "vpc_id" {
  description = "V3가 함께 쓰는 V2 VPC"
  value       = data.aws_vpc.v2.id
}

output "vpc_cidr" {
  description = "V2 VPC 대역. 10.1.0.0/16이어야 한다"
  value       = data.aws_vpc.v2.cidr_block
}

output "public_subnets" {
  description = "AZ별 V2 퍼블릭 서브넷 (NAT 인스턴스, 접속용 EC2가 쓴다)"
  value       = { for az, s in data.aws_subnet.v2_public : az => { id = s.id, cidr = s.cidr_block } }
}
