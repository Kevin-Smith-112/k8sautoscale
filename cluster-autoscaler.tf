# ========== CLUSTER AUTOSCALER ==========
# Cluster Autoscaler runs on the control plane nodes (so only they need the
# scaling permissions) and is applied by the first control plane node at boot.

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name = "cluster-autoscaler"
  role = aws_iam_role.control_plane.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Describe"
        Effect   = "Allow"
        Resource = "*"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
        ]
      },
      {
        Sid      = "ScaleWorkers"
        Effect   = "Allow"
        Resource = aws_autoscaling_group.workers.arn
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
        ]
      },
    ]
  })
}

locals {
  cluster_autoscaler_manifest = templatefile("${path.module}/templates/cluster-autoscaler.yaml.tpl", {
    cluster_name = var.cluster_name
    region       = var.region
    version      = var.cluster_autoscaler_version
  })
}
