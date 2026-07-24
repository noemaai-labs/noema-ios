#!/usr/bin/env python3
"""Generate runtime support documentation from Swift source."""

from __future__ import annotations

import argparse
import difflib
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOMAIN_MODELS = ROOT / "Noema" / "DomainModels.swift"
MODEL_SETTINGS = ROOT / "Noema" / "ModelSettings.swift"
MODEL_SETTINGS_VIEW = ROOT / "Noema" / "ModelSettingsView.swift"
OUTPUT = ROOT / "docs" / "RuntimeSupport.md"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def extract_braced_block(source: str, marker: str) -> str:
    start = source.find(marker)
    if start == -1:
        raise ValueError(f"Unable to find marker: {marker}")
    brace = source.find("{", start)
    if brace == -1:
        raise ValueError(f"Unable to find opening brace for: {marker}")
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise ValueError(f"Unable to find closing brace for: {marker}")


def parse_model_formats(source: str) -> list[dict[str, str]]:
    block = extract_braced_block(source, "public enum ModelFormat")
    formats: list[dict[str, str]] = []
    for match in re.finditer(r"case\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\"([^\"]+)\"", block):
        case = match.group(1)
        raw = match.group(2)
        display = "CML" if case == "ane" else raw
        formats.append({"case": case, "raw": raw, "display": display})
    return formats


def parse_enum_cases(source: str, enum_marker: str) -> list[dict[str, str]]:
    block = extract_braced_block(source, enum_marker)
    cases: list[dict[str, str]] = []
    for match in re.finditer(r"case\s+`?([A-Za-z_][A-Za-z0-9_]*)`?(?:\s*=\s*\"([^\"]+)\")?", block):
        name = match.group(1)
        raw = match.group(2) or name
        cases.append({"case": name, "raw": raw})
    return cases


def swift_label(name: str) -> str:
    pieces = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", name).replace("_", " ").split()
    return " ".join(piece[:1].upper() + piece[1:] for piece in pieces)


def parse_switch_returns(block: str, var_name: str) -> dict[str, str]:
    marker = f"var {var_name}:"
    try:
        var_block = extract_braced_block(block, marker)
    except ValueError:
        return {}
    results: dict[str, str] = {}
    for match in re.finditer(r"case\s+\.([A-Za-z_][A-Za-z0-9_]*):\s*return\s+\"([^\"]+)\"", var_block):
        results[match.group(1)] = match.group(2)
    return results


def parse_runtime_presets(source: str) -> list[dict[str, str]]:
    enum_block = extract_braced_block(source, "private enum ModelRuntimePreset")
    case_names = [match.group(1) for match in re.finditer(r"case\s+([A-Za-z_][A-Za-z0-9_]*)", enum_block)]
    titles = parse_switch_returns(enum_block, "titleKey")
    subtitles = parse_switch_returns(enum_block, "subtitleKey")
    icons = parse_switch_returns(enum_block, "systemImage")
    availability = parse_preset_availability(source)
    return [
        {
            "case": name,
            "title": titles.get(name, swift_label(name)),
            "subtitle": subtitles.get(name, ""),
            "icon": icons.get(name, ""),
            "availability": availability.get(name, "All formats"),
        }
        for name in case_names
    ]


def parse_preset_availability(source: str) -> dict[str, str]:
    try:
        block = extract_braced_block(source, "private var runtimePresets")
    except ValueError:
        return {}
    availability: dict[str, str] = {}
    for match in re.finditer(r"case\s+([^:]+):\s*return\s+([^\n]+)", block):
        condition = match.group(2).strip()
        cases = re.findall(r"\.([A-Za-z_][A-Za-z0-9_]*)", match.group(1))
        for case in cases:
            availability[case] = describe_condition(condition)
    return availability


def describe_condition(condition: str) -> str:
    replacements = {
        "model.isMultimodal || model.format == .gguf": "Multimodal models or GGUF",
        "model.format != .ane": "All formats except CML",
        "true": "All formats",
        "false": "Unavailable",
    }
    return replacements.get(condition, f"`{condition}`")


def parse_model_settings(source: str) -> list[dict[str, str]]:
    block = extract_braced_block(source, "struct ModelSettings")
    settings: list[dict[str, str]] = []
    pending_comment: list[str] = []
    for line in block.splitlines():
        stripped = line.strip()
        if stripped.startswith("///"):
            pending_comment.append(stripped.removeprefix("///").strip())
            continue
        if stripped.startswith("//"):
            pending_comment.append(stripped.removeprefix("//").strip())
            continue
        match = re.match(
            r"var\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^=\n]+?)(?:\s*=\s*(.+?))?$",
            stripped,
        )
        if match:
            default = clean_swift_default(match.group(3))
            settings.append(
                {
                    "name": match.group(1),
                    "type": match.group(2).strip(),
                    "default": default,
                    "note": " ".join(pending_comment),
                }
            )
            pending_comment = []
        elif stripped:
            pending_comment = []
    return settings


def clean_swift_default(value: str | None) -> str:
    if value is None:
        return "`nil`"
    cleaned = value.strip()
    if cleaned.endswith(","):
        cleaned = cleaned[:-1]
    return f"`{cleaned}`"


def parse_default_overrides(source: str) -> dict[str, list[str]]:
    try:
        block = extract_braced_block(source, "static func `default`(for format: ModelFormat)")
    except ValueError:
        return {}
    switch_start = block.find("switch format")
    if switch_start == -1:
        return {}
    switch_block = extract_braced_block(block[switch_start:], "switch format")
    overrides: dict[str, list[str]] = {}
    current: str | None = None
    for line in switch_block.splitlines():
        stripped = line.strip()
        case_match = re.match(r"case\s+\.([A-Za-z_][A-Za-z0-9_]*):", stripped)
        if case_match:
            current = case_match.group(1)
            overrides.setdefault(current, [])
            continue
        assignment = re.match(r"s\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)", stripped)
        if current and assignment:
            overrides[current].append(f"`{assignment.group(1)} = {assignment.group(2).strip()}`")
    return overrides


