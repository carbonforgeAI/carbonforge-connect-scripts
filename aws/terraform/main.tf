data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  masked     = var.reading_level == "masked"

  # Fixed names: CarbonForge Connect and its connection test look them up.
  reader_role_name   = "CarbonForgeReader"
  writer_role_name   = "CarbonForgeBedrockLogWriter"
  log_group_name     = "/aws/bedrock/modelinvocations"
  findings_group     = "/aws/bedrock/modelinvocations-findings"
  bucket_name        = "carbonforge-bedrock-logs-${local.account_id}"
  bucket_prefix      = "bedrock"
  retention_days     = 14
  writer_role_suffix = ":role/${local.writer_role_name}"
}

# ---------------------------------------------------------------------------
# Existing logging. Bedrock keeps one invocation logging configuration per
# region, and setting one replaces it. When logging is already on and is not
# this module's own, the module ADOPTS it: it changes nothing in it and only
# gives the reader role read access to its destination. When there is none, or
# it is this module's own (re-apply, level switch), the module manages it.
# It is our own only if every destination is: a CloudWatch destination needs
# both our log group and our writer role, an S3 one our bucket.
# ---------------------------------------------------------------------------

data "external" "existing_logging" {
  program = ["sh", "${path.module}/scripts/existing_logging.sh", local.region]
}

locals {
  existing      = data.external.existing_logging.result
  existing_cw   = local.existing.log_group != "None"
  existing_s3   = local.existing.bucket != "None"
  existing_ours = (!local.existing_cw || (local.existing.log_group == local.log_group_name && endswith(local.existing.role_arn, local.writer_role_suffix))) && (!local.existing_s3 || local.existing.bucket == local.bucket_name)

  adopt  = (local.existing_cw || local.existing_s3) && !local.existing_ours
  create = !local.adopt

  # What the reader reads when adopting: never the S3 copy at the masked level (it is not masked).
  adopt_reads_s3 = local.adopt && !local.masked && local.existing_s3
  their_path     = "${contains(["None", ""], local.existing.prefix) ? "" : "${local.existing.prefix}/"}AWSLogs/${local.account_id}/BedrockModelInvocationLogs/"
}

# ---------------------------------------------------------------------------
# Masked: CloudWatch log group with a data protection policy, and a second
# group that records which kind of data each mask hid (never the value).
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "logs" {
  count             = local.create && local.masked ? 1 : 0
  name              = local.log_group_name
  retention_in_days = local.retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "findings" {
  count             = local.create && local.masked ? 1 : 0
  name              = local.findings_group
  retention_in_days = local.retention_days
  tags              = var.tags
}

locals {
  data_identifiers = concat(
    [for id in local.managed_data_identifiers : "arn:aws:dataprotection::aws:data-identifier/${id}"],
    keys(local.custom_data_identifiers),
  )
}

resource "aws_cloudwatch_log_data_protection_policy" "mask" {
  count          = local.create && local.masked ? 1 : 0
  log_group_name = aws_cloudwatch_log_group.logs[0].name

  policy_document = jsonencode({
    Name    = "carbonforge-mask-pii"
    Version = "2021-06-01"
    Configuration = {
      CustomDataIdentifier = [for name, regex in local.custom_data_identifiers : { Name = name, Regex = regex }]
    }
    Statement = [
      {
        Sid            = "audit"
        DataIdentifier = local.data_identifiers
        Operation      = { Audit = { FindingsDestination = { CloudWatchLogs = { LogGroup = aws_cloudwatch_log_group.findings[0].name } } } }
      },
      {
        Sid            = "mask"
        DataIdentifier = local.data_identifiers
        Operation      = { Deidentify = { MaskConfig = {} } }
      },
    ]
  })
}

resource "aws_iam_role" "writer" {
  count = local.create && local.masked ? 1 : 0
  name  = local.writer_role_name
  tags  = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "writer" {
  count = local.create && local.masked ? 1 : 0
  name  = "WriteBedrockLogs"
  role  = aws_iam_role.writer[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.logs[0].arn}:*"
    }]
  })
}

