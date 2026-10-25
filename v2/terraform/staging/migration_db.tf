# 오하이오 dev → 서울 리허설 전용 DB. 재현할 때만 활성화하며 staging 서비스 DB와 분리한다.
resource "aws_instance" "migration_db" {
  count = var.migration_rehearsal_enabled ? 1 : 0

  ami                         = var.db_ami_id
  instance_type               = var.db_instance_type
  subnet_id                   = aws_subnet.private[1].id
  private_ip                  = var.db_migration_private_ip
  vpc_security_group_ids      = [aws_security_group.migration_db[0].id]
  iam_instance_profile        = aws_iam_instance_profile.db.name
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user_data/migration_db.sh.tftpl", {
    region      = var.region
    param_path  = "/meety/${var.env}/db"
    mysql_image = var.db_mysql_image
    private_ip  = var.db_migration_private_ip
    server_id   = var.db_migration_server_id
  })

  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.db_migration_root_volume_size
    encrypted             = true
    delete_on_termination = true

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
    Name    = "${local.name_prefix}-migration-db"
    Purpose = "Ohio-to-Seoul migration rehearsal"
  }
}

resource "aws_ec2_tag" "migration_db_eni_service" {
  count = var.migration_rehearsal_enabled ? 1 : 0

  resource_id = aws_instance.migration_db[0].primary_network_interface_id
  key         = "Service"
  value       = "meety"
}

# 기존 리소스의 주소를 유지한 채 조건부 관리로 전환한다.
moved {
  from = aws_instance.migration_db
  to   = aws_instance.migration_db[0]
}

moved {
  from = aws_ec2_tag.migration_db_eni_service
  to   = aws_ec2_tag.migration_db_eni_service[0]
}

moved {
  from = aws_security_group.migration_db
  to   = aws_security_group.migration_db[0]
}

moved {
  from = aws_vpc_security_group_ingress_rule.migration_db_mysql_from_dev_proxysql
  to   = aws_vpc_security_group_ingress_rule.migration_db_mysql_from_dev_proxysql[0]
}

moved {
  from = aws_vpc_security_group_egress_rule.migration_db_all
  to   = aws_vpc_security_group_egress_rule.migration_db_all[0]
}
