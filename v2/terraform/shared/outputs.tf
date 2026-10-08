# staging/, prod/ 폴더가 terraform_remote_state로 읽어 가는 값

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


output "alb_dns_name" {
  description = "ALB 주소. 외부 DNS의 CNAME 값으로 쓴다"
  value       = aws_lb.main.dns_name
}

output "alb_arn_suffix" {
  description = "CloudWatch 지표와 알람에서 ALB를 가리킬 때 쓰는 값"
  value       = aws_lb.main.arn_suffix
}

output "https_listener_arn" {
  description = "HTTPS 리스너 ARN. staging/, prod/에서 도메인별 전달 규칙을 이 리스너에 붙인다"
  value       = aws_lb_listener.https.arn
}

output "staging_cert_validation_records" {
  description = "외부 DNS에 추가할 staging 인증서 검증용 CNAME (이름, 값)"
  value = {
    for o in aws_acm_certificate.staging.domain_validation_options : o.domain_name => {
      type  = o.resource_record_type
      name  = o.resource_record_name
      value = o.resource_record_value
    }
  }
}

output "staging_cert_arn" {
  description = "V2 staging 인증서 ARN (ALB HTTPS 리스너에서 사용)"
  value       = aws_acm_certificate.staging.arn
}
