# 공용 ALB에 staging BE, FE용 대상 그룹과 전달 규칙을 붙인다.

# be-realtime 대상 그룹 2개(blue, green). AWS의 이름은 바꾸면 교체되므로 처음 만든 이름(-be-tg, -be-tg-green)을 유지한다
moved {
  from = aws_lb_target_group.be
  to   = aws_lb_target_group.be_realtime
}

moved {
  from = aws_lb_target_group.be_green
  to   = aws_lb_target_group.be_realtime_green
}

moved {
  from = aws_lb_listener_rule.be
  to   = aws_lb_listener_rule.be_realtime
}

resource "aws_lb_target_group" "be_realtime" {
  name        = "${local.name_prefix}-be-tg"
  vpc_id      = local.shared.vpc_id
  target_type = "ip" # Fargate 태스크는 IP로 등록된다
  protocol    = "HTTP"

  # ECS가 태스크를 등록할 때 컨테이너 포트(var.be_container_port)를 함께 지정하므로 실제 트래픽과 헬스 체크는 그 포트로 간다.
  # 이 값은 바꾸면 대상 그룹이 교체되어 처음 만든 값(80)으로 고정한다.
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
    Name = "${local.name_prefix}-be-tg"
  }
}

# 블루/그린 배포용 두 번째 BE 대상 그룹. 설정은 위 대상 그룹과 같다.
# 배포 때마다 ECS가 새 버전을 비어 있는 쪽 대상 그룹에 띄우고, 전달 규칙의 가중치를 바꿔 트래픽을 넘긴다
resource "aws_lb_target_group" "be_realtime_green" {
  name        = "${local.name_prefix}-be-tg-green"
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
    Name = "${local.name_prefix}-be-tg-green"
  }
}

# api-staging.meety.io.kr 의 실시간 경로 → be-realtime
# be-api 규칙(105)보다 먼저 검사되도록 번호를 작게 둔다
resource "aws_lb_listener_rule" "be_realtime" {
  listener_arn = local.shared.https_listener_arn
  priority     = 100 # staging은 100번대, prod는 200번대를 쓴다

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
    Name = "${local.name_prefix}-be-rule"
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

# api-staging.meety.io.kr 의 나머지 요청 → be-api
resource "aws_lb_listener_rule" "be_api" {
  listener_arn = local.shared.https_listener_arn
  priority     = 105

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

# staging FE: FE 인스턴스의 FE 컨테이너로 보낸다
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

# FE 인스턴스를 대상 그룹에 등록하는 일은 CI/CD가 맡는다.
# 배포 때마다 새 컨테이너를 다른 포트(3000, 3001)로 띄우고 등록 포트를 바꾸므로 Terraform이 관리하지 않는다.
# 처음 Terraform으로 등록한 3000번 대상은 그대로 두고 state에서만 뺀다
removed {
  from = aws_lb_target_group_attachment.fe

  lifecycle {
    destroy = false
  }
}

# staging.meety.io.kr 로 온 HTTPS 요청 → staging FE
resource "aws_lb_listener_rule" "fe" {
  listener_arn = local.shared.https_listener_arn
  priority     = 110

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
