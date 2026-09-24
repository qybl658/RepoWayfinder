"""Shared target-project configuration rules; never load the process environment.

Syntax is owned by the pinned python-dotenv parser. The Reader adapter only records
the value tokens that parser consumes, so edits preserve every surrounding byte.
"""
from __future__ import annotations

import io
import json
import re
import sys
from typing import NamedTuple

from dotenv import parser


def sensitive_key(key: str) -> bool:
    lower = key.lower()
    if re.search(r"_(expiry_in_minutes|expires_in|expiration_time|ttl|lifetime|timeout|max_age)$", lower):
        return False
    if re.search(r"(?:^|_)(?:secret|password|pass|token)(?:_|$)", lower):
        return True
    return bool(re.search(r"(?:api_?keys?|speech_key|credentials?|auth|cookie|private_key|encryption_key)$", lower))


def value_present(value: str | None) -> bool:
    return value is not None and value.strip().lower() not in {"", "[]", "{}", "none", "null"}


def dotenv_bindings(text: str) -> list[parser.Binding]:
    return list(parser.parse_stream(io.StringIO(text)))


def key_has_value(text: str, key: str) -> bool:
    value = None
    for binding in dotenv_bindings(text):
        if not binding.error and binding.key == key:
            value = binding.value
    return value_present(value)


class LocatedBinding(NamedTuple):
    binding: parser.Binding
    value_start: int
    value_end: int
    has_equal: bool


class _LocatedReader(parser.Reader):
    """Record upstream token boundaries without another dotenv grammar."""

    def set_mark(self) -> None:
        super().set_mark()
        self.value_start = self.position.chars
        self.value_end = self.position.chars
        self.has_equal = False

    def read_regex(self, regex):
        start = self.position.chars
        result = super().read_regex(regex)
        end = self.position.chars
        if regex in (parser._single_quoted_key, parser._unquoted_key):
            self.value_start = self.value_end = end
        elif regex is parser._equal_sign:
            self.has_equal = True
            self.value_start = self.value_end = end
        elif regex in (parser._single_quoted_value, parser._double_quoted_value):
            self.value_start, self.value_end = start, end
        elif regex is parser._unquoted_value:
            # Upstream removes whitespace before a comment and trailing spaces.
            token = re.sub(r"\s+#.*", "", result[0]).rstrip()
            self.value_start, self.value_end = start, start + len(token)
        return result


def located_bindings(text: str) -> list[LocatedBinding]:
    reader = _LocatedReader(io.StringIO(text))
    offset = len(text) - len(reader.string)  # UTF-8 BOM removed by upstream Reader.
    result = []
    while reader.has_next():
        binding = parser.parse_binding(reader)
        result.append(LocatedBinding(binding, reader.value_start + offset,
                                     reader.value_end + offset, reader.has_equal))
    return result


def display_value(key: str, value: str | None) -> str | None:
    if value is None or sensitive_key(key) or len(value) > 2048:
        return None
    lower = key.lower()
    selector = lower in {"llm_provider", "video_source"}
    companion = lower.endswith(("base_url", "model_name", "speech_region", "account_id", "gateway_id", "api_version"))
    if not selector and not companion:
        return None
    if selector and not re.fullmatch(r"[A-Za-z0-9_-]{1,40}", value):
        return None
    if lower.endswith("base_url") and any(char in value for char in "@?#"):
        return None
    return value


def dotenv_metadata(text: str) -> dict:
    if len(text) > 2097152:
        raise ValueError("Configuration exceeds 2 MiB of text.")
    # PowerShell indexes UTF-16 code units rather than Python code points.
    offsets = [0]
    for char in text:
        offsets.append(offsets[-1] + (2 if ord(char) > 0xFFFF else 1))
    fields, errors = [], []
    for located in located_bindings(text):
        binding = located.binding
        if binding.error:
            errors.append(binding.original.line)
        elif binding.key is not None:
            fields.append(dict(key=binding.key, line=binding.original.line,
                               value_start=offsets[located.value_start], value_end=offsets[located.value_end],
                               has_equal=located.has_equal, has_value=value_present(binding.value),
                               sensitive=sensitive_key(binding.key), display_value=display_value(binding.key, binding.value)))
    return dict(ok=True, fields=fields, error_lines=errors)


def quote_dotenv_value(value: str) -> str:
    escapes = {"\\": "\\\\", '"': '\\"', "\a": "\\a", "\b": "\\b", "\f": "\\f",
               "\v": "\\v", "\n": "\\n", "\r": "\\r", "\t": "\\t"}
    return '"' + "".join(escapes.get(char, char) for char in value) + '"'


def replace_dotenv_values(text: str, updates: dict[str, str]) -> str:
    """Edit existing unambiguous keys; callers own atomic file replacement."""
    located = located_bindings(text)
    if any(item.binding.error for item in located):
        raise ValueError("Malformed project configuration; nothing was saved.")
    edits = []
    for key, value in updates.items():
        matches = [item for item in located if item.binding.key == key]
        if len(matches) != 1:
            raise ValueError("Unknown or ambiguous project configuration field.")
        item = matches[0]
        encoded = quote_dotenv_value(value)
        edits.append((item.value_start, item.value_end, encoded if item.has_equal else " = " + encoded))
    for start, end, value in sorted(edits, reverse=True):
        text = text[:start] + value + text[end:]
    return text


def _main() -> int:
    try:
        if sys.argv[1:] != ["metadata"]:
            raise ValueError("Unknown configuration operation.")
        raw = sys.stdin.buffer.read(16777217)
        if len(raw) > 16777216:
            raise ValueError("Configuration payload exceeds the limit.")
        # Windows PowerShell's redirected writer may prepend a UTF-8 BOM.
        # Strip only the transport BOM; a BOM inside the JSON string is data.
        text = json.loads(raw.decode("utf-8-sig"))
        if not isinstance(text, str):
            raise ValueError("Configuration text is required.")
        result = dotenv_metadata(text)
    except Exception:
        # Input text, decoded secrets and tracebacks never enter metadata output.
        sys.stdout.write('{"ok":false,"error":"Unable to read project configuration."}\n')
        return 1
    sys.stdout.buffer.write((json.dumps(result, ensure_ascii=True) + "\n").encode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
