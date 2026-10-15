#!/bin/bash
# Additional control plane node: join the cluster created by the first node
set -euxo pipefail
exec > >(tee -a /var/log/k8s-bootstrap.log) 2>&1

${cloudwatch_agent_script}

${install_script}

${pki_script}

# Join through the first node, then switch to the local API server
echo "${init_node_ip} ${api_dns}" >>/etc/hosts

# cluster-info is published once kubeadm init has created the bootstrap token
until curl -ksf "https://${init_node_ip}:6443/api/v1/namespaces/kube-public/configmaps/cluster-info" >/dev/null; do
  echo "Waiting for the first control plane node..."
  sleep 15
done

cat >/root/kubeadm-join.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "${api_dns}:6443"
    token: "${bootstrap_token}"
    caCertHashes: ["$(ca_cert_hash /etc/kubernetes/pki/ca.crt)"]
nodeRegistration:
  name: $NODE_NAME
  kubeletExtraArgs:
    - name: cloud-provider
      value: external
controlPlane:
  localAPIEndpoint:
    advertiseAddress: $PRIVATE_IP
    bindPort: 6443
EOF

until kubeadm join --config /root/kubeadm-join.yaml; do
  echo "kubeadm join failed, retrying..."
  kubeadm reset -f
  sleep 30
done

sed -i "s/^${init_node_ip} ${api_dns}\$/127.0.0.1 ${api_dns}/" /etc/hosts

mkdir -p /root/.kube /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube

echo "Control plane join complete"
