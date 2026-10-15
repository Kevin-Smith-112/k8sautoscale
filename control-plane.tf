# ========== CONTROL PLANE NODES ==========
# Node 0 runs `kubeadm init` and installs Flannel, the AWS
# cloud-controller-manager and Cluster Autoscaler. The remaining nodes wait
# for it and `kubeadm join --control-plane` using the shared PKI from pki.tf.

locals {
  control_plane_init_script = templatefile("${path.module}/templates/control-plane-init.sh.tpl", {
    cloudwatch_agent_script     = local.cloudwatch_agent_script["control_plane"]
    install_script              = local.install_script
    pki_script                  = local.pki_script
    cluster_name                = var.cluster_name
    api_dns                     = local.api_dns
    api_public_dns              = aws_lb.api.dns_name
    pod_cidr                    = var.pod_cidr
    service_cidr                = var.service_cidr
    bootstrap_token             = local.bootstrap_token
    flannel_version             = var.flannel_version
    helm_version                = var.helm_version
    ccm_version                 = var.cloud_controller_manager_version
    cluster_autoscaler_manifest = local.cluster_autoscaler_manifest
  })

  control_plane_join_script = templatefile("${path.module}/templates/control-plane-join.sh.tpl", {
    cloudwatch_agent_script = local.cloudwatch_agent_script["control_plane"]
    install_script          = local.install_script
    pki_script              = local.pki_script
    api_dns                 = local.api_dns
    init_node_ip            = local.control_plane_ips[0]
    bootstrap_token         = local.bootstrap_token
  })
}

resource "aws_instance" "control_plane" {
  count = var.control_plane_count

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.control_plane_instance_type
  subnet_id                   = aws_subnet.private[count.index % length(aws_subnet.private)].id
  private_ip                  = local.control_plane_ips[count.index]
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.cluster.id]
  iam_instance_profile        = aws_iam_instance_profile.control_plane.name
  key_name                    = var.ssh_key_name

  # gzip keeps the PKI + manifests under the 16 KB user data limit
  user_data_base64 = base64gzip(count.index == 0 ? local.control_plane_init_script : local.control_plane_join_script)

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # lets pods (Cluster Autoscaler) reach IMDS
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(local.cluster_tag, {
    Name = "${var.cluster_name}-control-plane-${count.index + 1}"
    Role = "control-plane"
  })

  volume_tags = merge(local.common_tags, local.cluster_tag, {
    Name = "${var.cluster_name}-control-plane-${count.index + 1}"
  })

  # A new Ubuntu AMI or edited bootstrap script must not rebuild a running
  # control plane. Replace nodes deliberately with `terraform apply -replace`.
  lifecycle {
    ignore_changes = [ami, user_data_base64]
  }

  # Bootstrap needs outbound internet through the NAT gateway
  depends_on = [aws_route_table_association.private, aws_iam_role_policy_attachment.control_plane_cloudwatch_agent]
}
