# Inputs and situations where the plan must stop, so nothing is created. Every provider is
# mocked and the existing-logging check is overridden, so no AWS call and no CLI run happens.
# The reader role carries three preconditions; each case below satisfies the other two, so
# expect_failures on the role pins the one under test.

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

run "adopting_their_unmasked_group_at_masked_stops" {
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

  expect_failures = [aws_iam_role.reader]
}

run "adopting_their_bucket_only_at_masked_stops" {
  command = plan

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
        kms_key_arn = "None"
      }
    }
  }

  expect_failures = [aws_iam_role.reader]
}

run "adopting_logging_without_text_delivery_stops" {
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
        bucket      = "their-logs"
        prefix      = "audit"
        text        = "False"
        masking     = "None"
        kms_key_arn = "None"
      }
    }
  }

  expect_failures = [aws_iam_role.reader]
}

run "cli_account_different_from_provider_account_stops" {
  command = plan

  override_data {
    target = data.external.existing_logging
    values = {
      result = {
        account     = "222222222222"
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

  expect_failures = [aws_iam_role.reader]
}

run "reading_level_other_than_masked_or_full_is_rejected" {
  command = plan

  variables {
    reading_level = "raw"
  }

  expect_failures = [var.reading_level]
}

run "connector_role_that_is_not_a_carbonforge_connector_is_rejected" {
  command = plan

  variables {
    connector_role = "arn:aws:iam::379604374207:root"
  }

  expect_failures = [var.connector_role]
}

run "connector_role_with_another_role_name_is_rejected" {
  command = plan

  variables {
    connector_role = "arn:aws:iam::379604374207:role/SomeOtherRole"
  }

  expect_failures = [var.connector_role]
}

run "empty_external_id_is_rejected" {
  command = plan

  variables {
    external_id = ""
  }

  expect_failures = [var.external_id]
}

run "external_id_with_forbidden_characters_is_rejected" {
  command = plan

  variables {
    external_id = "has spaces"
  }

  expect_failures = [var.external_id]
}

run "dev_connector_role_is_accepted" {
  command = plan

  variables {
    connector_role = "arn:aws:iam::379604374207:role/CarbonForgeConnectorDev"
  }

  assert {
    condition     = jsondecode(aws_iam_role.reader.assume_role_policy).Statement[0].Principal.AWS == "arn:aws:iam::379604374207:role/CarbonForgeConnectorDev"
    error_message = "The dev connector role must be trusted as given."
  }
}
