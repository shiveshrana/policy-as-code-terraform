module "infrastructure" {
  source = "../../modules/infrastructure"

  environment = "prod"

  bucket_name = "policy-as-code-prod-shivesh-2026"

  tags = {
    Project   = "policy-as-code-terraform"
    ManagedBy = "Terraform"
  }
}