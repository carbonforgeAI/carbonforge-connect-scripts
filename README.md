# CarbonForge Connect scripts

What a customer runs to connect their cloud to CarbonForge Connect. Nothing here runs CarbonForge code in the customer's account, and nothing gives CarbonForge write access.

```
aws/
  terraform/            Terraform module: Bedrock invocation logging + the read-only CarbonForgeReader role
    tests/              terraform test cases (mocked providers, no AWS access needed)
    examples/basic/     the snippet CarbonForge Connect shows
  cloudformation/       CloudFormation template: the same resources, logging switched on in the console after
    connect.yaml
    tests/              pytest that evaluates the template offline per parameter combination
  identifiers.json      the CloudWatch masking identifiers (single source for identifiers.tf and connect.yaml)
gcp/                    Google Vertex AI (coming)
scripts/
  build_module_zip.sh   builds the published Terraform module zip from a commit, reproducibly, and prints its sha256
  gen_identifiers.py    writes identifiers.tf and connect.yaml's masking block from aws/identifiers.json (--check in CI)
  tests/                pytest for the generator
```

## Use the AWS module

This repository is private, so customers use the published copies, never a git source:

```
 aws/terraform/ (zip, module at the root) ─► https://carbonforge-connect-templates.s3.amazonaws.com/terraform-aws-connect-v<N>.zip
 aws/cloudformation/connect.yaml          ─► https://carbonforge-connect-templates.s3.amazonaws.com/connect-v<N>.yaml
```

A published object is never overwritten: a new version is a new name, so a customer's module source or stack keeps pointing at what it was created from. `scripts/build_module_zip.sh` builds the zip reproducibly from a commit and prints its sha256; after the upload, check that the public copy has the same sha256.

```hcl
provider "aws" {
  region              = "<AWS_REGION>"
  allowed_account_ids = ["<AWS_ACCOUNT_ID>"]
}

module "carbonforge_connect" {
  source = "https://carbonforge-connect-templates.s3.amazonaws.com/terraform-aws-connect-v1.zip"

  reading_level  = "masked"   # or "full"
  connector_role = "<CONNECTOR_ROLE_ARN shown in CarbonForge Connect>"
  external_id    = "<EXTERNAL_ID shown in CarbonForge Connect>"
}

output "reader_role_arn" {
  value = module.carbonforge_connect.reader_role_arn
}
```

Run `terraform init && terraform apply` with the AWS CLI signed in to the same account, paste `reader_role_arn` into CarbonForge Connect, then click **Test connection**. See [aws/terraform/README.md](aws/terraform/README.md) for what it creates, what CarbonForge can read, existing logging, switching level and revoking.

## Or use the CloudFormation template

CloudFormation has no resource for Bedrock's logging setting, so it is two steps: create a stack from [aws/cloudformation/connect.yaml](aws/cloudformation/connect.yaml), then turn logging on in the Bedrock console (**Settings > Model invocation logging**) with the stack's outputs. Revoke by turning logging off and deleting the stack. See [aws/cloudformation/README.md](aws/cloudformation/README.md).

## Develop

```sh
cd aws/terraform && terraform fmt -check -recursive && terraform init -backend=false && terraform validate && terraform test
python3 scripts/gen_identifiers.py --check
python3 -m pytest scripts/tests aws/cloudformation/tests   # needs pyyaml
cfn-lint aws/cloudformation/connect.yaml
```

`terraform test` uses mocked providers and never calls AWS; the template tests evaluate connect.yaml offline. To change the masking identifiers, edit `aws/identifiers.json` and run `python3 scripts/gen_identifiers.py`; keep the list identical to AWS step 2 of the setup runbook.
