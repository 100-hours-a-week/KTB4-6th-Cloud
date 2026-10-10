# staging BE 서비스. BE 이미지를 staging profile로 실행한다.

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
  task_role_arn            = aws_iam_role.be_task.arn

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

    # 비밀값이 아닌 설정. DB와 Redis 주소는 DB 인스턴스의 private IP를 참조한다
    environment = [
      { name = "SPRING_PROFILES_ACTIVE", value = "staging" },
      # staging profile의 ddl-auto create는 기동할 때마다 테이블을 다시 만든다.
      # 첫 기동에서 스키마를 만든 뒤에는 validate로 덮어써 데이터를 유지하고, 엔티티와 스키마 차이는 기동 실패로 드러나게 한다
      { name = "SPRING_JPA_HIBERNATE_DDL_AUTO", value = var.be_ddl_auto },
      # V1 dev, prod와 같이 KST로 동작한다. 기존 데이터 시각이 KST로 저장돼 있어 마이그레이션 후에도 맞아야 한다
      { name = "TZ", value = "Asia/Seoul" },
      { name = "DB_HOST", value = aws_instance.db.private_ip },
      { name = "DB_PORT", value = "3306" },
      { name = "REDIS_HOST", value = aws_instance.db.private_ip },
      { name = "REDIS_PORT", value = "6379" },
      { name = "KAKAO_REDIRECT_URI", value = var.be_kakao_redirect_uri },
      { name = "CORS_ALLOWED_ORIGINS", value = join(",", var.fe_allowed_origins) },
      # AI 인스턴스의 private IP로 직접 부른다 (ai-analysis 8001, ai-live 8000)
      { name = "AI_HTTP_URL", value = "http://${aws_instance.ai.private_ip}:8001" },
      { name = "AI_WEBSOCKET_URL", value = "ws://${aws_instance.ai.private_ip}:8000/v1/live-meeting" },
      { name = "AWS_S3_BUCKET", value = aws_s3_bucket.files.bucket },
      { name = "AWS_S3_REGION", value = var.region },
      # 테스트 편의를 위해 V1 dev와 같은 값을 쓴다 (녹음, 요약, 챗봇, 리포트 크레딧 차감 없음, 회의 생성 하루 100회)
      { name = "MEETING_DAILY_CREATE_LIMIT", value = "100" },
      { name = "CREDIT_RECORDING_COST", value = "0" },
      { name = "CREDIT_SUMMARY_REGENERATE_COST", value = "0" },
      { name = "CREDIT_AI_CHAT_MESSAGE_COST", value = "0" },
      { name = "CREDIT_ANALYSIS_REPORT_COST", value = "0" },
      # Sentry는 V1 dev와 같은 프로젝트로 보내되, environment를 나눠 V1 dev(staging) 이벤트와 섞이지 않게 한다
      { name = "SENTRY_ENVIRONMENT", value = "v2-staging" },
      { name = "SENTRY_SEND_DEFAULT_PII", value = "true" },
      { name = "BE_SENTRY_LOGS_ENABLED", value = "true" },
      { name = "BE_SENTRY_TRACES_SAMPLE_RATE", value = "1.0" },
      { name = "SENTRY_PROFILE_SESSION_SAMPLE_RATE", value = "1.0" },
      { name = "SENTRY_PROFILE_LIFECYCLE", value = "TRACE" },
    ]

    # 비밀값은 태스크가 시작할 때 ECS가 Parameter Store에서 읽어 넣는다 (실행 역할 권한).
    # BE는 DB_USERNAME을 읽고, Parameter Store 이름은 DB 인스턴스와 같은 DB_USER를 쓴다
    secrets = [
      { name = "DB_NAME", valueFrom = "${local.param_arn_prefix}/db/DB_NAME" },
      { name = "DB_USERNAME", valueFrom = "${local.param_arn_prefix}/db/DB_USER" },
      { name = "DB_PASSWORD", valueFrom = "${local.param_arn_prefix}/db/DB_PASSWORD" },
      { name = "REDIS_PASSWORD", valueFrom = "${local.param_arn_prefix}/db/REDIS_PASSWORD" },
      { name = "JWT_SECRET", valueFrom = "${local.param_arn_prefix}/be/JWT_SECRET" },
      { name = "KAKAO_CLIENT_ID", valueFrom = "${local.param_arn_prefix}/be/KAKAO_CLIENT_ID" },
      { name = "KAKAO_CLIENT_SECRET", valueFrom = "${local.param_arn_prefix}/be/KAKAO_CLIENT_SECRET" },
      { name = "KAKAO_ADMIN_KEY", valueFrom = "${local.param_arn_prefix}/be/KAKAO_ADMIN_KEY" },
      { name = "INTERNAL_API_KEY", valueFrom = "${local.param_arn_prefix}/be/INTERNAL_API_KEY" },
      { name = "SENTRY_DSN", valueFrom = "${local.param_arn_prefix}/be/SENTRY_DSN" },
    ]

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

  # 태스크가 뜨고 헬스체크 실패를 세기 시작하기까지 기다리는 시간.
  # 첫 기동은 넉넉히 두고, 로그로 실제 기동 시간을 잰 뒤 줄인다
  health_check_grace_period_seconds = 180

  # 서비스 태그(Service=meety 등)를 태스크에도 붙인다. default_tags는 태스크에 자동으로 붙지 않는다
  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"

  # 전달 규칙이 먼저 있어야 대상 그룹이 ALB에 연결된 상태로 서비스를 만들 수 있다
  depends_on = [aws_lb_listener_rule.be]

  tags = {
    Name = "${local.name_prefix}-be"
  }
}
