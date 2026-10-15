#!/bin/bash
# First control plane node: kubeadm init + cluster add-ons
set -euxo pipefail
exec > >(tee -a /var/log/k8s-bootstrap.log) 2>&1

${cloudwatch_agent_script}

${install_script}

${pki_script}

# Control plane nodes always talk to their local API server
echo "127.0.0.1 ${api_dns}" >>/etc/hosts

cat >/root/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
bootstrapTokens:
  - token: "${bootstrap_token}"
    ttl: "0s"
    usages: [signing, authentication]
    groups: [system:bootstrappers:kubeadm:default-node-token]
localAPIEndpoint:
  advertiseAddress: $PRIVATE_IP
  bindPort: 6443
nodeRegistration:
  name: $NODE_NAME
  kubeletExtraArgs:
    - name: cloud-provider
      value: external
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: ${cluster_name}
kubernetesVersion: $(kubeadm version -o short)
controlPlaneEndpoint: "${api_dns}:6443"
networking:
  podSubnet: ${pod_cidr}
  serviceSubnet: ${service_cidr}
apiServer:
  certSANs:
    - ${api_dns}
    - ${api_public_dns}
    - $PRIVATE_IP
EOF

kubeadm init --config /root/kubeadm-config.yaml

export KUBECONFIG=/etc/kubernetes/admin.conf
mkdir -p /root/.kube /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube

# Admin kubeconfig for use from a workstation through the public API NLB
cp /etc/kubernetes/admin.conf /home/ubuntu/kubeconfig-remote
kubectl --kubeconfig /home/ubuntu/kubeconfig-remote config set-cluster ${cluster_name} \
  --server=https://${api_public_dns}:6443
chown ubuntu:ubuntu /home/ubuntu/kubeconfig-remote
chmod 600 /home/ubuntu/kubeconfig-remote

# ---------- CNI: Flannel ----------
kubectl apply -f https://github.com/flannel-io/flannel/releases/download/${flannel_version}/kube-flannel.yml

# ---------- AWS cloud-controller-manager ----------
# Initialises nodes (providerID, zone labels), removes the node object when
# Cluster Autoscaler terminates an instance, and provides LoadBalancer Services.
curl -fsSL https://get.helm.sh/helm-${helm_version}-linux-amd64.tar.gz | tar -xz -C /tmp
install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
helm repo add aws-cloud-controller-manager https://kubernetes.github.io/cloud-provider-aws
helm repo update
helm upgrade --install aws-cloud-controller-manager aws-cloud-controller-manager/aws-cloud-controller-manager \
  --namespace kube-system \
  --set image.tag=${ccm_version}

# ---------- Cluster Autoscaler ----------
cat >/root/cluster-autoscaler.yaml <<'YAML'
${cluster_autoscaler_manifest}
YAML
kubectl apply -f /root/cluster-autoscaler.yaml

echo "Control plane bootstrap complete"
