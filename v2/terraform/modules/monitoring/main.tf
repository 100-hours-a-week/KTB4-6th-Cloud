# 환경마다 독립된 모니터링 서버를 만든다 (Prometheus, Loki, Grafana).
# staging과 prod를 나눠 서로의 부하와 장애가 영향을 주지 않게 한다.

# 서버의 /opt/meety/monitoring에 둘 설정 파일. 첫 부팅(user_data)과 이후 반영(v2/monitoring/sync-config.sh)이
# 같은 렌더링 결과(output config_files)를 쓰도록 여기서 한 번만 만든다
locals {
  config_files = {
    "docker-compose.yml" = templatefile("${var.config_dir}/docker-compose.yml.tftpl", {
      prometheus_image = var.prometheus_image
      loki_image       = var.loki_image
      grafana_image    = var.grafana_image
      grafana_domain   = var.grafana_domain
    })
    "prometheus.yml" = templatefile("${var.config_dir}/prometheus.yml.tftpl", {
      env           = var.env
      region        = var.region
      cluster_arn   = var.ecs_cluster_arn
      service_regex = join("|", var.ecs_scrape_services)
      port          = var.ecs_scrape_port
    })
    "loki.yml"                = file("${var.config_dir}/loki.yml")
    "grafana-datasources.yml" = templatefile("${var.config_dir}/grafana-datasources.yml.tftpl", { region = var.region })
  }
}

resource "aws_security_group" "monitoring" {
  name        = "${var.name_prefix}-monitoring-sg"
  description = "Grafana from ALB, Loki from environment log shippers"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-monitoring-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "grafana_from_alb" {
  security_group_id            = aws_security_group.monitoring.id
  description                  = "Grafana from ALB"
  referenced_security_group_id = var.alb_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
}

# 수집 대상(BE, exporter)으로의 연결, 이미지 다운로드, CloudWatch 조회에 사용한다
resource "aws_vpc_security_group_egress_rule" "outbound" {
  security_group_id = aws_security_group.monitoring.id
  description       = "Outbound via environment NAT"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_iam_role" "monitoring" {
  name = "${var.name_prefix}-monitoring"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.name_prefix}-monitoring" }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "params" {
  name = "read-grafana-admin-password"
  role = aws_iam_role.monitoring.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadGrafanaAdminPassword"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = var.grafana_admin_password_parameter_arn
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
        # SSM 관리형 정책의 넓은 조회 권한을 제한한다. DB 비밀번호 등 다른 값은 읽을 수 없다.
        Sid    = "DenyOtherParameters"
        Effect = "Deny"
        Action = [
          "ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory",
        ]
        NotResource = [var.grafana_admin_password_parameter_arn, "arn:aws:ssm:*::parameter/aws/*"]
      },
    ]
  })
}

# Grafana CloudWatch 데이터 소스가 ALB, ECS 지표와 로그를 읽는 권한 (Grafana 문서의 최소 권한 기준)
resource "aws_iam_role_policy" "cloudwatch_read" {
  name = "grafana-cloudwatch-read"
  role = aws_iam_role.monitoring.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarmsForMetric", "cloudwatch:DescribeAlarmHistory", "cloudwatch:DescribeAlarms",
          "cloudwatch:ListMetrics", "cloudwatch:GetMetricData", "cloudwatch:GetInsightRuleReport",
        ]
        Resource = "*"
      },
      {
        Sid    = "ReadLogs"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups", "logs:GetLogGroupFields", "logs:StartQuery", "logs:StopQuery",
          "logs:GetQueryResults", "logs:GetLogEvents",
        ]
        Resource = "*"
      },
      {
        Sid      = "ReadResourceNames"
        Effect   = "Allow"
        Action   = ["ec2:DescribeTags", "ec2:DescribeInstances", "ec2:DescribeRegions", "tag:GetResources"]
        Resource = "*"
      },
    ]
  })
}

