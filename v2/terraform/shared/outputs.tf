# dev/, prod/ 폴더가 terraform_remote_state로 읽어 가는 값

output "vpc_id" {
  description = "V2 VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "V2 VPC 대역"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "public 서브넷 ID 목록 (AZ 순서)"
  value       = aws_subnet.public[*].id
}

output "alb_security_group_id" {
  description = "ALB 보안 그룹 ID. 환경별 보안 그룹이 이 그룹에서 오는 요청만 허용한다"
  value       = aws_security_group.alb.id
}
