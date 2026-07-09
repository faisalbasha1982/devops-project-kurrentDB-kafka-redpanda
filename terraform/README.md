# Aequor — Terraform (Phase 4 platform / IaC)

Terraform modules that lift the Aequor stack from docker-compose onto **EKS**.
Everything here is authored to best-practice and pins provider/module versions,
but **`terraform apply` requires real AWS credentials** (an account, permissions
to create VPC/EKS/IAM/S3, and network access to the Terraform Registry + ECR
Public). It cannot be applied in an offline sandbox — CI validates `fmt`,
`init -backend=false`, `validate`, `tflint`, and `checkov` instead (see
`.github/workflows/ci-terraform.yml`).

## Modules

| Module            | What it does |
|-------------------|--------------|
| `modules/eks`     | Wraps `terraform-aws-modules/vpc` (~> 5.13) + `terraform-aws-modules/eks` (~> 20.24): private-subnet VPC, EKS with the **OIDC provider enabled** (IRSA), and a small managed node group for system add-ons. |
| `modules/karpenter` | Karpenter controller IRSA + Helm release + **v1** `NodePool`/`EC2NodeClass` CRs. Spot-first with on-demand fallback, consolidation on. |
| `modules/irsa`    | Reusable IAM-Role-for-ServiceAccount building block (OIDC-federated trust scoped by `sub` + `aud`). |
| `modules/addons`  | Instantiates `irsa` for real workloads — AWS LB Controller, the app role (settlement/rebuild → S3 chunk archive), optional external-dns — plus the KurrentDB cold-archive S3 bucket (Phase 2d DR). |

The modules are consumed per-environment through **Terragrunt** (`../terragrunt`),
which supplies remote state, provider generation, and dev/prod inputs. You can
also call a module directly for a one-off `plan`.

## Apply order

Karpenter and the addons depend on a live cluster + its OIDC provider, so:

1. `vpc-eks`   (`modules/eks`)      — VPC + EKS + OIDC + system node group
2. `karpenter` (`modules/karpenter`) — needs `cluster_name`, `cluster_endpoint`, `oidc_provider_arn`
3. `addons`    (`modules/addons`)    — needs `oidc_provider_arn`, `vpc_id`

With Terragrunt this ordering is declared via `dependency` blocks and
`terragrunt run-all apply` respects it. Standalone, apply them in the order above.

## Remote-state bootstrap (one-time)

State lives in S3 with a DynamoDB lock table. That backend must exist *before*
the first `init`. Create it once (manually or with a tiny bootstrap stack):

```bash
aws s3api create-bucket --bucket aequor-tfstate-<acct-id> --region us-east-1
aws s3api put-bucket-versioning --bucket aequor-tfstate-<acct-id> \
  --versioning-configuration Status=Enabled
aws dynamodb create-table --table-name aequor-tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region us-east-1
```

Terragrunt's root `terragrunt.hcl` points at exactly these names and creates the
per-env/per-unit state keys automatically.

## Providers you must supply

- `aws` (default, region per env) and an aliased `aws.us_east_1` — the Karpenter
  module pulls its chart from **ECR Public**, whose auth tokens are only issued
  in `us-east-1`. Terragrunt's generated `provider.tf` wires both.
- `helm` + `kubectl` providers, authenticated against the cluster the `eks`
  module just created (endpoint + CA + a `aws eks get-token` exec block).

## Deletion protection

EKS clusters have no native deletion-protection flag. Prod protection is
operational: prod state is a separate, access-restricted S3 prefix, and the
`enable_deletion_protection` input is surfaced as a resource tag so policy/OPA
checks can enforce it. Treat `destroy` on prod as a break-glass action.
