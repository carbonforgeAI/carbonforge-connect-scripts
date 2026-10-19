output "reader_role_arn" {
  description = "Paste this into CarbonForge Connect."
  value       = aws_iam_role.reader.arn
}

output "region" {
  description = "Region where Bedrock invocation logging is on."
  value       = local.region
}

output "reading_level" {
  description = "masked or full."
  value       = var.reading_level
}

output "adopted_existing_logging" {
  description = "True when Bedrock logging was already on: the module left it as it is and only gave CarbonForge read access to it."
  value       = local.adopt
}

output "log_group" {
  description = "CloudWatch log group CarbonForge reads, otherwise null."
  value = (
    local.adopt ? (local.adopt_reads_s3 ? null : local.existing.log_group) :
    local.masked ? aws_cloudwatch_log_group.logs[0].name : null
  )
}

output "findings_log_group" {
  description = "Log group recording which kind of data each mask hid (masked level, logging created by this module), otherwise null."
  value       = local.create && local.masked ? aws_cloudwatch_log_group.findings[0].name : null
}

output "bucket" {
  description = "S3 bucket CarbonForge reads, otherwise null."
  value = (
    local.adopt ? (local.adopt_reads_s3 ? local.existing.bucket : null) :
    local.masked ? null : aws_s3_bucket.logs[0].id
  )
}
