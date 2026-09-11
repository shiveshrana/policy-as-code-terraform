module "infrastructure" {
  source = "../../modules/infrastructure"

  environment = "staging"

  bucket_name = "policy-as-code-staging-shivesh-2026"

  tags = {
    Project   = "policy-as-code-terraform"
    ManagedBy = "Terraform"
  }
}