#!/usr/bin/env bash
# aws/launch.sh — Launches EC2 instances in 3 regions for inteliLB backends.
#
# CPU layout:
#   us-east-1   backend-1   t3.medium   → Docker --cpus=1
#   us-west-2   backend-2   t3.medium   → Docker --cpus=2
#   eu-west-1   backend-3   t3.xlarge   → Docker --cpus=4
#
# Expects KEY_NAME and KEY_FILE to be set by deploy.sh.

set -euo pipefail

KEY_NAME="${KEY_NAME:-inteliLB-key}"
KEY_FILE="${KEY_FILE:-$HOME/.ssh/${KEY_NAME}.pem}"
SG_NAME="inteliLB-backend-sg"
STATE_FILE="/tmp/inteliLB-aws-instances.txt"
DIR="$(cd "$(dirname "$0")" && pwd)"

# region  id  instance_type  docker_cpus
declare -a BACKENDS=(
  "us-east-1   backend-1   t3.medium   1"
  "us-west-2   backend-2   t3.medium   2"
  "eu-west-1   backend-3   t3.xlarge   4"
)

get_latest_ami() {
  local region="$1"
  aws ec2 describe-images \
    --region "$region" \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-kernel-*-x86_64" \
              "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text
}

ensure_sg() {
  local region="$1"
  local sg_id
  sg_id=$(aws ec2 describe-security-groups \
    --region "$region" \
    --filters "Name=group-name,Values=$SG_NAME" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || true)

  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    sg_id=$(aws ec2 create-security-group \
      --region "$region" \
      --group-name "$SG_NAME" \
      --description "inteliLB backend security group" \
      --query "GroupId" --output text)
    echo "  Created security group $sg_id in $region"
    aws ec2 authorize-security-group-ingress --region "$region" \
      --group-id "$sg_id" --protocol tcp --port 22 --cidr 0.0.0.0/0
    aws ec2 authorize-security-group-ingress --region "$region" \
      --group-id "$sg_id" --protocol tcp --port 8080 --cidr 0.0.0.0/0
  else
    echo "  Reusing security group $sg_id in $region"
  fi
  echo "$sg_id"
}

launch_instance() {
  local region="$1" id="$2" instance_type="$3" docker_cpus="$4"

  echo "━━━ [$region] Launching $id ($instance_type, ${docker_cpus} docker CPU(s)) ━━━"

  local ami sg_id instance_id public_ip
  ami=$(get_latest_ami "$region")
  echo "  AMI: $ami"

  sg_id=$(ensure_sg "$region")

  local user_data
  user_data=$(cat <<'EOF'
#!/bin/bash
dnf update -y
dnf install -y docker
systemctl enable docker
systemctl start docker
mkdir -p /opt/inteliLB
EOF
)

  instance_id=$(aws ec2 run-instances \
    --region "$region" \
    --image-id "$ami" \
    --instance-type "$instance_type" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$sg_id" \
    --user-data "$user_data" \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=$id},{Key=Project,Value=inteliLB}]" \
    --query "Instances[0].InstanceId" \
    --output text)

  echo "  Instance $instance_id — waiting for running state..."
  aws ec2 wait instance-running --region "$region" --instance-ids "$instance_id"

  public_ip=$(aws ec2 describe-instances \
    --region "$region" \
    --instance-ids "$instance_id" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)

  echo "  $id UP at $public_ip"
  echo "$public_ip $id $region $docker_cpus" >> "$STATE_FILE"
}

# ── Main ──────────────────────────────────────────────────────────────────────

rm -f "$STATE_FILE"

for entry in "${BACKENDS[@]}"; do
  read -r region id instance_type docker_cpus <<< "$entry"
  launch_instance "$region" "$id" "$instance_type" "$docker_cpus"
done

echo ""
echo "━━━ Waiting 40s for SSH + Docker to become available... ━━━"
sleep 40

while IFS=' ' read -r ip id region docker_cpus; do
  echo "Deploying $id on $ip ($region)..."
  PUBLIC_IP="$ip" SSH_USER="ec2-user" REGION="$region" ID="$id" DOCKER_CPUS="$docker_cpus" \
    bash "$DIR/../deploy-backend.sh"
done < "$STATE_FILE"

# ── Print LB run command ───────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "All AWS backends deployed. Run the load balancer locally:"
echo ""

BACKEND_URLS=""
while IFS=' ' read -r ip id region docker_cpus; do
  BACKEND_URLS+="http://$ip:8080,"
done < "$STATE_FILE"
BACKEND_URLS="${BACKEND_URLS%,}"

echo "  go run ./cmd/loadbalancer \\"
echo "    -port=8080 \\"
echo "    -algorithm=intelligent \\"
echo "    -backends=\"$BACKEND_URLS\""
echo ""
echo "CPU layout:"
while IFS=' ' read -r ip id region docker_cpus; do
  printf "  %-12s  %-10s  %s core(s)  http://%s:8080\n" "$region" "$id" "$docker_cpus" "$ip"
done < "$STATE_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
