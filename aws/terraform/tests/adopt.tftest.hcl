# Bedrock logging is already on and is not this module's own: the module adopts it, changes
# nothing in it, and only creates the reader role with read access to its destination. Every
# provider is mocked and the existing-logging check is overridden, so no AWS call and no CLI
# run happens.

mock_provider "aws" {}
mock_provider "external" {}
mock_provider "time" {}

override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "111111111111" }
}

override_data {
  target = data.aws_region.current
  values = { region = "us-east-1" }
}

# Default: their own S3 bucket, under their own prefix, encrypted with their own KMS key.
override_data {
  target = data.external.existing_logging
  values = {
    result = {
      account     = "111111111111"
      log_group   = "None"
      role_arn    = "None"
      bucket      = "their-logs"
      prefix      = "audit"
      text        = "True"
      masking     = "None"
      kms_key_arn = "arn:aws:kms:us-east-1:111111111111:key/their-key"
    }
  }
}

variables {
  reading_level  = "full"
  connector_role = "arn:aws:iam::379604374207:role/CarbonForgeConnectorProd"
  external_id    = "cf-test-external-id"
}

run "adopt_their_bucket_at_full_creates_only_the_reader_role_and_policy" {
  command = plan

  assert {
    condition = (
      length(aws_cloudwatch_log_group.logs) + length(aws_cloudwatch_log_group.findings) +
      length(aws_cloudwatch_log_data_protection_policy.mask) + length(aws_iam_role.writer) + length(aws_iam_role_policy.writer) +
      length(aws_s3_bucket.logs) + length(aws_s3_bucket_public_access_block.logs) + length(aws_s3_bucket_lifecycle_configuration.logs) +
      length(aws_s3_bucket_policy.logs) + length(time_sleep.propagation) + length(aws_bedrock_model_invocation_logging_configuration.this)
    ) == 0
    error_message = "Adopting must create nothing but the reader role and its policy, and never a logging configuration."
  }
  assert {
    condition     = output.adopted_existing_logging == true && output.bucket == "their-logs" && output.log_group == null && output.findings_log_group == null
    error_message = "Outputs must say the logging was adopted and name their bucket."
  }
}

run "adopt_their_bucket_reads_only_their_bedrock_log_path" {
  command = plan

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.reader.policy).Statement :
      s.Action == "s3:ListBucket" && s.Resource == "arn:aws:s3:::their-logs" && s.Condition.StringLike["s3:prefix"] == ["audit/AWSLogs/111111111111/BedrockModelInvocationLogs/*"]
    ])
    error_message = "The reader must list their bucket under <prefix>/AWSLogs/<account>/BedrockModelInvocationLogs/ only."
  }
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.reader.policy).Statement :
      s.Action == "s3:GetObject" && s.Resource == "arn:aws:s3:::their-logs/audit/AWSLogs/111111111111/BedrockModelInvocationLogs/*"
    ])
    error_message = "The reader must get objects under their Bedrock log path only."
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.reader.policy).Statement : s if anytrue([for a in flatten([s.Action]) : startswith(a, "logs:")])]) == 0
    error_message = "Adopting a bucket-only configuration must not grant CloudWatch Logs reads."
  }
}

run "adopt_their_kms_encrypted_bucket_grants_decrypt_through_s3_only" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.reader.policy).Statement : s
      if s.Effect == "Allow" && s.Action == "kms:Decrypt" && s.Resource == "arn:aws:kms:us-east-1:111111111111:key/their-key" && s.Condition.StringEquals["kms:ViaService"] == "s3.us-east-1.amazonaws.com"
    ]) == 1
    error_message = "With their KMS key, the reader must get kms:Decrypt on that key through S3 only."
  }
}

run "adopt_their_bucket_without_kms_grants_no_decrypt_and_handles_no_prefix" {
  command = plan

  override_data {
    target = data.external.existing_logging
    values = {
      result = {
        account     = "111111111111"
        log_group   = "None"
        role_arn    = "None"
        bucket      = "their-logs"
        prefix      = "None"
        text        = "True"
        masking     = "None"
        kms_key_arn = "None"
      }
    }
  }

  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.reader.policy).Statement : s if anytrue([for a in flatten([s.Action]) : startswith(a, "kms:")])]) == 0
    error_message = "Without a KMS key, the reader must get no kms permission."
  }
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.reader.policy).Statement :
      s.Action == "s3:GetObject" && s.Resource == "arn:aws:s3:::their-logs/AWSLogs/111111111111/BedrockModelInvocationLogs/*"
    ])
    error_message = "Without a prefix, the Bedrock log path starts at AWSLogs/."
  }
}

