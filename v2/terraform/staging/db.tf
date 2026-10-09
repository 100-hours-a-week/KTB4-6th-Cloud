# staging DB 인스턴스: MySQL Primary와 Redis를 같은 인스턴스에서 실행한다.
# DB 사이징 설계의 Primary(t4g.small, EC2 자체 구축)를 따른다. Read Replica와 백업은 후속 작업이다.

resource "aws_instance" "db" {
  ami           = var.db_ami_id
  instance_type = var.db_instance_type

  # private 서브넷(2a). public IP 없이 FE/NAT 인스턴스를 거쳐 외부로 나간다
  subnet_id                   = aws_subnet.private[0].id
  vpc_security_group_ids      = [aws_security_group.db.id]
  iam_instance_profile        = aws_iam_instance_profile.db.name
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user_data/db.sh.tftpl", {
    region      = var.region
    param_path  = "/meety/${var.env}/db"
    mysql_image = var.db_mysql_image
    redis_image = var.db_redis_image
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
      Name      = "${local.name_prefix}-db-root"
      Service   = "meety"
      Project   = var.project
      Version   = "v2"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }

  tags = {
    Name = "${local.name_prefix}-db"
  }
}

# 인스턴스와 함께 만들어지는 기본 네트워크 인터페이스에도 default_tags가 붙지 않아 Service 태그를 직접 붙인다
resource "aws_ec2_tag" "db_eni_service" {
  resource_id = aws_instance.db.primary_network_interface_id
  key         = "Service"
  value       = "meety"
}
