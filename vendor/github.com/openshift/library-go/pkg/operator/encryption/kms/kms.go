// the functions in this file are borrowed from https://github.com/openshift/library-go/pull/2041/
package kms

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"

	configv1 "github.com/openshift/api/config/v1"
)

const (
	// unixSocketBaseDir is the base directory for KMS unix sockets
	unixSocketBaseDir = "unix:///var/run/kms"
)

// GenerateUnixSocketPath generates a unique unix socket path from KMS configuration
// by hashing the provider-specific configuration.
// Returns the socket path and the hash value (first 16 characters).
func GenerateUnixSocketPath(kmsConfig *configv1.KMSConfig) (string, string, error) {
	if kmsConfig == nil {
		return "", "", fmt.Errorf("kmsConfig cannot be nil")
	}

	// Determine KMS type and generate path accordingly
	switch kmsConfig.Type {
	case configv1.AWSKMSProvider:
		if kmsConfig.AWS == nil {
			return "", "", fmt.Errorf("AWS KMS config cannot be nil for AWS provider type")
		}
		return generateAWSUnixSocketPath(kmsConfig.AWS)
	default:
		return "", "", fmt.Errorf("unsupported KMS provider type: %s", kmsConfig.Type)
	}
}

// generateAWSUnixSocketPath generates a unique unix socket path from AWS KMS configuration
// by hashing the ARN and region. Returns the socket path and the hash (first 16 characters).
func generateAWSUnixSocketPath(awsConfig *configv1.AWSKMSConfig) (string, string, error) {
	if awsConfig.KeyARN == "" {
		return "", "", fmt.Errorf("AWS KMS KeyARN cannot be empty")
	}

	if awsConfig.Region == "" {
		return "", "", fmt.Errorf("AWS region cannot be empty")
	}

	// Combine KeyARN and region for hashing
	combined := awsConfig.KeyARN + ":" + awsConfig.Region

	// Compute SHA256 hash
	hash := sha256.Sum256([]byte(combined))
	hashStr := hex.EncodeToString(hash[:])

	// Take first 16 characters of hash for shorter path
	shortHash := hashStr[:16]

	socketPath := fmt.Sprintf("%s/kms-%s.sock", unixSocketBaseDir, shortHash)

	return socketPath, shortHash, nil
}
