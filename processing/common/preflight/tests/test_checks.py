"""Tier 1 unit tests for the pre-flight checks.

Mirrors the mocking style used by `processing/s3_ingester/tests/
test_finder.py`: `MagicMock()` stands in for boto3's S3 client, no
`moto`, no live AWS. Each test pins one branch of one check.

  - `_snapshot_root`: drops the last folder of a prefix.
  - `check_completed_sentinel`:
      * present -> True
      * 404 / NoSuchKey / NotFound -> False (delivery still in flight)
      * other ClientError -> re-raises (real failure, not "missing")
      * non-default `sentinel_name` is honoured
  - `list_partition_ids`:
      * returns sorted ints from `part-NNNNN.csv.gz` keys
      * ignores non-matching files (sentinel, other artefacts)
      * empty prefix -> []
      * custom `key_pattern` is honoured
  - `verify_object_encoding`:
      * gzip header -> no raise
      * missing header -> RuntimeError with the key in the message
  - `verify_content_encoding`:
      * delegates to verify_object_encoding per key, stops on first bad one
"""

from __future__ import annotations

import re
from unittest.mock import MagicMock

import pytest
from botocore.exceptions import ClientError

from processing.common.preflight import (
    check_completed_sentinel,
    checks,
    list_partition_ids,
    verify_content_encoding,
    verify_object_encoding,
)

# -----------------------------------------------------------------------------
# _snapshot_root
# -----------------------------------------------------------------------------

@pytest.mark.tier1
@pytest.mark.parametrize(
    "prefix, expected",
    [
        ("2026_04_22/data/",      "2026_04_22/"),
        ("2026_04_22/data",       "2026_04_22/"),
        ("2026_04_22/delta_data/", "2026_04_22/"),
        ("nested/deep/data/",     "nested/deep/"),
        ("data/",                 ""),
        ("",                      ""),
    ],
    ids=["trailing_slash", "no_trailing_slash", "delta_folder",
         "nested", "single_level", "empty"],
)
def test_snapshot_root(prefix, expected):
    """The sentinel sits one level above the data folder, so we drop
    the last segment from the prefix to find the delivery root."""
    assert checks._snapshot_root(prefix) == expected


# -----------------------------------------------------------------------------
# check_completed_sentinel
# -----------------------------------------------------------------------------

def _client_error(code):
    """Build a botocore ClientError with the given Error.Code shape."""
    return ClientError(
        {"Error": {"Code": code, "Message": "x"}}, "HeadObject",
    )


@pytest.mark.tier1
def test_check_completed_sentinel_present():
    """COMPLETED exists -> True. head_object hit the right key."""
    s3 = MagicMock()
    s3.head_object.return_value = {}

    assert check_completed_sentinel(s3, "b", "2026_04_22/data/") is True

    s3.head_object.assert_called_once_with(
        Bucket="b", Key="2026_04_22/COMPLETED",
    )


@pytest.mark.tier1
@pytest.mark.parametrize("code", ["404", "NoSuchKey", "NotFound"])
def test_check_completed_sentinel_missing(code):
    """Each of S3's three flavours of "object not there" maps to
    False (not raise). Otherwise we'd block on a delivery that's just
    still uploading."""
    s3 = MagicMock()
    s3.head_object.side_effect = _client_error(code)

    assert check_completed_sentinel(s3, "b", "2026_04_22/data/") is False


@pytest.mark.tier1
def test_check_completed_sentinel_other_error_bubbles():
    """403 / 500 / etc must re-raise. Pretending a real failure is
    "delivery missing" would silently skip the run."""
    s3 = MagicMock()
    s3.head_object.side_effect = _client_error("AccessDenied")

    with pytest.raises(ClientError):
        check_completed_sentinel(s3, "b", "2026_04_22/data/")


@pytest.mark.tier1
def test_check_completed_sentinel_custom_name():
    """Other sources' sentinel filename may not be `COMPLETED`. Override the
    default via the `sentinel_name` kwarg."""
    s3 = MagicMock()
    s3.head_object.return_value = {}

    check_completed_sentinel(s3, "b", "delivery_x/data/", sentinel_name="_SUCCESS")

    s3.head_object.assert_called_once_with(Bucket="b", Key="delivery_x/_SUCCESS")


# -----------------------------------------------------------------------------
# list_partition_ids
# -----------------------------------------------------------------------------

def _make_paginator(pages_by_prefix):
    """MagicMock S3 client that returns different Contents per prefix.

    Same shape used in s3_ingester/tests/test_finder.py.
    """
    s3 = MagicMock()
    paginator = MagicMock()

    def paginate(Bucket, Prefix):  # noqa: N803 (mirrors boto3 kwargs)
        return [{"Contents": pages_by_prefix.get(Prefix, [])}]

    paginator.paginate.side_effect = paginate
    s3.get_paginator.return_value = paginator
    return s3


