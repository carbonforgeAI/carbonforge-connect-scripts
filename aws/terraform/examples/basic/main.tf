# Connect an AWS account to CarbonForge.
# Replace <AWS_REGION>, <AWS_ACCOUNT_ID> and <EXTERNAL_ID> with the values shown in CarbonForge Connect.
# Once published, use: source = "github.com/<CARBONFORGE_GITHUB_ORG>/terraform-aws-carbonforge-connect?ref=<version>"

provider "aws" {
  region              = "<AWS_REGION>"
  allowed_account_ids = ["<AWS_ACCOUNT_ID>"]
}

module "carbonforge_connect" {
  source = "../.."

  reading_level  = "masked"
  connector_role = "arn:aws:iam::379604374207:role/CarbonForgeConnectorProd"
  external_id    = "<EXTERNAL_ID>"
  billed_spend   = false
}

output "reader_role_arn" {
  value = module.carbonforge_connect.reader_role_arn
}
