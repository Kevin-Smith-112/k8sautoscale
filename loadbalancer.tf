# ========== KUBERNETES API LOAD BALANCER ==========
# Internet-facing NLB so kubectl works from outside the VPC. Only
# var.admin_cidrs can reach it, and it health-checks every API server so
# traffic fails over if a control plane node goes down.
#
# Nodes keep using the internal Route53 name (networking.tf), so cluster
# traffic never leaves the VPC.

resource "aws_security_group" "api_lb" {
  name_prefix = "${var.cluster_name}-api-lb-"
  description = "Public Kubernetes API load balancer for ${var.cluster_name}"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.cluster_name}-api-lb" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "api_lb_admin" {
  for_each = toset(var.admin_cidrs)

  security_group_id = aws_security_group.api_lb.id
  description       = "Kubernetes API from admin"
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "api_lb_to_control_plane" {
  security_group_id            = aws_security_group.api_lb.id
  description                  = "Forward to API servers and health checks"
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  referenced_security_group_id = aws_security_group.cluster.id
}

resource "aws_vpc_security_group_ingress_rule" "control_plane_from_api_lb" {
  security_group_id            = aws_security_group.cluster.id
  description                  = "Kubernetes API from the public NLB"
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  referenced_security_group_id = aws_security_group.api_lb.id
}

resource "aws_lb" "api" {
  name                             = "${var.cluster_name}-api"
  load_balancer_type               = "network"
  internal                         = false
  subnets                          = aws_subnet.public[*].id
  security_groups                  = [aws_security_group.api_lb.id]
  enable_cross_zone_load_balancing = true

  tags = { Name = "${var.cluster_name}-api" }
}

# IP targets: the control plane IPs are fixed, and with client IP
# preservation off the API servers see the NLB as the source, which the
# cluster security group allows via the NLB's security group.
resource "aws_lb_target_group" "api" {
  name               = "${var.cluster_name}-api"
  port               = 6443
  protocol           = "TCP"
  target_type        = "ip"
  vpc_id             = aws_vpc.main.id
  preserve_client_ip = false

  health_check {
    protocol            = "HTTPS"
    port                = "6443"
    path                = "/readyz"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "${var.cluster_name}-api" }
}

resource "aws_lb_target_group_attachment" "api" {
  count = var.control_plane_count

  target_group_arn = aws_lb_target_group.api.arn
  target_id        = local.control_plane_ips[count.index]
  port             = 6443
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
