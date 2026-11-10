# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# The Revit side of PHCP.  The calculation stays in the Perl engine: this
# package walks a network, writes a .phc model, runs phcp, and reads the
# JSON back.  Nothing here solves a pipe.

EXTENSION_NAME = "PHCP"
# Written against the engine's JSON contract.  interface 2 is the one
# HardyCross::Json publishes; a different number is refused rather than
# guessed.  Interface 2 adds the calculation's acceptance: a converged solve
# is used only when it is ACCEPTED or NONCOMPLIANT (RunResult.usable).
JSON_INTERFACE = 2
