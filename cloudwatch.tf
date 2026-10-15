# ========== CLOUDWATCH MONITORING ==========
# - Built-in EC2 metrics (CPU, status checks, CPU credits) for every node
# - CloudWatch agent for memory and root disk usage, plus the bootstrap log
# - Alarms -> SNS topic (optional email subscription)
# - One dashboard for the whole cluster
#
# Control plane nodes are fixed, so they get per-instance alarms. Workers come
# and go with Cluster Autoscaler, so their alarms use Auto Scaling Group
# aggregates instead of instance IDs.

locals {
  cw_namespace = "${var.cluster_name}/Nodes"
  ec2_dims_cp  = [for i in aws_instance.control_plane : { InstanceId = i.id }]
  asg_dims     = { AutoScalingGroupName = aws_autoscaling_group.workers.name }
  alarm_topic  = [aws_sns_topic.alarms.arn]
}

# ---------- CloudWatch agent permissions ----------
resource "aws_iam_role_policy_attachment" "control_plane_cloudwatch_agent" {
  role       = aws_iam_role.control_plane.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "worker_cloudwatch_agent" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# ---------- Bootstrap logs ----------
resource "aws_cloudwatch_log_group" "bootstrap" {
  name              = "/k8s/${var.cluster_name}/bootstrap"
  retention_in_days = var.log_retention_days
}

# ---------- CloudWatch agent configs (pulled via SSM at boot) ----------
# Names must start with "AmazonCloudWatch-" so CloudWatchAgentServerPolicy
# allows the nodes to read them.
locals {
  cloudwatch_agent_config = {
    control_plane = {
      append_dimensions      = { InstanceId = "$${aws:InstanceId}" }
      aggregation_dimensions = null
    }
    worker = {
      append_dimensions = {
        InstanceId           = "$${aws:InstanceId}"
        AutoScalingGroupName = "$${aws:AutoScalingGroupName}"
      }
      aggregation_dimensions = [["AutoScalingGroupName"]]
    }
  }
}

resource "aws_ssm_parameter" "cloudwatch_agent_config" {
  for_each = local.cloudwatch_agent_config

  name = "AmazonCloudWatch-${var.cluster_name}-${replace(each.key, "_", "-")}"
  type = "String"

  value = jsonencode({
    agent = {
      metrics_collection_interval = 60
      run_as_user                 = "root"
    }
    metrics = merge(
      {
        namespace         = local.cw_namespace
        append_dimensions = each.value.append_dimensions
        metrics_collected = {
          mem = {
            measurement = ["mem_used_percent"]
          }
          disk = {
            measurement = ["used_percent"]
            resources   = ["/"]
            drop_device = true
          }
        }
      },
      each.value.aggregation_dimensions == null ? {} : { aggregation_dimensions = each.value.aggregation_dimensions }
    )
    logs = {
      logs_collected = {
        files = {
          collect_list = [{
            file_path       = "/var/log/k8s-bootstrap.log"
            log_group_name  = aws_cloudwatch_log_group.bootstrap.name
            log_stream_name = "{instance_id}"
          }]
        }
      }
    }
  })
}

locals {
  cloudwatch_agent_script = {
    for role, param in aws_ssm_parameter.cloudwatch_agent_config :
    role => templatefile("${path.module}/templates/cloudwatch-agent.sh.tpl", { ssm_parameter = param.name })
  }
}

# ---------- Notifications ----------
resource "aws_sns_topic" "alarms" {
  name = "${var.cluster_name}-alarms"
}

resource "aws_sns_topic_subscription" "alarm_email" {
  count = var.alarm_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ---------- Control plane alarms (per instance) ----------
# EC2 automatic recovery is on by default for t3 instances, so a failed
# system status check is repaired by AWS; these alarms tell you it happened.
resource "aws_cloudwatch_metric_alarm" "control_plane_status_check" {
  count = var.control_plane_count

  alarm_name          = "${var.cluster_name}-control-plane-${count.index + 1}-status-check"
  alarm_description   = "Control plane node ${count.index + 1} (${aws_instance.control_plane[count.index].id}) failed an EC2 status check"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = local.ec2_dims_cp[count.index]
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_topic
  ok_actions          = local.alarm_topic
}

resource "aws_cloudwatch_metric_alarm" "control_plane_cpu" {
  count = var.control_plane_count

  alarm_name          = "${var.cluster_name}-control-plane-${count.index + 1}-cpu-high"
  alarm_description   = "Control plane node ${count.index + 1} CPU above ${var.cpu_alarm_threshold}% for 15 minutes"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = local.ec2_dims_cp[count.index]
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.cpu_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_topic
  ok_actions          = local.alarm_topic
}

resource "aws_cloudwatch_metric_alarm" "control_plane_memory" {
  count = var.control_plane_count

  alarm_name          = "${var.cluster_name}-control-plane-${count.index + 1}-memory-high"
  alarm_description   = "Control plane node ${count.index + 1} memory above ${var.memory_alarm_threshold}% for 10 minutes"
  namespace           = local.cw_namespace
  metric_name         = "mem_used_percent"
  dimensions          = local.ec2_dims_cp[count.index]
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.memory_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_topic
  ok_actions          = local.alarm_topic
}

resource "aws_cloudwatch_metric_alarm" "control_plane_disk" {
  count = var.control_plane_count

  alarm_name          = "${var.cluster_name}-control-plane-${count.index + 1}-disk-high"
  alarm_description   = "Control plane node ${count.index + 1} root disk above ${var.disk_alarm_threshold}%"
  namespace           = local.cw_namespace
  metric_name         = "disk_used_percent"
  dimensions          = merge(local.ec2_dims_cp[count.index], { path = "/", fstype = "ext4" })
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.disk_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_topic
  ok_actions          = local.alarm_topic
}

# ---------- Worker alarms (Auto Scaling Group aggregates) ----------
# Impaired workers are replaced automatically by the ASG's EC2 health check;
# the capacity alarms below catch it if replacement isn't keeping up.
resource "aws_cloudwatch_metric_alarm" "workers_below_min" {
  alarm_name          = "${var.cluster_name}-workers-below-minimum"
  alarm_description   = "Fewer than ${var.worker_min_size} worker instances in service for 10 minutes"
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  dimensions          = local.asg_dims
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.worker_min_size
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_topic
  ok_actions          = local.alarm_topic
}

resource "aws_cloudwatch_metric_alarm" "workers_at_max" {
  alarm_name          = "${var.cluster_name}-workers-at-maximum"
  alarm_description   = "Workers at the maximum of ${var.worker_max_size} for 30 minutes: Cluster Autoscaler cannot add capacity, so pending pods may not schedule"
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  dimensions          = local.asg_dims
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 6
  threshold           = var.worker_max_size
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_topic
  ok_actions          = local.alarm_topic
}

resource "aws_cloudwatch_metric_alarm" "workers_cpu" {
  alarm_name          = "${var.cluster_name}-workers-cpu-high"
  alarm_description   = "Average worker CPU above ${var.cpu_alarm_threshold}% for 15 minutes"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = local.asg_dims
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.cpu_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_topic
  ok_actions          = local.alarm_topic
}

resource "aws_cloudwatch_metric_alarm" "workers_memory" {
  alarm_name          = "${var.cluster_name}-workers-memory-high"
  alarm_description   = "Average worker memory above ${var.memory_alarm_threshold}% for 10 minutes"
  namespace           = local.cw_namespace
  metric_name         = "mem_used_percent"
  dimensions          = local.asg_dims
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.memory_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_topic
  ok_actions          = local.alarm_topic
}

resource "aws_cloudwatch_metric_alarm" "workers_disk" {
  alarm_name          = "${var.cluster_name}-workers-disk-high"
  alarm_description   = "A worker's root disk is above ${var.disk_alarm_threshold}%"
  namespace           = local.cw_namespace
  metric_name         = "disk_used_percent"
  dimensions          = local.asg_dims
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.disk_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_topic
  ok_actions          = local.alarm_topic
}

# ---------- Kubernetes API health (NLB target health) ----------
resource "aws_cloudwatch_metric_alarm" "api_unhealthy" {
  alarm_name          = "${var.cluster_name}-api-servers-unhealthy"
  alarm_description   = "Fewer than ${var.control_plane_count} API servers are passing the NLB /readyz health check"
  namespace           = "AWS/NetworkELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = aws_lb.api.arn_suffix, TargetGroup = aws_lb_target_group.api.arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = var.control_plane_count
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_topic
  ok_actions          = local.alarm_topic
}

# ---------- Dashboard ----------
locals {
  cp_ids = aws_instance.control_plane[*].id

  dashboard_widgets = [
    {
      title   = "Control plane CPU %"
      metrics = [for i, id in local.cp_ids : ["AWS/EC2", "CPUUtilization", "InstanceId", id, { label = "cp-${i + 1}" }]]
      stat    = "Average"
    },
    {
      title = "Worker CPU % (ASG)"
      metrics = [
        ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.workers.name, { stat = "Average", label = "average" }],
        ["...", { stat = "Maximum", label = "busiest node" }],
      ]
      stat = "Average"
    },
    {
      title = "Memory used %"
      metrics = concat(
        [for i, id in local.cp_ids : [local.cw_namespace, "mem_used_percent", "InstanceId", id, { label = "cp-${i + 1}" }]],
        [[local.cw_namespace, "mem_used_percent", "AutoScalingGroupName", aws_autoscaling_group.workers.name, { label = "workers (avg)" }]],
      )
      stat = "Average"
    },
    {
      title = "Root disk used %"
      metrics = concat(
        [for i, id in local.cp_ids : [local.cw_namespace, "disk_used_percent", "InstanceId", id, "path", "/", "fstype", "ext4", { label = "cp-${i + 1}" }]],
        [[local.cw_namespace, "disk_used_percent", "AutoScalingGroupName", aws_autoscaling_group.workers.name, { label = "workers (max)" }]],
      )
      stat = "Maximum"
    },
    {
      title = "Worker count (Cluster Autoscaler)"
      metrics = [
        ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", aws_autoscaling_group.workers.name, { label = "in service" }],
        ["AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", aws_autoscaling_group.workers.name, { label = "desired" }],
        ["AWS/AutoScaling", "GroupMaxSize", "AutoScalingGroupName", aws_autoscaling_group.workers.name, { label = "max" }],
      ]
      stat = "Maximum"
    },
    {
      title = "API servers healthy (NLB)"
      metrics = [
        ["AWS/NetworkELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.api.arn_suffix, "LoadBalancer", aws_lb.api.arn_suffix, { stat = "Minimum", label = "healthy" }],
        ["AWS/NetworkELB", "UnHealthyHostCount", "TargetGroup", aws_lb_target_group.api.arn_suffix, "LoadBalancer", aws_lb.api.arn_suffix, { stat = "Maximum", label = "unhealthy" }],
      ]
      stat = "Minimum"
    },
    {
      # t3 instances run in "unlimited" mode by default: once credits hit zero,
      # sustained CPU above baseline is billed as surplus credits.
      title = "CPU credit balance"
      metrics = concat(
        [for i, id in local.cp_ids : ["AWS/EC2", "CPUCreditBalance", "InstanceId", id, { label = "cp-${i + 1}" }]],
        [["AWS/EC2", "CPUCreditBalance", "AutoScalingGroupName", aws_autoscaling_group.workers.name, { label = "workers (min)", stat = "Minimum" }]],
      )
      stat = "Average"
    },
    {
      title = "Status check failures"
      metrics = concat(
        [for i, id in local.cp_ids : ["AWS/EC2", "StatusCheckFailed", "InstanceId", id, { label = "cp-${i + 1}" }]],
        [["AWS/EC2", "StatusCheckFailed", "AutoScalingGroupName", aws_autoscaling_group.workers.name, { label = "workers" }]],
      )
      stat = "Maximum"
    },
  ]
}

resource "aws_cloudwatch_dashboard" "cluster" {
  dashboard_name = var.cluster_name

  dashboard_body = jsonencode({
    widgets = [
      for idx, w in local.dashboard_widgets : {
        type   = "metric"
        x      = (idx % 2) * 12
        y      = floor(idx / 2) * 6
        width  = 12
        height = 6
        properties = {
          title   = w.title
          metrics = w.metrics
          stat    = w.stat
          period  = 300
          region  = var.region
          view    = "timeSeries"
          stacked = false
        }
      }
    ]
  })
}
