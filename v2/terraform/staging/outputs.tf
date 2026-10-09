output "ecs_cluster_name" {
  description = "staging ECS 클러스터 이름"
  value       = aws_ecs_cluster.main.name
}

output "ecs_cluster_arn" {
  description = "staging ECS 클러스터 ARN. 배포 역할의 권한 범위를 정할 때 쓴다"
  value       = aws_ecs_cluster.main.arn
}

output "be_service_name" {
  description = "staging BE ECS 서비스 이름"
  value       = aws_ecs_service.be.name
}

output "be_log_group" {
  description = "staging BE 컨테이너 로그 그룹"
  value       = aws_cloudwatch_log_group.be.name
}
