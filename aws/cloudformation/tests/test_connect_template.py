"""Tests for aws/cloudformation/connect.yaml, read offline.

The template is parsed and its Conditions, Rules and intrinsic functions are evaluated here for
each parameter combination, so the tests can say what a stack would create and what the reader
role would be allowed, without AWS. The expected reader policies are the Terraform module's.
"""

import json
import re
from pathlib import Path
from typing import Any

import pytest
import yaml

REPO = Path(__file__).resolve().parents[3]
TEMPLATE = REPO / "aws" / "cloudformation" / "connect.yaml"
IDENTIFIERS = REPO / "aws" / "identifiers.json"
TF_VARIABLES = REPO / "aws" / "terraform" / "variables.tf"

ACCOUNT, REGION = "111111111111", "us-east-1"
PSEUDO = {"AWS::AccountId": ACCOUNT, "AWS::Region": REGION, "AWS::Partition": "aws"}
CONNECTOR = "arn:aws:iam::379604374207:role/CarbonForgeConnectorProd"
EXTERNAL_ID = "cf-test-external-id"
NO_VALUE = object()

# ---------------------------------------------------------------------------
# A small offline evaluator: enough of CloudFormation to resolve this template.
# ---------------------------------------------------------------------------


class CfnLoader(yaml.SafeLoader):
    """YAML loader that turns CloudFormation short tags (!Ref, !Sub...) into their long form."""


def construct_tag(loader: yaml.SafeLoader, suffix: str, node: yaml.Node) -> dict[str, Any]:
    """Turn `!Name value` into `{"Fn::Name": value}` (`{"Ref": value}` for !Ref)."""
    value: Any
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node, deep=True)
    else:
        assert isinstance(node, yaml.MappingNode)
        value = loader.construct_mapping(node, deep=True)
    if suffix in ("Ref", "Condition"):
        return {suffix: value}
    if suffix == "GetAtt" and isinstance(value, str):
        value = value.split(".", 1)
    return {f"Fn::{suffix}": value}


CfnLoader.add_multi_constructor("!", construct_tag)


def load_template() -> dict[str, Any]:
    """Parse connect.yaml."""
    template: dict[str, Any] = yaml.load(TEMPLATE.read_text(encoding="utf-8"), Loader=CfnLoader)
    return template


