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

# prod를 서울 ALB로 전환한다. 기존 리소스 주소를 유지해 두 레코드를 제자리에서 수정한다.
# DB 승격과 서울 애플리케이션 검증을 마친 뒤 plan을 확인하고 적용한다.
resource "aws_route53_record" "v1_prod" {
  for_each = toset(["", "api"])

  zone_id = aws_route53_zone.main.zone_id
  name    = each.value == "" ? aws_route53_zone.main.name : "${each.value}.${aws_route53_zone.main.name}"
  type    = "A"
  # 루트 도메인도 지원하는 ALB 별칭을 쓴다. TTL은 ALB 별칭의 값을 따른다.
  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# V1 dev (오하이오 dev-app 인스턴스의 탄력적 IP).
# DB 이전 리허설 동안 서울 ALB를 가리켰다가, 개발자가 다시 쓸 수 있게 오하이오로 되돌렸다 (2026-10-15).
# 다음 이전 때 빨리 옮길 수 있도록 TTL을 60초로 둔다
resource "aws_route53_record" "v1_dev" {
  for_each = toset(["dev", "api-dev"])

  zone_id = aws_route53_zone.main.zone_id
  name    = "${each.value}.${aws_route53_zone.main.name}"
  type    = "A"
  ttl     = 60
  records = ["3.147.128.193"]
}

# V2 ALB로 가는 이름
resource "aws_route53_record" "alb" {
  for_each = toset(["staging", "api-staging"])

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

# prod 인증서 검증 레코드 (2026-10-17).
# 위 리소스에 합치면, 아직 만들지 않은 인증서의 값 때문에 기존 staging, dev 레코드까지 교체되는 것으로 계획된다.
# 그래서 따로 두고, 목록은 이미 아는 도메인 변수로 정한다
resource "aws_route53_record" "cert_validation_prod" {
  for_each = toset(var.prod_domains)

  zone_id = aws_route53_zone.main.zone_id
  name    = one([for o in aws_acm_certificate.prod.domain_validation_options : o.resource_record_name if o.domain_name == each.key])
  type    = one([for o in aws_acm_certificate.prod.domain_validation_options : o.resource_record_type if o.domain_name == each.key])
  ttl     = 600
  records = [one([for o in aws_acm_certificate.prod.domain_validation_options : o.resource_record_value if o.domain_name == each.key])]
}

# dev 레코드를 서울 ALB CNAME(alb)에서 오하이오 A 레코드(v1_dev)로 옮긴다.
# 같은 이름에 CNAME과 A를 동시에 둘 수 없어, 새 리소스로 만들지 않고 기존 레코드를 수정하게 한다 (타입, 값, TTL을 한 번에 변경)
moved {
  from = aws_route53_record.alb["dev"]
  to   = aws_route53_record.v1_dev["dev"]
}

moved {
  from = aws_route53_record.alb["api-dev"]
  to   = aws_route53_record.v1_dev["api-dev"]
}
