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