class Stack:
    """What a stack created from the template with the given parameters would hold."""

    def __init__(self, template: dict[str, Any], params: dict[str, str]) -> None:
        """Evaluate the conditions, then resolve every resource and output that is created."""
        self.template, self.params = template, params
        self.conditions = {name: self.truth(expr) for name, expr in template["Conditions"].items()}
        self.resources = {
            name: res
            for name, res in template["Resources"].items()
            if self.conditions.get(res.get("Condition", ""), True)
        }
        self.outputs = {
            name: self.resolve(out["Value"])
            for name, out in template.get("Outputs", {}).items()
            if self.conditions.get(out.get("Condition", ""), True)
        }

    def truth(self, expr: Any) -> bool:
        """Evaluate a condition or rule expression."""
        ((fn, arg),) = expr.items()
        if fn == "Fn::Equals":
            return bool(self.resolve(arg[0]) == self.resolve(arg[1]))
        if fn == "Fn::Not":
            return not self.truth(arg[0])
        if fn == "Fn::And":
            return all(self.truth(e) for e in arg)
        if fn == "Fn::Or":
            return any(self.truth(e) for e in arg)
        if fn == "Condition":
            return self.truth(self.template["Conditions"][arg])
        raise AssertionError(f"unsupported condition function {fn}")

    def ref(self, name: str) -> Any:
        """Ref: a parameter, a pseudo parameter, or a resource's physical name."""
        if name == "AWS::NoValue":
            return NO_VALUE
        if name in self.params:
            return self.params[name]
        if name in PSEUDO:
            return PSEUDO[name]
        props = self.resolve(self.template["Resources"][name].get("Properties", {}))
        for key in ("BucketName", "LogGroupName", "RoleName"):
            if key in props:
                return props[key]
        return f"<{name}>"

    def get_att(self, name: str, attribute: str) -> str:
        """GetAtt: a role's ARN is predictable from its name; anything else is a placeholder."""
        if attribute == "Arn" and self.template["Resources"][name]["Type"] == "AWS::IAM::Role":
            return f"arn:aws:iam::{ACCOUNT}:role/{self.ref(name)}"
        return f"<{name}.{attribute}>"

    def sub(self, arg: Any) -> str:
        """Fn::Sub, with or without a variable map."""
        text, variables = (arg, {}) if isinstance(arg, str) else (arg[0], arg[1])

        def one(match: re.Match[str]) -> str:
            name = match.group(1)
            if name.startswith("!"):
                return "${" + name[1:] + "}"
            if name in variables:
                return str(self.resolve(variables[name]))
            if "." in name:
                return self.get_att(*name.split(".", 1))
            return str(self.ref(name))

        return re.sub(r"\$\{([^}]+)\}", one, text)

    def resolve(self, node: Any) -> Any:
        """Resolve intrinsic functions; AWS::NoValue removes the list item or key."""
        if isinstance(node, list):
            items = [self.resolve(n) for n in node]
            return [i for i in items if i is not NO_VALUE]
        if not isinstance(node, dict):
            return node
        if len(node) == 1:
            ((key, arg),) = node.items()
            if key == "Ref":
                return self.ref(arg)
            if key == "Fn::If":
                return self.resolve(arg[1] if self.conditions[arg[0]] else arg[2])
            if key == "Fn::Sub":
                return self.sub(arg)
            if key == "Fn::GetAtt":
                return self.get_att(arg[0], arg[1])
            if key == "Fn::Join":
                return arg[0].join(str(p) for p in self.resolve(arg[1]))
            assert not key.startswith("Fn::"), f"unsupported function {key}"
        resolved = {k: self.resolve(v) for k, v in node.items()}
        return {k: v for k, v in resolved.items() if v is not NO_VALUE}

    def rule_failures(self) -> list[str]:
        """The Rules assertions this parameter set breaks (CloudFormation refuses the stack)."""
        failures = []
        for name, rule in self.template.get("Rules", {}).items():
            if "RuleCondition" in rule and not self.truth(rule["RuleCondition"]):
                continue
            failures += [name for a in rule["Assertions"] if not self.truth(a["Assert"])]
        return failures

    def types(self) -> dict[str, str]:
        """Created resources by logical id, with their type."""
        return {name: res["Type"] for name, res in self.resources.items()}

    def properties(self, name: str) -> Any:
        """A created resource's resolved properties."""
        return self.resolve(self.resources[name].get("Properties", {}))

    def reader_statements(self) -> list[dict[str, Any]]:
        """The reader role's inline policy statements."""
        (policy,) = self.properties("ReaderRole")["Policies"]
        assert policy["PolicyName"] == "CarbonForgeReadLogs"
        statements: list[dict[str, Any]] = policy["PolicyDocument"]["Statement"]
        return statements


def stack(**overrides: str) -> Stack:
    """A stack with the required parameters, the template's defaults, and the given overrides."""
    template = load_template()
    params = {name: str(p.get("Default", "")) for name, p in template["Parameters"].items()}
    params.update(ConnectorRole=CONNECTOR, ExternalId=EXTERNAL_ID, ReadingLevel="masked")
    params.update(overrides)
    created = Stack(template, params)
    assert created.rule_failures() == [], "valid parameters must pass every rule"
    return created


# ---------------------------------------------------------------------------
# Expected policies: the same statements as the Terraform module and the runbook.
# ---------------------------------------------------------------------------

