# ========== LOCAL VALUES ==========

locals {
  common_tags = {
    Project     = var.cluster_name
    Environment = "Development"
    ManagedBy   = "Terraform"
  }

  # Required by the AWS cloud-controller-manager to discover cluster resources
  cluster_tag = { "kubernetes.io/cluster/${var.cluster_name}" = "owned" }

  azs = slice(data.aws_availability_zones.available.names, 0, length(var.private_subnet_cidrs))

  nat_gateway_count = var.nat_gateway_per_az ? length(var.public_subnet_cidrs) : 1

  # Stable API endpoint (private Route53 record -> control plane IPs)
  api_dns = "api.${var.cluster_name}.internal"

  # Fixed private IPs for the control plane, spread across private subnets/AZs
  control_plane_ips = [
    for i in range(var.control_plane_count) :
    cidrhost(var.private_subnet_cidrs[i % length(var.private_subnet_cidrs)], 10 + floor(i / length(var.private_subnet_cidrs)))
  ]

  # Shared node bootstrap: containerd + kubelet/kubeadm/kubectl
  install_script = templatefile("${path.module}/templates/install-k8s.sh.tpl", {
    kubernetes_version = var.kubernetes_version
  })
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Canonical's Ubuntu 24.04 LTS (free tier eligible)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
