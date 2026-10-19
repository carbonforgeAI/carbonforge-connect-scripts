# No Bedrock logging in the region, or logging this module set up itself: the module creates
# and manages the destination. Every provider is mocked and the existing-logging check is
# overridden, so no AWS call and no CLI run happens.

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

override_data {
  target = data.external.existing_logging
  values = {
    result = {
      account     = "111111111111"
      log_group   = "None"
      role_arn    = "None"
      bucket      = "None"
      prefix      = "None"
      text        = "None"
      masking     = "None"
      kms_key_arn = "None"
    }
  }
}

variables {
  reading_level  = "masked"
  connector_role = "arn:aws:iam::379604374207:role/CarbonForgeConnectorProd"
  external_id    = "cf-test-external-id"
}

run "new_customer_masked_creates_log_groups_masking_writer_logging_and_reader" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_log_group.logs) == 1 && aws_cloudwatch_log_group.logs[0].name == "/aws/bedrock/modelinvocations" && aws_cloudwatch_log_group.logs[0].retention_in_days == 14
    error_message = "Masked must create the /aws/bedrock/modelinvocations group with 14 days retention."
  }
  assert {
    condition     = length(aws_cloudwatch_log_group.findings) == 1 && aws_cloudwatch_log_group.findings[0].name == "/aws/bedrock/modelinvocations-findings"
    error_message = "Masked must create the findings group."
  }
  assert {
    condition     = length(aws_cloudwatch_log_data_protection_policy.mask) == 1 && length(aws_iam_role.writer) == 1 && length(aws_iam_role_policy.writer) == 1
    error_message = "Masked must create the masking policy and the writer role with its policy."
  }
  assert {
    condition     = length(aws_bedrock_model_invocation_logging_configuration.this) == 1 && length(time_sleep.propagation) == 1
    error_message = "Masked must turn logging on, after the propagation wait."
  }
  assert {
    condition     = length(aws_s3_bucket.logs) == 0 && length(aws_s3_bucket_policy.logs) == 0 && length(aws_s3_bucket_lifecycle_configuration.logs) == 0 && length(aws_s3_bucket_public_access_block.logs) == 0
    error_message = "Masked must not create a bucket."
  }
  assert {
    condition     = output.adopted_existing_logging == false && output.log_group == "/aws/bedrock/modelinvocations" && output.findings_log_group == "/aws/bedrock/modelinvocations-findings" && output.bucket == null
    error_message = "Masked outputs must name our log groups and no bucket."
  }
}

run "masked_logging_config_delivers_text_only_to_our_log_group" {
  command = plan

  assert {
    condition     = length(aws_bedrock_model_invocation_logging_configuration.this[0].logging_config[0].cloudwatch_config) == 1 && length(aws_bedrock_model_invocation_logging_configuration.this[0].logging_config[0].s3_config) == 0
    error_message = "Masked logging must go to CloudWatch only."
  }
  assert {
    condition     = aws_bedrock_model_invocation_logging_configuration.this[0].logging_config[0].cloudwatch_config[0].log_group_name == "/aws/bedrock/modelinvocations"
    error_message = "Masked logging must go to our log group."
  }
  assert {
    condition = (
      aws_bedrock_model_invocation_logging_configuration.this[0].logging_config[0].text_data_delivery_enabled == true &&
      aws_bedrock_model_invocation_logging_configuration.this[0].logging_config[0].image_data_delivery_enabled == false &&
      aws_bedrock_model_invocation_logging_configuration.this[0].logging_config[0].embedding_data_delivery_enabled == false &&
      aws_bedrock_model_invocation_logging_configuration.this[0].logging_config[0].video_data_delivery_enabled == false
    )
    error_message = "Logging must deliver text only, with the other kinds set to false explicitly."
  }
}

