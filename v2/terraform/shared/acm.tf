# V2 staging용 HTTPS 인증서 (ACM, DNS 검증)
# - 검증용 CNAME은 route53.tf에서 관리한다. 네임서버를 Route 53으로 바꾸기 전까지는 가비아에 등록한 레코드로 검증된다.
# - 검증용 CNAME은 자동 갱신에도 쓰이므로 발급 후에도 지우지 않는다.
# - prod 도메인은 별도 인증서로 만든다 (이 인증서의 이름을 바꾸면 인증서가 새로 발급되기 때문).
resource "aws_acm_certificate" "staging" {
  domain_name               = var.staging_domains[0]
  subject_alternative_names = slice(var.staging_domains, 1, length(var.staging_domains))
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.name_prefix}-staging-cert"
  }
}

# V1 dev 도메인을 서울로 옮기는 이전 리허설용 HTTPS 인증서 (ACM, DNS 검증)
# - staging 인증서에 도메인을 추가하면 인증서가 새로 발급되므로 별도 인증서로 만든다.
# - 검증용 CNAME은 staging과 같이 route53.tf에서 관리한다.
# - ALB 리스너에는 발급이 끝난 뒤 aws_lb_listener_certificate로 붙인다.
resource "aws_acm_certificate" "dev" {
  domain_name               = var.dev_domains[0]
  subject_alternative_names = slice(var.dev_domains, 1, length(var.dev_domains))
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.name_prefix}-dev-cert"
  }
}
