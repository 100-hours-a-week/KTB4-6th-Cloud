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
