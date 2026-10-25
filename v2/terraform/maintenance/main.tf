data "aws_caller_identity" "current" {}

data "terraform_remote_state" "shared" {
  backend = "local"
  config = {
    path = "${path.module}/../shared/terraform.tfstate"
  }
}

data "terraform_remote_state" "prod" {
  backend = "local"
  config = {
    path = "${path.module}/../prod/terraform.tfstate"
  }
}

# 인증 콜백·토큰 갱신은 브라우저 대신 FE 서버가 BE를 호출한다.
# FE의 고정 출구 IP와 인증 경로를 모두 확인해 일반 외부 요청은 계속 차단한다.
resource "aws_lb_listener_rule" "fe_server_auth" {
  listener_arn = data.terraform_remote_state.shared.outputs.https_listener_arn
  priority     = 204

  condition {
    host_header {
      values = ["api.meety.io.kr"]
    }
  }
  condition {
    source_ip {
      values = ["${data.terraform_remote_state.prod.outputs.fe_public_ip}/32"]
    }
  }
  condition {
    path_pattern {
      values = ["/api/v1/auth/*"]
    }
  }
  action {
    type             = "forward"
    target_group_arn = data.aws_lb_target_group.prod_api.arn
  }
  tags = { Name = "${local.name}-fe-server-auth" }
}

# 회의 Q&A 채팅은 AI 서버가 BE 내부 API를 조회한다. AI는 FE 인스턴스를 NAT로 사용하므로
# FE의 고정 출구 IP와 Q&A 내부 경로를 모두 확인해 그 외 내부 API 요청은 계속 차단한다.
resource "aws_lb_listener_rule" "ai_internal_qna" {
  listener_arn = data.terraform_remote_state.shared.outputs.https_listener_arn
  priority     = 203

  condition {
    host_header {
      values = ["api.meety.io.kr"]
    }
  }
  condition {
    source_ip {
      values = ["${data.terraform_remote_state.prod.outputs.fe_public_ip}/32"]
    }
  }
  condition {
    path_pattern {
      values = ["/internal/v1/qna/*"]
    }
  }
  action {
    type             = "forward"
    target_group_arn = data.aws_lb_target_group.prod_api.arn
  }
  tags = { Name = "${local.name}-ai-internal-qna" }
}

