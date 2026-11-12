locals {
  # V3 리소스의 이름 접두사. 예: meety-v3-eks
  name_prefix = "${var.project}-v3"

  # V2 shared가 만든 리소스의 이름 접두사. 조회할 때만 쓴다.
  v2_prefix = "${var.project}-v2"
}
