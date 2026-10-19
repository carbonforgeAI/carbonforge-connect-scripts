variable "reading_level" {
  description = "What CarbonForge reads: \"masked\" (prompts with personal data masked by CloudWatch) or \"full\" (prompts as logged)."
  type        = string

  validation {
    condition     = contains(["masked", "full"], var.reading_level)
    error_message = "reading_level must be \"masked\" or \"full\"."
  }
}

variable "connector_role" {
  description = "The CarbonForge connector role that may assume the reader role, as shown in CarbonForge Connect."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/CarbonForgeConnector(Prod|Dev)$", var.connector_role))
    error_message = "connector_role must be the CarbonForge connector role ARN shown in CarbonForge Connect (arn:aws:iam::<account>:role/CarbonForgeConnectorProd)."
  }
}

variable "external_id" {
  description = "Your external ID, as shown in CarbonForge Connect. The reader role can only be assumed with it."
  type        = string

  validation {
    condition     = length(var.external_id) >= 2 && length(var.external_id) <= 1224 && can(regex("^[A-Za-z0-9+=,.@:/_-]+$", var.external_id))
    error_message = "external_id must be the value shown in CarbonForge Connect (2 to 1224 characters, letters, digits and +=,.@:/_-)."
  }
}

variable "billed_spend" {
  description = "Let CarbonForge read your billed Bedrock spend with Cost Explorer. Cost Explorer access covers your whole AWS bill; CarbonForge only queries Amazon Bedrock."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}