# 내장 ECS 탐색은 클러스터/서비스/태스크를 조회한다. 목록은 해당 환경으로 제한한다.
resource "aws_iam_role_policy" "ecs_read" {
  name = "read-ecs-tasks"
  role = aws_iam_role.monitoring.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # SDK 초기 인증 검사에서 클러스터 미지정 DescribeClusters도 호출한다.
        Sid      = "DescribeClusters"
        Effect   = "Allow"
        Action   = "ecs:DescribeClusters"
        Resource = "*"
      },
      {
        Sid      = "ListEnvironmentServicesAndTasks"
        Effect   = "Allow"
        Action   = ["ecs:ListServices", "ecs:ListTasks"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = var.ecs_cluster_arn }
        }
      },
      {
        Sid    = "DescribeEnvironmentServicesAndTasks"
        Effect = "Allow"
        Action = ["ecs:DescribeServices", "ecs:DescribeTasks"]
        Resource = [
          "${replace(var.ecs_cluster_arn, ":cluster/", ":service/")}/*",
          "${replace(var.ecs_cluster_arn, ":cluster/", ":task/")}/*",
        ]
      },
      {
        # 내장 탐색은 ENI의 공인 IP도 조회하지만 실제 수집에는 사설 IP를 사용한다.
        Sid      = "DescribeNetworkInterfaces"
        Effect   = "Allow"
        Action   = "ec2:DescribeNetworkInterfaces"
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = var.region }
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "${var.name_prefix}-monitoring"
  role = aws_iam_role.monitoring.name
  tags = { Name = "${var.name_prefix}-monitoring" }
}

resource "aws_instance" "monitoring" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  private_ip                  = var.private_ip
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.monitoring.id]
  iam_instance_profile        = aws_iam_instance_profile.monitoring.name

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region         = var.region
    parameter_name = split(":parameter", var.grafana_admin_password_parameter_arn)[1]
    files          = local.config_files
  })

  # 초기 용량은 실측 전이다. CPU 크레딧 소진으로 추가 요금이 발생하지 않게 한다.
  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens = "required"
    # Grafana 컨테이너가 인스턴스 역할로 CloudWatch를 읽으려면 컨테이너 네트워크를 한 번 더 거쳐야 한다
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
    tags                  = merge(var.volume_tags, { Name = "${var.name_prefix}-monitoring-root" })
  }

  # user_data는 첫 부팅 때만 쓴다. 이후 설정 변경은 서버에 직접 반영해, 설정을 고칠 때마다 서버가 재시작되지 않게 한다.
  lifecycle {
    ignore_changes = [user_data]
  }

  # 인스턴스 첫 부팅 전에 파라미터 조회와 SSM 권한이 준비되어야 한다.
  depends_on = [aws_iam_role_policy.params, aws_iam_role_policy_attachment.ssm, aws_iam_role_policy.ecs_read]
  tags       = { Name = "${var.name_prefix}-monitoring" }
}

resource "aws_ec2_tag" "eni_service" {
  resource_id = aws_instance.monitoring.primary_network_interface_id
  key         = "Service"
  value       = "meety"
}

# Grafana: 공용 ALB에서 도메인으로 접속한다
resource "aws_lb_target_group" "grafana" {
  name        = "${var.name_prefix}-grafana-tg"
  vpc_id      = var.vpc_id
  target_type = "instance"
  protocol    = "HTTP"
  port        = 3000

  deregistration_delay = 30

  health_check {
    path                = "/api/health"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.name_prefix}-grafana-tg" }
}

resource "aws_lb_target_group_attachment" "grafana" {
  target_group_arn = aws_lb_target_group.grafana.arn
  target_id        = aws_instance.monitoring.id
  port             = 3000
}

resource "aws_lb_listener_rule" "grafana" {
  listener_arn = var.https_listener_arn
  priority     = var.listener_rule_priority

  condition {
    host_header {
      values = [var.grafana_domain]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }

  tags = { Name = "${var.name_prefix}-grafana-rule" }
}
