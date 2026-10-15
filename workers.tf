# ========== WORKER NODES ==========
# Workers run in an Auto Scaling Group that Cluster Autoscaler discovers by
# tag and resizes between worker_min_size and worker_max_size.

locals {
  worker_script = templatefile("${path.module}/templates/worker.sh.tpl", {
    cloudwatch_agent_script = local.cloudwatch_agent_script["worker"]
    install_script          = local.install_script
    ca_cert                 = tls_self_signed_cert.ca["ca"].cert_pem
    api_dns                 = local.api_dns
    bootstrap_token         = local.bootstrap_token
  })
}

resource "aws_launch_template" "worker" {
  name_prefix   = "${var.cluster_name}-worker-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.worker_instance_type
  key_name      = var.ssh_key_name
  user_data     = base64gzip(local.worker_script)

  iam_instance_profile {
    arn = aws_iam_instance_profile.worker.arn
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.cluster.id]
    delete_on_termination       = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, local.cluster_tag, {
      Name = "${var.cluster_name}-worker"
      Role = "worker"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.common_tags, local.cluster_tag, {
      Name = "${var.cluster_name}-worker"
    })
  }
}

resource "aws_autoscaling_group" "workers" {
  name                      = "${var.cluster_name}-workers"
  vpc_zone_identifier       = aws_subnet.private[*].id
  min_size                  = var.worker_min_size
  max_size                  = var.worker_max_size
  desired_capacity          = var.worker_min_size
  health_check_type         = "EC2"
  health_check_grace_period = 300

  # Free 1-minute group metrics, used by the alarms and dashboard in cloudwatch.tf
  metrics_granularity = "1Minute"
  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances",
  ]

  launch_template {
    id      = aws_launch_template.worker.id
    version = aws_launch_template.worker.latest_version
  }

  # Cluster Autoscaler auto-discovery tags
  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = false
  }

  tag {
    key                 = "k8s.io/cluster-autoscaler/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = false
  }

  tag {
    key                 = "kubernetes.io/cluster/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }

  # Cluster Autoscaler owns desired capacity after creation
  lifecycle {
    ignore_changes = [desired_capacity]
  }

  # Workers can only join once the API endpoint exists
  depends_on = [
    aws_instance.control_plane,
    aws_route53_record.api,
    aws_route_table_association.private,
    aws_iam_role_policy_attachment.worker_cloudwatch_agent,
  ]
}
