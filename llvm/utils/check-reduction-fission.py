#!/usr/bin/env python3
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Compatibility command for the independent scalar-fission execution checker."""

from pathlib import Path
import runpy
import sys


if __name__ == "__main__":
    print("check-reduction-fission.py: migrated to check-scalar-fission.py; "
          "use --build-dir and --work-dir", file=sys.stderr)
    runpy.run_path(str(Path(__file__).with_name("check-scalar-fission.py")),
                   run_name="__main__")
