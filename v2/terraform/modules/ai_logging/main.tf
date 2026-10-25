# AI 저장소의 Docker 실행 옵션은 유지하고, 전용 EC2의 json-file 로그를 Agent로 수집한다.
resource "aws_cloudwatch_log_group" "ai" {
  for_each = var.instance_ids

  name              = "/ec2/${var.name_prefix}/ai-${each.key}"
  retention_in_days = var.retention_in_days
}

# 로그 그룹 생성과 보존 정책 변경은 Terraform만 담당한다. Agent에는 전송 권한만 준다.
resource "aws_iam_role_policy" "ai_logs" {
  name = "write-ai-container-logs"
  role = var.instance_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = [for group in aws_cloudwatch_log_group.ai : "${group.arn}:*"]
    }]
  })
}

locals {
  agent_configs = {
    for role in keys(var.instance_ids) : role => jsonencode({
      agent = {
        region      = var.region
        run_as_user = "root"
      }
      logs = {
        force_flush_interval = 5
        logs_collected = {
          files = {
            collect_list = [{
              # 전용 인스턴스의 모든 컨테이너를 수집하므로 blue/green 교체 때 설정을 갱신할 필요가 없다.
              # 기본 wildcard 모드는 최신 파일만 선택한다. 여러 슬롯을 함께 읽도록 명시한다.
              file_path          = "/var/lib/docker/containers/*/*-json.log"
              publish_multi_logs = true
              log_group_name     = aws_cloudwatch_log_group.ai[role].name
              # 다중 파일 모드는 파일 경로를 suffix로 붙여 컨테이너별 스트림을 만든다.
              log_stream_name = "{instance_id}"
              # Docker가 원본 파일과 로테이션을 관리한다. Agent는 삭제하지 않는다.
              auto_removal = false
            }]
          }
        }
      }
    })
  }
}

# user_data를 수정하면 기존 EC2가 중지/시작될 수 있어 State Manager로 설치한다.
# 설치와 설정을 한 문서에서 순차 실행해 비동기 Association 사이의 설치 경합을 피한다.
resource "aws_ssm_document" "ai_logs" {
  for_each = var.instance_ids

  name            = "${var.name_prefix}-ai-${each.key}-logs"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install CloudWatch Agent and collect AI Docker JSON logs"
    mainSteps = [
      {
        action = "aws:configurePackage"
        name   = "installAgent"
        inputs = {
          name             = "AmazonCloudWatchAgent"
          action           = "Install"
          installationType = "In-place update"
          # AWS 공식 Distributor 패키지 버전을 고정한다. publish_multi_logs를 지원한다.
          version = "1.300074.0b1920"
        }
      },
      {
        action = "aws:runShellScript"
        name   = "configureAgent"
        inputs = {
          timeoutSeconds = "120"
          runCommand = [<<-SCRIPT
            #!/bin/sh
            # 동일 설정 재적용 시 Agent를 재시작하지 않고, 수집 위치 상태 파일도 보존한다.
            set -eu
            config=/opt/aws/amazon-cloudwatch-agent/etc/meety-ai.json
            umask 077
            cat > "$config.new" <<'CONFIG'
            ${local.agent_configs[each.key]}
            CONFIG
            systemctl enable amazon-cloudwatch-agent
            if ! cmp -s "$config.new" "$config"; then
              /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
                -a fetch-config -m ec2 -s -c "file:$config.new"
              mv "$config.new" "$config"
            else
              rm -f "$config.new"
              systemctl start amazon-cloudwatch-agent
            fi
            systemctl is-active --quiet amazon-cloudwatch-agent
          SCRIPT
          ]
        }
      },
    ]
  })
}

# EC2가 교체돼도 새 ID에 다시 적용한다. apply 시 원격 설치가 실행되므로 plan 확인 후 반영한다.
resource "aws_ssm_association" "ai_logs" {
  for_each = var.instance_ids

  name                = aws_ssm_document.ai_logs[each.key].name
  association_name    = "${var.name_prefix}-ai-${each.key}-logs"
  document_version    = aws_ssm_document.ai_logs[each.key].latest_version
  compliance_severity = "HIGH"

  targets {
    key    = "InstanceIds"
    values = [each.value]
  }

  # 설치 성공까지 기다려 설치/설정 실패를 Terraform 실행 결과에서 확인한다.
  wait_for_success_timeout_seconds = 600

  depends_on = [aws_iam_role_policy.ai_logs]
}

output "log_group_names" {
  description = "역할별 AI Docker 로그 그룹"
  value       = { for role, group in aws_cloudwatch_log_group.ai : role => group.name }
}
