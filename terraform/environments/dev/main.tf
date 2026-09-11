module "infrastructure" {
  source = "../../modules/infrastructure"

  environment = "dev"

  bucket_name = "policy-as-code-dev-shivesh-2026"

  tags = {
    Project   = "policy-as-code-terraform"
    ManagedBy = "Terraform"
  }
}
