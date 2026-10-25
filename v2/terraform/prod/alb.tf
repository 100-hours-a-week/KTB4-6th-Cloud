# 공용 ALB에 prod BE, FE용 대상 그룹과 전달 규칙을 붙인다.
# 규칙 번호는 prod 200번대(staging 100번대). meety.io.kr, api.meety.io.kr이 아직 오하이오 V1을 가리켜 실제 요청은 오지 않는다.

# be-realtime 대상 그룹 2개(blue, green). 블루/그린 배포 때 ECS가 새 버전을 비어 있는 쪽에 띄우고 가중치를 바꾼다
resource "aws_lb_target_group" "be_realtime" {
  name        = "${local.name_prefix}-be-realtime-tg"
  vpc_id      = local.shared.vpc_id
  target_type = "ip" # Fargate 태스크는 IP로 등록된다
  protocol    = "HTTP"

  # ECS가 태스크를 등록할 때 컨테이너 포트(var.be_container_port)를 함께 지정하므로 실제 트래픽과 헬스 체크는 그 포트로 간다
  port = 80

  # 태스크를 내릴 때 진행 중인 요청을 마칠 시간. 기본값 300초는 배포를 늦춘다
  deregistration_delay = 30

  health_check {
    path                = var.be_health_check_path
    matcher             = "200-399"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${local.name_prefix}-be-realtime-tg"
  }
}

resource "aws_lb_target_group" "be_realtime_green" {
  name        = "${local.name_prefix}-be-realtime-green"
  vpc_id      = local.shared.vpc_id
  target_type = "ip"
  protocol    = "HTTP"
  port        = 80

  deregistration_delay = 30

  health_check {
    path                = var.be_health_check_path
    matcher             = "200-399"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${local.name_prefix}-be-realtime-green"
  }
}

# api.meety.io.kr 의 실시간 경로 → be-realtime
# be-api 규칙(205)보다 먼저 검사되도록 번호를 작게 둔다
resource "aws_lb_listener_rule" "be_realtime" {
  listener_arn = local.shared.https_listener_arn
  priority     = 200

  # 전달 동작은 계속 ECS가 관리하고, 점검 중에만 접속 IP 조건을 추가한다.
  dynamic "condition" {
    for_each = length(var.maintenance_allowed_cidrs) == 0 ? [] : [true]
    content {
      source_ip {
        values = var.maintenance_allowed_cidrs
      }
    }
  }

  condition {
    host_header {
      values = [var.be_domain]
    }
  }

  # 녹음 WebSocket, 회의 SSE, 알림 SSE
  condition {
    path_pattern {
      values = var.be_realtime_paths
    }
  }

  # 두 대상 그룹을 가중치로 연결해 두고, 배포 때 ECS가 가중치를 바꾼다
  action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.be_realtime.arn
        weight = 100
      }

      target_group {
        arn    = aws_lb_target_group.be_realtime_green.arn
        weight = 0
      }
    }
  }

  # 배포 후 가중치는 ECS가 관리한다. Terraform이 처음 값으로 되돌리면 이전 버전으로 트래픽이 넘어간다
  lifecycle {
    ignore_changes = [action]
  }

  tags = {
    Name = "${local.name_prefix}-be-realtime-rule"
  }
}

# BE actuator는 8080에서 서비스 API와 함께 열린다 (Prometheus 수집용 /actuator/prometheus 포함).
# 외부에는 CI 배포 확인용 health만 허용하고 나머지 actuator 경로는 막는다.
# ALB 대상 그룹 health check와 Prometheus 수집은 태스크로 직접 가므로 이 규칙의 영향을 받지 않는다.
# 실시간 경로 규칙(200)에는 /actuator가 없으므로 be-api 규칙(205)보다 앞에만 두면 된다
resource "aws_lb_listener_rule" "be_actuator_health" {
  listener_arn = local.shared.https_listener_arn
  priority     = 201

  condition {
    host_header {
      values = [var.be_domain]
    }
  }

  condition {
    path_pattern {
      values = ["/actuator/health", "/actuator/health/*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.be_api.arn
  }

  tags = {
    Name = "${local.name_prefix}-be-actuator-health-rule"
  }
}

resource "aws_lb_listener_rule" "be_actuator_block" {
  listener_arn = local.shared.https_listener_arn
  priority     = 202

  condition {
    host_header {
      values = [var.be_domain]
    }
  }

  condition {
    path_pattern {
      values = ["/actuator", "/actuator/*"]
    }
  }

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }

  tags = {
    Name = "${local.name_prefix}-be-actuator-block-rule"
  }
}

# be-api 대상 그룹
resource "aws_lb_target_group" "be_api" {
  name        = "${local.name_prefix}-be-api-tg"
  vpc_id      = local.shared.vpc_id
  target_type = "ip"
  protocol    = "HTTP"
  port        = 80

  deregistration_delay = 30

  health_check {
    path                = var.be_health_check_path
    matcher             = "200-399"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${local.name_prefix}-be-api-tg"
  }
}

# api.meety.io.kr 의 나머지 요청 → be-api
resource "aws_lb_listener_rule" "be_api" {
  listener_arn = local.shared.https_listener_arn
  priority     = 205

  dynamic "condition" {
    for_each = length(var.maintenance_allowed_cidrs) == 0 ? [] : [true]
    content {
      source_ip {
        values = var.maintenance_allowed_cidrs
      }
    }
  }

  condition {
    host_header {
      values = [var.be_domain]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.be_api.arn
  }

  tags = {
    Name = "${local.name_prefix}-be-api-rule"
  }
}

# prod FE: FE 인스턴스의 FE 컨테이너로 보낸다.
# FE 인스턴스를 대상 그룹에 등록하는 일은 CI/CD가 맡는다 (배포 때마다 3000, 3001 포트를 번갈아 등록). prod CI/CD를 붙일 때 등록된다
resource "aws_lb_target_group" "fe" {
  name        = "${local.name_prefix}-fe-tg"
  vpc_id      = local.shared.vpc_id
  target_type = "instance"
  protocol    = "HTTP"
  port        = var.fe_container_port

  deregistration_delay = 30

  health_check {
    path                = var.fe_health_check_path
    matcher             = "200-399"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${local.name_prefix}-fe-tg"
  }
}

# meety.io.kr 로 온 HTTPS 요청 → prod FE
resource "aws_lb_listener_rule" "fe" {
  listener_arn = local.shared.https_listener_arn
  priority     = 210

  dynamic "condition" {
    for_each = length(var.maintenance_allowed_cidrs) == 0 ? [] : [true]
    content {
      source_ip {
        values = var.maintenance_allowed_cidrs
      }
    }
  }

  condition {
    host_header {
      values = [var.fe_domain]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.fe.arn
  }

  tags = {
    Name = "${local.name_prefix}-fe-rule"
  }
}
