output "instance_id" {
  description = "모니터링 서버 EC2 인스턴스 ID"
  value       = aws_instance.monitoring.id
}

output "private_ip" {
  description = "모니터링 서버 사설 IP. 로그 수집기가 Loki(3100)로 보낼 주소"
  value       = aws_instance.monitoring.private_ip
}

output "security_group_id" {
  description = "수집 대상의 보안 그룹에서 모니터링 서버 접근을 허용할 때 참조하는 ID"
  value       = aws_security_group.monitoring.id
}
