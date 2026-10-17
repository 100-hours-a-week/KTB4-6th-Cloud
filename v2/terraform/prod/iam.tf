# ECS 태스크 실행 역할: ECS가 이미지를 받고, 로그를 CloudWatch에 쓰고, 컨테이너에 넣을 비밀값을 읽는 데 쓴다.
# 컨테이너 안의 앱이 쓰는 권한(S3)은 아래 태스크 역할로 따로 준다.

resource "aws_iam_role" "ecs_execution" {
  name = "${local.name_prefix}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${local.name_prefix}-ecs-execution"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# BE 컨테이너에 넣을 비밀값 읽기. DB 값은 BE가 쓰는 것만 허용하고 DB_ROOT_PASSWORD는 뺀다
resource "aws_iam_role_policy" "ecs_execution_params" {
  name = "read-be-params"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadBeParams"
        Effect = "Allow"
        Action = "ssm:GetParameters"
        Resource = concat(
          ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/meety/${var.env}/be/*"],
          [for name in ["DB_NAME", "DB_USER", "DB_PASSWORD", "REDIS_PASSWORD"] :
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/meety/${var.env}/db/${name}"],
        )
      },
      {
        # SecureString 복호화는 Parameter Store를 거친 요청에만 허용한다
        Sid      = "DecryptViaSsm"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = data.aws_kms_alias.ssm.target_key_arn
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${var.region}.amazonaws.com" }
        }
      },
    ]
  })
}

# BE 태스크 역할: 컨테이너 안의 BE가 쓰는 권한. BE의 S3 클라이언트가 이 역할의 자격 증명을 자동으로 쓴다.
resource "aws_iam_role" "be_task" {
  name = "${local.name_prefix}-be-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${local.name_prefix}-be-task"
  }
}

resource "aws_iam_role_policy" "be_task_files" {
  name = "files-bucket"
  role = aws_iam_role.be_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # presigned URL 업로드, 다운로드와 파일 삭제, 크기 조회(HeadObject는 GetObject 권한을 쓴다)
        Sid      = "ReadWriteObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.files.arn}/*"
      },
      {
        # 없는 파일을 조회할 때 403 대신 404(NoSuchKey)를 받으려면 필요하다
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.files.arn
      },
    ]
  })
}

# FE 인스턴스 역할: SSM 접속과, FE 컨테이너를 띄울 때 /meety/prod/fe/ 아래 비밀값을 읽는 권한을 준다.
resource "aws_iam_role" "fe" {
  name = "${local.name_prefix}-fe"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${local.name_prefix}-fe"
  }
}

resource "aws_iam_role_policy_attachment" "fe_ssm" {
  role       = aws_iam_role.fe.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 버그 리포트를 보내는 Discord webhook 주소 등. FE 서버 쪽에서 쓴다
resource "aws_iam_role_policy" "fe_params" {
  name = "read-fe-params"
  role = aws_iam_role.fe.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadFeParams"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParametersByPath"]
        Resource = ["${local.param_arn_prefix}/fe", "${local.param_arn_prefix}/fe/*"]
      },
      {
        # SecureString 복호화는 Parameter Store를 거친 요청에만 허용한다
        Sid      = "DecryptViaSsm"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = data.aws_kms_alias.ssm.target_key_arn
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${var.region}.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "fe" {
  name = "${local.name_prefix}-fe"
  role = aws_iam_role.fe.name

  tags = {
    Name = "${local.name_prefix}-fe"
  }
}

# DB 인스턴스 역할: SSM 접속과, 첫 부팅 때 /meety/prod/db/ 아래 비밀값을 읽는 권한만 준다.
resource "aws_iam_role" "db" {
  name = "${local.name_prefix}-db"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${local.name_prefix}-db"
  }
}

resource "aws_iam_role_policy_attachment" "db_ssm" {
  role       = aws_iam_role.db.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "db_params" {
  name = "read-db-params"
  role = aws_iam_role.db.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 경로 단위 조회(GetParametersByPath)는 경로 자체, 개별 조회는 경로 아래 파라미터에 권한이 필요하다
        Sid    = "ReadDbParams"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = [
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/meety/${var.env}/db",
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/meety/${var.env}/db/*",
        ]
      },
      {
        # SecureString 복호화는 Parameter Store를 거친 요청에만 허용한다
        Sid      = "DecryptViaSsm"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = data.aws_kms_alias.ssm.target_key_arn
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${var.region}.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "db" {
  name = "${local.name_prefix}-db"
  role = aws_iam_role.db.name

  tags = {
    Name = "${local.name_prefix}-db"
  }
}

# AI 인스턴스 역할: SSM 접속과, BE와 공유하는 INTERNAL_API_KEY, /meety/prod/ai/ 아래 공급자 키를 읽는 권한만 준다.
resource "aws_iam_role" "ai" {
  name = "${local.name_prefix}-ai"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${local.name_prefix}-ai"
  }
}

resource "aws_iam_role_policy_attachment" "ai_ssm" {
  role       = aws_iam_role.ai.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ai_params" {
  name = "read-ai-params"
  role = aws_iam_role.ai.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # AI가 챗봇 처리 중 BE 내부 API를 부를 때 쓰는 키. BE와 같은 값을 쓴다
        Sid      = "ReadInternalApiKey"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "${local.param_arn_prefix}/be/INTERNAL_API_KEY"
      },
      {
        # 실제 공급자 키(Speechmatics, OpenRouter, Modal 등)
        Sid      = "ReadAiParams"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParametersByPath"]
        Resource = ["${local.param_arn_prefix}/ai", "${local.param_arn_prefix}/ai/*"]
      },
      {
        # SecureString 복호화는 Parameter Store를 거친 요청에만 허용한다
        Sid      = "DecryptViaSsm"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = data.aws_kms_alias.ssm.target_key_arn
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${var.region}.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "ai" {
  name = "${local.name_prefix}-ai"
  role = aws_iam_role.ai.name

  tags = {
    Name = "${local.name_prefix}-ai"
  }
}

# ECS 인프라 역할: 블루/그린 배포 때 ECS가 전달 규칙의 가중치를 바꾸고 대상 그룹에 태스크를 등록하는 데 쓴다
resource "aws_iam_role" "ecs_infrastructure" {
  name = "${local.name_prefix}-ecs-infrastructure"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${local.name_prefix}-ecs-infrastructure"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_infrastructure" {
  role       = aws_iam_role.ecs_infrastructure.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers"
}

# GitHub Actions 배포 역할(BE, FE, AI)은 prod CI/CD를 붙일 때 만든다 (2026-10-17 결정)

# 인스턴스 역할이 자기 경로 밖의 파라미터를 읽지 못하게 막는다 (2026-10-12)
# AmazonSSMManagedInstanceCore가 ssm:GetParameter(s)를 모든 파라미터(*)에 허용하므로, 위의 읽기 허용 범위만으로는 막을 수 없다.
# Deny는 Allow보다 우선한다. 다른 리전(오하이오 V1)의 파라미터도 함께 거부된다.
locals {
  instance_param_allow = {
    fe = { role = aws_iam_role.fe.id, paths = ["fe", "fe/*"] }
    db = { role = aws_iam_role.db.id, paths = ["db", "db/*"] }
    ai = { role = aws_iam_role.ai.id, paths = ["ai", "ai/*", "be/INTERNAL_API_KEY"] }
  }
}

resource "aws_iam_role_policy" "instance_params_deny" {
  for_each = local.instance_param_allow

  name = "deny-other-params"
  role = each.value.role

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyParamsOutsideOwnPath"
      Effect = "Deny"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath",
        "ssm:GetParameterHistory",
      ]
      NotResource = concat(
        [for p in each.value.paths : "${local.param_arn_prefix}/${p}"],
        # AMI ID 등 AWS가 공개하는 파라미터
        ["arn:aws:ssm:*::parameter/aws/*"],
      )
    }]
  })
}
