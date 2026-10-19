# CarbonForge Connect scripts

What a customer runs to connect their cloud to CarbonForge Connect. Nothing here runs CarbonForge code in the customer's account, and nothing gives CarbonForge write access.

```
aws/
  terraform/            Terraform module: Bedrock invocation logging + the read-only CarbonForgeReader role
    tests/              terraform test cases (mocked providers, no AWS access needed)
    examples/basic/     the snippet CarbonForge Connect shows
  identifiers.json      the CloudWatch masking identifiers (single source; identifiers.tf is generated from it)
gcp/                    Google Vertex AI (coming)
scripts/
  gen_identifiers.py    writes aws/terraform/identifiers.tf from aws/identifiers.json (--check in CI)
  tests/                pytest for the generator
```

## Use the AWS module

```hcl
provider "aws" {
  region              = "<AWS_REGION>"
  allowed_account_ids = ["<AWS_ACCOUNT_ID>"]
}

module "carbonforge_connect" {
  source = "github.com/carbonforgeAI/carbonforge-connect-scripts//aws/terraform?ref=<version>"

  reading_level  = "masked"   # or "full"
  connector_role = "<CONNECTOR_ROLE_ARN shown in CarbonForge Connect>"
  external_id    = "<EXTERNAL_ID shown in CarbonForge Connect>"
}

output "reader_role_arn" {
  value = module.carbonforge_connect.reader_role_arn
}
```

Run `terraform init && terraform apply` with the AWS CLI signed in to the same account, paste `reader_role_arn` into CarbonForge Connect, then click **Test connection**. See [aws/terraform/README.md](aws/terraform/README.md) for what it creates, what CarbonForge can read, existing logging, switching level and revoking.

## Develop

```sh
cd aws/terraform && terraform fmt -check -recursive && terraform init -backend=false && terraform validate && terraform test
python3 scripts/gen_identifiers.py --check
python3 -m pytest scripts/tests
```

`terraform test` uses mocked providers and never calls AWS. To change the masking identifiers, edit `aws/identifiers.json` and run `python3 scripts/gen_identifiers.py`; keep the list identical to AWS step 2 of the setup runbook.
