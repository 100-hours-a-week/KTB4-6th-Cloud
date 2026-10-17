output "ecs_cluster_name" {
  description = "staging ECS 클러스터 이름"
  value       = aws_ecs_cluster.main.name
}

output "ecs_cluster_arn" {
  description = "staging ECS 클러스터 ARN. 배포 역할의 권한 범위를 정할 때 쓴다"
  value       = aws_ecs_cluster.main.arn
}

output "be_realtime_service_name" {
  description = "staging BE 실시간 ECS 서비스 이름 (녹음 WebSocket, SSE)"
  value       = aws_ecs_service.be_realtime.name
}

output "be_api_service_name" {
  description = "staging BE REST ECS 서비스 이름"
  value       = aws_ecs_service.be_api.name
}

output "private_subnet_ids" {
  description = "staging private 서브넷 ID 목록 (AZ 순서). DB, Redis EC2를 둔다"
  value       = aws_subnet.private[*].id
}

output "be_log_group" {
  description = "staging BE 컨테이너 로그 그룹"
  value       = aws_cloudwatch_log_group.be.name
}

output "db_private_ip" {
  description = "staging DB 인스턴스 private IP. BE의 DB_HOST, REDIS_HOST로 쓴다 (#28)"
  value       = aws_instance.db.private_ip
}

output "db_replica_private_ip" {
  description = "staging Read Replica DB private IP. BE 읽기 분산 설정이 들어오면 BE에 넘긴다"
  value       = aws_instance.db_replica.private_ip
}

output "db_replica_instance_id" {
  description = "staging Read Replica DB 인스턴스 ID. SSM 접속에 쓴다"
  value       = aws_instance.db_replica.id
}

output "migration_db_instance_id" {
  description = "DB 이전 리허설용 MySQL 인스턴스 ID. SSM 접속 대상이다"
  value       = aws_instance.migration_db.id
}

output "migration_db_private_ip" {
  description = "DB 이전 리허설용 MySQL 사설 IP. 오하이오 dev-app ProxySQL의 서울 서버 주소로 쓴다"
  value       = aws_instance.migration_db.private_ip
}

output "ai_private_ip" {
  description = "staging AI 인스턴스 private IP. BE의 AI_HTTP_URL, AI_WEBSOCKET_URL에 쓴다"
  value       = aws_instance.ai.private_ip
}

output "gha_deploy_fe_role_name" {
  description = "FE 저장소 v2-staging Environment의 AWS_ROLE_ARN에 넣을 역할 이름 (ARN은 aws iam get-role로 확인)"
  value       = aws_iam_role.gha_deploy_fe.name
}

output "fe_target_group_name" {
  description = "FE 배포 workflow가 대상을 등록하는 대상 그룹 이름"
  value       = aws_lb_target_group.fe.name
}

output "gha_deploy_ai_role_name" {
  description = "AI 저장소 v2-staging Environment의 AWS_ROLE_ARN에 넣을 역할 이름 (ARN은 aws iam get-role로 확인)"
  value       = aws_iam_role.gha_deploy_ai.name
}

output "ai_instance_id" {
  description = "AI 저장소 v2-staging Environment의 AI_INSTANCE_ID에 넣을 값"
  value       = aws_instance.ai.id
}

output "ai_analysis_private_ip" {
  description = "staging AI 분석 인스턴스 private IP. BE의 AI_HTTP_URL에 쓴다"
  value       = aws_instance.ai_analysis.private_ip
}

output "ai_analysis_instance_id" {
  description = "AI 저장소 v2-staging Environment의 AI_ANALYSIS_INSTANCE_ID에 넣을 값"
  value       = aws_instance.ai_analysis.id
}

