# staging BE 서비스. BE 이미지를 staging profile로 실행한다.

resource "aws_cloudwatch_log_group" "be" {
  name              = "/ecs/${local.name_prefix}/be"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${local.name_prefix}-be-logs"
  }
}

resource "aws_ecs_task_definition" "be" {
  family = "${local.name_prefix}-be"

  # 설정이 바뀌어 새 리비전을 만들 때 이전 리비전을 지우지(INACTIVE) 않는다.
  # 서비스가 아직 이전 리비전으로 실행 중일 수 있고, 롤백할 때 이전 리비전이 필요하다
  skip_destroy             = true
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

  # be 컨테이너와, 켜져 있으면 ProxySQL 사이드카를 함께 띄운다
  container_definitions = jsonencode(concat([{
    name      = "be"
    image     = var.be_image
    essential = true

    # 종료 신호(SIGTERM)를 받은 뒤 강제 종료까지 기다리는 시간. Fargate 최대값으로 두어 진행 중인 처리를 마칠 시간을 준다
    stopTimeout = 120

    # ProxySQL이 접속을 받을 수 있게 된 뒤 시작한다. 종료는 반대 순서라 BE가 진행 중인 DB 처리를 마친 뒤 ProxySQL이 내려간다
    dependsOn = var.be_proxysql_enabled ? [{ containerName = "proxysql", condition = "HEALTHY" }] : []

    portMappings = [{
      containerPort = var.be_container_port
      protocol      = "tcp"
    }]

    # 비밀값이 아닌 설정. DB와 Redis 주소는 각각의 접속 대상을 참조한다
    environment = concat([
      { name = "SPRING_PROFILES_ACTIVE", value = "staging" },
      # staging profile의 ddl-auto create는 기동할 때마다 테이블을 다시 만든다.
      # 첫 기동에서 스키마를 만든 뒤에는 validate로 덮어써 데이터를 유지하고, 엔티티와 스키마 차이는 기동 실패로 드러나게 한다
      { name = "SPRING_JPA_HIBERNATE_DDL_AUTO", value = var.be_ddl_auto },
      # V1 dev, prod와 같이 KST로 동작한다. 기존 데이터 시각이 KST로 저장돼 있어 마이그레이션 후에도 맞아야 한다
      { name = "TZ", value = "Asia/Seoul" },
      # ProxySQL을 켜면 같은 태스크의 ProxySQL(127.0.0.1:6033)을 거쳐 DB에 접속한다
      { name = "DB_HOST", value = var.be_proxysql_enabled ? "127.0.0.1" : aws_instance.db.private_ip },
      { name = "DB_PORT", value = var.be_proxysql_enabled ? "6033" : "3306" },
      { name = "REDIS_HOST", value = local.be_redis_host },
      { name = "REDIS_PORT", value = "6379" },
      { name = "KAKAO_REDIRECT_URI", value = var.be_kakao_redirect_uri },
      { name = "CORS_ALLOWED_ORIGINS", value = join(",", var.fe_allowed_origins) },
      # AI 인스턴스의 private IP로 직접 부른다 (분석은 ai_analysis 인스턴스 8001, 실시간 STT는 ai 인스턴스 8000)
      { name = "AI_HTTP_URL", value = "http://${aws_instance.ai_analysis.private_ip}:8001" },
      { name = "AI_WEBSOCKET_URL", value = "ws://${aws_instance.ai.private_ip}:8000/v1/live-meeting" },
      { name = "AWS_S3_BUCKET", value = aws_s3_bucket.files.bucket },
      { name = "AWS_S3_REGION", value = var.region },
      # V1 dev와 같은 JVM 힙 설정. 지정하지 않으면 컨테이너 메모리의 25%(512MB)만 힙으로 쓴다
      { name = "JAVA_TOOL_OPTIONS", value = "-Xmx1024m -Xms512m" },
      # V1 dev와 같이 DB에 연결되지 않아도 앱 기동은 성공하게 한다. 연결 상태는 헬스체크(/actuator/health)로 드러난다
      { name = "SPRING_DATASOURCE_HIKARI_INITIALIZATION_FAIL_TIMEOUT", value = "-1" },
      # 테스트 편의를 위해 V1 dev와 같은 값을 쓴다 (녹음, 요약, 챗봇, 리포트 크레딧 차감 없음, 회의 생성 하루 100회)
      { name = "MEETING_DAILY_CREATE_LIMIT", value = "100" },
      { name = "CREDIT_RECORDING_COST", value = "0" },
      { name = "CREDIT_SUMMARY_REGENERATE_COST", value = "0" },
      { name = "CREDIT_AI_CHAT_MESSAGE_COST", value = "0" },
      { name = "CREDIT_ANALYSIS_REPORT_COST", value = "0" },
      # DB 이전 리허설용 쓰기 게이트. 켜면 닫힌 채로 기동하고, 관리 API로 열 때까지 DB 쓰기를 대기시킨다
      { name = "MIGRATION_WRITE_GATE_ENABLED", value = tostring(var.be_migration_write_gate_enabled) },
      # 게이트가 닫힌 동안 쓰기 요청이 기다리는 최대 시간. 1차 리허설에서 기본값 10초로는 수동 전환 구간을 넘기지 못했다.
      # ALB 유휴 타임아웃(60초)과 부하 스크립트의 요청 타임아웃보다 짧게 둔다
      { name = "MIGRATION_WRITE_GATE_MAX_WAIT", value = "30s" },
      { name = "AUTH_ACCESS_TOKEN_COOKIE_NAME", value = "staging_accessToken" },
      ], var.be_db_read_enabled ? [
      # 읽기 풀은 같은 ProxySQL에 읽기 계정으로 접속하고, ProxySQL이 Replica로 보낸다.
      # 값이 없으면 BE는 읽기 풀도 쓰기 접속 정보를 쓴다
      { name = "DB_READ_HOST", value = "127.0.0.1" },
      { name = "DB_READ_PORT", value = "6033" },
      ] : [], var.redis_sentinel_enabled ? [
      # Sentinel 설정이 있으면 Spring은 REDIS_HOST 대신 Sentinel에게 현재 Master 주소를 물어 접속한다
      { name = "SPRING_DATA_REDIS_SENTINEL_MASTER", value = module.redis.sentinel_master_name },
      { name = "SPRING_DATA_REDIS_SENTINEL_NODES", value = join(",", module.redis.sentinel_nodes) },
      # 장애 실험용: Lettuce 기본 명령 타임아웃(60초) 대신 짧게 실패시키고, Redis 장애 중 누락된 STOP을 DB 상태로 보정한다(간격 기본 3초)
      { name = "SPRING_DATA_REDIS_TIMEOUT", value = "2s" },
      { name = "RECORDING_STOP_RECONCILIATION_ENABLED", value = "true" },
    ] : [])

    # 비밀값은 태스크가 시작할 때 ECS가 Parameter Store에서 읽어 넣는다 (실행 역할 권한).
    # BE는 DB_USERNAME을 읽고, Parameter Store 이름은 DB 인스턴스와 같은 DB_USER를 쓴다
    secrets = concat([
      { name = "DB_NAME", valueFrom = "${local.param_arn_prefix}/db/DB_NAME" },
      { name = "DB_USERNAME", valueFrom = "${local.param_arn_prefix}/db/DB_USER" },
      { name = "DB_PASSWORD", valueFrom = "${local.param_arn_prefix}/db/DB_PASSWORD" },
      { name = "REDIS_PASSWORD", valueFrom = "${local.param_arn_prefix}/db/REDIS_PASSWORD" },
      { name = "JWT_SECRET", valueFrom = "${local.param_arn_prefix}/be/JWT_SECRET" },
      { name = "KAKAO_CLIENT_ID", valueFrom = "${local.param_arn_prefix}/be/KAKAO_CLIENT_ID" },
      { name = "KAKAO_CLIENT_SECRET", valueFrom = "${local.param_arn_prefix}/be/KAKAO_CLIENT_SECRET" },
      { name = "KAKAO_ADMIN_KEY", valueFrom = "${local.param_arn_prefix}/be/KAKAO_ADMIN_KEY" },
      { name = "INTERNAL_API_KEY", valueFrom = "${local.param_arn_prefix}/be/INTERNAL_API_KEY" },
      # 게이트 관리 API 토큰(32자 이상). Parameter Store에 값이 없으면 태스크가 시작되지 않는다
      { name = "MIGRATION_WRITE_GATE_ADMIN_TOKEN", valueFrom = "${local.param_arn_prefix}/be/MIGRATION_WRITE_GATE_ADMIN_TOKEN" },
      ], var.be_db_read_enabled ? [
      { name = "DB_READ_USERNAME", valueFrom = "${local.param_arn_prefix}/db/DB_READ_USER" },
      { name = "DB_READ_PASSWORD", valueFrom = "${local.param_arn_prefix}/db/DB_READ_PASSWORD" },
      ] : [], var.redis_sentinel_enabled ? [
      # Sentinel도 Redis와 같은 비밀번호를 쓴다
      { name = "SPRING_DATA_REDIS_SENTINEL_PASSWORD", valueFrom = "${local.param_arn_prefix}/db/REDIS_PASSWORD" },
    ] : [])

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.be.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "be"
      }
    }
    }], var.be_proxysql_enabled ? [{
    # ProxySQL 사이드카: BE의 DB 접속을 계정에 따라 Primary(쓰기)와 Replica(읽기)로 보낸다.
    # 설정과 시작 순서는 proxysql/start.sh.tftpl에 있다
    name      = "proxysql"
    image     = var.be_proxysql_image
    essential = true

    # 작은 상한에 걸려 강제 종료되면 태스크 전체가 내려가므로 상한 없이 예약만 잡는다. 실측 후 조정한다
    memoryReservation = 256

    command = ["bash", "-c", templatefile("${path.module}/proxysql/start.sh.tftpl", {
      primary_ip          = aws_instance.db.private_ip
      replica_ip          = aws_instance.db_replica.private_ip
      max_replication_lag = var.be_proxysql_max_replication_lag
      read_enabled        = var.be_db_read_enabled
    })]

    # 앱 계정(쓰기)과 읽기 계정은 BE와 같은 값을 쓴다
    secrets = concat([
      { name = "DB_USERNAME", valueFrom = "${local.param_arn_prefix}/db/DB_USER" },
      { name = "DB_PASSWORD", valueFrom = "${local.param_arn_prefix}/db/DB_PASSWORD" },
      { name = "PROXYSQL_ADMIN_PASSWORD", valueFrom = "${local.param_arn_prefix}/db/PROXYSQL_ADMIN_PASSWORD" },
      { name = "PROXYSQL_MONITOR_PASSWORD", valueFrom = "${local.param_arn_prefix}/db/PROXYSQL_MONITOR_PASSWORD" },
      ], var.be_db_read_enabled ? [
      { name = "DB_READ_USERNAME", valueFrom = "${local.param_arn_prefix}/db/DB_READ_USER" },
      { name = "DB_READ_PASSWORD", valueFrom = "${local.param_arn_prefix}/db/DB_READ_PASSWORD" },
    ] : [])

    # 접속 포트가 열렸는지만 본다. DB 상태까지 보면 DB 장애 때 태스크가 계속 교체되므로 넣지 않는다
    healthCheck = {
      command     = ["CMD", "bash", "-c", "</dev/tcp/127.0.0.1/6033"]
      interval    = 10
      timeout     = 3
      retries     = 3
      startPeriod = 10
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.be.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "proxysql"
      }
    }
  }] : []))

  tags = {
    Name = "${local.name_prefix}-be"
  }
}