def parse_preset_effects(source: str) -> dict[str, list[str]]:
    try:
        block = extract_braced_block(source, "func applyRuntimePreset")
    except ValueError:
        return {}
    switch_start = block.find("switch preset")
    if switch_start == -1:
        return {}
    switch_block = extract_braced_block(block[switch_start:], "switch preset")
    effects: dict[str, list[str]] = {}
    current: str | None = None
    for line in switch_block.splitlines():
        stripped = line.strip()
        case_match = re.match(r"case\s+\.([A-Za-z_][A-Za-z0-9_]*):", stripped)
        if case_match:
            current = case_match.group(1)
            effects.setdefault(current, [])
            continue
        assignment = re.match(r"settings\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)", stripped)
        if current and assignment:
            value = assignment.group(2).strip()
            if value.endswith("{"):
                continue
            effects[current].append(f"`{assignment.group(1)} = {value}`")
    return effects


def md_table(headers: list[str], rows: list[list[str]]) -> list[str]:
    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(escape_md(cell) for cell in row) + " |")
    return lines


def escape_md(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", "<br>")


def bullet_join(values: list[str]) -> str:
    if not values:
        return "Base defaults"
    return "<br>".join(values)


def render() -> str:
    domain = read(DOMAIN_MODELS)
    settings_source = read(MODEL_SETTINGS)
    settings_view_source = read(MODEL_SETTINGS_VIEW)

    formats = parse_model_formats(domain)
    settings = parse_model_settings(settings_source)
    default_overrides = parse_default_overrides(settings_source)
    cache_quant = parse_enum_cases(settings_source, "enum CacheQuant")
    et_backends = parse_enum_cases(domain, "public enum ETBackend")
    processing_units = parse_enum_cases(settings_source, "enum ProcessingUnitConfiguration")
    guardrails = parse_enum_cases(settings_source, "enum AFMGuardrailsMode")
    system_prompt_modes = parse_enum_cases(settings_source, "enum SystemPromptMode")
    presets = parse_runtime_presets(settings_view_source)
    preset_effects = parse_preset_effects(settings_view_source)

    lines: list[str] = [
        "<!-- Generated by scripts/generate-runtime-docs.py. Do not edit by hand. -->",
        "",
        "# Runtime Support",
        "",
        "This document is generated from Swift source so supported model formats, persisted runtime settings, and UI runtime presets stay aligned with the app.",
        "",
        "Sources:",
        "",
        "- `Noema/DomainModels.swift`",
        "- `Noema/ModelSettings.swift`",
        "- `Noema/ModelSettingsView.swift`",
        "",
        "## Supported Model Formats",
        "",
    ]
    lines.extend(
        md_table(
            ["Case", "Raw value", "Display name", "Default overrides"],
            [
                [
                    f"`.{fmt['case']}`",
                    f"`{fmt['raw']}`",
                    fmt["display"],
                    bullet_join(default_overrides.get(fmt["case"], [])),
                ]
                for fmt in formats
            ],
        )
    )
    lines.extend(
        [
            "",
            "Compatibility aliases are handled by `ModelFormat.compatibleRawValue`; `APPLE` and `CML` map to `.ane`.",
            "",
            "## Runtime Setting Enums",
            "",
        ]
    )
    lines.extend(
        md_table(
            ["Enum", "Cases"],
            [
                ["`CacheQuant`", ", ".join(f"`{item['raw']}`" for item in cache_quant)],
                ["`ETBackend`", ", ".join(f"`{item['raw']}`" for item in et_backends)],
                ["`ProcessingUnitConfiguration`", ", ".join(f"`{item['case']}`" for item in processing_units)],
                ["`AFMGuardrailsMode`", ", ".join(f"`{item['case']}`" for item in guardrails)],
                ["`SystemPromptMode`", ", ".join(f"`{item['case']}`" for item in system_prompt_modes)],
            ],
        )
    )
    lines.extend(
        [
            "",
            "## Persisted Model Settings",
            "",
        ]
    )
    lines.extend(
        md_table(
            ["Setting", "Type", "Default", "Source note"],
            [
                [
                    f"`{setting['name']}`",
                    f"`{setting['type']}`",
                    setting["default"],
                    setting["note"] or "",
                ]
                for setting in settings
            ],
        )
    )
    lines.extend(
        [
            "",
            "## Runtime Presets",
            "",
        ]
    )
    lines.extend(
        md_table(
            ["Preset", "Subtitle", "Icon", "Availability"],
            [
                [
                    f"`{preset['case']}` / {preset['title']}",
                    preset["subtitle"],
                    f"`{preset['icon']}`",
                    preset["availability"],
                ]
                for preset in presets
            ],
        )
    )
    lines.extend(
        [
            "",
            "## Runtime Preset Effects",
            "",
        ]
    )
    lines.extend(
        md_table(
            ["Preset", "Settings touched"],
            [
                [
                    f"`{preset['case']}`",
                    bullet_join(preset_effects.get(preset["case"], [])),
                ]
                for preset in presets
            ],
        )
    )
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if the generated file is not current")
    args = parser.parse_args()

    generated = render()
    if args.check:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if current != generated:
            diff = difflib.unified_diff(
                current.splitlines(keepends=True),
                generated.splitlines(keepends=True),
                fromfile=str(OUTPUT),
                tofile="generated",
            )
            sys.stderr.writelines(diff)
            return 1
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(generated, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