run "masking_policy_masks_and_audits_every_identifier_into_the_findings_group" {
  command = plan

  assert {
    condition     = jsondecode(aws_cloudwatch_log_data_protection_policy.mask[0].policy_document).Name == "carbonforge-mask-pii"
    error_message = "The masking policy must be named carbonforge-mask-pii."
  }
  assert {
    condition     = length(jsondecode(aws_cloudwatch_log_data_protection_policy.mask[0].policy_document).Configuration.CustomDataIdentifier) == 10
    error_message = "The masking policy must define the 10 custom identifiers."
  }
  assert {
    condition = alltrue([
      for s in jsondecode(aws_cloudwatch_log_data_protection_policy.mask[0].policy_document).Statement :
      length(s.DataIdentifier) == 38 && length([for id in s.DataIdentifier : id if startswith(id, "arn:aws:dataprotection::aws:data-identifier/")]) == 28
    ])
    error_message = "Both statements must cover the 28 managed and 10 custom identifiers."
  }
  assert {
    condition     = jsondecode(aws_cloudwatch_log_data_protection_policy.mask[0].policy_document).Statement[0].Operation.Audit.FindingsDestination.CloudWatchLogs.LogGroup == "/aws/bedrock/modelinvocations-findings"
    error_message = "The audit statement must send findings to the findings group."
  }
  assert {
    condition     = jsondecode(aws_cloudwatch_log_data_protection_policy.mask[0].policy_document).Statement[1].Operation.Deidentify.MaskConfig == {}
    error_message = "The deidentify statement must use an empty MaskConfig."
  }
}

run "writer_role_is_trusted_by_bedrock_in_this_account_only" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_role.writer[0].assume_role_policy).Statement[0].Principal.Service == "bedrock.amazonaws.com"
    error_message = "The writer role must be trusted by Bedrock."
  }
  assert {
    condition     = jsondecode(aws_iam_role.writer[0].assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "111111111111"
    error_message = "The writer role trust must be limited to this account."
  }
}

run "masked_reader_reads_our_two_groups_and_is_denied_unmask" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_role.reader.assume_role_policy).Statement[0].Principal.AWS == "arn:aws:iam::379604374207:role/CarbonForgeConnectorProd" && jsondecode(aws_iam_role.reader.assume_role_policy).Statement[0].Condition.StringEquals["sts:ExternalId"] == "cf-test-external-id"
    error_message = "The reader role must trust only the connector role, with the external ID."
  }
  assert {
    condition = toset(jsondecode(aws_iam_role_policy.reader.policy).Statement[0].Resource) == toset([
      "arn:aws:logs:us-east-1:111111111111:log-group:/aws/bedrock/modelinvocations",
      "arn:aws:logs:us-east-1:111111111111:log-group:/aws/bedrock/modelinvocations:*",
      "arn:aws:logs:us-east-1:111111111111:log-group:/aws/bedrock/modelinvocations-findings",
      "arn:aws:logs:us-east-1:111111111111:log-group:/aws/bedrock/modelinvocations-findings:*",
    ])
    error_message = "The masked reader must read our two log groups only."
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.reader.policy).Statement : s if s.Effect == "Deny" && s.Action == "logs:Unmask" && s.Resource == "*"]) == 1
    error_message = "The masked reader must be denied logs:Unmask."
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.reader.policy).Statement : s if anytrue([for a in flatten([s.Action]) : startswith(a, "s3:") || startswith(a, "ce:")])]) == 0
    error_message = "The masked reader must not read S3, nor Cost Explorer when billed_spend is false."
  }
}

run "new_customer_full_creates_bucket_logging_and_reader_and_no_log_groups" {
  command = plan

  variables {
    reading_level = "full"
  }

  # The bucket id is only known after apply; give the mock its real value so the output can be checked.
  override_resource {
    target          = aws_s3_bucket.logs[0]
    override_during = plan
    values          = { id = "carbonforge-bedrock-logs-111111111111" }
  }

  assert {
    condition     = length(aws_s3_bucket.logs) == 1 && aws_s3_bucket.logs[0].bucket == "carbonforge-bedrock-logs-111111111111"
    error_message = "Full must create the carbonforge-bedrock-logs-<account> bucket."
  }
  assert {
    condition     = length(aws_s3_bucket_public_access_block.logs) == 1 && length(aws_s3_bucket_lifecycle_configuration.logs) == 1 && length(aws_s3_bucket_policy.logs) == 1
    error_message = "Full must block public access, expire objects and let Bedrock write."
  }
  assert {
    condition     = length(aws_cloudwatch_log_group.logs) == 0 && length(aws_cloudwatch_log_group.findings) == 0 && length(aws_cloudwatch_log_data_protection_policy.mask) == 0 && length(aws_iam_role.writer) == 0
    error_message = "Full must not create log groups, a masking policy or a writer role."
  }
  assert {
    condition     = length(aws_bedrock_model_invocation_logging_configuration.this) == 1 && length(aws_bedrock_model_invocation_logging_configuration.this[0].logging_config[0].s3_config) == 1 && length(aws_bedrock_model_invocation_logging_configuration.this[0].logging_config[0].cloudwatch_config) == 0
    error_message = "Full logging must go to S3 only."
  }
  assert {
    condition     = aws_bedrock_model_invocation_logging_configuration.this[0].logging_config[0].s3_config[0].key_prefix == "bedrock"
    error_message = "Full logging must write under the bedrock prefix."
  }
  assert {
    condition     = output.bucket == "carbonforge-bedrock-logs-111111111111" && output.log_group == null && output.findings_log_group == null && output.adopted_existing_logging == false
    error_message = "Full outputs must name our bucket and no log group."
  }
}

