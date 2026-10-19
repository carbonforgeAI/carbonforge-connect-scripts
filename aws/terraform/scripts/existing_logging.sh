#!/bin/sh
# Read-only. Prints, as JSON for Terraform's external data source, the account the AWS CLI is
# signed in to and Bedrock's current invocation logging in the given region: its destinations,
# whether it delivers text, whether its log group has a masking policy, and the bucket's KMS key.
# Terraform has no data source for this setting. The module uses it to adopt logging that is
# already on (read it as it is) instead of replacing it.
set -eu

region="$1"
account=$(aws sts get-caller-identity --query Account --output text)
current=$(aws bedrock get-model-invocation-logging-configuration --region "$region" \
  --query '[loggingConfig.cloudWatchConfig.logGroupName, loggingConfig.cloudWatchConfig.roleArn, loggingConfig.s3Config.bucketName, loggingConfig.s3Config.keyPrefix, loggingConfig.textDataDeliveryEnabled]' \
  --output text)

log_group=$(printf '%s' "$current" | cut -f1)
role_arn=$(printf '%s' "$current" | cut -f2)
bucket=$(printf '%s' "$current" | cut -f3)
prefix=$(printf '%s' "$current" | cut -f4)
text=$(printf '%s' "$current" | cut -f5)

masking=None
if [ "$log_group" != None ]; then
  masking=$(aws logs get-data-protection-policy --region "$region" --log-group-identifier "$log_group" \
    --query 'policyDocument != null' --output text 2>/dev/null || echo false)
fi

kms_key_arn=None
if [ "$bucket" != None ]; then
  key=$(aws s3api get-bucket-encryption --bucket "$bucket" \
    --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID' \
    --output text 2>/dev/null || echo None)
  if [ "$key" != None ]; then
    kms_key_arn=$(aws kms describe-key --region "$region" --key-id "$key" --query KeyMetadata.Arn --output text)
  fi
fi

printf '{"account":"%s","log_group":"%s","role_arn":"%s","bucket":"%s","prefix":"%s","text":"%s","masking":"%s","kms_key_arn":"%s"}\n' \
  "$account" "$log_group" "$role_arn" "$bucket" "$prefix" "$text" "$masking" "$kms_key_arn"
