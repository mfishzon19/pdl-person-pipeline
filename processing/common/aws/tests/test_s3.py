"""Unit tests for processing.common.aws.s3.

boto3 is mocked at the client boundary; no live AWS.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import botocore.exceptions
import pytest

from processing.common.aws import (
    AccessDenied,
    AWSOpsError,
    NotFound,
    TransientError,
    get_object_bytes,
    list_keys,
)
from processing.common.aws import s3 as s3_mod


def _mock_client(mocker):
    client = MagicMock()
    mocker.patch.object(s3_mod.boto3, "client", return_value=client)
    return client


def _client_error(code: str) -> botocore.exceptions.ClientError:
    return botocore.exceptions.ClientError(
        {"Error": {"Code": code, "Message": code}}, "Op",
    )


@pytest.mark.tier1
def test_list_keys_paginates(mocker):
    client = _mock_client(mocker)
    paginator = MagicMock()
    paginator.paginate.return_value = [
        {"Contents": [{"Key": "a"}, {"Key": "b"}]},
        {"Contents": [{"Key": "c"}]},
    ]
    client.get_paginator.return_value = paginator
    assert list(list_keys("bkt", "pre/")) == ["a", "b", "c"]
    paginator.paginate.assert_called_once_with(Bucket="bkt", Prefix="pre/")


@pytest.mark.tier1
def test_list_keys_empty_page(mocker):
    client = _mock_client(mocker)
    paginator = MagicMock()
    paginator.paginate.return_value = [{}]
    client.get_paginator.return_value = paginator
    assert list(list_keys("bkt")) == []


@pytest.mark.tier1
def test_get_object_bytes_returns_body(mocker):
    client = _mock_client(mocker)
    body = MagicMock()
    body.read.return_value = b"hello"
    client.get_object.return_value = {"Body": body}
    assert get_object_bytes("bkt", "k") == b"hello"
    client.get_object.assert_called_once_with(Bucket="bkt", Key="k")


@pytest.mark.tier1
def test_no_such_key_becomes_not_found(mocker):
    client = _mock_client(mocker)
    client.get_object.side_effect = _client_error("NoSuchKey")
    with pytest.raises(NotFound):
        get_object_bytes("bkt", "missing")


@pytest.mark.tier1
def test_access_denied_translated(mocker):
    client = _mock_client(mocker)
    client.get_object.side_effect = _client_error("AccessDenied")
    with pytest.raises(AccessDenied):
        get_object_bytes("bkt", "k")


@pytest.mark.tier1
def test_throttling_translated_to_transient(mocker):
    client = _mock_client(mocker)
    client.get_object.side_effect = _client_error("Throttling")
    with pytest.raises(TransientError):
        get_object_bytes("bkt", "k")


@pytest.mark.tier1
def test_unknown_error_falls_back_to_base(mocker):
    client = _mock_client(mocker)
    client.get_object.side_effect = _client_error("SomeNewCode")
    with pytest.raises(AWSOpsError):
        get_object_bytes("bkt", "k")
