#!/usr/bin/env bash
# aws/teardown.sh — Terminates all inteliLB EC2 instances across all regions.

set -euo pipefail

REGIONS=("us-east-1" "us-west-2" "eu-west-1")

for region in "${REGIONS[@]}"; do
  echo "Checking $region..."
  instance_ids=$(aws ec2 describe-instances \
    --region "$region" \
    --filters "Name=tag:Project,Values=inteliLB" \
              "Name=instance-state-name,Values=running,stopped,pending" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text)

  if [[ -z "$instance_ids" ]]; then
    echo "  No instances found in $region"
    continue
  fi

  echo "  Terminating: $instance_ids"
  aws ec2 terminate-instances \
    --region "$region" \
    --instance-ids $instance_ids \
    --query "TerminatingInstances[].{ID:InstanceId,State:CurrentState.Name}" \
    --output table
done

rm -f /tmp/inteliLB-aws-instances.txt
echo ""
echo "Done. Instances terminating (may take ~1 min to fully stop)."
