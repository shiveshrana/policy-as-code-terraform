# policy-as-code-terraform

Multi-environment AWS infrastructure managed with Terraform, gated by an
automated policy/security-scanning pipeline (Checkov) and deployed through
GitHub Actions using short-lived OIDC credentials — no long-lived AWS keys
anywhere in the repo or CI.

## What this project provisions

For each environment (`dev`, `staging`, `prod`) the `infrastructure` module
creates a small, consistent stack:

| Resource | Purpose |
|---|---|
| `aws_s3_bucket` | Per-environment bucket (`policy-as-code-<env>-shivesh-2026`) |
| `aws_s3_bucket_versioning` | Versioning enabled on the bucket |
| `aws_kms_key` | Customer-managed KMS key, rotation enabled, used for bucket encryption |
| `aws_s3_bucket_server_side_encryption_configuration` | Enforces SSE-KMS with a bucket key |
| `aws_s3_bucket_lifecycle_configuration` | Expires noncurrent versions after 30 days, aborts incomplete multipart uploads after 7 days |
| `aws_s3_bucket_public_access_block` | Blocks all public access (ACLs, policy, and cross-account) |
| `aws_security_group` | Environment-scoped security group in the account's default VPC |

Every environment shares the same module (`terraform/modules/infrastructure`)
and only differs by input variables (`environment`, `bucket_name`, `tags`),
so drift between environments is structural, not accidental.

## Repository layout

```
policy-as-code-terraform/
├── terraform-plan-policy.json          # IAM policy scoping the CI role's plan-time permissions
├── .github/workflows/terraform-ci.yml  # CI/CD pipeline (fmt, init, validate, Checkov, plan, apply)
├── terraform/
│   ├── main.tf                         # Root module (intentionally empty — see note below)
│   ├── versions.tf                     # Terraform + AWS provider version pins, region ap-south-1
│   ├── backend.tf                      # Root-level S3 backend config (not used by env stacks)
│   ├── modules/
│   │   └── infrastructure/
│   │       ├── main.tf                 # S3 bucket, KMS key, security group, encryption, lifecycle
│   │       ├── variables.tf            # environment / bucket_name / tags inputs
│   │       └── outputs.tf              # bucket_name, bucket_arn, security_group_id
│   └── environments/
│       ├── dev/       (main.tf, outputs.tf, backend.tf, state files)
│       ├── staging/    (main.tf, outputs.tf, backend.tf, state files)
│       └── prod/       (main.tf, outputs.tf, backend.tf, state files)
```

> **Note on `terraform/main.tf`:** the root module is a placeholder. Each
> environment under `terraform/environments/<env>/` is its own root module
> with its own backend and state file — this is what the setup script
> initializes, plans, and applies.

## How state is stored

Each environment keeps an independent state file in the **same** S3 bucket,
under a different key, with native S3 locking (`use_lockfile = true`,
Terraform's DynamoDB-free locking):

| Environment | Backend key |
|---|---|
| dev | `env/dev/terraform.tfstate` |
| staging | `env/staging/terraform.tfstate` |
| prod | `env/prod/terraform.tfstate` |

Backend bucket: `policy-as-code-terraform-state-shivesh-2026` (region `ap-south-1`).
This bucket must exist **before** `terraform init` can succeed — the setup
script creates it for you if it isn't there.

## How the CI/CD pipeline works

`.github/workflows/terraform-ci.yml` runs three sequential jobs — `dev` →
`staging` → `prod` (each gated on the previous one succeeding):

1. Checkout, install Terraform.
2. Assume the `GitHubActions-PolicyAsCode` IAM role via OIDC
   (`aws-actions/configure-aws-credentials`) — no static AWS secrets stored
   in GitHub.
3. `terraform fmt -check -recursive`
4. `terraform init` (dev also runs `terraform state list` as a sanity check
   that the S3 bucket resource is actually tracked in state)
5. `terraform validate`
6. **Checkov scan** (`checkov -d terraform --framework terraform`) — this is
   the "policy-as-code" gate: the pipeline fails the build if any Terraform
   resource violates Checkov's security/compliance rules, before anything is
   ever planned or applied.
7. `terraform plan -lock=false`
8. `terraform apply -auto-approve` — **only** on a push to `main` (pull
   requests stop after `plan`). `prod` additionally requires the GitHub
   Environment named `prod`, so it can carry required reviewers / approval
   gates configured in the repo settings.

`terraform-plan-policy.json` is the (intentionally minimal) IAM policy meant
to be attached to the plan-time role/permission set — as written it only
grants `ec2:DescribeVpcs`, since the modules read the account's default VPC.
Expand it to match whatever the CI role is actually allowed to do in your
AWS account (it does not currently include S3/KMS/SecurityGroup permissions
needed for apply — treat it as a template to extend, not a finished policy).

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5.0
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), configured with credentials that can create S3/KMS/EC2 resources
- [Checkov](https://www.checkov.io/) (the setup script installs `checkov==3.3.17` via `pip` if it's missing)
- An AWS account you're happy to deploy real, billable resources into

## Setup

```bash
chmod +x setup.sh destroy.sh
./setup.sh                 # interactive: prompts for environment(s) and applies
./setup.sh -e dev          # target a single environment
./setup.sh -e all -y       # init + plan + apply dev, staging, prod, no prompts
./setup.sh -e dev --plan-only   # create the state bucket and run plan only, no apply
```

What `setup.sh` does, in order:

1. Verifies `terraform`, `aws`, and `checkov` are installed (offers to
   `pip install` Checkov if missing).
2. Verifies the AWS CLI has valid credentials (`aws sts get-caller-identity`).
3. Creates the remote-state S3 bucket if it doesn't already exist, with
   versioning and encryption enabled, and blocks public access on it.
4. For each selected environment: `terraform fmt -check`, `init`,
   `validate`, a Checkov scan of `terraform/`, then `plan`, then — after
   your confirmation (unless `-y`/`--auto-approve` is passed) — `apply`.
5. Prints the Terraform outputs (`bucket_name`, `bucket_arn`,
   `security_group_id`) for each environment that was applied.

## Tearing everything down

```bash
./destroy.sh                # interactive: prompts for environment(s)
./destroy.sh -e staging     # destroy just one environment's resources
./destroy.sh -e all -y      # destroy dev, staging, and prod, no prompts
./destroy.sh -e all -y --delete-state-bucket   # also empty + delete the backend bucket
```

`destroy.sh` runs `terraform destroy -auto-approve` (after confirmation) for
each selected environment, in the safest order (`prod` → `staging` → `dev`,
the reverse of how CI applies them). The remote-state S3 bucket itself is
**left in place by default**, since it can hold state for environments you
didn't destroy in this run. Pass `--delete-state-bucket` only after every
environment has been destroyed, to also empty (including all versions) and
delete that bucket.

## Safety notes

- Both scripts require explicit confirmation before anything destructive
  happens, unless you pass `-y`/`--auto-approve`.
- `destroy.sh` will refuse to run against `prod` without `-e prod` or
  `-e all` being explicitly named — it never destroys prod as a side effect
  of a vague invocation.
- Real AWS resources cost money and `terraform apply` creates them for
  real. Run against `dev` first.
- The KMS key has a 7-day deletion window; after `destroy.sh` removes it,
  it's scheduled for deletion rather than removed immediately, and AWS will
  still show it (pending deletion) for those 7 days.
