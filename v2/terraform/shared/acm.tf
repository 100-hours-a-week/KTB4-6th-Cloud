# V2 staging용 HTTPS 인증서 (ACM, DNS 검증)
# - 도메인 DNS가 Route53이 아니라서, 검증용 CNAME은 외부 DNS(가비아)에 직접 추가한다 (output 참고).
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
