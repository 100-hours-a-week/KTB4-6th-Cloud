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

output "sentinel_master_name" {
  description = "Sentinel이 감시하는 Master 이름. Sentinel을 켜지 않으면 null"
  value       = var.sentinel_enabled ? local.sentinel_master_name : null
}

output "sentinel_nodes" {
  description = "BE가 접속할 Sentinel 주소 목록(host:port). Sentinel을 켜지 않으면 빈 목록"
  value       = var.sentinel_enabled ? [for port in local.sentinel_ports : "${aws_instance.redis.private_ip}:${port}"] : []
}
