output "ecs_cluster_name" {
  description = "prod ECS 클러스터 이름"
  value       = aws_ecs_cluster.main.name
}

output "ecs_cluster_arn" {
  description = "prod ECS 클러스터 ARN. 배포 역할의 권한 범위를 정할 때 쓴다"
  value       = aws_ecs_cluster.main.arn
}

output "be_realtime_service_name" {
  description = "prod BE 실시간 ECS 서비스 이름 (녹음 WebSocket, SSE)"
  value       = aws_ecs_service.be_realtime.name
}

output "be_api_service_name" {
  description = "prod BE REST ECS 서비스 이름"
  value       = aws_ecs_service.be_api.name
}

output "private_subnet_ids" {
  description = "prod private 서브넷 ID 목록 (AZ 순서). DB, AI EC2를 둔다"
  value       = aws_subnet.private[*].id
}

output "be_log_group" {
  description = "prod BE 컨테이너 로그 그룹"
  value       = aws_cloudwatch_log_group.be.name
}

output "db_private_ips" {
  description = "prod DB 인스턴스 private IP (primary, replica). BE의 DB_HOST, REDIS_HOST는 primary를 쓴다"
  value       = { for k, v in aws_instance.db : k => v.private_ip }
}

output "db_instance_ids" {
  description = "prod DB 인스턴스 ID (primary, replica). SSM 접속에 쓴다"
  value       = { for k, v in aws_instance.db : k => v.id }
}

output "ai_private_ip" {
  description = "prod AI live 인스턴스 private IP. BE의 AI_WEBSOCKET_URL에 쓴다"
  value       = aws_instance.ai.private_ip
}

output "ai_instance_id" {
  description = "prod AI live 인스턴스 ID. prod AI 배포 workflow를 만들 때 쓴다"
  value       = aws_instance.ai.id
}

output "ai_analysis_private_ip" {
  description = "prod AI 분석 인스턴스 private IP. BE의 AI_HTTP_URL에 쓴다"
  value       = aws_instance.ai_analysis.private_ip
}

output "ai_analysis_instance_id" {
  description = "prod AI 분석 인스턴스 ID. prod AI 배포 workflow를 만들 때 쓴다"
  value       = aws_instance.ai_analysis.id
}

output "fe_instance_id" {
  description = "prod FE 인스턴스 ID. prod FE 배포 workflow를 만들 때 쓴다"
  value       = aws_instance.fe.id
}

output "fe_public_ip" {
  description = "prod FE 인스턴스 EIP. private 서브넷의 외부 출구(NAT) IP이기도 하다"
  value       = aws_eip.fe.public_ip
}

output "fe_target_group_name" {
  description = "FE 배포 workflow가 대상을 등록하는 대상 그룹 이름"
  value       = aws_lb_target_group.fe.name
}

output "gha_deploy_role_arn" {
  description = "GitHub production BE 배포 역할 ARN. AWS_ROLE_ARN 시크릿에 등록한다"
  value       = aws_iam_role.gha_deploy.arn
}

output "gha_deploy_fe_role_arn" {
  description = "GitHub production FE 배포 역할 ARN. AWS_ROLE_ARN 시크릿에 등록한다"
  value       = aws_iam_role.gha_deploy_fe.arn
}

output "gha_deploy_ai_role_arn" {
  description = "GitHub production AI 배포 역할 ARN. AWS_ROLE_ARN 시크릿에 등록한다"
  value       = aws_iam_role.gha_deploy_ai.arn
}