run "full_reader_reads_our_bucket_prefix_only" {
  command = plan

  variables {
    reading_level = "full"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.reader.policy).Statement :
      s.Action == "s3:ListBucket" && s.Resource == "arn:aws:s3:::carbonforge-bedrock-logs-111111111111" && s.Condition.StringLike["s3:prefix"] == ["bedrock/*"]
    ])
    error_message = "The full reader must list our bucket under bedrock/ only."
  }
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.reader.policy).Statement :
      s.Action == "s3:GetObject" && s.Resource == "arn:aws:s3:::carbonforge-bedrock-logs-111111111111/bedrock/*"
    ])
    error_message = "The full reader must get objects under bedrock/ only."
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.reader.policy).Statement : s if anytrue([for a in flatten([s.Action]) : startswith(a, "logs:")])]) == 0
    error_message = "The full reader must not read CloudWatch Logs."
  }
}

run "billed_spend_adds_cost_explorer_to_the_reader" {
  command = plan

  variables {
    billed_spend = true
  }

  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.reader.policy).Statement : s if s.Effect == "Allow" && s.Action == "ce:GetCostAndUsage" && s.Resource == "*"]) == 1
    error_message = "billed_spend = true must allow ce:GetCostAndUsage."
  }
}

run "reapply_on_our_own_masked_logging_stays_in_create_mode" {
  command = plan

  override_data {
    target = data.external.existing_logging
    values = {
      result = {
        account     = "111111111111"
        log_group   = "/aws/bedrock/modelinvocations"
        role_arn    = "arn:aws:iam::111111111111:role/CarbonForgeBedrockLogWriter"
        bucket      = "None"
        prefix      = "None"
        text        = "True"
        masking     = "True"
        kms_key_arn = "None"
      }
    }
  }

  assert {
    condition     = output.adopted_existing_logging == false && length(aws_bedrock_model_invocation_logging_configuration.this) == 1 && length(aws_cloudwatch_log_group.logs) == 1
    error_message = "Our own logging must be managed, not adopted."
  }
}

run "reapply_on_our_own_full_logging_stays_in_create_mode" {
  command = plan

  variables {
    reading_level = "full"
  }

  override_data {
    target = data.external.existing_logging
    values = {
      result = {
        account     = "111111111111"
        log_group   = "None"
        role_arn    = "None"
        bucket      = "carbonforge-bedrock-logs-111111111111"
        prefix      = "bedrock"
        text        = "True"
        masking     = "None"
        kms_key_arn = "None"
      }
    }
  }

  assert {
    condition     = output.adopted_existing_logging == false && length(aws_bedrock_model_invocation_logging_configuration.this) == 1 && length(aws_s3_bucket.logs) == 1
    error_message = "Our own logging must be managed, not adopted."
  }
}

run "switching_our_masked_logging_to_full_stays_in_create_mode" {
  command = plan

  variables {
    reading_level = "full"
  }

  override_data {
    target = data.external.existing_logging
    values = {
      result = {
        account     = "111111111111"
        log_group   = "/aws/bedrock/modelinvocations"
        role_arn    = "arn:aws:iam::111111111111:role/CarbonForgeBedrockLogWriter"
        bucket      = "None"
        prefix      = "None"
        text        = "True"
        masking     = "True"
        kms_key_arn = "None"
      }
    }
  }

  assert {
    condition     = output.adopted_existing_logging == false && length(aws_s3_bucket.logs) == 1 && length(aws_cloudwatch_log_group.logs) == 0
    error_message = "Switching level on our own logging must move it to the other destination."
  }
}
