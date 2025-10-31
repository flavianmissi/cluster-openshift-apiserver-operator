// Package kmsplugin provides helpers for injecting KMS plugin sidecar containers
// into Kubernetes API server pods.
//
// This package enables OpenShift operators to add KMS (Key Management Service) plugin
// sidecars to API server workloads (kube-apiserver, openshift-apiserver, oauth-apiserver)
// for encryption at rest using external KMS providers like AWS KMS.
//
// # Overview
//
// The package provides three main functions:
//   - Container(): Creates a KMS plugin container spec
//   - Volumes(): Creates the required volumes (socket and optionally credentials)
//   - AddKMSPluginToPodSpec(): Convenience function that injects everything into a PodSpec
//
// # Usage Example
//
// For a static pod (e.g., kube-apiserver with hostNetwork):
//
//	kmsConfig := &configv1.KMSConfig{
//		Type: configv1.AWSKMSProvider,
//		AWS: &configv1.AWSKMSConfig{
//			KeyARN: "arn:aws:kms:us-east-1:123456789012:key/...",
//			Region: "us-east-1",
//		},
//	}
//
//	containerConfig := &kmsplugin.ContainerConfig{
//		Image:          "registry.k8s.io/kms-plugin-aws:v1.0",
//		UseHostNetwork: true, // Static pods use hostNetwork for IMDS access
//	}
//
//	err := kmsplugin.AddKMSPluginToPodSpec(
//		podSpec,
//		kmsConfig,
//		containerConfig,
//		true, // useHostPathForSocket
//	)
//
// For a deployment (e.g., openshift-apiserver without hostNetwork):
//
//	kmsConfig := &configv1.KMSConfig{
//		Type: configv1.AWSKMSProvider,
//		AWS: &configv1.AWSKMSConfig{
//			KeyARN: "arn:aws:kms:us-west-2:987654321098:key/...",
//			Region: "us-west-2",
//		},
//	}
//
//	containerConfig := &kmsplugin.ContainerConfig{
//		Image:                 "registry.k8s.io/kms-plugin-aws:v1.0",
//		UseHostNetwork:        false,
//		CredentialsSecretName: "kms-credentials", // Created by Cloud Credential Operator
//	}
//
//	err := kmsplugin.AddKMSPluginToPodSpec(
//		&deployment.Spec.Template.Spec,
//		kmsConfig,
//		containerConfig,
//		false, // useHostPathForSocket - use emptyDir for deployments
//	)
//
// # Credential Management
//
// The package supports two credential patterns:
//
//  1. Host Network (UseHostNetwork: true):
//     - Pod uses hostNetwork: true
//     - KMS plugin accesses AWS credentials via EC2 Instance Metadata Service (IMDS)
//     - Suitable for static pods that inherit the master node's IAM role
//
//  2. Credentials Secret (UseHostNetwork: false):
//     - Pod uses regular CNI networking
//     - KMS plugin reads credentials from a mounted secret
//     - Secret should be created by Cloud Credential Operator (CCO) via CredentialsRequest
//     - Secret must contain a "credentials" key in AWS shared credentials file format
//
// # Integration with Cloud Credential Operator
//
// For deployments using credential secrets, operators should create a CredentialsRequest:
//
//	apiVersion: cloudcredential.openshift.io/v1
//	kind: CredentialsRequest
//	metadata:
//	  name: openshift-apiserver-kms
//	  namespace: openshift-cloud-credential-operator
//	spec:
//	  providerSpec:
//	    kind: AWSProviderSpec
//	    statementEntries:
//	    - effect: Allow
//	      action:
//	      - kms:Encrypt
//	      - kms:Decrypt
//	      - kms:DescribeKey
//	      - kms:GenerateDataKey
//	      resource: "arn:aws:kms:*:*:key/*"
//	  secretRef:
//	    name: kms-credentials
//	    namespace: openshift-apiserver
//
// CCO will create the secret, which can then be referenced in ContainerConfig.CredentialsSecretName.
//
// # Socket Communication
//
// The KMS plugin communicates with the API server via a Unix socket:
//   - Static pods: Use hostPath volume at /var/run/kmsplugin for socket sharing across pod restarts
//   - Deployments: Use emptyDir volume (socket lifecycle tied to pod lifecycle)
//   - Default socket path: /var/run/kmsplugin/socket.sock
//
// The socket is automatically mounted into the main API server container (kube-apiserver,
// openshift-apiserver, or oauth-apiserver) by AddKMSPluginToPodSpec().
package kms
