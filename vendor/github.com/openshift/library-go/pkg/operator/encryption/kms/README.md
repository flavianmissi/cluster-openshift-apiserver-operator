# KMS Plugin Sidecar Helper

This package provides shared code for injecting AWS KMS plugin sidecars into OpenShift API server pods.

## Overview

OpenShift has three API servers that can use KMS encryption:
1. **kube-apiserver** - Static pod with `hostNetwork: true`
2. **openshift-apiserver** - Deployment without `hostNetwork`
3. **oauth-apiserver** - Deployment without `hostNetwork`

Each requires different credential management strategies.

## Credential Setup for POC

### Prerequisites

- OpenShift cluster running on AWS
- Cluster admin access (`oc login` as admin)
- AWS CLI configured with permissions to manage IAM
- Cloud Credential Operator in Mint mode (check with: `oc get cloudcredential cluster -o jsonpath='{.spec.credentialsMode}'`)

### Quick Start

Run these scripts in order:

```bash
# 1. Create AWS credentials for deployment-based API servers
./apply-credentials-requests.sh

# 2. Configure master node IAM role for kube-apiserver
./master-node-iam-setup.sh
```

### Detailed Setup

#### Step 1: Deployment-Based API Servers (openshift-apiserver, oauth-apiserver)

These need CredentialsRequests because they don't have access to IMDS:

```bash
./apply-credentials-requests.sh
```

This script will:
- Apply CredentialsRequest for `openshift-apiserver`
- Apply CredentialsRequest for `oauth-apiserver`
- Wait for CCO to create secrets
- Verify secrets contain valid AWS credentials

The secrets will be created at:
- `openshift-apiserver/kms-credentials`
- `openshift-oauth-apiserver/kms-credentials`

#### Step 2: kube-apiserver IAM Role

kube-apiserver uses `hostNetwork: true`, so it accesses AWS via IMDS using the master node's IAM role:

```bash
./master-node-iam-setup.sh
```

This script will:
- Find your cluster's master node IAM role
- Add KMS permissions to that role
- Allow you to restrict to a specific KMS key ARN

**Note:** This is a one-time AWS infrastructure setup, not managed by CCO.

### Manual Steps (Alternative)

If you prefer to apply manually:

```bash
# Apply CredentialsRequests
oc apply -f openshift-apiserver-kms-credentials-request.yaml
oc apply -f oauth-apiserver-kms-credentials-request.yaml

# Wait for secrets
oc wait --for=jsonpath='{.data.credentials}' \
  secret/kms-credentials -n openshift-apiserver --timeout=2m
oc wait --for=jsonpath='{.data.credentials}' \
  secret/kms-credentials -n openshift-oauth-apiserver --timeout=2m

# Verify
oc get secret kms-credentials -n openshift-apiserver -o yaml
oc get secret kms-credentials -n openshift-oauth-apiserver -o yaml
```

## Using the Library

### Example: kube-apiserver (Static Pod with hostNetwork)

```go
import (
    configv1 "github.com/openshift/api/config/v1"
    "github.com/openshift/library-go/pkg/operator/encryption/kmsplugin"
)

kmsConfig := &configv1.KMSConfig{
    Type: configv1.AWSKMSProvider,
    AWS: &configv1.AWSKMSConfig{
        KeyARN: "arn:aws:kms:us-east-1:123456789012:key/...",
        Region: "us-east-1",
    },
}

containerConfig := &kmsplugin.ContainerConfig{
    Image:          "registry.k8s.io/kms-plugin-aws:v1.0",
    UseHostNetwork: true, // Uses IMDS for credentials
}

err := kmsplugin.AddKMSPluginToPodSpec(
    &pod.Spec,
    kmsConfig,
    containerConfig,
    true, // useHostPathForSocket (static pod requirement)
)
```

### Example: openshift-apiserver (Deployment without hostNetwork)