LOG_READ = [
    "logs:FilterLogEvents",
    "logs:GetLogEvents",
    "logs:DescribeLogStreams",
    "logs:GetDataProtectionPolicy",
]
DENY_UNMASK = {"Effect": "Deny", "Action": "logs:Unmask", "Resource": "*"}
USAGE = {
    "Effect": "Allow",
    "Action": ["cloudwatch:GetMetricData", "cloudwatch:ListMetrics"],
    "Resource": "*",
}
SPEND = {"Effect": "Allow", "Action": "ce:GetCostAndUsage", "Resource": "*"}
LOGGING_CONFIG = {
    "Effect": "Allow",
    "Action": "bedrock:GetModelInvocationLoggingConfiguration",
    "Resource": "*",
}
OUR_BUCKET = f"carbonforge-bedrock-logs-{ACCOUNT}"
THEIR_KEY = f"arn:aws:kms:{REGION}:{ACCOUNT}:key/their-key"


def log_group_arns(*groups: str) -> list[str]:
    """A log group's ARN and its streams' ARN, for each group."""
    arns = []
    for group in groups:
        arn = f"arn:aws:logs:{REGION}:{ACCOUNT}:log-group:{group}"
        arns += [arn, arn + ":*"]
    return arns


def bucket_read(bucket: str, path: str) -> list[dict[str, Any]]:
    """List under a path and get objects under it."""
    return [
        {
            "Effect": "Allow",
            "Action": "s3:ListBucket",
            "Resource": f"arn:aws:s3:::{bucket}",
            "Condition": {"StringLike": {"s3:prefix": [path + "*"]}},
        },
        {"Effect": "Allow", "Action": "s3:GetObject", "Resource": f"arn:aws:s3:::{bucket}/{path}*"},
    ]


def logs_read(*groups: str) -> list[dict[str, Any]]:
    """Read the given log groups, never unmasked."""
    return [
        {"Effect": "Allow", "Action": LOG_READ, "Resource": log_group_arns(*groups)},
        DENY_UNMASK,
    ]


THEIR_PATH = f"audit/AWSLogs/{ACCOUNT}/BedrockModelInvocationLogs/"

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_no_lambda_custom_resource_or_transform_anywhere() -> None:
    """No CarbonForge code runs in the customer's account: AWS resources only."""
    template = load_template()
    assert "Transform" not in template
    for name, res in template["Resources"].items():
        kind = res["Type"]
        assert not kind.startswith(("AWS::Lambda::", "Custom::", "AWS::Serverless::")), name
        assert kind != "AWS::CloudFormation::CustomResource", name
    assert "Lambda" not in TEMPLATE.read_text(encoding="utf-8")


def test_new_masked_creates_log_groups_writer_and_reader() -> None:
    """Masked, no existing logging: the CloudWatch side of the Terraform module."""
    assert stack(ReadingLevel="masked").types() == {
        "LogGroup": "AWS::Logs::LogGroup",
        "FindingsLogGroup": "AWS::Logs::LogGroup",
        "WriterRole": "AWS::IAM::Role",
        "ReaderRole": "AWS::IAM::Role",
    }


def test_new_full_creates_bucket_bucket_policy_and_reader() -> None:
    """Full, no existing logging: the S3 side of the Terraform module."""
    assert stack(ReadingLevel="full").types() == {
        "LogsBucket": "AWS::S3::Bucket",
        "LogsBucketPolicy": "AWS::S3::BucketPolicy",
        "ReaderRole": "AWS::IAM::Role",
    }


@pytest.mark.parametrize(
    "params",
    [
        {"ReadingLevel": "full", "ExistingLogging": "their-bucket", "ExistingBucket": "their-logs"},
        {"ReadingLevel": "full", "ExistingLogging": "their-log-group", "ExistingLogGroup": "/x"},
        {"ReadingLevel": "masked", "ExistingLogging": "their-log-group", "ExistingLogGroup": "/x"},
    ],
)
def test_adopting_existing_logging_creates_only_the_reader_role(params: dict[str, str]) -> None:
    """Their logging is left exactly as it is: nothing but the reader role is created."""
    assert stack(**params).types() == {"ReaderRole": "AWS::IAM::Role"}