# BE는 같은 이미지와 태스크 정의로 서비스 2개를 띄운다. ALB가 경로로 나눠 보낸다 (alb.tf)
# - be-realtime: 녹음 WebSocket, 회의 SSE, 알림 SSE. 연결 수에 따라 부하가 늘어난다
# - be-api: 그 외 REST 요청. 요청 수(RPS)에 따라 부하가 늘어나 오토스케일링한다

# 서비스 이름을 바꾸면 서비스가 다시 만들어진다(10/11 -be에서 -be-realtime으로 변경)
moved {
  from = aws_ecs_service.be
  to   = aws_ecs_service.be_realtime
}

resource "aws_ecs_service" "be_realtime" {
  name            = "${local.name_prefix}-be-realtime"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.be.arn
  desired_count   = var.be_realtime_min_count

  # Spot이 회수되면 진행 중인 회의 연결이 끊기므로 On-Demand만 쓴다
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
    target_group_arn = aws_lb_target_group.be_realtime.arn
    container_name   = "be"
    container_port   = var.be_container_port

    # 블루/그린 배포: 새 버전을 다른 대상 그룹에 띄우고, 전달 규칙의 가중치를 바꿔 트래픽을 넘긴다
    advanced_configuration {
      alternate_target_group_arn = aws_lb_target_group.be_realtime_green.arn
      production_listener_rule   = aws_lb_listener_rule.be_realtime.arn
      role_arn                   = aws_iam_role.ecs_infrastructure.arn
    }
  }

  # 블루/그린 배포. 새 버전이 헬스체크를 통과하면 트래픽을 한 번에 넘기고,
  # 관찰 시간 동안 이전 버전 태스크를 유지한다. 이전 태스크에 연결된 녹음 WebSocket과 SSE는 그대로 이어진다(10/11 실측).
  # 관찰 시간은 회의 최대 시간(90분)보다 길게 둬서 배포 직전에 시작한 회의도 끊기지 않게 한다
  deployment_configuration {
    strategy             = "BLUE_GREEN"
    bake_time_in_minutes = var.be_bake_time_minutes
  }

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

  # 배포할 버전(태스크 정의)은 CI/CD가, 태스크 수는 오토스케일링이 정한다
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  # 전달 규칙이 먼저 있어야 대상 그룹이 ALB에 연결된 상태로 서비스를 만들 수 있다
  depends_on = [aws_lb_listener_rule.be_realtime]

  tags = {
    Name = "${local.name_prefix}-be-realtime"
  }
}

