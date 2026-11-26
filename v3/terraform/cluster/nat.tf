# AZ별 NAT 인스턴스 (5단계 4번 네트워크 설계 5.2절)
# - NAT Gateway의 GB당 처리 요금을 피하려고 NAT 전용 인스턴스를 AZ마다 둔다. V2처럼 FE와 겸용하지 않는다.
# - 크기 1 Auto Scaling 그룹이라 멈추면 새로 뜬다. 새 인스턴스는 부팅할 때 출발지/목적지 검사를 끄고,
#   같은 AZ의 EKS 라우팅 테이블 기본 경로를 자기 자신으로 바꾼다(user_data/nat.sh).
# - 다른 AZ로 자동 우회(4번 5.3절)는 아직 만들지 않았다. 감지와 경로 전환 자동화는 운영 설계 때 붙인다.

resource "aws_security_group" "nat" {
  name        = "${local.name_prefix}-nat"
  description = "V3 NAT instances: forward traffic from EKS subnets"
  vpc_id      = data.aws_vpc.v2.id

  tags = {
    Name = "${local.name_prefix}-nat"
  }
}

resource "aws_vpc_security_group_ingress_rule" "nat_from_eks" {
  for_each = var.eks_subnet_cidrs

  security_group_id = aws_security_group.nat.id
  description       = "All traffic from EKS subnet ${each.key}"
  cidr_ipv4         = each.value
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "nat_all" {
  security_group_id = aws_security_group.nat.id
  description       = "Outbound to internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_iam_role" "nat" {
  name = "${local.name_prefix}-nat"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "nat_ssm" {
  role       = aws_iam_role.nat.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 부팅 때 자기 출발지/목적지 검사를 끄고, EKS 라우팅 테이블의 기본 경로를 바꾸는 권한만 준다
resource "aws_iam_role_policy" "nat_route" {
  name = "nat-self-route"
  role = aws_iam_role.nat.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DisableOwnSourceDestCheck"
        Effect   = "Allow"
        Action   = "ec2:ModifyInstanceAttribute"
        Resource = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"
        # 자기 Auto Scaling 그룹이 띄운 NAT 인스턴스만 바꿀 수 있다
        Condition = { StringEquals = { "aws:ResourceTag/Role" = "nat" } }
      },
      {
        Sid      = "ReplaceEksDefaultRoute"
        Effect   = "Allow"
        Action   = ["ec2:CreateRoute", "ec2:ReplaceRoute"]
        Resource = [for rt in aws_route_table.eks : rt.arn]
      },
    ]
  })
}

resource "aws_iam_instance_profile" "nat" {
  name = "${local.name_prefix}-nat"
  role = aws_iam_role.nat.name
}

resource "aws_launch_template" "nat" {
  for_each = var.eks_subnet_cidrs

  name          = "${local.name_prefix}-nat-${local.az_suffix[each.key]}"
  image_id      = var.al2023_arm64_ami_id
  instance_type = var.nat_instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.nat.arn
  }

  # 퍼블릭 서브넷에서 공인 IP로 직접 나간다
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.nat.id]
    delete_on_termination       = true
  }

  user_data = base64encode(templatefile("${path.module}/user_data/nat.sh.tftpl", {
    region         = var.region
    route_table_id = aws_route_table.eks[each.key].id
    eks_cidrs      = join(", ", values(var.eks_subnet_cidrs))
  }))

  # 크레딧을 다 쓰면 기준 성능으로 제한되고 추가 요금은 없다
  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = 8
      encrypted             = true
      delete_on_termination = true
    }
  }

  dynamic "tag_specifications" {
    for_each = toset(["instance", "volume", "network-interface"])
    content {
      resource_type = tag_specifications.value
      tags = merge(local.common_tags, {
        Name = "${local.name_prefix}-nat-${local.az_suffix[each.key]}"
        Role = "nat"
      })
    }
  }

  tags = {
    Name = "${local.name_prefix}-nat-${local.az_suffix[each.key]}"
  }
}

resource "aws_autoscaling_group" "nat" {
  for_each = var.eks_subnet_cidrs

  name                = "${local.name_prefix}-nat-${local.az_suffix[each.key]}"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [data.aws_subnet.v2_public[each.key].id]
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.nat[each.key].id
    version = aws_launch_template.nat[each.key].latest_version
  }

  # 새 인스턴스가 라우팅을 바꾸려면 권한이 먼저 있어야 한다
  depends_on = [aws_iam_role_policy.nat_route, aws_iam_role_policy_attachment.nat_ssm, aws_route_table_association.eks]

  dynamic "tag" {
    for_each = merge(local.common_tags, { Name = "${local.name_prefix}-nat-${local.az_suffix[each.key]}" })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false
    }
  }
}
