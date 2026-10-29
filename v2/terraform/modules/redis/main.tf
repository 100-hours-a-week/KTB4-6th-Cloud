# 환경마다 독립된 Redis 서버를 만든다. DB 서버와 역할·보안 그룹을 공유하지 않는다.
resource "aws_security_group" "redis" {
  name        = "${var.name_prefix}-redis-sg"
  description = "Redis from environment BE only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-redis-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "from_be" {
  security_group_id            = aws_security_group.redis.id
  description                  = "Redis from environment BE"
  referenced_security_group_id = var.be_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

locals {
  # Sentinel 실험 구성은 한 서버에 모두 띄우므로 포트로 구분한다. Master는 기존과 같은 6379다.
  replica_port         = 6380
  sentinel_ports       = [26379, 26380, 26381]
  sentinel_master_name = "meety"
}

# Failover 뒤에는 Replica(6380)가 Master가 되므로 BE가 두 포트 모두에 접속할 수 있어야 한다.
resource "aws_vpc_security_group_ingress_rule" "replica_from_be" {
  count = var.sentinel_enabled ? 1 : 0

  security_group_id            = aws_security_group.redis.id
  description                  = "Redis replica from environment BE"
  referenced_security_group_id = var.be_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = local.replica_port
  to_port                      = local.replica_port
}

# BE가 현재 Master 주소를 Sentinel에게 묻는다. 같은 서버 안의 복제·감시 연결은 보안 그룹을 거치지 않는다.
resource "aws_vpc_security_group_ingress_rule" "sentinel_from_be" {
  count = var.sentinel_enabled ? 1 : 0

  security_group_id            = aws_security_group.redis.id
  description                  = "Redis Sentinel from environment BE"
  referenced_security_group_id = var.be_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = min(local.sentinel_ports...)
  to_port                      = max(local.sentinel_ports...)
}

# 패키지 설치·SSM 접속과, 이전 중 기존 Redis에서 복제받는 연결에 사용한다.
resource "aws_vpc_security_group_egress_rule" "outbound" {
  security_group_id = aws_security_group.redis.id
  description       = "Outbound via environment NAT"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_iam_role" "redis" {
  name = "${var.name_prefix}-redis"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.name_prefix}-redis" }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.redis.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "params" {
  name = "read-redis-password"
  role = aws_iam_role.redis.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadRedisPassword"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = var.password_parameter_arn
      },
      {
        Sid      = "DecryptViaSsm"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = var.ssm_kms_key_arn
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${var.region}.amazonaws.com" }
        }
      },
      {
        # SSM 관리형 정책의 넓은 조회 권한을 제한한다. DB 비밀번호도 읽을 수 없다.
        Sid    = "DenyOtherParameters"
        Effect = "Deny"
        Action = [
          "ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory",
        ]
        NotResource = [var.password_parameter_arn, "arn:aws:ssm:*::parameter/aws/*"]
      },
    ]
  })
}

resource "aws_iam_instance_profile" "redis" {
  name = "${var.name_prefix}-redis"
  role = aws_iam_role.redis.name
  tags = { Name = "${var.name_prefix}-redis" }
}

resource "aws_instance" "redis" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  private_ip                  = var.private_ip
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.redis.id]
  iam_instance_profile        = aws_iam_instance_profile.redis.name

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region               = var.region
    parameter_name       = split(":parameter", var.password_parameter_arn)[1]
    redis_image          = var.redis_image
    container_name       = "${var.env}-redis"
    maxmemory_mb         = var.maxmemory_mb
    sentinel_enabled     = var.sentinel_enabled
    private_ip           = var.private_ip
    replica_port         = local.replica_port
    sentinel_ports       = local.sentinel_ports
    sentinel_master_name = local.sentinel_master_name
  })
  # user_data는 첫 부팅에만 실행된다. 설정을 다시 적용하려면 인스턴스를 교체해야 하며, 이때 AOF 데이터는 사라진다.
  user_data_replace_on_change = var.user_data_replace_on_change

  # 초기 용량은 실측 전이다. CPU 크레딧 소진으로 추가 요금이 발생하지 않게 한다.
  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
    tags                  = merge(var.volume_tags, { Name = "${var.name_prefix}-redis-root" })
  }

  # 인스턴스 첫 부팅 전에 파라미터 조회와 SSM 권한이 준비되어야 한다.
  depends_on = [aws_iam_role_policy.params, aws_iam_role_policy_attachment.ssm]
  tags       = { Name = "${var.name_prefix}-redis" }
}

resource "aws_ec2_tag" "eni_service" {
  resource_id = aws_instance.redis.primary_network_interface_id
  key         = "Service"
  value       = "meety"
}