resource "aws_ecs_service" "be_api" {
  # API 설정 변경 뒤 새 태스크가 정상 기동했는지 기다린다.
  wait_for_steady_state = true

  name            = "${local.name_prefix}-be-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.be.arn
  desired_count   = var.be_api_min_count

  # 최소 1개는 On-Demand로 두고, 늘어나는 몫은 On-Demand:Spot = 1:3으로 배치한다
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = 1
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 3
  }

  network_configuration {
    subnets          = local.shared.public_subnet_ids
    security_groups  = [aws_security_group.be.id]
    assign_public_ip = true # NAT 없이 이미지 받기와 외부 API 호출을 하기 위해
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.be_api.arn
    container_name   = "be"
    container_port   = var.be_container_port
  }

  # 롤링 배포. 요청이 짧아서 새 태스크가 헬스체크를 통과한 뒤 기존 태스크를 내려도 끊기는 요청이 없다
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # 새 버전이 계속 실패하면 배포를 멈추고 이전 버전으로 되돌린다
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  health_check_grace_period_seconds = 180

  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"

  # 배포할 버전은 CI/CD가, 태스크 수는 오토스케일링이 정한다
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener_rule.be_api]

  tags = {
    Name = "${local.name_prefix}-be-api"
  }
}

# be-api 오토스케일링: 평균 CPU 사용률을 목표값에 맞추도록 태스크 수를 조절한다
resource "aws_appautoscaling_target" "be_api" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.be_api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.be_api_min_count
  max_capacity       = var.be_api_max_count

  tags = {
    Name = "${local.name_prefix}-be-api"
  }
}

