#!/bin/bash
# Worker node (launched by the Auto Scaling Group): join the cluster
set -euxo pipefail
exec > >(tee -a /var/log/k8s-bootstrap.log) 2>&1

${cloudwatch_agent_script}

${install_script}

# Cluster CA certificate (public), used only to pin the discovery hash
cat >/root/cluster-ca.crt <<'PEM'
${ca_cert}
PEM

until curl -ksf "https://${api_dns}:6443/api/v1/namespaces/kube-public/configmaps/cluster-info" >/dev/null; do
  echo "Waiting for the Kubernetes API..."
  sleep 15
done

cat >/root/kubeadm-join.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "${api_dns}:6443"
    token: "${bootstrap_token}"
    caCertHashes: ["$(ca_cert_hash /root/cluster-ca.crt)"]
nodeRegistration:
  name: $NODE_NAME
  kubeletExtraArgs:
    - name: cloud-provider
      value: external
EOF

until kubeadm join --config /root/kubeadm-join.yaml; do
  echo "kubeadm join failed, retrying..."
  kubeadm reset -f
  sleep 30
done

echo "Worker join complete"
