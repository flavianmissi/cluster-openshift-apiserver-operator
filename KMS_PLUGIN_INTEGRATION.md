# KMS Plugin Integration for openshift-apiserver-operator

This document describes the KMS plugin sidecar integration into the openshift-apiserver operator.

## ✅ Completed Integration

### Files Modified

1. **`pkg/operator/workload/workload_openshiftapiserver_v311_00_sync.go`**
   - Added `apiserverLister` field to `OpenShiftAPIServerWorkload` struct
   - Added `secretLister` field to track KMS credentials secret
   - Added `kmsPluginImage` field for the plugin container image
   - Updated `NewOpenShiftAPIServerWorkload()` to accept new parameters
   - Updated `manageOpenShiftAPIServerDeployment_v311_00_to_latest()` to inject KMS plugin
   - Added `corev1listers` import for secret lister

2. **`pkg/operator/starter.go`**
   - Updated call to `NewOpenShiftAPIServerWorkload()` with new parameters:
     - `configInformers.Config().V1().APIServers().Lister()` for APIServer lister
     - `kubeInformersForNamespaces.InformersFor(operatorclient.TargetNamespace).Core().V1().Secrets().Lister()` for secret lister
     - `os.Getenv("KMS_PLUGIN_IMAGE")` for the plugin image

### Files Created

3. **`pkg/operator/workload/kms_plugin.go`**
   - `getKMSEncryptionConfig()` - Reads APIServer config to check if KMS is enabled
   - `checkCredentialsSecret()` - Verifies CCO-created credentials secret exists
   - `injectKMSPlugin()` - Main integration function that injects the KMS sidecar

### Build Configuration

4. **`go.mod`**
   - Added replace directive: `replace github.com/openshift/library-go => ../library-go`
   - This allows using the local library-go with the new kmsplugin package

## How It Works

### 1. Configuration Detection

The operator reads the cluster-scoped APIServer config (`config.openshift.io/v1`):

```yaml
apiVersion: config.openshift.io/v1
kind: APIServer
metadata:
  name: cluster
spec:
  encryption:
    type: KMS
    kms:
      type: AWS
      aws:
        keyARN: arn:aws:kms:us-east-1:123456789012:key/...
        region: us-east-1
```

If `spec.encryption.type == "KMS"`, the operator injects the KMS plugin sidecar.

### 2. Sidecar Injection Flow

```
OpenShiftAPIServerWorkload.Sync()
  ↓
manageOpenShiftAPIServerDeployment_v311_00_to_latest()
  ↓
injectKMSPlugin()  ← New function
  ↓
checkCredentialsSecret()  ← Verify CCO secret exists
  ↓
kmsplugin.AddKMSPluginToPodSpec()  ← From library-go
  ↓
Deployment spec updated with:
  - KMS plugin container
  - Socket volume (emptyDir)
  - Credentials volume (secret)
  - Socket mount in openshift-apiserver container
```

### 3. Credential Management

