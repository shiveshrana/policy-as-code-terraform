terraform {
  backend "s3" {
    bucket       = "policy-as-code-terraform-state-shivesh-2026"
    key          = "env/staging/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