def test_reader_trusts_only_the_connector_role_with_the_external_id() -> None:
    """The reader role is assumable by the CarbonForge connector role, with the external ID only."""
    props = stack().properties("ReaderRole")
    assert props["RoleName"] == "CarbonForgeReader"
    assert props["AssumeRolePolicyDocument"]["Statement"] == [
        {
            "Effect": "Allow",
            "Principal": {"AWS": CONNECTOR},
            "Action": "sts:AssumeRole",
            "Condition": {"StringEquals": {"sts:ExternalId": EXTERNAL_ID}},
        }
    ]


def test_masked_reader_reads_our_two_groups_never_unmasked() -> None:
    """Same statements as the Terraform module at masked."""
    assert stack(ReadingLevel="masked").reader_statements() == [
        *logs_read("/aws/bedrock/modelinvocations", "/aws/bedrock/modelinvocations-findings"),
        USAGE,
        LOGGING_CONFIG,
    ]


def test_full_reader_reads_our_bucket_prefix_only() -> None:
    """Same statements as the Terraform module at full."""
    assert stack(ReadingLevel="full").reader_statements() == [
        *bucket_read(OUR_BUCKET, "bedrock/"),
        USAGE,
        LOGGING_CONFIG,
    ]


def test_billed_spend_adds_cost_explorer_after_usage() -> None:
    """BilledSpend=true adds ce:GetCostAndUsage, and nothing else changes."""
    statements = stack(BilledSpend="true").reader_statements()
    ours = logs_read("/aws/bedrock/modelinvocations", "/aws/bedrock/modelinvocations-findings")
    assert statements == [*ours, USAGE, SPEND, LOGGING_CONFIG]


def test_adopt_their_bucket_with_kms_reads_their_bedrock_path_and_decrypts_through_s3() -> None:
    """Their bucket and prefix, plus kms:Decrypt on their key through S3 only."""
    statements = stack(
        ReadingLevel="full",
        ExistingLogging="their-bucket",
        ExistingBucket="their-logs",
        ExistingKeyPrefix="audit",
        ExistingKmsKeyArn=THEIR_KEY,
    ).reader_statements()
    assert statements == [
        *bucket_read("their-logs", THEIR_PATH),
        {
            "Effect": "Allow",
            "Action": "kms:Decrypt",
            "Resource": THEIR_KEY,
            "Condition": {"StringEquals": {"kms:ViaService": f"s3.{REGION}.amazonaws.com"}},
        },
        USAGE,
        LOGGING_CONFIG,
    ]


def test_adopt_their_bucket_without_kms_or_prefix() -> None:
    """No key: no kms permission. No prefix: the Bedrock path starts at AWSLogs/."""
    statements = stack(
        ReadingLevel="full", ExistingLogging="their-bucket", ExistingBucket="their-logs"
    ).reader_statements()
    assert statements == [
        *bucket_read("their-logs", f"AWSLogs/{ACCOUNT}/BedrockModelInvocationLogs/"),
        USAGE,
        LOGGING_CONFIG,
    ]


@pytest.mark.parametrize("level", ["masked", "full"])
def test_adopt_their_log_group_reads_it_never_unmasked(level: str) -> None:
    """Their group only, with logs:Unmask denied, at either level."""
    statements = stack(
        ReadingLevel=level, ExistingLogging="their-log-group", ExistingLogGroup="/acme/bedrock"
    ).reader_statements()
    assert statements == [*logs_read("/acme/bedrock"), USAGE, LOGGING_CONFIG]


@pytest.mark.parametrize(
    ("params", "rule"),
    [
        (
            {"ReadingLevel": "masked", "ExistingLogging": "their-bucket", "ExistingBucket": "b"},
            "MaskedAdoptsOnlyALogGroup",
        ),
        ({"ReadingLevel": "full", "ExistingLogging": "their-log-group"}, "TheirLogGroupNamed"),
        ({"ReadingLevel": "full", "ExistingLogging": "their-bucket"}, "TheirBucketNamed"),
    ],
)
def test_rules_refuse_inconsistent_parameters(params: dict[str, str], rule: str) -> None:
    """CloudFormation refuses the stack before creating anything."""
    template = load_template()
    values = {name: str(p.get("Default", "")) for name, p in template["Parameters"].items()}
    values.update(ConnectorRole=CONNECTOR, ExternalId=EXTERNAL_ID, **params)
    assert Stack(template, values).rule_failures() == [rule]


