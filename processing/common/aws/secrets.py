"""AWS Secrets Manager helper.

One wrapper for fetching secrets so callers never build a boto3
client or parse the JSON envelope themselves.
"""

from __future__ import annotations

import base64
import json

import boto3


def get_secret(secret_name, secret_field=None, region=None, parse_json=True):
    """Fetch a secret from AWS Secrets Manager.

    Args:
      secret_name:  the secret's name or ARN.
      secret_field: when the secret is a JSON object, the field to
                    return. Required for JSON secrets, ignored for
                    plain-string secrets.
      region:       AWS region. None lets boto3 resolve it from the
                    environment / config.
      parse_json:   when True (default), parse a JSON secret and
                    return `secret_field`. When False, return the raw
                    secret string verbatim.

    Returns:
      The secret value as a string.

    Raises:
      RuntimeError: the secret has neither SecretString nor SecretBinary.
      ValueError:   the secret is JSON but no `secret_field` was given.
      KeyError:     `secret_field` is not present in the JSON secret.
    """
    client = (
        boto3.client("secretsmanager", region_name=region)
        if region
        else boto3.client("secretsmanager")
    )

    response = client.get_secret_value(SecretId=secret_name)

    if response.get("SecretString") is not None:
        raw_secret = response["SecretString"]
    elif response.get("SecretBinary") is not None:
        raw_secret = base64.b64decode(response["SecretBinary"]).decode("utf-8")
    else:
        raise RuntimeError(
            f"Secret '{secret_name}' had no SecretString or SecretBinary"
        )

    if not parse_json:
        return raw_secret

    try:
        parsed = json.loads(raw_secret)
    except json.JSONDecodeError:
        return raw_secret  # plain-string secret

    if not isinstance(parsed, dict):
        return str(parsed)

    if not secret_field:
        raise ValueError(
            f"Secret '{secret_name}' is JSON; provide secret_field"
        )
    if secret_field not in parsed:
        raise KeyError(
            f"Field '{secret_field}' not found in secret '{secret_name}'"
        )
    return str(parsed[secret_field])
