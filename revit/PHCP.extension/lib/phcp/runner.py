# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# Run the PHCP engine and read what it prints.
#
# The engine is a program, not a library (decided 28 October 2026).  This
# asks it the same way any other program does: phcp --json model.phc, and
# the exit status says whether the results may be used.  The model is
# written to a temporary file because a report path is beside that file's
# folder for SUPPLYGRAPH; standard input would lose the folder.

import json
import os
import subprocess
import tempfile

from phcp.results import ResultError, accept


class RunResult(object):
    def __init__(self, code, data, raw, model_path):
        self.code = code
        self.data = data
        self.raw = raw
        self.model_path = model_path

    @property
    def converged(self):
        return self.code == 0 and bool(self.data.get("converged"))

    @property
    def acceptance(self):
        """ACCEPTED, NONCOMPLIANT, REJECTED, INDETERMINATE or ERROR."""
        return self.data.get("acceptance") or "ERROR"

    @property
    def usable(self):
        """A valid solution: numerically and physically sound.  The design
        may still fail (NONCOMPLIANT); the summary says so."""
        return self.code == 0 and self.acceptance in ("ACCEPTED", "NONCOMPLIANT")


def run(command, text, report_path=None, cwd=None):
    """Run PHCP on the model text.

    command is the argv that starts the engine, without the model arguments:
    ["phcp.exe"], or ["perl", "phcp.pl"].  A report path, when given, is
    passed as --report and the engine writes the PDF there as well as the
    JSON this returns.

    Exit 0 is a valid solution, ACCEPTED or NONCOMPLIANT.  Exit 1 did not
    converge or its device states did not settle (INDETERMINATE): the numbers
    are returned and must not be used.  Exit 2 is a model the engine refused;
    the reason is in the JSON.  Exit 3 converged but is REJECTED: a pump
    running backwards, a reverse discharge, continuity not holding.  Its
    numbers must not be used either.
    """
    if not command:
        raise ResultError("PHCP was not found")
    folder = cwd or tempfile.gettempdir()
    fd, model_path = tempfile.mkstemp(prefix="phcp-", suffix=".phc", dir=folder)
    os.close(fd)
    try:
        try:
            with open(model_path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text if text.endswith("\n") else text + "\n")
            argv = list(command) + ["--json", model_path]
            if report_path:
                argv.extend(["--report", report_path])
            proc = subprocess.run(
                argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                cwd=folder, check=False)
        except OSError as err:
            raise ResultError("could not run PHCP: %s" % err)
        raw = proc.stdout.decode("utf-8", errors="replace")
        err = proc.stderr.decode("utf-8", errors="replace").strip()
        try:
            data = json.loads(raw) if raw.strip() else {}
        except ValueError:
            detail = err or raw.strip() or "no output"
            raise ResultError("PHCP did not return JSON (exit %s): %s" % (proc.returncode, detail))
        if not data:
            raise ResultError(err or "PHCP returned nothing (exit %s)" % proc.returncode)
        accept(data)
        return RunResult(proc.returncode, data, raw, model_path)
    finally:
        # The model was only a way to hand the text to the engine.  The
        # caller that wants a .phc of its own writes that file itself.
        try:
            os.remove(model_path)
        except OSError:
            pass


def command_for(exe):
    """argv for an engine path: a .pl is run with perl, anything else directly."""
    if not exe:
        return None
    if exe.lower().endswith(".pl"):
        return ["perl", exe]
    return [exe]


def config_path():
    """Where this machine remembers phcp.exe.

    The Perl program keeps its own settings in the same PHCP folder.  This
    file is only the path the Revit buttons use, so the two do not share a
    key and cannot overwrite each other.
    """
    base = os.environ.get("APPDATA") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "PHCP", "revit.ini")


def load_exe():
    """phcp.exe, from PHCP_EXE or from the path remembered on this machine."""
    env = os.environ.get("PHCP_EXE")
    if env and os.path.isfile(env):
        return env
    path = config_path()
    if os.path.isfile(path):
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("exe="):
                    got = line.split("=", 1)[1].strip()
                    if os.path.isfile(got):
                        return got
    return None


def save_exe(exe):
    folder = os.path.dirname(config_path())
    if not os.path.isdir(folder):
        os.makedirs(folder)
    with open(config_path(), "w", encoding="utf-8") as fh:
        fh.write("exe=%s\n" % exe)