data "aws_route53_zone" "main" {
  name         = "meety.io.kr."
  private_zone = false
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

# 배포가 사용하는 헬스 체크는 점검 중에도 실제 FE·BE에서 응답해야 한다.
data "aws_lb_target_group" "prod_fe" {
  name = "meety-v2-prod-fe-tg"
}

data "aws_lb_target_group" "prod_api" {
  name = "meety-v2-prod-be-api-tg"
}

locals {
  name        = "meety-v2-maintenance"
  assets_path = "${path.module}/../../maintenance/site"
  # 명시한 정적 파일만 업로드하며 FE 빌드 결과나 인증 자료를 포함하지 않는다.
  assets = {
    "index.html"                   = "text/html; charset=utf-8"
    "assets/maintenance.css"       = "text/css; charset=utf-8"
    "assets/meety-maintenance.png" = "image/png"
    "robots.txt"                   = "text/plain; charset=utf-8"
  }
}

resource "aws_s3_bucket" "page" {
  bucket = "${local.name}-${data.aws_caller_identity.current.account_id}-ap-northeast-2"
  tags   = { Name = local.name }
}

resource "aws_s3_bucket_public_access_block" "page" {
  bucket                  = aws_s3_bucket.page.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "page" {
  bucket = aws_s3_bucket.page.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "page" {
  bucket = aws_s3_bucket.page.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "page" {
  bucket = aws_s3_bucket.page.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "page" {
  for_each = local.assets

  bucket        = aws_s3_bucket.page.id
  key           = each.key
  source        = "${local.assets_path}/${each.key}"
  source_hash   = filemd5("${local.assets_path}/${each.key}")
  content_type  = each.value
  cache_control = "no-store, max-age=0"

  depends_on = [aws_s3_bucket_ownership_controls.page, aws_s3_bucket_versioning.page]
}

resource "aws_acm_certificate" "page" {
  provider          = aws.certificate
  domain_name       = var.maintenance_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "certificate" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = one(aws_acm_certificate.page.domain_validation_options).resource_record_name
  type    = one(aws_acm_certificate.page.domain_validation_options).resource_record_type
  ttl     = 60
  records = [one(aws_acm_certificate.page.domain_validation_options).resource_record_value]
}

resource "aws_acm_certificate_validation" "page" {
  provider                = aws.certificate
  certificate_arn         = aws_acm_certificate.page.arn
  validation_record_fqdns = [aws_route53_record.certificate.fqdn]
}

resource "aws_cloudfront_origin_access_control" "page" {
  name                              = local.name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_response_headers_policy" "page" {
  name = local.name

  security_headers_config {
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "no-referrer"
      override        = true
    }
    strict_transport_security {
      access_control_max_age_sec = 31536000
      override                   = true
    }
    content_security_policy {
      content_security_policy = "default-src 'none'; style-src 'self' https://cdn.jsdelivr.net; font-src https://cdn.jsdelivr.net; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
      override                = true
    }
  }

  custom_headers_config {
    items {
      header   = "X-Robots-Tag"
      value    = "noindex, nofollow, noarchive"
      override = true
    }
  }
}

resource "aws_cloudfront_distribution" "page" {
  enabled             = true
  is_ipv6_enabled     = true
  aliases             = [var.maintenance_domain]
  comment             = "Meety 점검 안내 정적 페이지"
  default_root_object = "index.html"
  http_version        = "http2and3"

  origin {
    domain_name              = aws_s3_bucket.page.bucket_regional_domain_name
    origin_id                = local.name
    origin_access_control_id = aws_cloudfront_origin_access_control.page.id
  }

  default_cache_behavior {
    target_origin_id           = local.name
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.page.id
    compress                   = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.page.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  # 전파가 끝나고 콘텐츠 접근 권한이 준비된 다음 ALB 점검 규칙을 만든다.
  depends_on = [aws_s3_object.page]
}

resource "aws_s3_bucket_policy" "page" {
  bucket = aws_s3_bucket.page.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowMaintenanceCloudFront"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.page.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.page.arn } }
    }]
  })
}

resource "aws_route53_record" "page" {
  for_each = toset(["A", "AAAA"])

  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.maintenance_domain
  type    = each.value
  alias {
    name                   = aws_cloudfront_distribution.page.domain_name
    zone_id                = aws_cloudfront_distribution.page.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_lb_listener_rule" "preview_fe" {
  listener_arn = data.terraform_remote_state.shared.outputs.https_listener_arn
  priority     = 190

  condition {
    host_header {
      values = ["meety.io.kr"]
    }
  }

  # 허용 IP에서도 헤더를 명시하면 점검 안내를 미리 확인할 수 있다.
  condition {
    http_header {
      http_header_name = "X-Meety-Maintenance-Preview"
      values           = ["1"]
    }
  }

  action {
    type = "redirect"
    redirect {
      protocol = "HTTPS"
      port     = "443"
      host     = var.maintenance_domain
      path     = "/"
      # OAuth 코드나 기타 사용자 쿼리를 점검 페이지로 전달하지 않는다.
      query       = ""
      status_code = "HTTP_302"
    }
  }

  tags       = { Name = "${local.name}-fe" }
  depends_on = [aws_route53_record.page, aws_s3_bucket_policy.page]
}

resource "aws_lb_listener_rule" "health_fe" {
  listener_arn = data.terraform_remote_state.shared.outputs.https_listener_arn
  priority     = 188

  condition {
    host_header {
      values = ["meety.io.kr"]
    }
  }
  condition {
    path_pattern {
      values = ["/api/health"]
    }
  }
  action {
    type             = "forward"
    target_group_arn = data.aws_lb_target_group.prod_fe.arn
  }
  tags = { Name = "${local.name}-health-fe" }
}

resource "aws_lb_listener_rule" "health_api" {
  listener_arn = data.terraform_remote_state.shared.outputs.https_listener_arn
  priority     = 189

  condition {
    host_header {
      values = ["api.meety.io.kr"]
    }
  }
  condition {
    path_pattern {
      values = ["/actuator/health", "/actuator/health/*"]
    }
  }
  action {
    type             = "forward"
    target_group_arn = data.aws_lb_target_group.prod_api.arn
  }
  tags = { Name = "${local.name}-health-api" }
}

resource "aws_lb_listener_rule" "preview_api" {
  listener_arn = data.terraform_remote_state.shared.outputs.https_listener_arn
  priority     = 191

  condition {
    host_header {
      values = ["api.meety.io.kr"]
    }
  }

  condition {
    http_header {
      http_header_name = "X-Meety-Maintenance-Preview"
      values           = ["1"]
    }
  }

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      status_code  = "503"
      message_body = jsonencode({
        success        = false
        code           = "SERVICE_MAINTENANCE"
        message        = "서비스 점검 중입니다. 잠시 후 다시 이용해 주세요."
        maintenanceUrl = "https://${var.maintenance_domain}/"
      })
    }
  }

  tags       = { Name = "${local.name}-api" }
  depends_on = [aws_route53_record.page, aws_s3_bucket_policy.page]
}