```go
kmsConfig := &configv1.KMSConfig{
    Type: configv1.AWSKMSProvider,
    AWS: &configv1.AWSKMSConfig{
        KeyARN: "arn:aws:kms:us-west-2:987654321098:key/...",
        Region: "us-west-2",
    },
}

containerConfig := &kmsplugin.ContainerConfig{
    Image:                 "registry.k8s.io/kms-plugin-aws:v1.0",
    UseHostNetwork:        false,
    CredentialsSecretName: "kms-credentials", // Created by CCO
}

err := kmsplugin.AddKMSPluginToPodSpec(
    &deployment.Spec.Template.Spec,
    kmsConfig,
    containerConfig,
    false, // useHostPathForSocket (emptyDir for deployments)
)
```

## Architecture

### Credential Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ kube-apiserver (Static Pod)                                     │
├─────────────────────────────────────────────────────────────────┤
│ hostNetwork: true → IMDS (169.254.169.254) → Master IAM Role   │
│ No CredentialsRequest needed                                    │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ openshift-apiserver / oauth-apiserver (Deployments)             │
├─────────────────────────────────────────────────────────────────┤
│ CredentialsRequest → CCO → Secret → Mounted in KMS container   │
│ AWS SDK reads /var/run/secrets/aws/credentials                 │
└─────────────────────────────────────────────────────────────────┘
```

### Socket Communication

All API servers communicate with their KMS plugin sidecar via Unix socket:
- **Path:** `/var/run/kmsplugin/socket.sock`
- **Static pods:** Uses `hostPath` volume
- **Deployments:** Uses `emptyDir` volume

## Troubleshooting

### CredentialsRequest not creating secrets

```bash
# Check CCO logs
oc logs -n openshift-cloud-credential-operator deployment/cloud-credential-operator -f

# Check CredentialsRequest status
oc get credentialsrequest -n openshift-cloud-credential-operator
oc describe credentialsrequest openshift-apiserver-kms -n openshift-cloud-credential-operator
```

### Verify CCO mode

```bash
oc get cloudcredential cluster -o yaml
```

Expected: `credentialsMode: ""` or `credentialsMode: "Mint"`

### Check secret contents

```bash
# Decode and view credentials
oc get secret kms-credentials -n openshift-apiserver \
  -o jsonpath='{.data.credentials}' | base64 -d
```

Should show AWS credentials file format:
```ini
[default]
aws_access_key_id = AKIA...
aws_secret_access_key = ...
```

### Verify master node IAM role

```bash
# Get master instance profile
CLUSTER_ID="your-cluster-id"
aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_ID,Values=owned" \
            "Name=tag:Name,Values=*master*" \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn'

# Check role policy
aws iam get-role-policy \
  --role-name <role-name> \
  --policy-name OpenShiftKMSEncryption
```

## Production Considerations

### Restrict KMS Key ARN

In production, update CredentialsRequests to use specific KMS key ARN:

```yaml
spec:
  providerSpec:
    statementEntries:
    - action: [...]
      resource: "arn:aws:kms:us-east-1:123456789012:key/your-specific-key-id"
```

### Migrate to STS Mode

For better security, migrate from CCO Mint mode to STS mode:
- Uses temporary credentials via IRSA
- No long-lived IAM users
- Automatic credential rotation

See: [Cloud Credential Operator documentation](https://docs.openshift.com/container-platform/latest/authentication/managing_cloud_provider_credentials/about-cloud-credential-operator.html)

## Files

- `container.go` - Main library code for creating KMS plugin containers
- `container_test.go` - Unit tests
- `doc.go` - Package documentation
- `openshift-apiserver-kms-credentials-request.yaml` - CredentialsRequest for openshift-apiserver
- `oauth-apiserver-kms-credentials-request.yaml` - CredentialsRequest for oauth-apiserver
- `apply-credentials-requests.sh` - Helper script to apply CredentialsRequests
- `master-node-iam-setup.sh` - Helper script to configure master node IAM role

## Next Steps

After credential setup is complete:
1. Implement sidecar injection in each operator
2. Add detection logic for when KMS encryption is enabled
3. Configure API server encryption config to use KMS provider
4. Test encryption/decryption functionality