# ---------------------------------------------------------------------------
# Full: S3 bucket, private, 14 days.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "logs" {
  count  = local.create && !local.masked ? 1 : 0
  bucket = local.bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "logs" {
  count                   = local.create && !local.masked ? 1 : 0
  bucket                  = aws_s3_bucket.logs[0].id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  count  = local.create && !local.masked ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id

  rule {
    id     = "carbonforge-14-days"
    status = "Enabled"
    filter {
      prefix = "${local.bucket_prefix}/"
    }
    expiration {
      days = local.retention_days
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  count  = local.create && !local.masked ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.logs[0].arn}/${local.bucket_prefix}/*"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.logs]
}

# ---------------------------------------------------------------------------
# Bedrock invocation logging. Bedrock validates the destination's permissions
# when the configuration is set, and a just-created role or bucket policy takes
# a few seconds to be visible to it: without the wait the first apply fails.
# The masking policy must exist before logging starts, because CloudWatch only
# masks events written after the policy.
# ---------------------------------------------------------------------------

resource "time_sleep" "propagation" {
  count           = local.create ? 1 : 0
  create_duration = "15s"
  triggers = {
    reading_level = var.reading_level
  }

  depends_on = [aws_iam_role_policy.writer, aws_s3_bucket_policy.logs, aws_cloudwatch_log_data_protection_policy.mask]
}

resource "aws_bedrock_model_invocation_logging_configuration" "this" {
  count = local.create ? 1 : 0

  logging_config {
    text_data_delivery_enabled      = true
    image_data_delivery_enabled     = false
    embedding_data_delivery_enabled = false
    video_data_delivery_enabled     = false

    dynamic "cloudwatch_config" {
      for_each = local.masked ? [1] : []
      content {
        log_group_name = aws_cloudwatch_log_group.logs[0].name
        role_arn       = aws_iam_role.writer[0].arn
      }
    }

    dynamic "s3_config" {
      for_each = local.masked ? [] : [1]
      content {
        bucket_name = aws_s3_bucket.logs[0].id
        key_prefix  = local.bucket_prefix
      }
    }
  }

  depends_on = [time_sleep.propagation]
}

# ---------------------------------------------------------------------------
# CarbonForgeReader: the only access CarbonForge gets. Read-only, assumable
# only by the CarbonForge connector role with your external ID.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "reader" {
  name = local.reader_role_name
  tags = var.tags

  lifecycle {
    precondition {
      condition     = local.existing.account == local.account_id
      error_message = "The AWS CLI is signed in to account ${local.existing.account}, but Terraform's AWS provider uses account ${local.account_id}. Use the same credentials for both (for example the same AWS_PROFILE), so the existing-logging check reads the right account."
    }
    precondition {
      condition     = !local.adopt || local.existing.text == "True"
      error_message = "Bedrock invocation logging is already on in ${local.region} but does not deliver prompt text, so there is nothing for CarbonForge to read. Your logging is left as it is."
    }
    precondition {
      condition     = !(local.adopt && local.masked) || local.existing.masking == "True"
      error_message = "Bedrock invocation logging is already on in ${local.region} and its logs are not masked by a CloudWatch data protection policy. Your logging is left as it is: set reading_level = \"full\", or contact CarbonForge."
    }
  }

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.connector_role }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "sts:ExternalId" = var.external_id } }
    }]
  })
}

locals {
  read_masked = [
    {
      Effect = "Allow"
      Action = [
        "logs:FilterLogEvents", "logs:GetLogEvents", "logs:DescribeLogStreams", "logs:GetDataProtectionPolicy",
      ]
      Resource = [
        "arn:aws:logs:${local.region}:${local.account_id}:log-group:${local.log_group_name}",
        "arn:aws:logs:${local.region}:${local.account_id}:log-group:${local.log_group_name}:*",
        "arn:aws:logs:${local.region}:${local.account_id}:log-group:${local.findings_group}",
        "arn:aws:logs:${local.region}:${local.account_id}:log-group:${local.findings_group}:*",
      ]
    },
    # CarbonForge can never see unmasked data, whatever else the role is given.
    { Effect = "Deny", Action = "logs:Unmask", Resource = "*" },
  ]

  read_full = [
    {
      Effect    = "Allow"
      Action    = "s3:ListBucket"
      Resource  = "arn:aws:s3:::${local.bucket_name}"
      Condition = { StringLike = { "s3:prefix" = ["${local.bucket_prefix}/*"] } }
    },
    {
      Effect   = "Allow"
      Action   = "s3:GetObject"
      Resource = "arn:aws:s3:::${local.bucket_name}/${local.bucket_prefix}/*"
    },
  ]

  # Adopting existing logging: read its destination as it is.
  their_log_group = "arn:aws:logs:${local.region}:${local.account_id}:log-group:${local.existing.log_group}"
  read_adopt_logs = [
    {
      Effect = "Allow"
      Action = [
        "logs:FilterLogEvents", "logs:GetLogEvents", "logs:DescribeLogStreams", "logs:GetDataProtectionPolicy",
      ]
      Resource = [local.their_log_group, "${local.their_log_group}:*"]
    },
    { Effect = "Deny", Action = "logs:Unmask", Resource = "*" },
  ]
  read_adopt_s3 = concat([
    {
      Effect    = "Allow"
      Action    = "s3:ListBucket"
      Resource  = "arn:aws:s3:::${local.existing.bucket}"
      Condition = { StringLike = { "s3:prefix" = ["${local.their_path}*"] } }
    },
    {
      Effect   = "Allow"
      Action   = "s3:GetObject"
      Resource = "arn:aws:s3:::${local.existing.bucket}/${local.their_path}*"
    },
    ], local.existing.kms_key_arn == "None" ? [] : [{
      # Your bucket's own KMS key: decrypt through S3 only.
      Effect    = "Allow"
      Action    = "kms:Decrypt"
      Resource  = local.existing.kms_key_arn
      Condition = { StringEquals = { "kms:ViaService" = "s3.${local.region}.amazonaws.com" } }
  }])

  # Usage history per model. AWS cannot limit metric reads to one namespace;
  # CarbonForge only queries AWS/Bedrock.
  read_usage = [{ Effect = "Allow", Action = ["cloudwatch:GetMetricData", "cloudwatch:ListMetrics"], Resource = "*" }]

  # Cost Explorer has no resource scoping: it covers the whole bill.
  read_spend = var.billed_spend ? [{ Effect = "Allow", Action = "ce:GetCostAndUsage", Resource = "*" }] : []

  read_logging_config = [{ Effect = "Allow", Action = "bedrock:GetModelInvocationLoggingConfiguration", Resource = "*" }]
}

resource "aws_iam_role_policy" "reader" {
  name = "CarbonForgeReadLogs"
  role = aws_iam_role.reader.id

  # Encoded per case: the read blocks have different shapes, so Terraform cannot choose between them as lists.
  policy = (
    local.adopt_reads_s3 ? jsonencode({
      Version   = "2012-10-17"
      Statement = concat(local.read_adopt_s3, local.read_usage, local.read_spend, local.read_logging_config)
      }) : local.adopt ? jsonencode({
      Version   = "2012-10-17"
      Statement = concat(local.read_adopt_logs, local.read_usage, local.read_spend, local.read_logging_config)
      }) : local.masked ? jsonencode({
      Version   = "2012-10-17"
      Statement = concat(local.read_masked, local.read_usage, local.read_spend, local.read_logging_config)
      }) : jsonencode({
      Version   = "2012-10-17"
      Statement = concat(local.read_full, local.read_usage, local.read_spend, local.read_logging_config)
    })
  )
}
