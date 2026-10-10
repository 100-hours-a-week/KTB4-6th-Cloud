locals {
  # 환경별 리소스의 이름 접두사. 예: meety-v2-staging-be
  name_prefix = "${var.project}-v2-${var.env}"

  # Parameter Store 비밀값 ARN의 공통 앞부분. 예: <prefix>/db/DB_PASSWORD
  param_arn_prefix = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/meety/${var.env}"
}
