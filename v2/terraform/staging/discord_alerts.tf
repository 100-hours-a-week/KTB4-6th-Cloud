# 전달용 Lambda와 분리된 알림 전용 Lambda. Grafana EC2 장애에도 Alarm을 보낼 수 있게 둔다.
# VPC에 연결하지 않아 Discord·SSM 접근을 위한 NAT나 보안 그룹은 추가하지 않는다.
locals {
  discord_notifier_name = "${local.name_prefix}-discord-notifier"
  discord_webhook_name  = "/meety/${var.env}/monitoring/DISCORD_WEBHOOK_URL"
  discord_webhook_arn   = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.discord_webhook_name}"
  discord_alarm_arns = {
    for metric in ["Errors", "AsyncEventsDropped"] : metric =>
    "arn:aws:cloudwatch:${var.region}:${data.aws_caller_identity.current.account_id}:alarm:${local.loki_forwarder_name}-${metric}"
  }
}

resource "aws_cloudwatch_log_group" "discord_notifier" {
  name              = "/aws/lambda/${local.discord_notifier_name}"
  retention_in_days = 14
}

resource "aws_iam_role" "discord_notifier" {
  name = local.discord_notifier_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "discord_notifier" {
  name = "read-own-webhook-and-write-execution-logs"
  role = aws_iam_role.discord_notifier.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = local.discord_webhook_arn
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = data.aws_kms_alias.ssm.target_key_arn
        Condition = {
          StringEquals = {
            "kms:ViaService"                      = "ssm.${var.region}.amazonaws.com"
            "kms:EncryptionContext:PARAMETER_ARN" = local.discord_webhook_arn
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.discord_notifier.arn}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "discord_notifier" {
  function_name    = local.discord_notifier_name
  description      = "Staging CloudWatch log delivery alarms to Discord"
  role             = aws_iam_role.discord_notifier.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "discord_notifier.handler"
  filename         = "${path.module}/../../monitoring/.artifacts/discord-notifier.zip"
  source_code_hash = filebase64sha256("${path.module}/../../monitoring/.artifacts/discord-notifier.zip")
  memory_size      = 128
  timeout          = 45

  environment {
    variables = {
      ENVIRONMENT            = var.env
      EXPECTED_ACCOUNT_ID    = data.aws_caller_identity.current.account_id
      WEBHOOK_PARAMETER      = local.discord_webhook_name
      LOG_FORWARDER_FUNCTION = local.loki_forwarder_name
      GRAFANA_URL            = "https://${var.monitoring_grafana_domain}/explore"
      # ARN을 문자열로 구성해 Alarm → Lambda → Alarm 순환 의존성을 피한다.
      ALARM_METRICS = jsonencode({ for metric, arn in local.discord_alarm_arns : arn => metric })
    }
  }

  depends_on = [aws_iam_role_policy.discord_notifier]
}

# 웹훅 429/일시 오류에 대한 코드 내 재시도 외에 함수 실패 시 AWS 재시도를 유지한다.
resource "aws_lambda_function_event_invoke_config" "discord_notifier" {
  function_name                = aws_lambda_function.discord_notifier.function_name
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600
}

resource "aws_lambda_permission" "discord_notifier" {
  for_each = local.discord_alarm_arns

  statement_id   = "CloudWatchAlarm-${each.key}"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.discord_notifier.function_name
  principal      = "lambda.alarms.cloudwatch.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
  source_arn     = each.value
}

output "discord_log_alerts" {
  description = "staging 알림 검증용 메타데이터. 웹훅 값은 Terraform에서 읽거나 저장하지 않는다"
  value = {
    env            = var.env
    region         = var.region
    function_name  = aws_lambda_function.discord_notifier.function_name
    alarm_arns     = local.discord_alarm_arns
    parameter_name = local.discord_webhook_name
    log_group_name = aws_cloudwatch_log_group.discord_notifier.name
  }
}
