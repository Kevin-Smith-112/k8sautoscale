# k8sautoscale

A self-managed Kubernetes cluster on AWS (`ca-central-1`) built with kubeadm.
The worker pool grows and shrinks on its own through the
[Kubernetes Cluster Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler).

| Component      | Default                                                       |
| -------------- | ------------------------------------------------------------- |
| AMI            | Ubuntu 24.04 LTS (Canonical, free tier eligible)              |
| Control plane  | 3 × `t3.small` EC2 instances (stacked etcd)                   |
| Workers        | Auto Scaling Group, min 2 / max 4 × `t3.small`                |
| Kubernetes     | 1.33 (kubeadm, containerd)                                    |
| CNI            | Flannel                                                       |
| Cloud provider | AWS cloud-controller-manager (out-of-tree)                    |
| Autoscaling    | Cluster Autoscaler with ASG tag auto-discovery                |
| Networking     | Nodes in private subnets across 3 AZs, outbound via NAT gateway |
| API access     | Internet-facing NLB on 6443, restricted to `admin_cidrs`       |
| Node access    | AWS SSM Session Manager (no public node IPs)                   |
| Monitoring     | CloudWatch metrics, agent (memory/disk), alarms, dashboard     |

## File layout

| File                    | Contents                                                          |
| ----------------------- | ----------------------------------------------------------------- |
| `terraform.tf`          | Terraform and provider configuration                              |
| `variables.tf`          | Input variables                                                   |
| `locals.tf`             | Shared values, AZ lookup, Ubuntu AMI lookup                       |
| `networking.tf`         | VPC, private node subnets, public subnets, NAT gateway, API DNS   |
| `security.tf`           | Security group for the nodes (intra-cluster only)                 |
| `loadbalancer.tf`       | Public NLB for the Kubernetes API, locked to `admin_cidrs`        |
| `cloudwatch.tf`         | CloudWatch agent config, alarms, SNS notifications, dashboard     |
| `iam.tf`                | IAM roles: control plane (cloud-controller-manager) and workers   |
| `pki.tf`                | Cluster CAs, service account key and kubeadm bootstrap token      |
| `control-plane.tf`      | Control plane EC2 instances                                       |
| `workers.tf`            | Worker launch template and Auto Scaling Group                     |
| `cluster-autoscaler.tf` | Cluster Autoscaler IAM policy and manifest rendering              |
| `outputs.tf`            | Outputs                                                           |
| `templates/`            | Node bootstrap scripts and the Cluster Autoscaler manifest        |

## How it works

1. Terraform creates the cluster CAs and a bootstrap token that never expires,
   then passes them to the nodes in user data.
2. Control plane node 1 runs `kubeadm init`. It then installs Flannel, the AWS
   cloud-controller-manager (through Helm) and Cluster Autoscaler.
3. Control plane nodes 2 and 3 wait for node 1, then run `kubeadm join --control-plane`.
4. Workers start from the ASG launch template. Each one finds the API at
   `api.<cluster>.internal` (a private Route53 record) and runs `kubeadm join`.
5. Cluster Autoscaler runs on the control plane and finds the ASG through the
   `k8s.io/cluster-autoscaler/*` tags. When pods are `Pending` it raises the
   ASG's desired capacity, up to `worker_max_size`. It removes nodes that have
   been under-used for 5 minutes, down to `worker_min_size`. When an instance
   is terminated, the cloud-controller-manager deletes its Node object.

## Network layout

```
VPC 10.0.0.0/16
├── public  10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24   NAT gateway, internet-facing LBs
└── private 10.0.11.0/24, 10.0.12.0/24, 10.0.13.0/24 all Kubernetes nodes (no public IPs)
```

The control plane nodes sit one per AZ (`10.0.11.10`, `10.0.12.10`, `10.0.13.10`),
so losing a whole AZ still leaves etcd with quorum. Nodes have no public IPs.

- **kubectl** goes through an internet-facing NLB in the public subnets. Its
  security group only allows `admin_cidrs`, and it health-checks `/readyz` on
  every API server so traffic fails over if a control plane node goes down.
- **Nodes** use the internal name `api.<cluster>.internal`, so cluster traffic
  never goes through the NLB.
- **Shell access** to nodes is through SSM Session Manager.

## Deploy

Prerequisites: the AWS CLI and the
[Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).

```bash
cp terraform.tfvars.example terraform.tfvars   # set admin_cidrs to your home IP
terraform init
terraform apply
terraform output -raw get_kubeconfig   # commands to download a kubeconfig for the NLB
```

If your home IP changes, update `admin_cidrs` and run `terraform apply` again.
If the NLB is unavailable, you can still reach the API with an SSM
port-forward to a control plane node:

