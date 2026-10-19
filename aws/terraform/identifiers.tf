# Generated from connectors/cloud_setup.md (AWS step 2). Keep identical: the page and this module
# must mask the same way. Regenerate rather than edit by hand.

locals {
  managed_data_identifiers = [
    "Name",
    "EmailAddress",
    "PhoneNumber-US",
    "PhoneNumber-FR",
    "PhoneNumber-GB",
    "Address",
    "ZipCode-US",
    "DateOfBirth",
    "LatLong",
    "Ssn-US",
    "InseeCode-FR",
    "PassportNumber-US",
    "PassportNumber-FR",
    "DriversLicense-US",
    "TaxId-FR",
    "IndividualTaxIdentificationNumber-US",
    "CreditCardNumber",
    "CreditCardExpiration",
    "CreditCardSecurityCode",
    "BankAccountNumber-FR",
    "BankAccountNumber-US",
    "IpAddress",
    "VehicleIdentificationNumber",
    "AwsSecretKey",
    "OpenSshPrivateKey",
    "PgpPrivateKey",
    "PkcsPrivateKey",
    "PuttyPrivateKey",
  ]

  # AWS allows at most 10 custom data identifiers per policy.
  custom_data_identifiers = {
    CarbonForgeIntlPhone  = "\\+\\d{1,3}(?:[ .-]?\\d{1,4}){2,5}"
    CarbonForgeCardGroups = "\\b\\d{4}[ -]\\d{4}[ -]\\d{4}[ -]\\d{1,7}\\b"
    CarbonForgeCardDigits = "\\b\\d{13,19}\\b"
    CarbonForgeFrPhone    = "\\b0[1-9](?:[ .-]?\\d{2}){4}\\b"
    CarbonForgeIban       = "\\b[A-Z]{2}\\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,3})?\\b"
    CarbonForgeLatLong    = "-?\\d{1,2}\\.\\d{4,}, ?-?\\d{1,3}\\.\\d{4,}"
    CarbonForgeFrNir      = "\\b[12] ?\\d{2} ?\\d{2} ?(?:\\d{2}|2A|2B) ?\\d{3} ?\\d{3} ?\\d{2}\\b"
    CarbonForgeMac        = "\\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\\b"
    CarbonForgeApiKey     = "\\b(?:sk|pk|rk)-[A-Za-z0-9_-]{20,}"
    CarbonForgePrivateKey = "-----BEGIN [A-Z ]{0,20}PRIVATE KEY-----[A-Za-z0-9+/=\\\\ ]{20,}"
  }
}
