# ALB 보안 그룹: 인터넷에서 80, 443만 받는다.
# BE, FE 같은 환경별 보안 그룹은 staging/, prod/ 폴더에서 만들고, ALB 보안 그룹에서 오는 요청만 허용한다.
# 규칙은 V1과 같이 별도 리소스(aws_vpc_security_group_*_rule)로 관리하고, 인라인 규칙은 쓰지 않는다.

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "V2 ALB: HTTP, HTTPS from internet"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP (HTTPS redirect)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# ALB는 VPC 안의 대상(ECS 태스크)으로만 요청을 보낸다
resource "aws_vpc_security_group_egress_rule" "alb_to_vpc" {
  security_group_id = aws_security_group.alb.id
  description       = "To targets in VPC"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}
