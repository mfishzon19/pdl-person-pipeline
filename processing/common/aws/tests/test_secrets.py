"""Unit tests for processing.common.aws.secrets.

boto3 is mocked at the client boundary; no live AWS.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from processing.common.aws import secrets


def _patch_client(mocker, response):
    """Patch boto3.client('secretsmanager') to return `response` from
    get_secret_value."""
    client = MagicMock()
    client.get_secret_value.return_value = response
    mocker.patch.object(secrets.boto3, "client", return_value=client)
    return client


@pytest.mark.tier1
def test_plain_string_secret(mocker):
    """A non-JSON SecretString comes back verbatim."""
    _patch_client(mocker, {"SecretString": "super-secret-value"})
    assert secrets.get_secret("some/secret") == "super-secret-value"


@pytest.mark.tier1
def test_json_secret_returns_field(mocker):
    """A JSON SecretString returns the requested field."""
    _patch_client(mocker, {"SecretString": '{"password": "pw123", "user": "etl"}'})
    assert secrets.get_secret("db/creds", "password") == "pw123"


@pytest.mark.tier1
def test_json_secret_without_field_raises(mocker):
    """JSON secret + no field is a caller error."""
    _patch_client(mocker, {"SecretString": '{"password": "pw"}'})
    with pytest.raises(ValueError, match="provide secret_field"):
        secrets.get_secret("db/creds")


@pytest.mark.tier1
def test_json_secret_missing_field_raises(mocker):
    """Asking for a field the JSON secret doesn't have raises KeyError."""
    _patch_client(mocker, {"SecretString": '{"user": "etl"}'})
    with pytest.raises(KeyError, match="password"):
        secrets.get_secret("db/creds", "password")
