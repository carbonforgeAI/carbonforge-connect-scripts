# CarbonForge Connect for AWS

Connects an AWS account to CarbonForge. It turns on Amazon Bedrock invocation logging in one region and creates a read-only role that only CarbonForge's connector can assume, with your external ID. **If logging is already on, it stays exactly as it is**: the module only creates the read-only role, with access to your existing destination. It creates the same resources as the "I set it up, you read" steps in CarbonForge Connect, and nothing else. No CarbonForge code runs in your account.

## Usage

```hcl
provider "aws" {
  region              = "<AWS_REGION>"
  allowed_account_ids = ["<AWS_ACCOUNT_ID>"]
}

module "carbonforge_connect" {
  source = "github.com/carbonforgeAI/carbonforge-connect-scripts//aws/terraform?ref=<version>"

  reading_level  = "masked"   # or "full"
  connector_role = "arn:aws:iam::379604374207:role/CarbonForgeConnectorProd"
  external_id    = "<EXTERNAL_ID>"
  billed_spend   = false
}

output "reader_role_arn" {
  value = module.carbonforge_connect.reader_role_arn
}
```

Run `terraform init && terraform apply`, paste `reader_role_arn` into CarbonForge Connect, then click **Test connection**.

**Requirements:**
- Terraform 1.5 or later.
- The **AWS CLI**, signed in with the **same credentials** as the Terraform AWS provider (for example the same `AWS_PROFILE`). The module uses it once per plan to read Bedrock's current logging setting and, when logging is already on, its log group's masking policy and its bucket's encryption key (all read-only), because Terraform has no data source for these. If the CLI and the provider point at different accounts, the plan stops and says so.

## What it creates

| Level | Resources |
|---|---|
| `masked` | CloudWatch log group `/aws/bedrock/modelinvocations` (14 days) with a data protection policy that masks personal data as each event is written. Log group `/aws/bedrock/modelinvocations-findings` (14 days) recording which kind of data each mask hid, never the value. IAM role `CarbonForgeBedrockLogWriter`, used by Bedrock to write the logs. |
| `full` | S3 bucket `carbonforge-bedrock-logs-<account_id>`, public access blocked, objects under `bedrock/` expire after 14 days. |
| both | Bedrock invocation logging in the provider's region (text only). IAM role `CarbonForgeReader`, trusted only by `connector_role` with `external_id`. |
| logging already on | **Only** the IAM role `CarbonForgeReader`. Your logging, log group and bucket are left as they are. |

## What CarbonForge can read

| Permission | Used for | Scope |
|---|---|---|
| Logs read on the two log groups (`masked`), with `logs:Unmask` explicitly denied | Prompts and answers, personal data masked | Those two log groups only. CarbonForge can never see unmasked data. |
| `s3:ListBucket`, `s3:GetObject` on `bedrock/` (`full`) | Prompts and answers as logged | That bucket prefix only |
| `cloudwatch:GetMetricData`, `cloudwatch:ListMetrics` | Calls, tokens and latency per model, about 15 months back | All metrics in the account (AWS cannot limit it to one namespace); CarbonForge only queries `AWS/Bedrock` |
| `ce:GetCostAndUsage` (only with `billed_spend = true`) | Billed Bedrock spend per model | Your whole AWS bill; CarbonForge only queries Amazon Bedrock |
| `bedrock:GetModelInvocationLoggingConfiguration` | Checking that logging is on | Read-only |

## Inputs

| Name | Description | Default |
|---|---|---|
| `reading_level` | `masked` or `full` | required |
| `connector_role` | CarbonForge connector role ARN, as shown in CarbonForge Connect | required |
| `external_id` | Your external ID, as shown in CarbonForge Connect | required |
| `billed_spend` | Let CarbonForge read your billed Bedrock spend | `false` |
| `tags` | Tags for every resource | `{}` |

## Outputs

`reader_role_arn` (paste into CarbonForge Connect), `region`, `reading_level`, `adopted_existing_logging`, `log_group` and `bucket` (whichever CarbonForge reads), `findings_log_group` (masked, logging created by the module).

## Behaviour to know

- **Existing logging:** Bedrock keeps one logging configuration per region, and setting one replaces it. If logging is already on in the region and isn't this module's own, the module **adopts** it: it changes nothing in it and gives the reader role read access to its destination only.
  - `full`: your bucket's Bedrock log path (plus `kms:Decrypt` on your bucket's KMS key, through S3 only), or your log group if you log only to CloudWatch.
  - `masked`: your log group, only if it already has a CloudWatch data protection policy; CarbonForge then sees only what your policy masks, with generic labels. Without one, the plan stops: *"... its logs are not masked by a CloudWatch data protection policy. Your logging is left as it is: set reading_level = "full", or contact CarbonForge."*
  - Logging that does not deliver text also stops the plan.
  - `terraform destroy` then removes only the reader role.
- **Masking applies to everyone.** At the `masked` level, your own team also sees `****` in these logs unless they hold `logs:Unmask`.
- **Large calls.** Calls larger than about 100 KB are not delivered to CloudWatch, so CarbonForge doesn't read them at the `masked` level.
- **Switching level:** change `reading_level` and apply. Logging moves to the other destination, the reader role loses access to the old one, and **the old level's resources are deleted, including the logs they hold**. Terraform removes the old destination before pointing logging at the new one, so calls made during those few seconds (about 15) are not logged.
- **Revoking:** `terraform destroy` turns logging off and deletes everything the module created. At the `full` level the bucket must be emptied first (`aws s3 rm s3://carbonforge-bedrock-logs-<account_id> --recursive`); the module never force-deletes your data.

## Maintainers

`identifiers.tf` is generated from [`aws/identifiers.json`](../identifiers.json) by [`scripts/gen_identifiers.py`](../../scripts/gen_identifiers.py); never edit it by hand. To change what is masked, edit the JSON, run `python3 scripts/gen_identifiers.py` from the repository root, and commit both files. CI runs the script with `--check` and fails if they differ. The list must stay identical to AWS step 2 of the setup runbook (`cloud_setup.md`), so the module and the manual steps mask the same way.

Tests: `terraform test` in this directory runs the cases in [`tests/`](tests/) against mocked providers, with the existing-logging check overridden, so it needs no AWS credentials and no AWS CLI.
