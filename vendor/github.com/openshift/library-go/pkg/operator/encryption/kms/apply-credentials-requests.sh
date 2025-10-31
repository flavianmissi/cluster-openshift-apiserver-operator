#!/bin/bash
# Helper script to apply CredentialsRequests and verify secret creation
# Run this script to set up AWS credentials for KMS plugin sidecars

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "KMS Plugin CredentialsRequest Setup"
echo "=========================================="
echo ""

# Check if oc is available
if ! command -v oc &> /dev/null; then
    echo "Error: 'oc' command not found. Please install the OpenShift CLI."
    exit 1
fi

# Check cluster connectivity
if ! oc whoami &> /dev/null; then
    echo "Error: Not logged into an OpenShift cluster."
    echo "Please run 'oc login' first."
    exit 1
fi

echo "Current cluster:"
oc cluster-info | head -1
echo ""

# Check CCO mode
echo "Checking Cloud Credential Operator mode..."
CCO_MODE=$(oc get cloudcredential cluster -o jsonpath='{.spec.credentialsMode}' 2>/dev/null || echo "")
if [ -z "$CCO_MODE" ]; then
    CCO_MODE="Mint (default)"
fi
echo "CCO Mode: $CCO_MODE"
echo ""

if [[ "$CCO_MODE" == "Manual" ]]; then
    echo "WARNING: Cluster is in Manual CCO mode."
    echo "You will need to manually create IAM users and secrets."
    echo "These CredentialsRequests will not automatically provision credentials."
    echo ""
    read -p "Do you want to continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "=========================================="
echo "Step 1: Apply openshift-apiserver CredentialsRequest"
echo "=========================================="
oc apply -f "$SCRIPT_DIR/openshift-apiserver-kms-credentials-request.yaml"
echo "✓ Applied"
echo ""

echo "=========================================="
echo "Step 2: Apply oauth-apiserver CredentialsRequest"
echo "=========================================="
oc apply -f "$SCRIPT_DIR/oauth-apiserver-kms-credentials-request.yaml"
echo "✓ Applied"
echo ""

echo "=========================================="
echo "Step 3: Wait for CCO to provision secrets"
echo "=========================================="
echo "This may take 1-2 minutes..."
echo ""

# Wait for openshift-apiserver secret
echo -n "Waiting for openshift-apiserver secret..."
timeout=120
elapsed=0
while ! oc get secret kms-credentials -n openshift-apiserver &> /dev/null; do
    if [ $elapsed -ge $timeout ]; then
        echo " TIMEOUT"
        echo "Error: Secret not created after ${timeout}s"
        echo "Check CCO logs: oc logs -n openshift-cloud-credential-operator deployment/cloud-credential-operator"
        exit 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    echo -n "."
done
echo " ✓"

# Wait for oauth-apiserver secret
echo -n "Waiting for oauth-apiserver secret..."
elapsed=0
while ! oc get secret kms-credentials -n openshift-oauth-apiserver &> /dev/null; do
    if [ $elapsed -ge $timeout ]; then
        echo " TIMEOUT"
        echo "Error: Secret not created after ${timeout}s"
        echo "Check CCO logs: oc logs -n openshift-cloud-credential-operator deployment/cloud-credential-operator"
        exit 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    echo -n "."
done
echo " ✓"
echo ""

echo "=========================================="
echo "Step 4: Verify secrets"
echo "=========================================="
echo ""

echo "openshift-apiserver secret:"
oc get secret kms-credentials -n openshift-apiserver -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null && echo " (created)" || echo " NOT FOUND"
if oc get secret kms-credentials -n openshift-apiserver -o jsonpath='{.data.credentials}' 2>/dev/null | base64 -d | grep -q "aws_access_key_id"; then
    echo "  ✓ Contains AWS credentials"
else
    echo "  ✗ Does not contain valid AWS credentials"
fi
echo ""

echo "oauth-apiserver secret:"
oc get secret kms-credentials -n openshift-oauth-apiserver -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null && echo " (created)" || echo " NOT FOUND"
if oc get secret kms-credentials -n openshift-oauth-apiserver -o jsonpath='{.data.credentials}' 2>/dev/null | base64 -d | grep -q "aws_access_key_id"; then
    echo "  ✓ Contains AWS credentials"
else
    echo "  ✗ Does not contain valid AWS credentials"
fi
echo ""

echo "=========================================="
echo "✓ Setup Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Configure master node IAM role for kube-apiserver (see master-node-iam-setup.sh)"
echo "2. Restrict KMS key ARN in CredentialsRequests (currently set to '*')"
echo "3. Proceed with KMS plugin sidecar injection"
echo ""
echo "To view created secrets:"
echo "  oc get secret kms-credentials -n openshift-apiserver -o yaml"
echo "  oc get secret kms-credentials -n openshift-oauth-apiserver -o yaml"
echo ""
echo "To view CCO logs:"
echo "  oc logs -n openshift-cloud-credential-operator deployment/cloud-credential-operator -f"
