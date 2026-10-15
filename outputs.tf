# ========== OUTPUTS ==========

output "control_plane_private_ips" {
  description = "Private IPs of the control plane nodes"
  value       = aws_instance.control_plane[*].private_ip
}

output "control_plane_instance_ids" {
  description = "Instance IDs of the control plane nodes (for SSM Session Manager)"
  value       = aws_instance.control_plane[*].id
}

output "nat_gateway_public_ips" {
  description = "Public IPs the cluster's outbound traffic comes from"
  value       = aws_eip.nat[*].public_ip
}

output "api_endpoint_internal" {
  description = "In-VPC Kubernetes API endpoint"
  value       = "https://${local.api_dns}:6443"
}

output "worker_asg_name" {
  description = "Auto Scaling Group managed by Cluster Autoscaler"
  value       = aws_autoscaling_group.workers.name
}

output "api_endpoint_public" {
  description = "Public Kubernetes API endpoint (NLB), reachable from admin_cidrs"
  value       = "https://${aws_lb.api.dns_name}:6443"
}

output "get_kubeconfig" {
  description = "Commands to download an admin kubeconfig that points at the public API NLB"
  value       = <<-EOT
    CMD_ID=$(aws ssm send-command --region ${var.region} --instance-ids ${aws_instance.control_plane[0].id} \
      --document-name AWS-RunShellScript --parameters 'commands=["cat /home/ubuntu/kubeconfig-remote"]' \
      --query Command.CommandId --output text)
    sleep 5
    aws ssm get-command-invocation --region ${var.region} --command-id "$CMD_ID" \
      --instance-id ${aws_instance.control_plane[0].id} --query StandardOutputContent --output text > kubeconfig
    chmod 600 kubeconfig
    export KUBECONFIG=$PWD/kubeconfig
    kubectl get nodes
  EOT
}