# 기존 미리보기 규칙의 ARN을 유지한다.
moved {
  from = aws_lb_listener_rule.maintenance_fe
  to   = aws_lb_listener_rule.preview_fe
}

moved {
  from = aws_lb_listener_rule.maintenance_api
  to   = aws_lb_listener_rule.preview_api
}

# 기존 prod 라우팅(200/205/210) 뒤에 둔다. 점검 중 허용 IP는 기존 규칙에 일치하고,
# 그 외 요청만 이 규칙으로 내려오므로 ECS의 실시간 가중치를 복제할 필요가 없다.
resource "aws_lb_listener_rule" "fallback_fe" {
  listener_arn = data.terraform_remote_state.shared.outputs.https_listener_arn
  priority     = 220

  condition {
    host_header {
      values = ["meety.io.kr"]
    }
  }
  dynamic "condition" {
    for_each = var.maintenance_enabled ? [] : [true]
    content {
      http_header {
        http_header_name = "X-Meety-Maintenance-Preview"
        values           = ["1"]
      }
    }
  }
  action {
    type = "redirect"
    redirect {
      protocol    = "HTTPS"
      port        = "443"
      host        = var.maintenance_domain
      path        = "/"
      query       = ""
      status_code = "HTTP_302"
    }
  }
  tags       = { Name = "${local.name}-fallback-fe" }
  depends_on = [aws_route53_record.page, aws_s3_bucket_policy.page]
}

resource "aws_lb_listener_rule" "fallback_api" {
  listener_arn = data.terraform_remote_state.shared.outputs.https_listener_arn
  priority     = 221

  condition {
    host_header {
      values = ["api.meety.io.kr"]
    }
  }
  dynamic "condition" {
    for_each = var.maintenance_enabled ? [] : [true]
    content {
      http_header {
        http_header_name = "X-Meety-Maintenance-Preview"
        values           = ["1"]
      }
    }
  }
  action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      status_code  = "503"
      message_body = jsonencode({
        success        = false
        code           = "SERVICE_MAINTENANCE"
        message        = "서비스 점검 중입니다. 잠시 후 다시 이용해 주세요."
        maintenanceUrl = "https://${var.maintenance_domain}/"
      })
    }
  }
  tags       = { Name = "${local.name}-fallback-api" }
  depends_on = [aws_route53_record.page, aws_s3_bucket_policy.page]
}