```bash
aws ssm start-session --target <instance-id> --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["6443"],"localPortNumber":["6443"]}'
kubectl --server=https://127.0.0.1:6443 --tls-server-name=api.<cluster>.internal get nodes
```

Bootstrapping takes about 5–10 minutes after `apply` finishes. To follow
progress, open a shell with `aws ssm start-session --target <instance-id>` and
run `sudo tail -f /var/log/k8s-bootstrap.log`.

## Monitoring

Every node runs the CloudWatch agent. The agent's config is stored in SSM
Parameter Store as `AmazonCloudWatch-<cluster>-*`, and each node pulls it at
boot. The agent publishes memory and root-disk usage to the `<cluster>/Nodes`
namespace. It also ships `/var/log/k8s-bootstrap.log` to the log group
`/k8s/<cluster>/bootstrap`, with one stream per instance ID. That log is the
first place to look when a node doesn't join.

Alarms notify the `<cluster>-alarms` SNS topic. Set `alarm_email` to get
emails, and confirm the subscription email AWS sends you.

| Alarm                                | Scope                     | Fires when                                         |
| ------------------------------------ | ------------------------- | -------------------------------------------------- |
| `control-plane-N-status-check`       | each control plane node   | EC2 status check fails for 2 minutes               |
| `control-plane-N-cpu/memory/disk-high` | each control plane node | over `cpu/memory/disk_alarm_threshold`             |
| `workers-cpu/memory/disk-high`       | worker ASG (aggregate)    | average CPU/memory, or the fullest disk, over threshold |
| `workers-below-minimum`              | worker ASG                | fewer than `worker_min_size` in service for 10 min |
| `workers-at-maximum`                 | worker ASG                | at `worker_max_size` for 30 min (no room to scale) |
| `api-servers-unhealthy`              | API NLB                   | any API server fails `/readyz` for 3 minutes       |

Workers come and go with Cluster Autoscaler, so their alarms use Auto Scaling
Group aggregates rather than instance IDs. An impaired worker is replaced by
the ASG health check. Expect `api-servers-unhealthy` and the status-check
alarms to fire briefly while the cluster first boots.

The `<cluster>` dashboard shows CPU, memory, disk, worker count, API server
health, CPU credit balance and status checks.

CloudWatch only sees the EC2 instances. For pod and container metrics, add
metrics-server (`kubectl top`) or Prometheus.

## Test autoscaling

```bash
kubectl create deployment scale-test --image=registry.k8s.io/pause:3.10 --replicas=12
kubectl set resources deployment scale-test --requests=cpu=500m
kubectl get nodes -w                                   # workers grow to 4
kubectl -n kube-system logs deploy/cluster-autoscaler -f
kubectl delete deployment scale-test                   # back to 2 after ~5-10 min
```

## Caveats

- **Free tier is not free here.** The legacy free tier gives 750
  instance-hours a month, which covers about one instance running all month.
  This cluster runs 5–7 instances. Under the newer credit-based free plan,
  the instances use up your credits. The NAT gateway is the biggest fixed
  cost: about $35 a month plus data processing charges, per gateway (three
  times that with `nat_gateway_per_az = true`). EBS beyond 30 GiB, the NAT
  gateway's public IP and the Route53 zone (about $0.50 a month) also cost money.
  The API NLB adds about $18–20 a month. CloudWatch adds about $5–8 a month:
  about 2–3 custom metrics per node, 18 alarms (the first 10 are free) and 1
  dashboard (the first 3 are free).
- **t3 CPU credits.** t3 instances default to "unlimited" mode. When a node's
  CPU credit balance (shown on the dashboard) reaches zero, sustained CPU above
  baseline is billed as extra charges.
  Run `terraform destroy` when you are not using the cluster.
- **Control plane HA.** With 3 control plane nodes, etcd keeps quorum (2 of 3)
  if one node fails, and workers fail over between API servers through the
  Route53 record. Keep `control_plane_count` odd; an even count adds cost
  without tolerating more failures.
- **Single NAT gateway.** By default one NAT gateway serves all three AZs. If
  its AZ goes down, nodes in the other AZs lose outbound internet: running
  pods keep working, but new image pulls and new nodes fail. Set
  `nat_gateway_per_az = true` to remove that dependency.
- **Secrets.** The CA private keys and the bootstrap token are stored in
  Terraform state and in EC2 user data. Keep the state file private. Do not
  commit `terraform.tfstate`; `.gitignore` already excludes it.
- **Pinned versions.** Keep `kubernetes_version`,
  `cluster_autoscaler_version` and `cloud_controller_manager_version` on the
  same minor version.
