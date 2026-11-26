# 클러스터 접속용 EC2 (5단계 4번 네트워크 설계 6.2절)
# - 클러스터 API는 비공개라, 사람(Cloud 담당자)은 SSM Session Manager로 이 EC2에 들어가 kubectl, helm을 쓴다.
# - 인바운드 규칙과 SSH 키가 없다. SSM은 EC2가 바깥으로 연결하는 방식이다.
# - NAT가 멈춰도 들어갈 수 있게 퍼블릭 서브넷에 두고, 크기 1 Auto Scaling 그룹으로 두 AZ에 걸친다.
#   교체되면 인스턴스 ID가 바뀌므로 Name 태그로 찾아 접속한다. 인스턴스 안에는 상태를 저장하지 않는다.

resource "aws_security_group" "bastion" {
  name        = "${local.name_prefix}-bastion"
  description = "V3 cluster access instance (SSM only, no inbound)"
  vpc_id      = data.aws_vpc.v2.id

  tags = {
    Name = "${local.name_prefix}-bastion"
  }
}

resource "aws_vpc_security_group_egress_rule" "bastion_all" {
  security_group_id = aws_security_group.bastion.id
  description       = "Outbound for SSM, EKS API, package download"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_iam_role" "bastion" {
  name = "${local.name_prefix}-bastion"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# kubeconfig를 만들 때 클러스터 주소만 조회한다. 클러스터 안 권한은 EKS access entry로 준다(eks.tf).
resource "aws_iam_role_policy" "bastion_eks" {
  name = "describe-cluster"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "eks:DescribeCluster"
      Resource = module.eks.cluster_arn
    }]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${local.name_prefix}-bastion"
  role = aws_iam_role.bastion.name
}

resource "aws_launch_template" "bastion" {
  name          = "${local.name_prefix}-bastion"
  image_id      = var.al2023_arm64_ami_id
  instance_type = var.bastion_instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.bastion.arn
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.bastion.id]
    delete_on_termination       = true
  }

  user_data = base64encode(templatefile("${path.module}/user_data/bastion.sh.tftpl", {
    region             = var.region
    cluster_name       = local.cluster_name
    kubernetes_version = var.kubernetes_version
  }))

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
      tags          = merge(local.common_tags, { Name = "${local.name_prefix}-bastion" })
    }
  }

  tags = {
    Name = "${local.name_prefix}-bastion"
  }
}

resource "aws_autoscaling_group" "bastion" {
  name                = "${local.name_prefix}-bastion"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [for s in data.aws_subnet.v2_public : s.id]
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.bastion.id
    version = aws_launch_template.bastion.latest_version
  }

  depends_on = [aws_iam_role_policy_attachment.bastion_ssm]

  dynamic "tag" {
    for_each = merge(local.common_tags, { Name = "${local.name_prefix}-bastion" })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false
    }
  }
}
