# DB 이전 리허설용 MySQL 인스턴스 (2026-10-16)
# - 오하이오 V1 dev DB를 복제받아, 오하이오 dev-app의 ProxySQL이 쓰기 대상을 서울로 넘기는 리허설에 쓴다.
# - staging DB(db.tf)는 staging 앱 전용으로 두고, 리허설 데이터와 읽기 전용 전환이 staging에 영향을 주지 않도록 분리한다.
#   (super_read_only는 MySQL 서버 전체에 걸리므로, 같은 서버에 DB 이름만 나누는 방식으로는 분리할 수 없다)
# - 리허설이 끝나면 이 파일의 리소스를 지운다.

resource "aws_security_group" "migration_db" {
  name        = "${local.name_prefix}-migration-db-sg"
  description = "V1 dev DB migration rehearsal MySQL"
  vpc_id      = local.shared.vpc_id

  tags = {
    Name = "${local.name_prefix}-migration-db-sg"
  }
}

# 전환 후 오하이오 dev-app의 ProxySQL이 이 DB에 접속한다.
# 리전 간 피어링은 보안 그룹을 참조할 수 없어 사설 IP로 허용한다
resource "aws_vpc_security_group_ingress_rule" "migration_db_mysql_from_v1_dev_proxysql" {
  security_group_id = aws_security_group.migration_db.id
  description       = "MySQL from V1 dev-app ProxySQL (Ohio, VPC peering)"
  cidr_ipv4         = "${var.v1_dev_app_private_ip}/32"
  ip_protocol       = "tcp"
  from_port         = 3306
  to_port           = 3306
}

# 패키지와 이미지 받기, SSM 연결은 FE/NAT 인스턴스를 거쳐 인터넷으로 나가고,
# 오하이오 dev DB 덤프와 복제는 피어링으로 나간다
resource "aws_vpc_security_group_egress_rule" "migration_db_all" {
  security_group_id = aws_security_group.migration_db.id
  description       = "Outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# 인스턴스 역할: SSM 접속과, 첫 부팅 때 /meety/staging/migration-db/ 아래 비밀값을 읽는 권한만 준다.
# 다른 경로의 파라미터는 iam.tf의 instance_params_deny가 막는다
resource "aws_iam_role" "migration_db" {
  name = "${local.name_prefix}-migration-db"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${local.name_prefix}-migration-db"
  }
}

resource "aws_iam_role_policy_attachment" "migration_db_ssm" {
  role       = aws_iam_role.migration_db.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "migration_db_params" {
  name = "read-migration-db-params"
  role = aws_iam_role.migration_db.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadMigrationDbParams"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = [
          "${local.param_arn_prefix}/migration-db",
          "${local.param_arn_prefix}/migration-db/*",
        ]
      },
      {
        # SecureString 복호화는 Parameter Store를 거친 요청에만 허용한다
        Sid      = "DecryptViaSsm"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = data.aws_kms_alias.ssm.target_key_arn
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${var.region}.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "migration_db" {
  name = "${local.name_prefix}-migration-db"
  role = aws_iam_role.migration_db.name

  tags = {
    Name = "${local.name_prefix}-migration-db"
  }
}

resource "aws_instance" "migration_db" {
  ami           = var.db_ami_id
  instance_type = var.db_instance_type

  # staging DB와 같은 private 서브넷(2a). public IP 없이 FE/NAT 인스턴스를 거쳐 외부로 나간다
  subnet_id                   = aws_subnet.private[0].id
  private_ip                  = var.migration_db_private_ip
  vpc_security_group_ids      = [aws_security_group.migration_db.id]
  iam_instance_profile        = aws_iam_instance_profile.migration_db.name
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user_data/migration_db.sh.tftpl", {
    region       = var.region
    param_path   = "/meety/${var.env}/migration-db"
    mysql_image  = var.db_mysql_image
    db_server_id = var.migration_db_server_id
  })

  credit_specification {
    cpu_credits = "standard"
  }

  # 인스턴스 메타데이터는 토큰 방식(IMDSv2)만 허용한다
  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.db_root_volume_size
    encrypted             = true
    delete_on_termination = true

    # provider default_tags는 루트 볼륨에 자동으로 붙지 않아서 직접 지정한다
    tags = {
      Name      = "${local.name_prefix}-migration-db-root"
      Service   = "meety"
      Project   = var.project
      Version   = "v2"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }

  tags = {
    Name = "${local.name_prefix}-migration-db"
  }
}

# 인스턴스와 함께 만들어지는 기본 네트워크 인터페이스에도 default_tags가 붙지 않아 Service 태그를 직접 붙인다
resource "aws_ec2_tag" "migration_db_eni_service" {
  resource_id = aws_instance.migration_db.primary_network_interface_id
  key         = "Service"
  value       = "meety"
}
