#!/usr/bin/env bash
#
# setup.sh — bootstrap and deploy the policy-as-code-terraform project.
#
# What it does:
#   1. Checks for terraform, aws cli, checkov (offers to install checkov)
#   2. Verifies AWS credentials are usable
#   3. Creates the remote Terraform state S3 bucket if missing
#   4. For each selected environment: fmt check, init, validate, checkov
#      scan, plan, and (after confirmation) apply
#
# Usage:
#   ./setup.sh                     interactive — asks which environment(s)
#   ./setup.sh -e dev              target one environment
#   ./setup.sh -e all -y           init+plan+apply dev, staging, prod, no prompts
#   ./setup.sh -e dev --plan-only  create state bucket, run plan only, skip apply
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
TF_ROOT="$PROJECT_ROOT/terraform"
ENV_ROOT="$TF_ROOT/environments"

STATE_BUCKET="policy-as-code-terraform-state-shivesh-2026"
STATE_REGION="ap-south-1"
CHECKOV_VERSION="3.3.17"
ALL_ENVS=(dev staging prod)

TARGET_ENV=""
AUTO_APPROVE="false"
PLAN_ONLY="false"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[FAIL]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
usage() {
  grep '^#' "${BASH_SOURCE[0]}" | sed -e 's/^#//' -e 's/^ //' | head -n 20
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env) TARGET_ENV="$2"; shift 2 ;;
    -y|--auto-approve) AUTO_APPROVE="true"; shift ;;
    --plan-only) PLAN_ONLY="true"; shift ;;
    -h|--help) usage ;;
    *) err "Unknown argument: $1"; usage ;;
  esac
done

confirm() {
  local prompt="$1"
  if [[ "$AUTO_APPROVE" == "true" ]]; then
    return 0
  fi
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# 1. Prerequisite checks
# ---------------------------------------------------------------------------
info "Checking prerequisites..."

if ! command -v terraform >/dev/null 2>&1; then
  err "terraform is not installed. Install it from https://developer.hashicorp.com/terraform/downloads and re-run."
  exit 1
fi
ok "terraform found: $(terraform version -json 2>/dev/null | grep -o '"terraform_version":"[^"]*"' || terraform version | head -n1)"

if ! command -v aws >/dev/null 2>&1; then
  err "AWS CLI is not installed. Install it from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html and re-run."
  exit 1
fi
ok "aws cli found: $(aws --version)"

if ! command -v checkov >/dev/null 2>&1; then
  warn "checkov is not installed."
  if confirm "Install checkov==${CHECKOV_VERSION} via pip now?"; then
    pip install "checkov==${CHECKOV_VERSION}" --break-system-packages 2>/dev/null \
      || pip install "checkov==${CHECKOV_VERSION}"
  else
    err "checkov is required for the policy scan step. Aborting."
    exit 1
  fi
fi
ok "checkov found: $(checkov --version)"

# ---------------------------------------------------------------------------
# 2. Verify AWS credentials
# ---------------------------------------------------------------------------
info "Verifying AWS credentials..."
if ! CALLER_IDENTITY=$(aws sts get-caller-identity 2>&1); then
  err "Unable to verify AWS credentials:"
  echo "$CALLER_IDENTITY" >&2
  err "Configure credentials (aws configure, an SSO profile, or env vars) and re-run."
  exit 1
fi
ok "Authenticated as: $(echo "$CALLER_IDENTITY" | grep -o '"Arn":[^,]*' | sed 's/"Arn": *//')"

# ---------------------------------------------------------------------------
# 3. Environment selection
# ---------------------------------------------------------------------------
if [[ -z "$TARGET_ENV" ]]; then
  echo
  echo "Which environment(s) do you want to set up?"
  select choice in "dev" "staging" "prod" "all"; do
    [[ -n "${choice:-}" ]] && TARGET_ENV="$choice" && break
  done
fi

if [[ "$TARGET_ENV" == "all" ]]; then
  ENVS=("${ALL_ENVS[@]}")
elif [[ " ${ALL_ENVS[*]} " == *" $TARGET_ENV "* ]]; then
  ENVS=("$TARGET_ENV")
else
  err "Invalid environment: '$TARGET_ENV' (expected dev, staging, prod, or all)"
  exit 1
fi
info "Selected environment(s): ${ENVS[*]}"

# ---------------------------------------------------------------------------
# 4. Create the remote state bucket if it doesn't exist
# ---------------------------------------------------------------------------
info "Checking remote state bucket '$STATE_BUCKET'..."
if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
  ok "State bucket already exists."
else
  warn "State bucket does not exist yet."
  if confirm "Create S3 bucket '$STATE_BUCKET' in $STATE_REGION for Terraform state?"; then
    if [[ "$STATE_REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$STATE_REGION"
    else
      aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$STATE_REGION" \
        --create-bucket-configuration LocationConstraint="$STATE_REGION"
    fi

    aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" \
      --versioning-configuration Status=Enabled

    aws s3api put-bucket-encryption --bucket "$STATE_BUCKET" \
      --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

    aws s3api put-public-access-block --bucket "$STATE_BUCKET" \
      --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

    ok "State bucket created, versioned, encrypted, and locked to private."
  else
    err "Cannot proceed without the state bucket. Aborting."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 5. Per-environment: fmt, init, validate, checkov, plan, apply
# ---------------------------------------------------------------------------
info "Running 'terraform fmt -check -recursive' against terraform/..."
if ! terraform -chdir="$TF_ROOT" fmt -check -recursive; then
  warn "Some files are not fmt-clean. Run 'terraform fmt -recursive' in terraform/ to fix formatting."
fi

info "Running Checkov policy scan against terraform/..."
if ! checkov -d "$TF_ROOT" --framework terraform; then
  warn "Checkov reported findings above. Review them before applying to prod."
  if ! confirm "Continue despite Checkov findings?"; then
    err "Aborting at your request."
    exit 1
  fi
fi

APPLIED_ENVS=()

for env in "${ENVS[@]}"; do
  echo
  info "=== Environment: $env ==="
  ENV_DIR="$ENV_ROOT/$env"

  if [[ ! -d "$ENV_DIR" ]]; then
    err "Directory $ENV_DIR not found, skipping."
    continue
  fi

  info "[$env] terraform init"
  terraform -chdir="$ENV_DIR" init -input=false

  info "[$env] terraform validate"
  terraform -chdir="$ENV_DIR" validate

  PLAN_FILE="$ENV_DIR/tfplan.$env"
  info "[$env] terraform plan"
  terraform -chdir="$ENV_DIR" plan -input=false -out="$PLAN_FILE"

  if [[ "$PLAN_ONLY" == "true" ]]; then
    info "[$env] --plan-only set, skipping apply."
    continue
  fi

  if [[ "$env" == "prod" ]]; then
    warn "You are about to apply changes to PRODUCTION."
  fi

  if confirm "[$env] Apply the plan above?"; then
    terraform -chdir="$ENV_DIR" apply -input=false "$PLAN_FILE"
    APPLIED_ENVS+=("$env")
    ok "[$env] Apply complete."
  else
    warn "[$env] Skipped apply."
  fi

  rm -f "$PLAN_FILE"
done

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
echo
if [[ ${#APPLIED_ENVS[@]} -eq 0 ]]; then
  info "No environments were applied. Nothing further to report."
else
  ok "Applied environments: ${APPLIED_ENVS[*]}"
  for env in "${APPLIED_ENVS[@]}"; do
    echo
    info "--- Outputs for $env ---"
    terraform -chdir="$ENV_ROOT/$env" output
  done
fi

echo
ok "setup.sh finished."
