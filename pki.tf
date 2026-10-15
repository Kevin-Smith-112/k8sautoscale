# ========== CLUSTER PKI & BOOTSTRAP TOKEN ==========
# Generating the shared CAs here (instead of letting kubeadm do it) means the
# second control plane node and every autoscaled worker can join unattended:
# no copying certs between nodes and no expiring --certificate-key.
#
# NOTE: these private keys live in Terraform state and in instance user data.
# Keep the state file private.

locals {
  cluster_cas = {
    "ca"             = "kubernetes"
    "front-proxy-ca" = "front-proxy-ca"
    "etcd/ca"        = "etcd-ca"
  }
}

resource "tls_private_key" "ca" {
  for_each = local.cluster_cas

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "ca" {
  for_each = local.cluster_cas

  private_key_pem       = tls_private_key.ca[each.key].private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 87600 # 10 years, same as kubeadm

  subject {
    common_name = each.value
  }

  allowed_uses = ["cert_signing", "key_encipherment", "digital_signature"]
}

# Service account token signing key pair
resource "tls_private_key" "sa" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# kubeadm bootstrap token: [a-z0-9]{6}.[a-z0-9]{16}. Created with no expiry so
# that workers launched later by Cluster Autoscaler can still join.
resource "random_string" "token_id" {
  length  = 6
  upper   = false
  special = false
}

resource "random_string" "token_secret" {
  length  = 16
  upper   = false
  special = false
}

locals {
  bootstrap_token = "${random_string.token_id.result}.${random_string.token_secret.result}"

  pki_script = templatefile("${path.module}/templates/pki.sh.tpl", {
    certs  = { for k, _ in local.cluster_cas : k => tls_self_signed_cert.ca[k].cert_pem }
    keys   = { for k, _ in local.cluster_cas : k => tls_private_key.ca[k].private_key_pem }
    sa_key = tls_private_key.sa.private_key_pem
    sa_pub = tls_private_key.sa.public_key_pem
  })
}
