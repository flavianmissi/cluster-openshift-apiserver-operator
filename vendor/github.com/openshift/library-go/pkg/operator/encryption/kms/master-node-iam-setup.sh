#!/bin/bash
# Helper script to add KMS permissions to control plane node IAM role
# This is needed for kube-apiserver KMS plugin (uses hostNetwork + IMDS)

set -e

echo "=========================================="
echo "Control plane Node IAM Role - KMS Setup"
echo "=========================================="
echo ""
echo "This script adds KMS permissions to the control plane node IAM role"
echo "so that kube-apiserver KMS plugin can access AWS KMS via IMDS."
echo ""

# Check if aws CLI is available
if ! command -v aws &> /dev/null; then
    echo "Error: 'aws' command not found. Please install the AWS CLI."
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo "Error: AWS credentials not configured or invalid."
    echo "Please run 'aws configure' or set AWS environment variables."
    exit 1
fi

echo "Current AWS identity:"
aws sts get-caller-identity
echo ""

# Get cluster ID
CLUSTER_ID=$(oc get infrastructure/cluster -ojsonpath='{.status.infrastructureName}')
# read -p "Enter your OpenShift cluster ID (infrastructure name): " CLUSTER_ID
if [ -z "$CLUSTER_ID" ]; then
    echo "Error: Cluster ID is required"
    exit 1
fi

echo ""
echo "Looking for control plane nodes with tag kubernetes.io/cluster/$CLUSTER_ID..."
echo ""

# Find control plane node instance profile
INSTANCE_PROFILE_ARN=$(aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_ID,Values=owned" \
            "Name=tag:Name,Values=*master*" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
  --output text 2>/dev/null)

if [ "$INSTANCE_PROFILE_ARN" == "None" ] || [ -z "$INSTANCE_PROFILE_ARN" ]; then
    echo "Error: Could not find control plane node instance profile."
    echo "Please verify:"
    echo "  1. Cluster ID is correct"
    echo "  2. Control plane nodes are running"
    echo "  3. AWS credentials have ec2:DescribeInstances permission"
    exit 1
fi

INSTANCE_PROFILE_NAME=$(echo "$INSTANCE_PROFILE_ARN" | awk -F/ '{print $NF}')
echo "Found instance profile: $INSTANCE_PROFILE_NAME"

# Get the role name from the instance profile
ROLE_NAME=$(aws iam get-instance-profile \
  --instance-profile-name "$INSTANCE_PROFILE_NAME" \
  --query 'InstanceProfile.Roles[0].RoleName' \
  --output text)

echo "Found IAM role: $ROLE_NAME"
echo ""

# Ask for KMS key ARN (optional)
echo "KMS Key Configuration:"
echo "  Option 1: Use '*' to allow access to all KMS keys (for testing)"
echo "  Option 2: Specify exact KMS key ARN (recommended for production)"
echo ""
read -p "Enter KMS key ARN (or press Enter to use '*'): " KMS_KEY_ARN

if [ -z "$KMS_KEY_ARN" ]; then
    KMS_KEY_ARN="*"
    echo "Using '*' (all KMS keys)"
else
    echo "Using specific key: $KMS_KEY_ARN"
fi
echo ""

# Create policy document
POLICY_NAME="OpenShiftKMSEncryption"
POLICY_FILE="/tmp/kms-policy-$$.json"

cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKey"
      ],
      "Resource": "$KMS_KEY_ARN"
    }
  ]
}
EOF

echo "Policy document created:"
cat "$POLICY_FILE"
echo ""

# Confirm before applying
read -p "Apply this policy to role $ROLE_NAME? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    rm "$POLICY_FILE"
    exit 0
fi

# Apply the policy
echo ""
echo "Applying policy to IAM role..."
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "file://$POLICY_FILE"

echo "✓ Policy applied successfully"
echo ""

# Verify
echo "Verifying policy..."
if aws iam get-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" &> /dev/null; then
    echo "✓ Policy verified"
else
    echo "✗ Policy verification failed"
    rm "$POLICY_FILE"
    exit 1
fi

# Cleanup
rm "$POLICY_FILE"
echo ""

echo "=========================================="
echo "✓ Setup Complete!"
echo "=========================================="
echo ""
echo "IAM Role: $ROLE_NAME"
echo "Policy: $POLICY_NAME"
echo "KMS Resource: $KMS_KEY_ARN"
echo ""
echo "The kube-apiserver KMS plugin will now be able to:"
echo "  - Access AWS KMS via IMDS (169.254.169.254)"
echo "  - Use control plane node IAM role credentials"
echo "  - Encrypt/decrypt with KMS key"
echo ""
echo "To view the policy:"
echo "  aws iam get-role-policy --role-name $ROLE_NAME --policy-name $POLICY_NAME"
echo ""
echo "To remove the policy (if needed):"
echo "  aws iam delete-role-policy --role-name $ROLE_NAME --policy-name $POLICY_NAME"
