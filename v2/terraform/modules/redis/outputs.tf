output "instance_id" {
  description = "Redis EC2 인스턴스 ID"
  value       = aws_instance.redis.id
}

output "private_ip" {
  description = "Redis 전용 사설 IP"
  value       = aws_instance.redis.private_ip
}

output "security_group_id" {
  description = "BE 접근과 임시 복제 연결을 구분하는 Redis 보안 그룹 ID"
  value       = aws_security_group.redis.id
}
