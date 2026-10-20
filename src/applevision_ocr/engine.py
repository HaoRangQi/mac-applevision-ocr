"""Vision OCR engine wrapper.

The engine is a small Swift binary that renders PDF pages (or reads images)
and runs Apple's Vision framework, emitting one JSON object per text line.
This module locates it and normalises its output.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

ENGINE_NAME = "ocrvision"
INSTALL_ROOT = os.path.expanduser("~/.local/share/applevision-ocr")


class EngineNotFound(RuntimeError):
    pass


def find_engine() -> str:
    """Locate the engine binary.

    Order: $APPLEVISION_OCR_ENGINE, the install root, the package's parent tree
    (source checkout), then $PATH.
    """
    env = os.environ.get("APPLEVISION_OCR_ENGINE")
    if env and os.path.isfile(env) and os.access(env, os.X_OK):
        return env

    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(INSTALL_ROOT, ENGINE_NAME),
        os.path.join(here, ENGINE_NAME),
        os.path.join(os.path.dirname(here), ENGINE_NAME),
        os.path.join(os.path.dirname(here), "bin", ENGINE_NAME),
        os.path.join(os.path.dirname(os.path.dirname(here)), "bin", ENGINE_NAME),
    ]
    for c in candidates:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c

    found = shutil.which(ENGINE_NAME)
    if found:
        return found

    raise EngineNotFound(
        "找不到识别引擎 ocrvision。\n"
        "请先运行 `make engine` 或 `make install` 编译安装。"
    )


def run(
    path: str,
    pages: str | None = None,
    scale: float = 4.5,
    rot: float = 0,
    langs: str = "zh-Hans,en-US",
    correct: bool = True,
    fast: bool = False,
) -> list[dict]:
    """Run the engine over one file and return parsed line records."""
    cmd = [
        find_engine(),
        "--input", path,
        "--scale", str(scale),
        "--rot", str(rot),
        "--lang", langs,
    ]
    if pages:
        cmd += ["--pages", pages]
    if not correct:
        cmd.append("--no-correct")
    if fast:
        cmd.append("--fast")

    proc = subprocess.run(cmd, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError(
            "引擎执行失败：\n" + proc.stderr.decode("utf-8", "ignore")[:800]
        )

    out: list[dict] = []
    for line in proc.stdout.decode("utf-8", "ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def group_pages(lines: list[dict]) -> dict[int, list[dict]]:
    """Group line records by page, ordered top-to-bottom then left-to-right."""
    pages: dict[int, list[dict]] = {}
    for line in lines:
        pages.setdefault(line["p"], []).append(line)
    for value in pages.values():
        value.sort(key=lambda item: (item["y"], item["x"]))
    return pages
