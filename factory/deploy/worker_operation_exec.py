#!/usr/bin/env python3
"""Pinned systemd unit wrapper for an invocation-bound held operation."""

import importlib.util
from pathlib import Path
import stat
import sys


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] != "--manifest":
        sys.stderr.write("factory operation held wrapper failed\n")
        return 1
    try:
        transport_path = Path(__file__).resolve(strict=True).with_name("worker_operation_transport.py")
        info = transport_path.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
                or stat.S_IMODE(info.st_mode) & 0o022):
            raise OSError("unsafe held wrapper helper")
        spec = importlib.util.spec_from_file_location("_factory_operation_transport", transport_path)
        if spec is None or spec.loader is None:
            raise OSError("held wrapper helper is unavailable")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        return module.held_wrapper_main(sys.argv[2])
    except (OSError, ImportError, ValueError):
        sys.stderr.write("factory operation held wrapper failed\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
