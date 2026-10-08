# V2 ALB: dev와 prod가 같이 쓰고, 도메인(Host 헤더)별로 환경을 나눈다.
# - 여기서는 ALB와 리스너만 만든다. 도메인별 전달 규칙과 대상 그룹은 dev/, prod/ 폴더에서 만든다.
# - 규칙에 맞지 않는 요청은 기본 동작으로 404를 돌려준다.

# 인증서 발급 완료를 확인한다. DNS 검증 레코드는 외부 DNS에 이미 등록했다.
# 발급이 끝난 상태라 바로 통과하고, 발급 전이라면 끝날 때까지 기다린다.
resource "aws_acm_certificate_validation" "dev" {
  certificate_arn = aws_acm_certificate.dev.arn
}

resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  # SSE와 오디오 WebSocket은 연결을 오래 유지한다. 기본값(60초)이면 이벤트가 없는 동안 연결이 끊길 수 있다.
  # BE의 heartbeat 주기를 확인한 뒤 다시 조정한다.
  idle_timeout = 600

  # 형식이 잘못된 HTTP 헤더는 ALB에서 제거한다 (요청 스머글링 방지)
  drop_invalid_header_fields = true

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

# HTTP는 모두 HTTPS로 보낸다
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }

  tags = {
    Name = "${local.name_prefix}-http"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06" # TLS 1.2, 1.3만 허용
  certificate_arn   = aws_acm_certificate_validation.dev.certificate_arn

  # 어떤 환경 규칙에도 맞지 않는 요청 (등록하지 않은 도메인, ALB 주소로 직접 접속 등)
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }

  tags = {
    Name = "${local.name_prefix}-https"
  }
}
