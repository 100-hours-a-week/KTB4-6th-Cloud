locals {
  # staging과 prod가 같이 쓰는 리소스의 이름 접두사. 예: meety-v2-vpc, meety-v2-alb
  name_prefix = "${var.project}-v2"
}