def test_parameter_validation_matches_the_terraform_module() -> None:
    """Same accepted values as the Terraform variables, so both paths take the same input."""
    params = load_template()["Parameters"]
    tf = TF_VARIABLES.read_text(encoding="utf-8")
    assert params["ReadingLevel"]["AllowedValues"] == ["masked", "full"]
    assert params["BilledSpend"]["AllowedValues"] == ["true", "false"]
    assert params["BilledSpend"]["Default"] == "false"
    assert params["ExistingLogging"]["AllowedValues"] == ["none", "their-log-group", "their-bucket"]
    assert params["ExistingLogging"]["Default"] == "none"
    assert f'regex("{params["ConnectorRole"]["AllowedPattern"]}"' in tf
    assert f'regex("{params["ExternalId"]["AllowedPattern"]}"' in tf
    assert (params["ExternalId"]["MinLength"], params["ExternalId"]["MaxLength"]) == (2, 1224)


def test_log_groups_keep_14_days_and_the_masking_policy_audits_into_findings() -> None:
    """Fixed names, 14 days, and the findings group as the audit destination."""
    created = stack(ReadingLevel="masked")
    logs, findings = created.properties("LogGroup"), created.properties("FindingsLogGroup")
    assert (logs["LogGroupName"], logs["RetentionInDays"]) == ("/aws/bedrock/modelinvocations", 14)
    assert (findings["LogGroupName"], findings["RetentionInDays"]) == (
        "/aws/bedrock/modelinvocations-findings",
        14,
    )
    policy = logs["DataProtectionPolicy"]
    assert (policy["Name"], policy["Version"]) == ("carbonforge-mask-pii", "2021-06-01")
    audit, mask = policy["Statement"]
    destination = audit["Operation"]["Audit"]["FindingsDestination"]["CloudWatchLogs"]["LogGroup"]
    assert destination == "/aws/bedrock/modelinvocations-findings"
    assert mask["Operation"] == {"Deidentify": {"MaskConfig": {}}}


def test_masking_identifiers_equal_identifiers_json() -> None:
    """The 28 managed and 10 custom identifiers, in order, character for character."""
    source = json.loads(IDENTIFIERS.read_text(encoding="utf-8"))
    policy = stack(ReadingLevel="masked").properties("LogGroup")["DataProtectionPolicy"]
    custom = [(c["Name"], c["Regex"]) for c in policy["Configuration"]["CustomDataIdentifier"]]
    assert custom == list(source["custom"].items())
    expected = [
        "arn:aws:dataprotection::aws:data-identifier/" + name for name in source["managed"]
    ] + list(source["custom"])
    assert [s["DataIdentifier"] for s in policy["Statement"]] == [expected, expected]


def test_writer_role_lets_bedrock_in_this_account_write_to_our_log_group_only() -> None:
    """Same trust and permissions as the Terraform module's writer role."""
    props = stack(ReadingLevel="masked").properties("WriterRole")
    assert props["RoleName"] == "CarbonForgeBedrockLogWriter"
    assert props["AssumeRolePolicyDocument"]["Statement"] == [
        {
            "Effect": "Allow",
            "Principal": {"Service": "bedrock.amazonaws.com"},
            "Action": "sts:AssumeRole",
            "Condition": {"StringEquals": {"aws:SourceAccount": ACCOUNT}},
        }
    ]
    (policy,) = props["Policies"]
    assert policy["PolicyName"] == "WriteBedrockLogs"
    assert policy["PolicyDocument"]["Statement"] == [
        {
            "Effect": "Allow",
            "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
            "Resource": log_group_arns("/aws/bedrock/modelinvocations")[1],
        }
    ]


