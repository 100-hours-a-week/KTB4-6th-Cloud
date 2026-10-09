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
