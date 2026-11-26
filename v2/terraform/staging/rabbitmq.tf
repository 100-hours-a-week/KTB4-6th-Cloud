# staging RabbitMQ 서버 (#102): BE–AI 작업 전달을 비동기로 바꾸기 위한 개발·연동 검증용 단일 서버.
# Cloud는 서버, 네트워크, 접속 권한과 Docker 설치까지만 준비한다. RabbitMQ 설치, 큐 구성, 앱 연동은 BE가 맡는다.
# - AMQP 5672는 staging BE와 AI 2대의 보안 그룹에서만 받는다.
# - 관리 화면 15672는 보안 그룹에서 열지 않는다. SSM 포트 포워딩으로 서버 안에서만 접근한다.
# - SSH는 열지 않고 SSM으로 접속한다. 자정 종료 예약 대상이다(power_schedule.tf).

resource "aws_security_group" "rabbitmq" {
  name        = "${local.name_prefix}-rabbitmq-sg"
  description = "V2 staging RabbitMQ instance"
  vpc_id      = local.shared.vpc_id

  tags = {
    Name = "${local.name_prefix}-rabbitmq-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rabbitmq_amqp" {
  for_each = {
    be          = aws_security_group.be.id
    ai          = aws_security_group.ai.id
    ai-analysis = aws_security_group.ai_analysis.id
  }

  security_group_id            = aws_security_group.rabbitmq.id
  description                  = "AMQP from staging ${each.key}"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5672
  to_port                      = 5672
}

# 패키지와 이미지 받기, SSM 연결은 FE/NAT 인스턴스를 거쳐 인터넷으로 나간다
resource "aws_vpc_security_group_egress_rule" "rabbitmq_all" {
  security_group_id = aws_security_group.rabbitmq.id
  description       = "Outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# 서버 역할은 SSM 접속만 허용한다. 파라미터나 다른 AWS 리소스는 읽지 않는다.
resource "aws_iam_role" "rabbitmq" {
  name = "${local.name_prefix}-rabbitmq"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${local.name_prefix}-rabbitmq"
  }
}

resource "aws_iam_role_policy_attachment" "rabbitmq_ssm" {
  role       = aws_iam_role.rabbitmq.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "rabbitmq" {
  name = "${local.name_prefix}-rabbitmq"
  role = aws_iam_role.rabbitmq.name

  tags = {
    Name = "${local.name_prefix}-rabbitmq"
  }
}

resource "aws_instance" "rabbitmq" {
  ami           = var.rabbitmq_ami_id
  instance_type = var.rabbitmq_instance_type

  # private 서브넷(2a). public IP 없이 FE/NAT 인스턴스를 거쳐 외부로 나간다
  subnet_id                   = aws_subnet.private[0].id
  vpc_security_group_ids      = [aws_security_group.rabbitmq.id]
  iam_instance_profile        = aws_iam_instance_profile.rabbitmq.name
  associate_public_ip_address = false

  # 첫 부팅에 Docker만 설치한다. 바꾸면 인스턴스가 중지 후 다시 시작되므로 RabbitMQ 설정은 넣지 않는다.
  user_data = file("${path.module}/user_data/rabbitmq.sh")

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
    volume_size           = var.rabbitmq_root_volume_size
    encrypted             = true
    delete_on_termination = true

    # provider default_tags는 루트 볼륨에 자동으로 붙지 않아서 직접 지정한다
    tags = {
      Name      = "${local.name_prefix}-rabbitmq-root"
      Service   = "meety"
      Project   = var.project
      Version   = "v2"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }

  # 첫 부팅의 패키지 설치는 NAT 경로가 준비된 뒤에 해야 한다
  depends_on = [aws_route.private_nat, aws_route_table_association.private, aws_iam_role_policy_attachment.rabbitmq_ssm]

  tags = {
    Name = "${local.name_prefix}-rabbitmq"
  }
}

# 인스턴스와 함께 만들어지는 기본 네트워크 인터페이스에도 default_tags가 붙지 않아 Service 태그를 직접 붙인다
resource "aws_ec2_tag" "rabbitmq_eni_service" {
  resource_id = aws_instance.rabbitmq.primary_network_interface_id
  key         = "Service"
  value       = "meety"
}

# BE 담당자(meety-viewer)가 RabbitMQ 서버에 셸 접속과 관리 화면 포트 포워딩을 할 수 있게 한다.
# meety-viewer 사용자 자체는 관리하지 않고, 이 서버 접속만 인라인 정책으로 붙인다.
resource "aws_iam_user_policy" "rabbitmq_access" {
  name = "${local.name_prefix}-rabbitmq-session"
  user = "meety-viewer"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StartSessionToStagingRabbitmq"
        Effect = "Allow"
        Action = "ssm:StartSession"
        Resource = [
          "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.rabbitmq.id}",
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:document/SSM-SessionManagerRunShell",
          "arn:aws:ssm:${var.region}::document/AWS-StartPortForwardingSession",
        ]
        # 기존 Redis 실험 권한과 같이, 문서 검사 키가 없는 요청도 통과하도록 BoolIfExists를 쓴다.
        Condition = { BoolIfExists = { "ssm:SessionDocumentAccessCheck" = "true" } }
      },
      {
        Sid      = "OwnSessionsOnly"
        Effect   = "Allow"
        Action   = ["ssm:TerminateSession", "ssm:ResumeSession", "ssmmessages:OpenDataChannel"]
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:session/$${aws:username}-*"
      },
    ]
  })
}
