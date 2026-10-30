# #89 Redis Sentinel 장애 실험용 임시 권한. 실험이 끝나면 이 파일을 지우고 apply한 뒤 main에 머지한다.
# meety-viewer 사용자 자체는 관리하지 않고, staging Redis 서버 셸 접속만 인라인 정책으로 붙였다 뗀다.
resource "aws_iam_user_policy" "redis_test_access" {
  name = "${local.name_prefix}-redis-test-session"
  user = "meety-viewer"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StartSessionToStagingRedis"
        Effect = "Allow"
        Action = "ssm:StartSession"
        Resource = [
          "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/${module.redis.instance_id}",
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:document/SSM-SessionManagerRunShell",
        ]
        # 기존 dev MySQL 터널과 같이, 문서 검사 키가 없는 요청도 통과하도록 BoolIfExists를 쓴다.
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
