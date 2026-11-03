# 매일 한국 시간 00:00에 staging을 종료한다. 켜기는 수동 스크립트를 사용한다.
# 대상: BE ECS 2개, AI EC2 2대, 모니터링 EC2. FE·DB·Replica·Redis는 유지한다.
# 종료 예약은 한 번만 실행하므로 자정 이후 수동으로 켜면 다음 자정까지 유지된다.
locals {
  power_timezone = "Asia/Seoul"
  power_off_cron = "cron(0 0 * * ? *)"

  power_instance_ids = [aws_instance.ai.id, aws_instance.ai_analysis.id, module.monitoring.instance_id]

  power_scalable_targets = {
    be-api      = aws_appautoscaling_target.be_api
    be-realtime = aws_appautoscaling_target.be_realtime
  }
}

# ECS: 태스크 수만 0으로 바꾸면 오토스케일링이 최소값으로 되돌리므로, 최소·최대값 자체를 바꾼다
resource "aws_appautoscaling_scheduled_action" "be_off" {
  for_each = local.power_scalable_targets

  name               = "${local.name_prefix}-${each.key}-off"
  service_namespace  = each.value.service_namespace
  resource_id        = each.value.resource_id
  scalable_dimension = each.value.scalable_dimension
  schedule           = local.power_off_cron
  timezone           = local.power_timezone

  scalable_target_action {
    min_capacity = 0
    max_capacity = 0
  }
}

# EC2: EventBridge Scheduler가 종료 API를 직접 호출한다 (Lambda 없음)
resource "aws_scheduler_schedule_group" "power" {
  name = "${local.name_prefix}-power"

  tags = {
    Name = "${local.name_prefix}-power"
  }
}

resource "aws_iam_role" "power_scheduler" {
  name = "${local.name_prefix}-power-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })

  tags = {
    Name = "${local.name_prefix}-power-scheduler"
  }
}

# 대상 서버만 종료할 수 있다. 루트 볼륨은 AWS 관리형 키(aws/ebs)라 KMS 권한은 따로 필요 없다
resource "aws_iam_role_policy" "power_scheduler" {
  name = "stop-staging-instances"
  role = aws_iam_role.power_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ec2:StopInstances"]
      Resource = [
        for id in local.power_instance_ids :
        "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/${id}"
      ]
    }]
  })
}

resource "aws_scheduler_schedule" "ec2" {
  for_each = {
    off = { cron = local.power_off_cron, api = "stopInstances" }
  }

  name                         = "${local.name_prefix}-ec2-${each.key}"
  group_name                   = aws_scheduler_schedule_group.power.name
  schedule_expression          = each.value.cron
  schedule_expression_timezone = local.power_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:${each.value.api}"
    role_arn = aws_iam_role.power_scheduler.arn
    input    = jsonencode({ InstanceIds = local.power_instance_ids })

    retry_policy {
      maximum_retry_attempts = 3
    }
  }
}
