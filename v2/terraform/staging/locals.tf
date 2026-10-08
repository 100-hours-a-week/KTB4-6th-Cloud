locals {
  # 환경별 리소스의 이름 접두사. 예: meety-v2-staging-be
  name_prefix = "${var.project}-v2-${var.env}"
}
