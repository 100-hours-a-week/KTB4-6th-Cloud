# 1단계는 서버만 준비한다. 복제·검증 뒤 redis_use_dedicated_instance를 true로 전환한다.
# 이 값은 CI/CD용 태스크 템플릿을 바꾸며, 실행 중인 BE는 별도의 배포가 필요하다.
module "redis" {
  source = "../modules/redis"

  name_prefix          = local.name_prefix
  env                  = var.env
  region               = var.region
  vpc_id               = local.shared.vpc_id
  subnet_id            = aws_subnet.private[0].id
  private_ip           = var.redis_private_ip
  be_security_group_id = aws_security_group.be.id
  ami_id               = var.redis_ami_id
  instance_type        = var.redis_instance_type
  root_volume_size     = var.redis_root_volume_size
  redis_image          = var.db_redis_image
  maxmemory_mb         = var.redis_maxmemory_mb
  # 비밀번호 경로를 유지해 앱의 시크릿 설정과 데이터 이전을 동시에 바꾸지 않는다.
  password_parameter_arn = "${local.param_arn_prefix}/db/REDIS_PASSWORD"
  ssm_kms_key_arn        = data.aws_kms_alias.ssm.target_key_arn
  volume_tags = {
    Service   = "meety"
    Project   = var.project
    Version   = "v2"
    Env       = var.env
    ManagedBy = "terraform"
  }

  depends_on = [aws_route.private_nat, aws_route_table_association.private]
}

# 기존 Redis에서 전용 Redis로 복제할 때만 사용한다. 이전 검증 후 false로 닫는다.
resource "aws_vpc_security_group_ingress_rule" "db_redis_from_dedicated_redis" {
  count = var.redis_migration_access_enabled ? 1 : 0

  security_group_id            = aws_security_group.db.id
  description                  = "Temporary Redis replication to dedicated Redis"
  referenced_security_group_id = module.redis.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

locals {
  # 구·신 Redis에 BE가 나뉘면 Pub/Sub 전달이 끊기므로, 전환 시 두 BE 서비스를 함께 중지·재시작한다.
  be_redis_host = var.redis_use_dedicated_instance ? module.redis.private_ip : aws_instance.db["primary"].private_ip
}
