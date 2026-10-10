# 공용 ALB에 staging BE, FE용 대상 그룹과 전달 규칙을 붙인다.

resource "aws_lb_target_group" "be" {
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

# api-staging.meety.io.kr 로 온 HTTPS 요청 → staging BE
resource "aws_lb_listener_rule" "be" {
  listener_arn = local.shared.https_listener_arn
  priority     = 100 # staging은 100번대, prod는 200번대를 쓴다

  condition {
    host_header {
      values = [var.be_domain]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.be.arn
  }

  tags = {
    Name = "${local.name_prefix}-be-rule"
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

resource "aws_lb_target_group_attachment" "fe" {
  target_group_arn = aws_lb_target_group.fe.arn
  target_id        = aws_instance.fe.id
  port             = var.fe_container_port
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
