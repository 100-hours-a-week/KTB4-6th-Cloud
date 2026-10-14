# dev 서버 역할이 dev 밖의 파라미터를 읽지 못하게 막는다 (2026-10-12)
# - 모든 인스턴스에 붙은 AWS 관리형 정책 AmazonSSMManagedInstanceCore가 ssm:GetParameter(s)를 모든 파라미터(*)에 허용한다.
#   그래서 meety-params-read-server의 범위를 줄이는 것만으로는 이름을 아는 값 하나씩 읽기를 막을 수 없다.
# - Deny는 Allow보다 우선하므로 dev 경로와 AWS 공개 파라미터를 뺀 나머지 읽기를 거부한다.
# - meety-ec2-cloudwatch-role은 prod AI(ai-v1-meety)도 같이 쓴다. prod는 Parameter Store를 쓰지 않아 지금은 영향이 없지만,
#   나중에 prod 값을 Parameter Store에 두려면 prod AI 역할을 먼저 분리해야 한다.
resource "aws_iam_policy" "params_deny_outside_dev" {
  name        = "meety-params-deny-outside-dev"
  description = "dev 경로 밖의 Parameter Store 읽기를 거부한다"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyParamsOutsideDev"
      Effect = "Deny"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath",
        "ssm:GetParameterHistory",
      ]
      NotResource = [
        "arn:aws:ssm:us-east-2:${local.account_id}:parameter/meety/dev",
        "arn:aws:ssm:us-east-2:${local.account_id}:parameter/meety/dev/*",
        # AMI ID 등 AWS가 공개하는 파라미터
        "arn:aws:ssm:*::parameter/aws/*",
      ]
    }]
  })

  tags = {
    Service = "meety"
  }
}

resource "aws_iam_role_policy_attachment" "ec2_dev_params_deny" {
  role       = aws_iam_role.ec2_dev.name
  policy_arn = aws_iam_policy.params_deny_outside_dev.arn
}

resource "aws_iam_role_policy_attachment" "ec2_cloudwatch_params_deny" {
  role       = aws_iam_role.ec2_cloudwatch.name
  policy_arn = aws_iam_policy.params_deny_outside_dev.arn
}
