# ---------- CloudWatch agent (memory/disk metrics + bootstrap log) ----------
# Installed first so the bootstrap log reaches CloudWatch even if the rest of
# the bootstrap fails. A monitoring failure never blocks the node from joining.
curl -fsSL -o /tmp/amazon-cloudwatch-agent.deb \
  https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb \
  && dpkg -i -E /tmp/amazon-cloudwatch-agent.deb \
  && /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config -m ec2 -s -c ssm:${ssm_parameter} \
  || echo "WARNING: CloudWatch agent setup failed; continuing bootstrap"
