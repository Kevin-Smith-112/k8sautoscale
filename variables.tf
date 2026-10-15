# ========== INPUT VARIABLES ==========

locals {
  # x86_64 instance types eligible for the AWS Free Tier. The legacy (pre
  # July 15 2025) free tier covers t2.micro / t3.micro; the current
  # credit-based free plan additionally covers t3.small and the *-flex types.
  free_tier_instance_types = ["t2.micro", "t3.micro", "t3.small", "c7i-flex.large", "m7i-flex.large"]
}

variable "region" {
  description = "AWS region to deploy the cluster into"
  type        = string
  default     = "ca-central-1"
}

variable "cluster_name" {
  description = "Name of the Kubernetes cluster (used in tags, DNS and Cluster Autoscaler discovery)"
  type        = string
  default     = "k8sautoscale"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,32}$", var.cluster_name))
    error_message = "cluster_name must be 3-32 characters of lowercase letters, digits and hyphens."
  }
}

variable "admin_cidrs" {
  description = "CIDR blocks allowed to reach the Kubernetes API through the public NLB, e.g. your home IP [\"203.0.113.10/32\"]"
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && !contains(var.admin_cidrs, "0.0.0.0/0")
    error_message = "admin_cidrs must list at least one CIDR and must not be 0.0.0.0/0."
  }
}

variable "ssh_key_name" {
  description = "Optional existing EC2 key pair name for SSH over SSM Session Manager. Leave null to use SSM shell sessions only"
  type        = string
  default     = null
}

# ---------- Networking ----------
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private node subnets (one per availability zone)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets holding the NAT gateway(s) and internet-facing load balancers (one per availability zone)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == length(var.private_subnet_cidrs)
    error_message = "public_subnet_cidrs and private_subnet_cidrs must have the same number of entries (one pair per availability zone)."
  }
}

variable "nat_gateway_per_az" {
  description = "true = one NAT gateway per availability zone (resilient, ~3x cost); false = a single shared NAT gateway"
  type        = bool
  default     = false
}

variable "pod_cidr" {
  description = "Pod network CIDR (must match the Flannel default network)"
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes Service CIDR"
  type        = string
  default     = "10.96.0.0/12"
}

# ---------- Compute ----------
variable "control_plane_instance_type" {
  description = "Instance type for control plane nodes (kubeadm needs 2 vCPU / ~2 GiB, so t3.small is recommended)"
  type        = string
  default     = "t3.small"

  validation {
    condition     = contains(local.free_tier_instance_types, var.control_plane_instance_type)
    error_message = "control_plane_instance_type must be a free-tier eligible x86_64 type."
  }
}

variable "worker_instance_type" {
  description = "Instance type for worker nodes"
  type        = string
  default     = "t3.small"

  validation {
    condition     = contains(local.free_tier_instance_types, var.worker_instance_type)
    error_message = "worker_instance_type must be a free-tier eligible x86_64 type."
  }
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB for every node (free tier includes 30 GiB in total)"
  type        = number
  default     = 10
}

variable "control_plane_count" {
  description = "Number of control plane nodes (odd, so etcd keeps quorum when a node fails)"
  type        = number
  default     = 3

  validation {
    condition     = var.control_plane_count >= 1 && var.control_plane_count % 2 == 1
    error_message = "control_plane_count must be an odd number (1, 3, 5) for etcd quorum."
  }
}

variable "worker_min_size" {
  description = "Minimum (and initial) number of worker nodes"
  type        = number
  default     = 2
}

variable "worker_max_size" {
  description = "Maximum number of worker nodes Cluster Autoscaler may scale to"
  type        = number
  default     = 4
}

# ---------- Software versions ----------
# Keep these on the same Kubernetes minor version: Cluster Autoscaler and the
# AWS cloud-controller-manager are released in lock-step with Kubernetes.
variable "kubernetes_version" {
  description = "Kubernetes minor version to install from pkgs.k8s.io"
  type        = string
  default     = "1.33"
}

variable "cluster_autoscaler_version" {
  description = "Cluster Autoscaler image tag (match the Kubernetes minor version)"
  type        = string
  default     = "v1.33.0"
}

variable "cloud_controller_manager_version" {
  description = "AWS cloud-controller-manager image tag (match the Kubernetes minor version)"
  type        = string
  default     = "v1.33.0"
}

variable "flannel_version" {
  description = "Flannel CNI release"
  type        = string
  default     = "v0.26.4"
}

variable "helm_version" {
  description = "Helm release used on the first control plane node to install the cloud-controller-manager"
  type        = string
  default     = "v3.16.4"
}

# ---------- Monitoring ----------
variable "alarm_email" {
  description = "Email address subscribed to CloudWatch alarm notifications (leave empty to skip; confirm the subscription email AWS sends)"
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "Retention period, in days, for the node bootstrap logs in CloudWatch Logs"
  type        = number
  default     = 14
}

variable "cpu_alarm_threshold" {
  description = "CPU utilization percentage that triggers an alarm"
  type        = number
  default     = 80
}

variable "memory_alarm_threshold" {
  description = "Memory used percentage that triggers an alarm"
  type        = number
  default     = 85
}

variable "disk_alarm_threshold" {
  description = "Root disk used percentage that triggers an alarm"
  type        = number
  default     = 80
}
