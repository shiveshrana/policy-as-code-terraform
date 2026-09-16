#!/usr/bin/env bash
#
# destroy.sh — tear down infrastructure created by setup.sh.
#
# What it does:
#   1. Destroys the selected environment(s), in the order prod -> staging -> dev
#   2. Optionally empties and deletes the remote Terraform state S3 bucket
#      (only when --delete-state-bucket is passed, and only after you
#      confirm — this bucket may still hold state for environments you
#      chose not to destroy in this run)
#
# Usage:
#   ./destroy.sh                              interactive — asks which environment(s)
#   ./destroy.sh -e staging                   destroy one environment
#   ./destroy.sh -e all -y                    destroy dev, staging, prod, no prompts
#   ./destroy.sh -e all -y --delete-state-bucket   also remove the backend bucket
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
TF_ROOT="$PROJECT_ROOT/terraform"
ENV_ROOT="$TF_ROOT/environments"

STATE_BUCKET="policy-as-code-terraform-state-shivesh-2026"
ALL_ENVS_DESTROY_ORDER=(prod staging dev)

TARGET_ENV=""
AUTO_APPROVE="false"
DELETE_STATE_BUCKET="false"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[FAIL]${NC} $*" >&2; }

usage() {
  grep '^#' "${BASH_SOURCE[0]}" | sed -e 's/^#//' -e 's/^ //' | head -n 18
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env) TARGET_ENV="$2"; shift 2 ;;
    -y|--auto-approve) AUTO_APPROVE="true"; shift ;;
    --delete-state-bucket) DELETE_STATE_BUCKET="true"; shift ;;
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
# Prerequisite checks
# ---------------------------------------------------------------------------
if ! command -v terraform >/dev/null 2>&1; then
  err "terraform is not installed."
  exit 1
fi
if ! command -v aws >/dev/null 2>&1; then
  err "AWS CLI is not installed."
  exit 1
fi
if ! CALLER_IDENTITY=$(aws sts get-caller-identity 2>&1); then
  err "Unable to verify AWS credentials:"
  echo "$CALLER_IDENTITY" >&2
  exit 1
fi
ok "Authenticated as: $(echo "$CALLER_IDENTITY" | grep -o '"Arn":[^,]*' | sed 's/"Arn": *//')"

# ---------------------------------------------------------------------------
# Environment selection (explicit — no silent "destroy everything" default)
# ---------------------------------------------------------------------------
if [[ -z "$TARGET_ENV" ]]; then
  echo
  echo "Which environment(s) do you want to DESTROY?"
  select choice in "dev" "staging" "prod" "all"; do
    [[ -n "${choice:-}" ]] && TARGET_ENV="$choice" && break
  done
fi

if [[ "$TARGET_ENV" == "all" ]]; then
  ENVS=("${ALL_ENVS_DESTROY_ORDER[@]}")
elif [[ " ${ALL_ENVS_DESTROY_ORDER[*]} " == *" $TARGET_ENV "* ]]; then
  ENVS=("$TARGET_ENV")
else
  err "Invalid environment: '$TARGET_ENV' (expected dev, staging, prod, or all)"
  exit 1
fi

warn "About to destroy Terraform-managed resources for: ${ENVS[*]}"
warn "This deletes real AWS resources (S3 buckets, KMS keys, security groups) and cannot be undone."
if ! confirm "Type 'y' to continue"; then
  info "Aborted, nothing was destroyed."
  exit 0
fi

# ---------------------------------------------------------------------------
# Destroy each selected environment, prod first (reverse of CI apply order)
# ---------------------------------------------------------------------------
DESTROYED_ENVS=()

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

  if [[ "$env" == "prod" ]]; then
    warn "You are about to DESTROY PRODUCTION."
    if ! confirm "[$env] Really destroy PROD? This is your last chance to back out"; then
      warn "[$env] Skipped."
      continue
    fi
  fi

  info "[$env] terraform plan -destroy"
  terraform -chdir="$ENV_DIR" plan -destroy -input=false -out="$ENV_DIR/tfplan.destroy.$env"

  if confirm "[$env] Apply the destroy plan above?"; then
    terraform -chdir="$ENV_DIR" apply -input=false "$ENV_DIR/tfplan.destroy.$env"
    DESTROYED_ENVS+=("$env")
    ok "[$env] Destroy complete."
  else
    warn "[$env] Skipped destroy."
  fi

  rm -f "$ENV_DIR/tfplan.destroy.$env"
done

# ---------------------------------------------------------------------------
# Optionally remove the remote state bucket
# ---------------------------------------------------------------------------
echo
if [[ "$DELETE_STATE_BUCKET" == "true" ]]; then
  warn "You asked to delete the remote state bucket '$STATE_BUCKET'."
  warn "Only do this once every environment's state has been destroyed —"
  warn "deleting it while other environments still depend on it will orphan their state."
  if confirm "Empty (all versions) and permanently delete '$STATE_BUCKET'?"; then
    if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
      info "Emptying bucket (including all object versions and delete markers)..."
      aws s3api list-object-versions --bucket "$STATE_BUCKET" --output json \
        --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' > /tmp/_versions.json 2>/dev/null || echo '{"Objects":null}' > /tmp/_versions.json
      if [[ "$(cat /tmp/_versions.json)" != '{"Objects":null}' ]]; then
        aws s3api delete-objects --bucket "$STATE_BUCKET" --delete file:///tmp/_versions.json >/dev/null || true
      fi
      aws s3api list-object-versions --bucket "$STATE_BUCKET" --output json \
        --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' > /tmp/_markers.json 2>/dev/null || echo '{"Objects":null}' > /tmp/_markers.json
      if [[ "$(cat /tmp/_markers.json)" != '{"Objects":null}' ]]; then
        aws s3api delete-objects --bucket "$STATE_BUCKET" --delete file:///tmp/_markers.json >/dev/null || true
      fi
      rm -f /tmp/_versions.json /tmp/_markers.json

      aws s3api delete-bucket --bucket "$STATE_BUCKET"
      ok "State bucket deleted."
    else
      info "State bucket already gone."
    fi
  else
    info "Leaving state bucket in place."
  fi
else
  info "Leaving remote state bucket '$STATE_BUCKET' in place (pass --delete-state-bucket to remove it)."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
if [[ ${#DESTROYED_ENVS[@]} -eq 0 ]]; then
  info "No environments were destroyed."
else
  ok "Destroyed environments: ${DESTROYED_ENVS[*]}"
fi
info "Note: the KMS key in each destroyed environment is scheduled for deletion"
info "(7-day window) rather than removed immediately — this is expected AWS behavior."

echo
ok "destroy.sh finished."
