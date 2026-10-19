# CarbonForge Connect for AWS: CloudFormation

`connect.yaml` creates the same resources as the [Terraform module](../terraform/README.md): the Bedrock log destination for your reading level and the read-only role `CarbonForgeReader`, which only CarbonForge's connector role can assume, with your external ID. If your Bedrock logging is already on, it creates **only** the reader role, with read access to your existing destination, and leaves your logging exactly as it is. There is no Lambda function and no custom resource: no CarbonForge code runs in your account.

CloudFormation has no resource for Bedrock's invocation logging setting, so setup takes two steps: create the stack, then switch logging on in one console screen using the stack's outputs.

```
 1. create stack ──► outputs ──► 2. Bedrock console: Settings > Model invocation logging ──► paste ReaderRoleArn into CarbonForge Connect
    (skip step 2 when ExistingLogging is not none: your logging is already on)
```

## Before you start: is Bedrock logging already on?

Bedrock keeps one logging configuration per region, and saving a new one replaces it. In the region you use Bedrock in, open the Bedrock console, **Settings**, and look at **Model invocation logging** (or run `aws bedrock get-model-invocation-logging-configuration --region <region>`).

| What you see | Parameters |
|---|---|
| Logging is off | `ExistingLogging = none` |
| Logging is on, to a CloudWatch log group | `ExistingLogging = their-log-group`, `ExistingLogGroup` = that log group |
| Logging is on, to an S3 bucket | `ExistingLogging = their-bucket`, `ExistingBucket` = that bucket, `ExistingKeyPrefix` = its key prefix if any, `ExistingKmsKeyArn` = the bucket's own KMS key ARN if it uses one |

- At the `masked` level only `their-log-group` is possible, and only if that log group already has a CloudWatch data protection policy: CarbonForge then sees only what your policy masks. The stack cannot check this; CarbonForge Connect's **Test connection** does. If your logs are not masked, choose `full`.
- Your logging must deliver text. If it doesn't, there is nothing for CarbonForge to read.
- If logging goes to both, choose `their-bucket` at `full`, `their-log-group` at `masked`.

## Step 1: create the stack

In the region where you use Bedrock: **CloudFormation > Create stack > With new resources**, upload `connect.yaml`, fill in the values shown in CarbonForge Connect, and tick the acknowledgement that the stack creates IAM roles with fixed names. Or:

```sh
aws cloudformation deploy --region <AWS_REGION> --stack-name carbonforge-connect \
  --template-file connect.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ReadingLevel=masked ConnectorRole=<CONNECTOR_ROLE_ARN> ExternalId=<EXTERNAL_ID> BilledSpend=false
```

| Parameter | Meaning | Default |
|---|---|---|
| `ReadingLevel` | `masked` or `full` | required |
| `ConnectorRole` | CarbonForge connector role ARN, as shown in CarbonForge Connect | required |
| `ExternalId` | Your external ID, as shown in CarbonForge Connect | required |
| `BilledSpend` | `true` lets CarbonForge read your billed Bedrock spend (Cost Explorer covers your whole bill; CarbonForge only queries Amazon Bedrock) | `false` |
| `ExistingLogging` | `none`, `their-log-group` or `their-bucket` (see above) | `none` |
| `ExistingLogGroup`, `ExistingBucket`, `ExistingKeyPrefix`, `ExistingKmsKeyArn` | Your existing destination, when logging is already on | empty |

## Step 2: turn logging on (new logging only)

Skip this step when `ExistingLogging` is not `none`. Otherwise, check once more that logging is still off (saving replaces any logging that is on), then in the Bedrock console, **Settings > Model invocation logging**:

1. Turn logging on.
2. Data types: **Text** only (untick image, embedding and video).
3. Destination: the stack output `LoggingDestination`.
   - **CloudWatch Logs only** (`masked`): log group name = output `LogGroup`; service role: **Use an existing service role** = output `WriterRoleArn`.
   - **S3 only** (`full`): S3 location = output `S3Location`.
4. Save.

The output `EnableLoggingCommand` holds the same setting as one AWS CLI command, if you prefer it to the console.

Then paste the output `ReaderRoleArn` into CarbonForge Connect and click **Test connection**.

## What it creates

| Level | Resources |
|---|---|
| `masked` | Log group `/aws/bedrock/modelinvocations` (14 days) with a data protection policy that masks personal data as each event is written. Log group `/aws/bedrock/modelinvocations-findings` (14 days) recording which kind of data each mask hid, never the value. IAM role `CarbonForgeBedrockLogWriter`, used by Bedrock to write the logs. |
| `full` | S3 bucket `carbonforge-bedrock-logs-<account_id>`, public access blocked, objects under `bedrock/` expire after 14 days, writable only by Bedrock in your account. |
| both | IAM role `CarbonForgeReader`, trusted only by `ConnectorRole` with `ExternalId`. |
| logging already on | **Only** the IAM role `CarbonForgeReader`, reading your log group (with `logs:Unmask` denied) or your bucket's Bedrock log path (`<prefix>/AWSLogs/<account_id>/BedrockModelInvocationLogs/`, plus `kms:Decrypt` on your key through S3 only). |

What CarbonForge can read is the same as with the Terraform module: see [What CarbonForge can read](../terraform/README.md#what-carbonforge-can-read). The masking identifiers come from [`aws/identifiers.json`](../identifiers.json); the block between the `BEGIN generated` and `END generated` markers in `connect.yaml` is written by `scripts/gen_identifiers.py`, never by hand.

## Switching level

Update the stack with the other `ReadingLevel`, then repeat step 2 with the new outputs. The old level's resources are deleted, **including the logs they hold**; from `full`, empty the bucket first (`aws s3 rm s3://carbonforge-bedrock-logs-<account_id> --recursive`).

## Revoking

- **New logging:** turn logging off first (Bedrock console, **Settings > Model invocation logging**, or `aws bedrock delete-model-invocation-logging-configuration --region <region>`). At `full`, empty the bucket (`aws s3 rm s3://carbonforge-bedrock-logs-<account_id> --recursive`); the stack never deletes your logs for you, and deleting a bucket that still holds objects fails. Then delete the stack.
- **Logging already on:** just delete the stack. It removes only the reader role; leave your logging on.
