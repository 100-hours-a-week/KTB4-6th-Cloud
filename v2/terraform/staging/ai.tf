# staging AI 인스턴스: 실시간 STT(ai-live)를 실행한다. 분석(ai-analysis)은 아래 ai_analysis 인스턴스로 옮겼다 (2026-10-17).
# 처음에는 V1 dev AI 구성(컨테이너 2개)을 기준으로 두 앱을 함께 띄웠다. user_data는 그때의 첫 부팅 설정이며,
# 바꾸면 인스턴스가 중지 후 다시 시작되므로 그대로 둔다. 실제 실행 구성은 AI 저장소의 배포 workflow가 정한다.

resource "aws_instance" "ai" {
  ami           = var.ai_ami_id
  instance_type = var.ai_instance_type

  # private 서브넷(2a). public IP 없이 FE/NAT 인스턴스를 거쳐 외부로 나간다
  subnet_id                   = aws_subnet.private[0].id
  vpc_security_group_ids      = [aws_security_group.ai.id]
  iam_instance_profile        = aws_iam_instance_profile.ai.name
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user_data/ai.sh.tftpl", {
    region                 = var.region
    internal_api_key_param = "/meety/${var.env}/be/INTERNAL_API_KEY"
    ai_image               = var.ai_image
    # 챗봇 처리 중 AI가 BE 내부 API를 부른다. BE는 Fargate라 IP가 바뀌므로 ALB 주소로 부른다
    backend_base_url = "https://${var.be_domain}"
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

# staging AI 분석 인스턴스: 회의 후 요약, 챗봇(ai-analysis)을 실시간 STT(ai-live)와 다른 인스턴스에서 실행한다 (2026-10-17).
# - live는 진행 중인 회의 수에 비례해 메모리(회의마다 디코더)를 쓰고, analysis는 요청 수에 비례해 부하가 는다.
#   한 인스턴스에 두면 회의 종료 때 몰리는 요약 처리가 live의 메모리를 빼앗을 수 있어 나눈다.
# - ai 인스턴스와 같은 역할(aws_iam_instance_profile.ai)을 쓴다. 읽는 파라미터 범위가 같다.
resource "aws_instance" "ai_analysis" {
  ami           = var.ai_ami_id
  instance_type = var.ai_analysis_instance_type

  # private 서브넷(2a). public IP 없이 FE/NAT 인스턴스를 거쳐 외부로 나간다
  subnet_id                   = aws_subnet.private[0].id
  vpc_security_group_ids      = [aws_security_group.ai_analysis.id]
  iam_instance_profile        = aws_iam_instance_profile.ai.name
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user_data/ai_analysis.sh.tftpl", {})

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
