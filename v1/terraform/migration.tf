# V1 public 라우트 테이블의 인터넷 경로
# - V2 서울과의 피어링 경로와 리허설 DB 접근 권한은 이전을 하지 않기로 해 삭제했다 (#91).
# - public 라우트 테이블의 경로는 aws_route로 관리한다. route 블록 안에 경로를 추가하면 Terraform이
#   기존 인터넷 경로까지 지웠다가 다시 만드는 것으로 계획할 수 있어, prod 인터넷 경로를 건드리지 않도록 분리했다.

# 기존 인터넷 경로. 리소스만 import하고 값은 그대로다.
import {
  to = aws_route.public_internet
  id = "rtb-006dcab3f189780a2_0.0.0.0/0"
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}
