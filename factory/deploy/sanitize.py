#!/usr/bin/env python3
"""Sanitize and bound evidence files before they leave a worker."""

from __future__ import annotations

import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any

SENSITIVE_KEY = re.compile(r"(?:secret|token|password|api.?key|access.?key|credential|authorization|cookie)", re.I)
MODEL_AUTH_PATH = Path("/srv/factory/homes/factory-worker/.codex/auth.json")
LEGACY_MODEL_AUTH_PATH = Path("/run/factory/model-auth.json")
MAX_MODEL_AUTH_BYTES = 1024 * 1024
TOKEN_PATTERNS = [
    re.compile(r"(?i)\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,})\b"),
    re.compile(r"(?i)\b(?:xox[baprs]-[A-Za-z0-9-]{12,}|npm_[A-Za-z0-9]{12,}|pypi-[A-Za-z0-9_-]{12,})\b"),
    re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----.*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", re.S),
    re.compile(r"(?i)(https?://[^:/\s]+:)[^@/\s]+@"),
]
CREDENTIAL_ASSIGNMENT = re.compile(
    r"(?i)(\b(?:api[_-]?key|access[_-]?(?:key|token)|auth(?:orization)?|client[_-]?secret|credential|password|secret|token)\b\s*[=:]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;#]+)"
)


def scrub_text(value: str, known_values: list[str]) -> str:
    for secret in known_values:
        if len(secret) >= 8:
            value = value.replace(secret, "[REDACTED]")
    for pattern in TOKEN_PATTERNS:
        value = pattern.sub("[REDACTED]", value)
    value = CREDENTIAL_ASSIGNMENT.sub(r"\1[REDACTED]", value)
    return value


def clean(value: Any, known_values: list[str], key: str = "") -> Any:
    if SENSITIVE_KEY.search(key):
        return "[REDACTED]"
    if isinstance(value, dict):
        return {str(k): clean(v, known_values, str(k)) for k, v in value.items()}
    if isinstance(value, list):
        return [clean(item, known_values) for item in value]
    if isinstance(value, str):
        return scrub_text(value, known_values)
    return value


def find_report(raw: str) -> dict[str, Any] | None:
    decoder = json.JSONDecoder()
    candidates: list[dict[str, Any]] = []
    for match in re.finditer(r"(?m)^[ \t]*\{", raw):
        index = match.end() - 1
        try:
            value, _end = decoder.raw_decode(raw, index)
        except json.JSONDecodeError:
            continue
        if not isinstance(value, dict):
            continue
        if value.get("status") in {"complete", "blocked", "valid"} and (
            "attempts" in value or "outputs" in value or "name" in value
        ):
            candidates.append(value)
    return candidates[-1] if candidates else None


def known_env_values() -> list[str]:
    import os

    values = [
        value
        for key, value in os.environ.items()
        if re.search(r"(?:SECRET|TOKEN|PASSWORD|API.?KEY|ACCESS.?KEY|CREDENTIAL|AUTH|COOKIE)", key, re.I)
        and len(value) >= 8
    ]
    values.extend(known_model_auth_values())
    return list(dict.fromkeys(values))


def known_model_auth_values() -> list[str]:
    values: list[str] = []
    for path in (MODEL_AUTH_PATH, LEGACY_MODEL_AUTH_PATH):
        try:
            info = path.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode):
            if path == MODEL_AUTH_PATH and os.readlink(path) == str(LEGACY_MODEL_AUTH_PATH):
                continue
            raise ValueError("model auth path must be a regular file for redaction")
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0))
        with os.fdopen(fd, "rb") as handle:
            info = os.fstat(handle.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or
                    stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > MAX_MODEL_AUTH_BYTES):
                raise ValueError("model auth file has unsafe type, permissions, or size")
            payload = handle.read(MAX_MODEL_AUTH_BYTES + 1)
        if len(payload) > MAX_MODEL_AUTH_BYTES:
            raise ValueError("model auth file exceeds the size limit")
        try:
            auth = json.loads(payload)
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise ValueError("model auth file is not valid JSON") from None
        tokens = auth.get("tokens") if isinstance(auth, dict) else None
        if (not isinstance(auth, dict) or auth.get("auth_mode") != "chatgpt" or
                not isinstance(tokens, dict) or not isinstance(tokens.get("access_token"), str) or
                not isinstance(tokens.get("refresh_token"), str)):
            raise ValueError("model auth file has an unsupported shape")

        def collect(value: Any, key: str = "") -> None:
            if SENSITIVE_KEY.search(key):
                if isinstance(value, str) and len(value) >= 8:
                    values.append(value)
                elif isinstance(value, (dict, list)):
                    if isinstance(value, dict):
                        for child_key, child in value.items():
                            collect(child, str(child_key))
                    else:
                        for child in value:
                            collect(child)
            elif isinstance(value, dict):
                for child_key, child in value.items():
                    collect(child, str(child_key))
            elif isinstance(value, list):
                for child in value:
                    collect(child)

        collect(auth)
    return list(dict.fromkeys(values))


def main() -> int:
    if len(sys.argv) == 5 and sys.argv[1] == "report":
        source_path, exit_status, target_path = Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
        raw = source_path.read_bytes()[: 16 * 1024 * 1024].decode("utf-8", errors="replace")
        report = find_report(raw)
        if report is None:
            report = {"status": "runner-error", "report_parse_error": True}
        report = clean(report, known_env_values())
        report["runner_exit_status"] = int(exit_status) if exit_status.isdecimal() else None
        target_path.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        return 0

    if len(sys.argv) == 5 and sys.argv[1] == "text":
        source_path, target_path = Path(sys.argv[2]), Path(sys.argv[3])
        try:
            maximum = int(sys.argv[4])
        except ValueError:
            print("text output limit must be an integer", file=sys.stderr)
            return 2
        if maximum < 128:
            print("text output limit is too small", file=sys.stderr)
            return 2
        raw = source_path.read_bytes().decode("utf-8", errors="replace")
        cleaned = scrub_text(raw, known_env_values()).encode("utf-8")
        marker = b"\n[remaining output truncated by factory-pilot]\n"
        if len(cleaned) > maximum:
            cleaned = cleaned[: maximum - len(marker)] + marker
        target_path.write_bytes(cleaned)
        return 0

    print("usage: sanitize.py report <runner-stdout> <runner-exit-status> <output>\n"
          "       sanitize.py text <input> <output> <limit-bytes>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
