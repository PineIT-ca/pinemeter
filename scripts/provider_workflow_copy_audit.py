#!/usr/bin/env python3
"""Audit provider-specific workflow copy and unsafe diagnostics.

This script intentionally scans a fixed allowlist of source and public-doc files.
It does not traverse the repository and must not read ignored/local planning paths.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Sequence

ROOT = Path(__file__).resolve().parents[1]

SOURCE_FILES: tuple[str, ...] = (
    "Pinemeter/Models/Errors/AppError.swift",
    "Pinemeter/Models/Errors/NetworkError.swift",
    "Pinemeter/Models/SessionKey.swift",
    "Pinemeter/Views/MenuBar/UsagePopoverView.swift",
    "Pinemeter/Views/Setup/SetupWizardView.swift",
    "Pinemeter/Views/Settings/SettingsView.swift",
    "Pinemeter/Services/NetworkService.swift",
    "Pinemeter/Services/UsageService.swift",
    "Pinemeter/Services/ChatGPTUsageService.swift",
)

DOC_FILES: tuple[str, ...] = (
    "README.md",
    "site/index.html",
)

ALLOWED_FILES = SOURCE_FILES + DOC_FILES
FORBIDDEN_PARTS = {".gsd", ".git", ".planning", ".audits", "DerivedData", ".build", "node_modules"}

SECRET_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"sk-ant-[A-Za-z0-9_-]+"),
    re.compile(r"(session-[A-Za-z0-9_-]{8,})", re.IGNORECASE),
    re.compile(r"(__Secure-[^=\s]+)=([^;\s]+)", re.IGNORECASE),
    re.compile(r"(session[_-]?token\s*[:=]\s*)['\"]?[^'\";\s]+", re.IGNORECASE),
    re.compile(r"(cookie\s*[:=]\s*)['\"]?[^'\"\n]+", re.IGNORECASE),
)


@dataclass(frozen=True)
class Finding:
    category: str
    path: str
    line: int
    message: str
    evidence: str
    enforced: bool = True


def redact(text: str) -> str:
    redacted = text.strip()
    for pattern in SECRET_PATTERNS:
        def replacement(match: re.Match[str]) -> str:
            if match.lastindex and match.lastindex >= 2:
                return f"{match.group(1)}<redacted>"
            return "<redacted>"

        redacted = pattern.sub(replacement, redacted)
    redacted = re.sub(r"\s+", " ", redacted)
    return redacted[:120]


def fail(message: str) -> int:
    print(f"provider-workflow-copy-audit: {message}", file=sys.stderr)
    return 2


def checked_path(relative_path: str) -> Path:
    path = Path(relative_path)
    if path.is_absolute() or any(part in FORBIDDEN_PARTS for part in path.parts):
        raise ValueError(f"refusing disallowed path: {relative_path}")
    resolved = (ROOT / path).resolve()
    try:
        resolved.relative_to(ROOT)
    except ValueError as exc:
        raise ValueError(f"refusing path outside repository: {relative_path}") from exc
    return resolved


def read_allowlisted_files() -> dict[str, str]:
    contents: dict[str, str] = {}
    for relative_path in ALLOWED_FILES:
        path = checked_path(relative_path)
        if not path.is_file():
            raise FileNotFoundError(f"missing required file: {relative_path}")
        contents[relative_path] = path.read_text(encoding="utf-8")
    return contents


def find_lines(text: str, predicate: Callable[[str], bool]) -> Iterable[tuple[int, str]]:
    for line_number, line in enumerate(text.splitlines(), start=1):
        if predicate(line):
            yield line_number, line


def add_contains_findings(
    findings: list[Finding],
    *,
    category: str,
    files: Sequence[str],
    contents: dict[str, str],
    terms: Sequence[str],
    message: str,
    enforced: bool = True,
) -> None:
    lowered_terms = tuple(term.lower() for term in terms)
    for relative_path in files:
        text = contents[relative_path]
        for line_number, line in find_lines(text, lambda value: any(term in value.lower() for term in lowered_terms)):
            findings.append(
                Finding(
                    category=category,
                    path=relative_path,
                    line=line_number,
                    message=message,
                    evidence=redact(line),
                    enforced=enforced,
                )
            )


def audit_claude_credential_copy(contents: dict[str, str]) -> list[Finding]:
    findings: list[Finding] = []
    credential_files = (
        "Pinemeter/Models/Errors/AppError.swift",
        "Pinemeter/Models/Errors/NetworkError.swift",
        "Pinemeter/Models/SessionKey.swift",
        "Pinemeter/Views/Setup/SetupWizardView.swift",
        "Pinemeter/Views/Settings/SettingsView.swift",
        "README.md",
        "site/index.html",
    )
    stale_patterns = (
        "session key",
        "api key",
        "key is invalid",
        "key could not be validated",
        "key must start",
    )
    for relative_path in credential_files:
        text = contents[relative_path]
        for line_number, line in find_lines(text, lambda value: any(term in value.lower() for term in stale_patterns)):
            lower_line = line.lower()
            if "chatgpt" in lower_line or "claude session key" in lower_line:
                continue
            findings.append(
                Finding(
                    category="Claude credential copy",
                    path=relative_path,
                    line=line_number,
                    message="Claude credential copy should say 'Claude session key' instead of provider-ambiguous key/session-key wording.",
                    evidence=redact(line),
                )
            )
    return findings


def audit_chatgpt_copy(contents: dict[str, str]) -> list[Finding]:
    findings: list[Finding] = []
    chatgpt_files = (
        "Pinemeter/Views/MenuBar/UsagePopoverView.swift",
        "Pinemeter/Views/Settings/SettingsView.swift",
        "Pinemeter/Services/ChatGPTUsageService.swift",
        "README.md",
        "site/index.html",
    )
    required_context_terms = ("chatgpt", "openai", "session cookie", "cookie", "quota")
    generic_provider_terms = (
        "multiple providers",
        "all providers",
        "any provider",
        "provider support",
        "generic provider",
        "ai providers",
    )
    add_contains_findings(
        findings,
        category="ChatGPT copy review",
        files=chatgpt_files,
        contents=contents,
        terms=required_context_terms,
        message="Review ChatGPT copy to keep it ChatGPT-specific and avoid generic provider language.",
        enforced=False,
    )
    for relative_path in chatgpt_files:
        for line_number, line in find_lines(contents[relative_path], lambda value: "chatgpt" in value.lower() and any(term in value.lower() for term in generic_provider_terms)):
            findings.append(
                Finding(
                    category="ChatGPT copy review",
                    path=relative_path,
                    line=line_number,
                    message="ChatGPT copy should stay ChatGPT-specific instead of claiming generic provider behavior.",
                    evidence=redact(line),
                )
            )
    return findings


def audit_public_docs(contents: dict[str, str]) -> list[Finding]:
    findings: list[Finding] = []
    docs_joined = "\n".join(contents[path].lower() for path in DOC_FILES)
    mentions_chatgpt_quota = "chatgpt" in docs_joined and "quota" in docs_joined
    mentions_optional = "optional" in docs_joined
    if not (mentions_chatgpt_quota and mentions_optional):
        findings.append(
            Finding(
                category="Public docs",
                path="README.md, site/index.html",
                line=0,
                message="Public docs should mention optional ChatGPT quota visibility.",
                evidence="missing optional ChatGPT quota visibility claim",
            )
        )

    generic_provider_terms = (
        "multiple providers",
        "all providers",
        "any provider",
        "provider support",
        "generic provider",
        "ai providers",
    )
    for relative_path in DOC_FILES:
        for line_number, line in find_lines(contents[relative_path], lambda value: any(term in value.lower() for term in generic_provider_terms)):
            findings.append(
                Finding(
                    category="Public docs",
                    path=relative_path,
                    line=line_number,
                    message="Public docs should not claim generic provider support.",
                    evidence=redact(line),
                )
            )
    return findings


def audit_response_body_logging(contents: dict[str, str]) -> list[Finding]:
    findings: list[Finding] = []
    relative_path = "Pinemeter/Services/NetworkService.swift"
    text = contents[relative_path]
    risky_terms = (
        "response body",
        "responsebody",
        "bodystring",
        "string(data:",
        "response data",
        "logger.error(\"response",
    )
    for line_number, line in find_lines(text, lambda value: any(term in value.lower() for term in risky_terms)):
        findings.append(
            Finding(
                category="Network diagnostics",
                path=relative_path,
                line=line_number,
                message="NetworkService should log redacted status/endpoint/byte-count diagnostics, not full response bodies.",
                evidence=redact(line),
            )
        )
    return findings


def audit(contents: dict[str, str]) -> list[Finding]:
    findings: list[Finding] = []
    findings.extend(audit_claude_credential_copy(contents))
    findings.extend(audit_chatgpt_copy(contents))
    findings.extend(audit_public_docs(contents))
    findings.extend(audit_response_body_logging(contents))
    return findings


def print_report(findings: Sequence[Finding], *, report_only: bool) -> None:
    print("Provider workflow copy audit")
    print(f"Mode: {'report-only' if report_only else 'enforce'}")
    print(f"Files scanned: {len(ALLOWED_FILES)} fixed allowlist")
    print("")

    if not findings:
        print("No findings.")
        return

    by_category: dict[str, list[Finding]] = {}
    for finding in findings:
        by_category.setdefault(finding.category, []).append(finding)

    for category in sorted(by_category):
        category_findings = by_category[category]
        print(f"[{category}] {len(category_findings)} finding(s)")
        for finding in category_findings[:8]:
            location = finding.path if finding.line == 0 else f"{finding.path}:{finding.line}"
            advisory = " [advisory]" if not finding.enforced else ""
            print(f"- {location}{advisory}: {finding.message}")
            if finding.evidence:
                print(f"  evidence: {finding.evidence}")
        remaining = len(category_findings) - 8
        if remaining > 0:
            print(f"- ... {remaining} more")
        print("")


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Audit provider workflow copy and diagnostics.")
    parser.add_argument(
        "--report-only",
        action="store_true",
        help="Print findings but exit 0 so current known drift can be inventoried before fixes land.",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    try:
        contents = read_allowlisted_files()
    except FileNotFoundError as exc:
        return fail(str(exc))
    except OSError as exc:
        return fail(f"unable to read allowlisted files: {exc}")
    except ValueError as exc:
        return fail(str(exc))

    findings = audit(contents)
    print_report(findings, report_only=args.report_only)
    if args.report_only:
        return 0
    return 1 if any(finding.enforced for finding in findings) else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
