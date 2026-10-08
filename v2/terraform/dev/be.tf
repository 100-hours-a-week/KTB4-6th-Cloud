# dev BE 서비스. 지금은 경로 검증용 nginx를 띄우고, BE 배포 시(10/10) 이미지와 값을 바꾼다.

resource "aws_cloudwatch_log_group" "be" {
  name              = "/ecs/${local.name_prefix}/be"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${local.name_prefix}-be-logs"
  }
}

resource "aws_ecs_task_definition" "be" {
  family                   = "${local.name_prefix}-be"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.be_cpu
  memory                   = var.be_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "be"
    image     = var.be_image
    essential = true

    portMappings = [{
      containerPort = var.be_container_port
      protocol      = "tcp"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.be.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "be"
      }
    }
  }])

  tags = {
    Name = "${local.name_prefix}-be"
  }
}

resource "aws_ecs_service" "be" {
  name            = "${local.name_prefix}-be"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.be.arn
  desired_count   = 1 # 실시간 기능(SSE, WebSocket)이 서버 메모리에 있어 1개로 운영

  # 실시간 기능을 포함하므로 On-Demand만 쓴다
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = 1
  }

  network_configuration {
    subnets          = local.shared.public_subnet_ids
    security_groups  = [aws_security_group.be.id]
    assign_public_ip = true # NAT 없이 이미지 받기와 외부 API 호출을 하기 위해
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.be.arn
    container_name   = "be"
    container_port   = var.be_container_port
  }

  # 배포할 때 새 태스크를 먼저 띄우고, 헬스체크를 통과하면 기존 태스크를 내린다
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # 새 버전이 계속 실패하면 배포를 멈추고 이전 버전으로 되돌린다
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # 태스크가 뜨고 헬스체크를 시작하기까지 기다리는 시간 (BE는 기동이 길어 배포 시 늘린다)
  health_check_grace_period_seconds = 60

  # 서비스 태그(Service=meety 등)를 태스크에도 붙인다. default_tags는 태스크에 자동으로 붙지 않는다
  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"

  # 전달 규칙이 먼저 있어야 대상 그룹이 ALB에 연결된 상태로 서비스를 만들 수 있다
  depends_on = [aws_lb_listener_rule.be]

  tags = {
    Name = "${local.name_prefix}-be"
  }
}
