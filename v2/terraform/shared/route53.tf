# meety.io.kr DNS를 가비아에서 Route 53으로 옮긴다.
# - 가비아는 TTL을 600초보다 낮출 수 없어, 환경을 옮길 때 이전 주소로 요청이 오래 남는다.
# - 네임서버를 바꾸는 동안에는 가비아와 Route 53이 섞여서 응답하므로, 처음에는 가비아 레코드를 값과 TTL까지 그대로 옮긴다.
#   TTL을 낮추거나 ALB 별칭(alias) 레코드로 바꾸는 일은 네임서버 전파가 끝난 뒤 따로 한다.
# - 가비아의 메일 레코드(MX, SPF TXT)는 이메일을 쓰지 않아 옮기지 않는다.
resource "aws_route53_zone" "main" {
  name    = "meety.io.kr"
  comment = "Meety 서비스 도메인. 가비아에서 옮김"

  tags = {
    Name = "${local.name_prefix}-meety-io-kr"
  }
}

# V1 prod (오하이오 app 인스턴스의 탄력적 IP). V1 prod를 정리할 때 함께 바꾼다
resource "aws_route53_record" "v1_prod" {
  for_each = toset(["", "api"])

  zone_id = aws_route53_zone.main.zone_id
  name    = each.value == "" ? aws_route53_zone.main.name : "${each.value}.${aws_route53_zone.main.name}"
  type    = "A"
  ttl     = 1800
  records = ["3.136.17.161"]
}

# V2 ALB로 가는 이름. dev는 V1 dev 이전 리허설 이후 서울 ALB를 가리킨다
resource "aws_route53_record" "alb" {
  for_each = toset(["staging", "api-staging", "dev", "api-dev"])

  zone_id = aws_route53_zone.main.zone_id
  name    = "${each.value}.${aws_route53_zone.main.name}"
  type    = "CNAME"
  ttl     = 600
  records = [aws_lb.main.dns_name]
}

# ACM 인증서 DNS 검증 레코드. 인증서 자동 갱신에도 쓰이므로 지우지 않는다.
# 인증서의 검증 값을 그대로 참조해, 인증서를 다시 만들어도 레코드가 맞춰진다
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for o in concat(
      tolist(aws_acm_certificate.staging.domain_validation_options),
      tolist(aws_acm_certificate.dev.domain_validation_options),
    ) : o.domain_name => o
  }

  zone_id = aws_route53_zone.main.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  ttl     = 600
  records = [each.value.resource_record_value]
}
