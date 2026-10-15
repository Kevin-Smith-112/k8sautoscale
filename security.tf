# ========== SECURITY GROUPS ==========
# One cluster-wide security group: nodes talk freely to each other (etcd,
# kubelet, Flannel VXLAN, NodePorts). There is no inbound access from outside
# the cluster: nodes sit in private subnets and admins connect through SSM
# Session Manager, which needs only outbound HTTPS from the node.

resource "aws_security_group" "cluster" {
  name_prefix = "${var.cluster_name}-nodes-"
  description = "Kubernetes nodes for ${var.cluster_name}"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.cluster_tag, { Name = "${var.cluster_name}-nodes" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "intra_cluster" {
  security_group_id            = aws_security_group.cluster.id
  description                  = "All traffic between cluster nodes"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.cluster.id
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.cluster.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
