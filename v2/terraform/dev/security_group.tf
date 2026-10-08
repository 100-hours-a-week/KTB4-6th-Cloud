# dev BE 보안 그룹: ALB 보안 그룹에서 오는 요청만 받는다.
# 태스크에 public IP가 있지만, 이 규칙 때문에 인터넷에서 태스크로 직접 접근할 수 없다.

resource "aws_security_group" "be" {
  name        = "${local.name_prefix}-be-sg"
  description = "V2 dev BE: from ALB only"
  vpc_id      = local.shared.vpc_id

  tags = {
    Name = "${local.name_prefix}-be-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "be_from_alb" {
  security_group_id            = aws_security_group.be.id
  description                  = "From ALB"
  referenced_security_group_id = local.shared.alb_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.be_container_port
  to_port                      = var.be_container_port
}

# 이미지 받기, Parameter Store, 외부 API(카카오 등) 호출에 인터넷 출구가 필요하다
resource "aws_vpc_security_group_egress_rule" "be_all" {
  security_group_id = aws_security_group.be.id
  description       = "Outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