def test_bucket_is_private_expires_bedrock_logs_and_lets_bedrock_write() -> None:
    """Same bucket settings as the Terraform module at full."""
    created = stack(ReadingLevel="full")
    bucket = created.properties("LogsBucket")
    assert bucket["BucketName"] == OUR_BUCKET
    assert bucket["PublicAccessBlockConfiguration"] == {
        "BlockPublicAcls": True,
        "IgnorePublicAcls": True,
        "BlockPublicPolicy": True,
        "RestrictPublicBuckets": True,
    }
    assert bucket["LifecycleConfiguration"]["Rules"] == [
        {
            "Id": "carbonforge-14-days",
            "Status": "Enabled",
            "Prefix": "bedrock/",
            "ExpirationInDays": 14,
        }
    ]
    policy = created.properties("LogsBucketPolicy")
    assert policy["Bucket"] == OUR_BUCKET
    assert policy["PolicyDocument"]["Statement"] == [
        {
            "Effect": "Allow",
            "Principal": {"Service": "bedrock.amazonaws.com"},
            "Action": "s3:PutObject",
            "Resource": f"arn:aws:s3:::{OUR_BUCKET}/bedrock/*",
            "Condition": {"StringEquals": {"aws:SourceAccount": ACCOUNT}},
        }
    ]


def logging_config(command: str) -> Any:
    """The JSON passed to --logging-config in the EnableLoggingCommand output."""
    prefix = f"aws bedrock put-model-invocation-logging-configuration --region {REGION} "
    assert command.startswith(prefix + "--logging-config '") and command.endswith("'")
    return json.loads(command[len(prefix + "--logging-config '") : -1])


TEXT_ONLY = {
    "textDataDeliveryEnabled": True,
    "imageDataDeliveryEnabled": False,
    "embeddingDataDeliveryEnabled": False,
    "videoDataDeliveryEnabled": False,
}


def test_masked_outputs_give_the_console_values_and_the_cli_command() -> None:
    """Everything needed to turn logging on to our log group with our writer role."""
    outputs = stack(ReadingLevel="masked").outputs
    writer = f"arn:aws:iam::{ACCOUNT}:role/CarbonForgeBedrockLogWriter"
    assert outputs["ReaderRoleArn"] == f"arn:aws:iam::{ACCOUNT}:role/CarbonForgeReader"
    assert outputs["Region"] == REGION
    assert outputs["LoggingDestination"] == "CloudWatch Logs only"
    assert outputs["LogGroup"] == "/aws/bedrock/modelinvocations"
    assert outputs["WriterRoleArn"] == writer
    assert "Bucket" not in outputs and "S3Location" not in outputs
    assert logging_config(outputs["EnableLoggingCommand"]) == {
        "cloudWatchConfig": {"logGroupName": "/aws/bedrock/modelinvocations", "roleArn": writer},
        **TEXT_ONLY,
    }


def test_full_outputs_give_the_console_values_and_the_cli_command() -> None:
    """Everything needed to turn logging on to our bucket under bedrock/."""
    outputs = stack(ReadingLevel="full").outputs
    assert outputs["LoggingDestination"] == "S3 only"
    assert outputs["S3Location"] == f"s3://{OUR_BUCKET}/bedrock"
    assert "LogGroup" not in outputs and "WriterRoleArn" not in outputs
    assert logging_config(outputs["EnableLoggingCommand"]) == {
        "s3Config": {"bucketName": OUR_BUCKET, "keyPrefix": "bedrock"},
        **TEXT_ONLY,
    }


def test_adopting_outputs_only_the_reader_role_and_region() -> None:
    """Nothing to turn on when adopting: their logging is already on."""
    outputs = stack(
        ReadingLevel="full", ExistingLogging="their-bucket", ExistingBucket="their-logs"
    ).outputs
    assert set(outputs) == {"ReaderRoleArn", "Region"}
