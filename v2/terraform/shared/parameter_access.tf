# 기존 수동 정책에는 Service 태그만 있다. 공통 provider의 default_tags 추가를 피한다.
provider "aws" {
  alias               = "parameter_access"
  region              = var.region
  allowed_account_ids = ["062270568040"]
}

# IAM은 전역 리소스다. 기존 이름과 설명을 유지해 정책 교체 없이 권한만 관리한다.
resource "aws_iam_policy" "parameter_access" {
  provider    = aws.parameter_access
  name        = "meety-params-viewer"
  path        = "/"
  description = "meety-params-only-viewer"
  tags        = { Service = "meety" }

  # 값과 이력 조회는 현재 계정의 모든 리전, 쓰기는 서울 애플리케이션 경로로 제한한다.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ConsoleList"
        Effect   = "Allow"
        Action   = ["ssm:DescribeParameters"]
        Resource = "*"
      },
      {
        Sid    = "ReadAllParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
          "ssm:GetParameterHistory",
          "ssm:ListTagsForResource",
        ]
        Resource = "arn:aws:ssm:*:062270568040:parameter/*"
      },
      {
        Sid    = "EditSeoulApplicationParameters"
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:DeleteParameter",
          "ssm:DeleteParameters",
          "ssm:AddTagsToResource",
        ]
        # DB, 상위 경로, 다른 환경과 리전은 쓰기 범위에 포함하지 않는다.
        Resource = [
          "arn:aws:ssm:ap-northeast-2:062270568040:parameter/meety/staging/be/*",
          "arn:aws:ssm:ap-northeast-2:062270568040:parameter/meety/staging/fe/*",
          "arn:aws:ssm:ap-northeast-2:062270568040:parameter/meety/staging/ai/*",
          "arn:aws:ssm:ap-northeast-2:062270568040:parameter/meety/prod/be/*",
          "arn:aws:ssm:ap-northeast-2:062270568040:parameter/meety/prod/fe/*",
          "arn:aws:ssm:ap-northeast-2:062270568040:parameter/meety/prod/ai/*",
        ]
      },
    ]
  })
}

# 그룹과 사용자 자체를 새로 관리하지 않고 기존 정책 연결만 가져온다.
resource "aws_iam_group_policy_attachment" "parameter_access" {
  provider   = aws.parameter_access
  group      = "meety-params-editors"
  policy_arn = aws_iam_policy.parameter_access.arn
}

import {
  to = aws_iam_policy.parameter_access
  id = "arn:aws:iam::062270568040:policy/meety-params-viewer"
}

import {
  to = aws_iam_group_policy_attachment.parameter_access
  id = "meety-params-editors/arn:aws:iam::062270568040:policy/meety-params-viewer"
}