run "adopt_their_group_with_masking_at_masked_reads_their_group_and_never_s3" {
  command = plan

  variables {
    reading_level = "masked"
  }

  # Their configuration also writes an S3 copy; it is not masked, so it is never read at masked.
  override_data {
    target = data.external.existing_logging
    values = {
      result = {
        account     = "111111111111"
        log_group   = "/their/bedrock"
        role_arn    = "arn:aws:iam::111111111111:role/TheirBedrockWriter"
        bucket      = "their-logs"
        prefix      = "audit"
        text        = "True"
        masking     = "True"
        kms_key_arn = "arn:aws:kms:us-east-1:111111111111:key/their-key"
      }
    }
  }

  assert {
    condition     = length(aws_bedrock_model_invocation_logging_configuration.this) == 0 && length(aws_cloudwatch_log_group.logs) == 0 && length(aws_cloudwatch_log_data_protection_policy.mask) == 0 && length(aws_iam_role.writer) == 0
    error_message = "Adopting their group must create no logging configuration, log group, masking policy or writer role."
  }
  assert {
    condition = toset(jsondecode(aws_iam_role_policy.reader.policy).Statement[0].Resource) == toset([
      "arn:aws:logs:us-east-1:111111111111:log-group:/their/bedrock",
      "arn:aws:logs:us-east-1:111111111111:log-group:/their/bedrock:*",
    ])
    error_message = "The reader must read their log group."
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.reader.policy).Statement : s if s.Effect == "Deny" && s.Action == "logs:Unmask" && s.Resource == "*"]) == 1
    error_message = "The reader must be denied logs:Unmask on their group."
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.reader.policy).Statement : s if anytrue([for a in flatten([s.Action]) : startswith(a, "s3:") || startswith(a, "kms:")])]) == 0
    error_message = "At masked the reader must never read their S3 copy, nor decrypt with their key."
  }
  assert {
    condition     = output.adopted_existing_logging == true && output.log_group == "/their/bedrock" && output.bucket == null && output.findings_log_group == null
    error_message = "Outputs must name their log group and no bucket."
  }
}

run "adopt_their_group_only_at_full_reads_their_group" {
  command = plan

  override_data {
    target = data.external.existing_logging
    values = {
      result = {
        account     = "111111111111"
        log_group   = "/their/bedrock"
        role_arn    = "arn:aws:iam::111111111111:role/TheirBedrockWriter"
        bucket      = "None"
        prefix      = "None"
        text        = "True"
        masking     = "False"
        kms_key_arn = "None"
      }
    }
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.reader.policy).Statement[0].Resource) == toset([
      "arn:aws:logs:us-east-1:111111111111:log-group:/their/bedrock",
      "arn:aws:logs:us-east-1:111111111111:log-group:/their/bedrock:*",
    ])
    error_message = "At full, with CloudWatch only, the reader must read their log group."
  }
  assert {
    condition     = output.adopted_existing_logging == true && output.log_group == "/their/bedrock" && output.bucket == null
    error_message = "Outputs must name their log group."
  }
}

run "our_writer_role_with_another_bucket_is_adopted_not_replaced" {
  command = plan

  # Same role name as ours, but the S3 copy is not our bucket: the configuration is not ours.
  override_data {
    target = data.external.existing_logging
    values = {
      result = {
        account     = "111111111111"
        log_group   = "/aws/bedrock/modelinvocations"
        role_arn    = "arn:aws:iam::111111111111:role/CarbonForgeBedrockLogWriter"
        bucket      = "their-logs"
        prefix      = "audit"
        text        = "True"
        masking     = "True"
        kms_key_arn = "None"
      }
    }
  }

  assert {
    condition     = output.adopted_existing_logging == true && length(aws_bedrock_model_invocation_logging_configuration.this) == 0
    error_message = "A configuration that writes to a bucket other than ours must be adopted."
  }
}
