// Package test contains Terratest coverage for the Aequor EKS platform module.
//
// Two modes, selected by the RUN_EKS_APPLY env var:
//
//   - default (unset/false): init + validate + plan only. Proves the module and
//     its community-module dependencies wire up and a plan can be produced.
//     Still needs AWS creds because the AWS provider + data sources initialize
//     during plan; CI supplies them via OIDC assume-role (see ci-terratest.yml).
//
//   - RUN_EKS_APPLY=true: full apply -> assert outputs -> destroy. Creates real
//     billable infrastructure, so it's opt-in only.
//
// This file is authored to compile and run against real AWS; it is NOT expected
// to pass in an offline sandbox (module downloads + AWS API calls both need
// network + credentials).
package test

import (
	"os"
	"testing"

	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func eksOptions(t *testing.T) *terraform.Options {
	// Unique-ish cluster name so parallel/leftover runs don't collide.
	name := "aequor-tt-" + random.UniqueId()

	return terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: "../../terraform/modules/eks",
		Vars: map[string]interface{}{
			"cluster_name":    name,
			"cluster_version": "1.31",
			"region":          "us-east-1",
			"vpc_cidr":        "10.90.0.0/16",
			"azs":             []string{"us-east-1a", "us-east-1b"},
			"private_subnets": []string{"10.90.0.0/20", "10.90.16.0/20"},
			"public_subnets":  []string{"10.90.128.0/24", "10.90.129.0/24"},
			// keep the terratest cluster cheap
			"single_nat_gateway": true,
			"node_group": map[string]interface{}{
				"instance_types": []string{"t3.large"},
				"min_size":       1,
				"max_size":       2,
				"desired_size":   1,
				"capacity_type":  "SPOT",
			},
		},
		EnvVars: map[string]string{
			"AWS_DEFAULT_REGION": "us-east-1",
		},
	})
}

func TestEksModulePlan(t *testing.T) {
	t.Parallel()

	opts := eksOptions(t)

	if os.Getenv("RUN_EKS_APPLY") != "true" {
		// Cheap path: prove init/validate/plan succeed.
		terraform.Init(t, opts)
		terraform.Validate(t, opts)
		terraform.Plan(t, opts)
		return
	}

	// Expensive path: stand it up, assert outputs, always tear down.
	defer terraform.Destroy(t, opts)
	terraform.InitAndApply(t, opts)

	clusterName := terraform.Output(t, opts, "cluster_name")
	require.NotEmpty(t, clusterName, "cluster_name output must be set")
	assert.Contains(t, clusterName, "aequor-tt-")

	// IRSA anchor: the OIDC issuer URL must be a real https endpoint.
	oidcIssuer := terraform.Output(t, opts, "cluster_oidc_issuer_url")
	require.NotEmpty(t, oidcIssuer, "cluster_oidc_issuer_url output must be set")
	assert.Contains(t, oidcIssuer, "https://oidc.eks.")

	oidcArn := terraform.Output(t, opts, "oidc_provider_arn")
	assert.Contains(t, oidcArn, ":oidc-provider/")
}
