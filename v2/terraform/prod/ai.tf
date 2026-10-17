# prod AI 인스턴스: 실시간 STT(live)와 회의 후 요약, 챗봇(analysis)을 서로 다른 인스턴스에서 실행한다 (staging과 같은 구성).
# - live는 진행 중인 회의 수에 비례해 메모리(회의마다 디코더)를 쓰고, analysis는 요청 수에 비례해 부하가 는다.
# - 두 인스턴스는 같은 역할(aws_iam_instance_profile.ai)과 첫 부팅 설정을 쓰고, 보안 그룹은 받는 포트에 따라 나눈다.
# - 컨테이너는 AI 저장소의 배포 workflow가 띄운다. prod 배포 workflow는 prod CI/CD를 붙일 때 만든다.

resource "aws_instance" "ai" {
  ami           = var.ai_ami_id
  instance_type = var.ai_instance_type

  # private 서브넷(2a). public IP 없이 FE/NAT 인스턴스를 거쳐 외부로 나간다
  subnet_id                   = aws_subnet.private[0].id
  vpc_security_group_ids      = [aws_security_group.ai.id]
  iam_instance_profile        = aws_iam_instance_profile.ai.name
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user_data/ai.sh.tftpl", {})

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
    volume_size           = var.ai_root_volume_size
    encrypted             = true
    delete_on_termination = true

    # provider default_tags는 루트 볼륨에 자동으로 붙지 않아서 직접 지정한다
    tags = {
      Name      = "${local.name_prefix}-ai-root"
      Service   = "meety"
      Project   = var.project
      Version   = "v2"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }

  tags = {
    Name = "${local.name_prefix}-ai"
  }
}

# 인스턴스와 함께 만들어지는 기본 네트워크 인터페이스에도 default_tags가 붙지 않아 Service 태그를 직접 붙인다
resource "aws_ec2_tag" "ai_eni_service" {
  resource_id = aws_instance.ai.primary_network_interface_id
  key         = "Service"
  value       = "meety"
}

resource "aws_instance" "ai_analysis" {
  ami           = var.ai_ami_id
  instance_type = var.ai_analysis_instance_type

  # private 서브넷(2a). public IP 없이 FE/NAT 인스턴스를 거쳐 외부로 나간다
  subnet_id                   = aws_subnet.private[0].id
  vpc_security_group_ids      = [aws_security_group.ai_analysis.id]
  iam_instance_profile        = aws_iam_instance_profile.ai.name
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user_data/ai.sh.tftpl", {})

  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.ai_root_volume_size
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name      = "${local.name_prefix}-ai-analysis-root"
      Service   = "meety"
      Project   = var.project
      Version   = "v2"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }

  tags = {
    Name = "${local.name_prefix}-ai-analysis"
  }
}

resource "aws_ec2_tag" "ai_analysis_eni_service" {
  resource_id = aws_instance.ai_analysis.primary_network_interface_id
  key         = "Service"
  value       = "meety"
}
