# prod 기존 awslogs를 유지하며 CloudWatch → Lambda → 사설 Loki 경로를 추가한다.
# BE 재배포·서비스 중지·장애 재현 없이 실제 BE 로그 그룹만 구독한다.
variable "loki_log_shipping_enabled" {
  description = "최초 구축은 false로 서버를 먼저 준비하고 Loki ready 확인 후 true로 로그 구독을 연결한다"
  type        = bool
  default     = true
}

locals {
  loki_forwarder_name    = "${local.name_prefix}-loki-forwarder"
  loki_forwarder_release = jsondecode(file("${path.module}/../../monitoring/lambda-promtail.release.json"))
  loki_forwarder_zip     = "${path.module}/../../monitoring/.artifacts/${local.loki_forwarder_release.filename}"
  loki_forwarder_sources = {
    be = aws_cloudwatch_log_group.be
  }
}

resource "aws_cloudwatch_log_group" "loki_forwarder" {
  name              = "/aws/lambda/${local.loki_forwarder_name}"
  retention_in_days = 14
}

resource "aws_security_group" "loki_forwarder" {
  name        = "${local.loki_forwarder_name}-sg"
  description = "CloudWatch log forwarder to private Loki only"
  vpc_id      = local.shared.vpc_id
  tags        = { Name = "${local.loki_forwarder_name}-sg" }
}

# 사설 Loki로만 전송한다. 인터넷 egress나 공개 Loki endpoint는 만들지 않는다.
resource "aws_vpc_security_group_egress_rule" "loki_forwarder" {
  security_group_id            = aws_security_group.loki_forwarder.id
  referenced_security_group_id = module.monitoring.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 3100
  to_port                      = 3100
}

resource "aws_vpc_security_group_ingress_rule" "loki_from_forwarder" {
  security_group_id            = module.monitoring.security_group_id
  referenced_security_group_id = aws_security_group.loki_forwarder.id
  description                  = "Loki push from prod log forwarder"
  ip_protocol                  = "tcp"
  from_port                    = 3100
  to_port                      = 3100
}

resource "aws_iam_role" "loki_forwarder" {
  name = local.loki_forwarder_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "loki_forwarder" {
  name = "vpc-and-own-execution-logs"
  role = aws_iam_role.loki_forwarder.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Lambda VPC 연결에 필요한 ENI 권한. BE 로그 조회나 비밀값 조회 권한은 부여하지 않는다.
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces", "ec2:DescribeSubnets",
          "ec2:DeleteNetworkInterface", "ec2:AssignPrivateIpAddresses", "ec2:UnassignPrivateIpAddresses",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.loki_forwarder.arn}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "loki_forwarder" {
  function_name    = local.loki_forwarder_name
  description      = "Pinned Grafana Lambda Promtail: prod CloudWatch logs to private Loki"
  role             = aws_iam_role.loki_forwarder.arn
  filename         = local.loki_forwarder_zip
  source_code_hash = filebase64sha256(local.loki_forwarder_zip)
  runtime          = local.loki_forwarder_release.runtime
  architectures    = [local.loki_forwarder_release.architecture]
  handler          = "bootstrap"
  memory_size      = 256
  # 5초 HTTP timeout과 내장 backoff가 끝나고 실패를 반환할 여유를 둔다.
  timeout = 180

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.loki_forwarder.id]
  }

  environment {
    variables = {
      WRITE_ADDRESS            = "http://${module.monitoring.private_ip}:3100/loki/api/v1/push"
      EXTRA_LABELS             = "env,${var.env},service,be,source,cloudwatch"
      OMIT_EXTRA_LABELS_PREFIX = "true"
      # 앱 로그를 Lambda 실행 로그에 다시 복사하지 않는다. 재귀 구독도 만들지 않는다.
      PRINT_LOG_LINE = "false"
      KEEP_STREAM    = "false"
      BATCH_SIZE     = "131072"
      LOG_LEVEL      = "info"
      # 원본 그룹만 정규 라벨로 복사한다. prod에는 리허설 서비스 분류가 없다.
      LOKI_STAGE_CONFIGS = jsonencode([
        { labels = { log_group = "__aws_cloudwatch_log_group" } },
        { labeldrop = ["__aws_cloudwatch_log_group", "__aws_cloudwatch_owner", "__aws_log_type"] },
      ])
    }
  }

  lifecycle {
    precondition {
      condition     = filesha256(local.loki_forwarder_zip) == local.loki_forwarder_release.sha256
      error_message = "공식 Lambda ZIP 해시가 다릅니다. v2/monitoring/prepare-lambda-promtail.py로 준비하세요."
    }
  }

  depends_on = [aws_iam_role_policy.loki_forwarder, aws_vpc_security_group_ingress_rule.loki_from_forwarder, aws_vpc_security_group_egress_rule.loki_forwarder]
}

# 운영 중 일시적인 전달 오류에 대비해 AWS 비동기 재시도를 유지한다.
resource "aws_lambda_function_event_invoke_config" "loki_forwarder" {
  function_name                = aws_lambda_function.loki_forwarder.function_name
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600
}

resource "aws_lambda_permission" "loki_forwarder" {
  for_each = local.loki_forwarder_sources

  statement_id   = "CloudWatch-${each.key}"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.loki_forwarder.function_name
  principal      = "logs.${var.region}.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
  source_arn     = "${each.value.arn}:*"
}

# 실제 BE 로그만 구독한다. Lambda 실행 로그는 재귀 전달하지 않는다.
resource "aws_cloudwatch_log_subscription_filter" "loki_forwarder" {
  # EC2 생성 완료와 Loki 기동 완료는 다르므로 초기 apply에서 구독만 보류할 수 있게 한다.
  for_each = var.loki_log_shipping_enabled ? local.loki_forwarder_sources : {}

  name            = "${local.loki_forwarder_name}-${each.key}"
  log_group_name  = each.value.name
  filter_pattern  = ""
  destination_arn = aws_lambda_function.loki_forwarder.arn

  depends_on = [aws_lambda_permission.loki_forwarder, aws_lambda_function_event_invoke_config.loki_forwarder]
}

# ALARM과 OK 전환을 전용 Lambda로 전달한다. OK는 누락분 복구 완료를 의미하지 않는다.
resource "aws_cloudwatch_metric_alarm" "loki_forwarder" {
  for_each = toset(["Errors", "AsyncEventsDropped"])

  alarm_name          = "${local.loki_forwarder_name}-${each.key}"
  alarm_description   = "Production log delivery failure; inspect Lambda logs and recover missing CloudWatch events"
  namespace           = "AWS/Lambda"
  metric_name         = each.key
  dimensions          = { FunctionName = aws_lambda_function.loki_forwarder.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.discord_notifier.arn]
  ok_actions          = [aws_lambda_function.discord_notifier.arn]

  # 호출 권한과 재시도 설정이 준비된 뒤 Alarm의 전달 대상을 연결한다.
  depends_on = [aws_lambda_permission.discord_notifier, aws_lambda_function_event_invoke_config.discord_notifier]
}

output "loki_log_shipping" {
  description = "prod 로그 전달 점검과 수동 재전송용 설정. 비밀값은 포함하지 않는다"
  value = {
    env                    = var.env
    region                 = var.region
    function_name          = aws_lambda_function.loki_forwarder.function_name
    function_log_group     = aws_cloudwatch_log_group.loki_forwarder.name
    allowed_log_groups     = [for group in local.loki_forwarder_sources : group.name]
    monitoring_instance_id = module.monitoring.instance_id
  }
}