**openshift-apiserver uses `hostNetwork: false`** (it's a regular Deployment), so:
- KMS plugin **cannot** access AWS via EC2 Instance Metadata Service (IMDS)
- Requires AWS credentials from a Secret created by Cloud Credential Operator (CCO)
- **CredentialsRequest required** - see `library-go/pkg/operator/encryption/kmsplugin/openshift-apiserver-kms-credentials-request.yaml`

Prerequisites:
- Apply the CredentialsRequest to the cluster
- Wait for CCO to create `kms-credentials` secret in `openshift-apiserver` namespace
- Secret must contain AWS credentials with KMS permissions

### 4. Graceful Degradation

If KMS encryption is enabled but the credentials secret doesn't exist yet:
- `checkCredentialsSecret()` returns `false, nil` (not an error)
- `injectKMSPlugin()` logs a warning and returns `nil`
- Deployment is created **without** the KMS sidecar
- When CCO creates the secret, the informer triggers reconciliation
- Next sync will successfully inject the KMS sidecar

This prevents the operator from blocking on credentials while allowing automatic retry.

### 5. Controller Reactivity

The operator watches:
- APIServer resource (encryption config changes)
- Secrets in `openshift-apiserver` namespace (credentials secret creation)
- KMS plugin image changes (via `KMS_PLUGIN_IMAGE` env var)

Any of these trigger automatic reconciliation and sidecar injection/update.

## Testing the Integration

### 1. Apply CredentialsRequest

```bash
# make sure you have checked out the kms-plugin-sidecars from github.com/flavianmissi/library-go
oc apply -f $(go env GOPATH)/src/github.com/openshift/library-go/pkg/operator/encryption/kms/openshift-apiserver-kms-credentials-request.yaml
```

Verify CCO created the secret:
```bash
oc get secret kms-credentials -n openshift-apiserver
```

### 2. Set Environment Variable

Edit the openshift-apiserver-operator deployment:

```bash
oc edit deployment openshift-apiserver-operator -n openshift-apiserver-operator
```

Add to the operator container env:
```yaml
env:
- name: KMS_PLUGIN_IMAGE
  value: "quay.io/fmissi/aws-kms-plugin:0.1.0"
```

### 3. Enable KMS Encryption

Create/update the APIServer config:

```bash
key_arn='arn:aws:kms:us-east-2:123456:key/123456-123456-123-123-12345678'
key_region='us-east-2'
oc patch apiserver cluster --type=merge --patch="
spec:
  encryption:
    type: KMS
    kms:
      type: AWS
      aws:
        keyARN: ${key_arn}
        region: ${key_region}
"

# verify
oc get apiserver/cluster -ojsonpath="{.spec.encryption}"
```

### 4. Verify Injection

Check the openshift-apiserver deployment:

```bash
oc get deployment openshift-apiserver -n openshift-apiserver -o yaml
```

Look for:
- `kms-plugin` container in the pod spec
- `kms-plugin-socket` volume (emptyDir)
- `kms-credentials` volume (secret)
- Volume mounts in both containers

Check logs:
```bash
# openshift-apiserver container
oc logs -n openshift-apiserver deployment/openshift-apiserver -c openshift-apiserver

# KMS plugin container
oc logs -n openshift-apiserver deployment/openshift-apiserver -c kms-plugin
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ openshift-apiserver Pod (hostNetwork: false)                │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────────┐       ┌──────────────────┐       │
│  │ openshift-apiserver  │ ◄───► │   kms-plugin     │       │
│  │                      │ Unix  │                  │       │
│  │                      │Socket │                  │       │
│  └──────────────────────┘       └──────────────────┘       │
│                                          │                  │
│                                          │ AWS SDK          │
│                                          ▼                  │
│                                  [credentials secret]       │
│                                  (from CCO)                 │
│                                          │                  │
└──────────────────────────────────────────┼──────────────────┘
                                           │
                                           ▼
                                       AWS KMS
```

**Key Differences from kube-apiserver:**
- Uses Deployment (not static pod)
- hostNetwork: false (cannot access IMDS)
- Requires credentials secret from CCO
- Uses emptyDir for socket (not hostPath)
- Socket path: `/var/run/kmsplugin/socket.sock`

## Key Implementation Details

### Credential Secret Check

```go
func checkCredentialsSecret(secretLister corev1listers.SecretLister, namespace string) (bool, error) {
    secret, err := secretLister.Secrets(namespace).Get(KMSCredentialsSecretName)
    if err != nil {
        if apierrors.IsNotFound(err) {
            // Not an error - just not ready yet
            return false, nil
        }
        return false, fmt.Errorf("failed to get secret: %w", err)
    }

    // Verify secret has data
    if secret.Data == nil || len(secret.Data["credentials"]) == 0 {
        return false, fmt.Errorf("secret exists but is empty")
    }

    return true, nil
}
```

### Container Configuration

```go
containerConfig := &kmsplugin.ContainerConfig{
    Image:                 kmsPluginImage,
    UseHostNetwork:        false,  // Deployment without hostNetwork
    CredentialsSecretName: KMSCredentialsSecretName,
}

err := kmsplugin.AddKMSPluginToPodSpec(
    podSpec,
    kmsConfig,
    containerConfig,
    false,  // false = use emptyDir (not hostPath)
)
```

## Production Considerations

### Image Management

Currently using `KMS_PLUGIN_IMAGE` env var. For production:
- Include KMS plugin image in operator's release payload
- Reference it like `OPERATOR_IMAGE` is referenced

### CCO Mode

The CredentialsRequest assumes CCO is in **Mint mode** (creates IAM users).

For production clusters using **STS mode** (temporary credentials):
- Update CredentialsRequest with proper STS role ARN
- See: https://docs.openshift.com/container-platform/latest/authentication/managing_cloud_provider_credentials/cco-mode-sts.html

### Error Handling

The current implementation will:
- Log warnings if credentials secret is missing
- Allow deployment creation without KMS sidecar
- Automatically inject sidecar when secret becomes available
- Fail deployment if injection fails (prevents misconfigured KMS)

### Monitoring

Add metrics/alerts for:
- KMS plugin health
- Encryption/decryption success/failure rates
- AWS KMS API call latency
- Credentials secret existence

## Related Documentation

- Shared library: `/path/to/library-go/pkg/operator/encryption/kmsplugin/README.md`
- CredentialsRequest: `/path/to/library-go/pkg/operator/encryption/kmsplugin/openshift-apiserver-kms-credentials-request.yaml`
- OpenShift API types: `github.com/openshift/api/config/v1/types_kmsencryption.go`
- CCO documentation: https://docs.openshift.com/container-platform/latest/authentication/managing_cloud_provider_credentials/about-cloud-credential-operator.html
