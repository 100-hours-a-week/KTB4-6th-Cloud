# V2 VPC와 퍼블릭 서브넷은 v2/terraform/shared가 관리한다.
# V3는 같은 VPC를 쓰되(5단계 4번 네트워크 설계 2장) 조회만 하고, 이 폴더에서 바꾸지 않는다.

data "aws_caller_identity" "current" {}

data "aws_vpc" "v2" {
  tags = {
    Name = "${local.v2_prefix}-vpc"
  }
}

# AZ마다 하나씩 조회해 AZ 순서를 var.azs와 맞춘다. 이름 규칙은 v2/terraform/shared/network.tf와 같다.
data "aws_subnet" "v2_public" {
  for_each = toset(var.azs)

  vpc_id            = data.aws_vpc.v2.id
  availability_zone = each.value

  tags = {
    Name = "${local.v2_prefix}-public-${substr(each.value, -1, 1)}"
  }
}
