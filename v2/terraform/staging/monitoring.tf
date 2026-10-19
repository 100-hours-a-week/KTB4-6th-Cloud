# staging 모니터링 서버 (Prometheus, Loki, Grafana). prod와 따로 둔다.
# Grafana는 공용 ALB에서 grafana-staging.meety.io.kr로 접속하고, 관리자 비밀번호는 Parameter Store에 미리 등록한다.
module "monitoring" {
  source = "../modules/monitoring"

  name_prefix      = local.name_prefix
  env              = var.env
  region           = var.region
  vpc_id           = local.shared.vpc_id
  subnet_id        = aws_subnet.private[0].id
  private_ip       = var.monitoring_private_ip
  ami_id           = var.monitoring_ami_id
  instance_type    = var.monitoring_instance_type
  root_volume_size = var.monitoring_root_volume_size
  config_dir       = "${path.module}/../../monitoring"
  prometheus_image = var.monitoring_images.prometheus
  loki_image       = var.monitoring_images.loki
  grafana_image    = var.monitoring_images.grafana
  grafana_domain   = var.monitoring_grafana_domain

  grafana_admin_password_parameter_arn = "${local.param_arn_prefix}/monitoring/GRAFANA_ADMIN_PASSWORD"
  ssm_kms_key_arn                      = data.aws_kms_alias.ssm.target_key_arn

  # Prometheus 내장 탐색이 실행 중인 태스크의 사설 IP를 조회한다. BE 포트는 8080 유지.
  ecs_cluster_arn     = aws_ecs_cluster.main.arn
  ecs_scrape_services = [aws_ecs_service.be_api.name, aws_ecs_service.be_realtime.name]
  ecs_scrape_port     = var.be_container_port

  alb_security_group_id  = local.shared.alb_security_group_id
  https_listener_arn     = local.shared.https_listener_arn
  listener_rule_priority = 115

  volume_tags = {
    Service   = "meety"
    Project   = var.project
    Version   = "v2"
    Env       = var.env
    ManagedBy = "terraform"
  }

  # 이미지 다운로드와 패키지 설치가 NAT 경로를 쓴다
  depends_on = [aws_route.private_nat, aws_route_table_association.private]
}

# Prometheus가 BE 태스크의 /actuator/prometheus(8080)를 직접 수집한다. ALB를 거치지 않으므로 외부 차단 규칙의 영향을 받지 않는다
resource "aws_vpc_security_group_ingress_rule" "be_from_monitoring" {
  security_group_id            = aws_security_group.be.id
  description                  = "Prometheus scrape from monitoring server"
  referenced_security_group_id = module.monitoring.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.be_container_port
  to_port                      = var.be_container_port
}