@pytest.mark.tier1
def test_list_partition_ids_returns_sorted_ints():
    """Out-of-order S3 listing -> sorted partition ids. Sort matters
    because the loader writes partitions sequentially and operators
    eyeball logs."""
    s3 = _make_paginator({"2026_04_22/data/": [
        {"Key": "2026_04_22/data/part-00003.csv.gz"},
        {"Key": "2026_04_22/data/part-00001.csv.gz"},
        {"Key": "2026_04_22/data/part-00002.csv.gz"},
    ]})

    assert list_partition_ids(s3, "b", "2026_04_22/data/") == [1, 2, 3]


@pytest.mark.tier1
def test_list_partition_ids_ignores_non_part_files():
    """COMPLETED / _SUCCESS / random artefacts under the prefix must
    not be returned as a partition id."""
    s3 = _make_paginator({"2026_04_22/data/": [
        {"Key": "2026_04_22/data/part-00001.csv.gz"},
        {"Key": "2026_04_22/data/COMPLETED"},
        {"Key": "2026_04_22/data/_SUCCESS"},
        {"Key": "2026_04_22/data/notes.txt"},
    ]})

    assert list_partition_ids(s3, "b", "2026_04_22/data/") == [1]


@pytest.mark.tier1
def test_list_partition_ids_empty_prefix():
    """Empty listing returns []. The caller decides whether that's
    fatal (PDL: yes) or fine (delta folder may be missing)."""
    s3 = _make_paginator({"2026_04_22/data/": []})

    assert list_partition_ids(s3, "b", "2026_04_22/data/") == []


@pytest.mark.tier1
def test_list_partition_ids_custom_pattern():
    """Other sources' files may not match `part-NNNNN.csv.gz`. Caller can pass a
    different regex; group 1 is still the integer id."""
    s3 = _make_paginator({"2026_04_22/data/": [
        {"Key": "2026_04_22/data/file-007.csv.gz"},
        {"Key": "2026_04_22/data/file-002.csv.gz"},
        {"Key": "2026_04_22/data/COMPLETED"},
    ]})

    pattern = re.compile(r"^file-(\d+)\.csv\.gz$")
    assert list_partition_ids(s3, "b", "2026_04_22/data/",
                              key_pattern=pattern) == [2, 7]


# -----------------------------------------------------------------------------
# verify_object_encoding
# -----------------------------------------------------------------------------

@pytest.mark.tier1
def test_verify_object_encoding_gzip_ok():
    """Properly-tagged gzip object: no raise."""
    s3 = MagicMock()
    s3.head_object.return_value = {"ContentEncoding": "gzip"}

    verify_object_encoding(s3, "b", "2026_04_22/data/part-00001.csv.gz")


@pytest.mark.tier1
@pytest.mark.parametrize("encoding", [None, "", "identity", "deflate"])
def test_verify_object_encoding_missing_raises(encoding):
    """Anything other than 'gzip' raises. Missing the header is the
    common upstream-PDL-bug case; the others guard against junk."""
    s3 = MagicMock()
    head = {} if encoding is None else {"ContentEncoding": encoding}
    s3.head_object.return_value = head

    with pytest.raises(RuntimeError, match="Content-Encoding: gzip"):
        verify_object_encoding(s3, "b", "2026_04_22/data/part-00001.csv.gz")


@pytest.mark.tier1
def test_verify_object_encoding_message_includes_key():
    """The error message must name the offending key. Operators
    reading the failure log need to know which file to fix."""
    s3 = MagicMock()
    s3.head_object.return_value = {}

    with pytest.raises(RuntimeError, match="part-00042"):
        verify_object_encoding(s3, "my-bucket",
                               "2026_04_22/data/part-00042.csv.gz")


# -----------------------------------------------------------------------------
# verify_content_encoding
# -----------------------------------------------------------------------------

@pytest.mark.tier1
def test_verify_content_encoding_all_good():
    """All keys gzip-tagged -> head_object called once per key, no raise."""
    s3 = MagicMock()
    s3.head_object.return_value = {"ContentEncoding": "gzip"}

    keys = [
        "2026_04_22/data/part-00001.csv.gz",
        "2026_04_22/data/part-00002.csv.gz",
        "2026_04_22/data/part-00003.csv.gz",
    ]
    verify_content_encoding(s3, "b", keys)

    assert s3.head_object.call_count == 3


@pytest.mark.tier1
def test_verify_content_encoding_stops_on_first_bad_key():
    """The first bad object raises immediately. Don't keep walking;
    one bad header almost always means the whole batch is bad and
    needs operator attention."""
    s3 = MagicMock()
    s3.head_object.side_effect = [
        {"ContentEncoding": "gzip"},
        {},  # bad
        {"ContentEncoding": "gzip"},
    ]

    keys = [
        "2026_04_22/data/part-00001.csv.gz",
        "2026_04_22/data/part-00002.csv.gz",
        "2026_04_22/data/part-00003.csv.gz",
    ]

    with pytest.raises(RuntimeError, match="part-00002"):
        verify_content_encoding(s3, "b", keys)

    # Only the first two keys are HEADed before the second raises.
    assert s3.head_object.call_count == 2
