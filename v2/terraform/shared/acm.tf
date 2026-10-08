# V2 dev용 HTTPS 인증서 (ACM, DNS 검증)
# - 도메인 DNS가 Route53이 아니라서, 검증용 CNAME은 외부 DNS에 직접 추가한다 (output 참고).
# - 검증용 CNAME은 자동 갱신에도 쓰이므로 발급 후에도 지우지 않는다.
# - 발급 완료를 기다리는 aws_acm_certificate_validation은 DNS 등록 후 ALB를 만들 때 추가한다.
#   지금 넣으면 DNS를 등록할 때까지 apply가 멈춰 있게 된다.
# - prod 도메인은 별도 인증서로 만든다 (dev 인증서의 이름을 바꾸면 인증서가 새로 발급되기 때문).

resource "aws_acm_certificate" "dev" {
  domain_name               = var.dev_domains[0]
  subject_alternative_names = slice(var.dev_domains, 1, length(var.dev_domains))
  validation_method         = "DNS"

  # 인증서를 교체해야 할 때 새 인증서를 먼저 만들고 기존 것을 지워서, ALB에 인증서가 없는 순간이 생기지 않게 한다
  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.name_prefix}-dev-cert"
  }
}
