# ECS 태스크 실행 역할: ECS가 이미지를 받고 로그를 CloudWatch에 쓰는 데 쓴다.
# 컨테이너 안의 앱이 쓰는 권한(S3 등)은 태스크 역할로 따로 만든다 (BE 배포 시).

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

# FE 인스턴스 역할: 지금은 SSM 접속에 필요한 권한만 준다.
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

resource "aws_iam_instance_profile" "fe" {
  name = "${local.name_prefix}-fe"
  role = aws_iam_role.fe.name

  tags = {
    Name = "${local.name_prefix}-fe"
  }
}

# DB 인스턴스 역할: SSM 접속과, 첫 부팅 때 /meety/staging/db/ 아래 비밀값을 읽는 권한만 준다.
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
