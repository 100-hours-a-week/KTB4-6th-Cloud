# 공용 ALB에 dev BE용 대상 그룹과 전달 규칙을 붙인다.

resource "aws_lb_target_group" "be" {
  name        = "${local.name_prefix}-be-tg"
  vpc_id      = local.shared.vpc_id
  target_type = "ip" # Fargate 태스크는 IP로 등록된다
  protocol    = "HTTP"
  port        = var.be_container_port

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

# v2-api-dev.meety.io.kr 로 온 HTTPS 요청 → dev BE
resource "aws_lb_listener_rule" "be" {
  listener_arn = local.shared.https_listener_arn
  priority     = 100 # dev는 100번대, prod는 200번대를 쓴다

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
