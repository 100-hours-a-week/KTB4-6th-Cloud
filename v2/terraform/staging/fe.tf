# staging FE 인스턴스. 지금은 staging private 서브넷의 NAT 인스턴스 역할만 한다.
# FE 앱 배포는 후속 작업이다. 문제가 확인되면 NAT를 전용 인스턴스로 분리한다.

resource "aws_instance" "fe" {
  ami           = var.fe_ami_id
  instance_type = var.fe_instance_type

  subnet_id              = local.shared.public_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.fe.id]
  iam_instance_profile   = aws_iam_instance_profile.fe.name

  # 첫 부팅 때 user_data가 패키지를 받으려면 EIP 연결 전에도 인터넷에 나가야 한다.
  # EIP를 연결하면 이 IP는 EIP로 바뀐다.
  associate_public_ip_address = true

  # NAT는 자기 IP가 아닌 패킷을 전달해야 하므로 출발지/목적지 검사를 끈다
  source_dest_check = false

  user_data = templatefile("${path.module}/user_data/fe_nat.sh.tftpl", {
    private_cidrs = join(" ", aws_subnet.private[*].cidr_block)
  })

  # 크레딧을 다 쓰면 기준 성능으로 제한되고 추가 요금은 없다
  credit_specification {
    cpu_credits = "standard"
  }

  # 인스턴스 메타데이터는 토큰 방식(IMDSv2)만 허용한다
  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.fe_root_volume_size
    encrypted             = true
    delete_on_termination = true

    # provider default_tags는 루트 볼륨에 자동으로 붙지 않아서 직접 지정한다
    tags = {
      Name      = "${local.name_prefix}-fe-root"
      Service   = "meety"
      Project   = var.project
      Version   = "v2"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }

  tags = {
    Name = "${local.name_prefix}-fe"
  }
}

# 인스턴스와 함께 만들어지는 기본 네트워크 인터페이스에도 default_tags가 붙지 않아 Service 태그를 직접 붙인다
resource "aws_ec2_tag" "fe_eni_service" {
  resource_id = aws_instance.fe.primary_network_interface_id
  key         = "Service"
  value       = "meety"
}

# 중지 후 다시 시작해도 공인 IP와 NAT 출구 IP가 바뀌지 않도록 EIP를 붙인다
resource "aws_eip" "fe" {
  domain   = "vpc"
  instance = aws_instance.fe.id

  tags = {
    Name = "${local.name_prefix}-fe-eip"
  }
}
