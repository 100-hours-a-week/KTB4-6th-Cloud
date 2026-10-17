# prod DB: Primary 1대 + Read Replica 1대를 서로 다른 AZ에 둔다 (DB 사이징 설계, EC2 자체 구축).
# - Primary(2a): MySQL과 Redis(SSE Pub/Sub)를 같이 실행한다. 쓰기를 맡는다.
# - Read Replica(2c): MySQL만 실행하고 Primary에서 복제받는다. Primary 장애 때 수동으로 승격한다.
# - 복제 연결과 백업은 데이터 이전 절차에서 설정한다. 두 인스턴스는 같은 역할과 보안 그룹을 쓴다.

locals {
  db_nodes = {
    primary = {
      subnet_index = 0
      private_ip   = var.db_primary_private_ip
      server_id    = var.db_primary_server_id
      with_redis   = true
    }
    replica = {
      subnet_index = 1
      private_ip   = var.db_replica_private_ip
      server_id    = var.db_replica_server_id
      with_redis   = false
    }
  }
}

resource "aws_instance" "db" {
  for_each = local.db_nodes

  ami           = var.db_ami_id
  instance_type = var.db_instance_type

  # private 서브넷. public IP 없이 FE/NAT 인스턴스를 거쳐 외부로 나간다
  subnet_id                   = aws_subnet.private[each.value.subnet_index].id
  private_ip                  = each.value.private_ip
  vpc_security_group_ids      = [aws_security_group.db.id]
  iam_instance_profile        = aws_iam_instance_profile.db.name
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user_data/db.sh.tftpl", {
    region           = var.region
    param_path       = "/meety/${var.env}/db"
    container_prefix = "${var.env}-${each.key}"
    mysql_image      = var.db_mysql_image
    redis_image      = var.db_redis_image
    db_server_id     = each.value.server_id
    with_redis       = each.value.with_redis
  })

  # 크레딧을 다 쓰면 기준 성능으로 제한되고 추가 요금은 없다.
  # 크레딧 소진이 반복되면 설계 문서의 변경 조건대로 인스턴스 계열을 다시 검토한다.
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
      Name      = "${local.name_prefix}-db-${each.key}-root"
      Service   = "meety"
      Project   = var.project
      Version   = "v2"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }

  tags = {
    Name = "${local.name_prefix}-db-${each.key}"
  }
}

# 인스턴스와 함께 만들어지는 기본 네트워크 인터페이스에도 default_tags가 붙지 않아 Service 태그를 직접 붙인다
resource "aws_ec2_tag" "db_eni_service" {
  for_each = aws_instance.db

  resource_id = each.value.primary_network_interface_id
  key         = "Service"
  value       = "meety"
}