resource "aws_appautoscaling_policy" "be_api_cpu" {
  name               = "${local.name_prefix}-be-api-cpu"
  service_namespace  = aws_appautoscaling_target.be_api.service_namespace
  resource_id        = aws_appautoscaling_target.be_api.resource_id
  scalable_dimension = aws_appautoscaling_target.be_api.scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value = var.be_api_cpu_target

    # 늘릴 때는 빨리, 줄일 때는 천천히 (설계값)
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}

# be-realtime 오토스케일링: be-api와 같은 CPU 기준으로 시작하고, 부하 테스트에서 연결 수와 CPU 관계를 본 뒤 기준을 다시 정한다.
# 줄어드는 태스크의 회의는 FE가 남은 태스크로 다시 연결하고, 그 태스크가 AI 연결을 새로 맺어 이어진다(BE 확인, 2026-10-17).
# 옮겨 가는 동안의 전사 누락 등 문제가 보이면 disable_scale_in으로 줄이는 동작만 막는다
resource "aws_appautoscaling_target" "be_realtime" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.be_realtime.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.be_realtime_min_count
  max_capacity       = var.be_realtime_max_count

  tags = {
    Name = "${local.name_prefix}-be-realtime"
  }
}

resource "aws_appautoscaling_policy" "be_realtime_cpu" {
  name               = "${local.name_prefix}-be-realtime-cpu"
  service_namespace  = aws_appautoscaling_target.be_realtime.service_namespace
  resource_id        = aws_appautoscaling_target.be_realtime.resource_id
  scalable_dimension = aws_appautoscaling_target.be_realtime.scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value = var.be_realtime_cpu_target

    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}

# CI/CD가 새 버전을 등록할 때 기준으로 삼는 태스크 정의.
# CI/CD는 이 정의에서 이미지만 바꿔 등록하므로, Terraform에서 바꾼 환경변수와 리소스 설정이 다음 배포에 반영된다
resource "aws_ssm_parameter" "be_task_template" {
  name  = "/meety/${var.env}/be/deploy/TASK_TEMPLATE_ARN"
  type  = "String"
  value = aws_ecs_task_definition.be.arn

  tags = {
    Name = "${local.name_prefix}-be-task-template"
  }
}
