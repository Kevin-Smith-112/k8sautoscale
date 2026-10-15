# ========== NETWORKING ==========
# Nodes live in private subnets with no public IPs and reach the internet
# (apt, container registries, AWS APIs) through a NAT gateway. The public
# subnets only hold the NAT gateway(s) and any internet-facing load balancers
# created for `type: LoadBalancer` Services. Admin access is via SSM.

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.cluster_tag, { Name = "${var.cluster_name}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.cluster_name}-igw" }
}

# ---------- Public subnets (NAT gateway + internet-facing LBs) ----------
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.cluster_tag, {
    Name                     = "${var.cluster_name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.cluster_tag, { Name = "${var.cluster_name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------- NAT gateway(s) ----------
resource "aws_eip" "nat" {
  count = local.nat_gateway_count

  domain = "vpc"
  tags   = { Name = "${var.cluster_name}-nat-${local.azs[count.index]}" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = { Name = "${var.cluster_name}-nat-${local.azs[count.index]}" }

  depends_on = [aws_internet_gateway.main]
}

# ---------- Private subnets (all Kubernetes nodes) ----------
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.cluster_tag, {
    Name                              = "${var.cluster_name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

# One route table per private subnet so each can point at its own AZ's NAT
# gateway when nat_gateway_per_az = true
resource "aws_route_table" "private" {
  count = length(aws_subnet.private)

  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index % local.nat_gateway_count].id
  }

  tags = merge(local.cluster_tag, { Name = "${var.cluster_name}-private-rt-${local.azs[count.index]}" })
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------- Kubernetes API endpoint ----------
# A private hosted zone (~$0.50/month) instead of a load balancer. Workers
# resolve the API name to every control plane IP; control plane nodes pin the
# name to themselves via /etc/hosts.
resource "aws_route53_zone" "internal" {
  name = "${var.cluster_name}.internal"

  vpc {
    vpc_id = aws_vpc.main.id
  }
}

resource "aws_route53_record" "api" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = local.api_dns
  type    = "A"
  ttl     = 30
  records = local.control_plane_ips
}
