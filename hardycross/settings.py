#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# settings.py -- Python port of HardyCross/Settings.pm.
#
# The few settings that belong to a machine, not to a model: the database
# folder and the window themes.  See Settings.pm for the rationale; this
# module follows it line for line.  PHCP_SETTINGS and PHCP_DATABASE_DIR win
# over the file, exactly as in Perl.
#

import os
import re

def file():
    env = os.environ.get('PHCP_SETTINGS')
    if env:
        return env
    if os.name == 'nt':
        base = os.environ.get('APPDATA') or os.environ.get('USERPROFILE') or '.'
        return os.path.join(base, 'PHCP', 'settings.ini')
    return os.path.join(os.environ.get('HOME') or '.', '.config', 'phcp', 'settings.ini')

_LINE = re.compile(r'^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$')

def all():
    s = {}
    try:
        fh = open(file(), 'r')
    except OSError:
        return s
    with fh:
        for l in fh:
            l = re.sub(r'\r?\n$', '', l)
            if re.match(r'^\s*(#|;|$)', l):
                continue
            m = _LINE.match(l)
            if m:
                s[m.group(1).upper()] = m.group(2)
    return s

def get(key):
    return all().get(key.upper())

def set(key, value):
    key = key.upper()
    f = file()
    lines = []
    try:
        with open(f, 'r') as fh:
            lines = [re.sub(r'\r?\n$', '', l) for l in fh]
    except OSError:
        pass
    lines = [l for l in lines if not re.match(r'^\s*' + re.escape(key) + r'\s*=', l, re.I)]
    if not lines:
        lines.insert(0, '# PHCP settings - see HardyCross/Settings.pm')
    if value is not None and len(value):
        lines.append(key + '=' + value)
    d = os.path.dirname(f)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    with open(f, 'w') as out:
        for l in lines:
            out.write(l + '\n')
    return 1

def database_dir():
    d = os.environ.get('PHCP_DATABASE_DIR') or get('DATABASE_DIR')
    return d if d is not None and len(d) else None
