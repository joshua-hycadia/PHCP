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

# The file is read and written as the Perl did: bytes, whatever they are.  A
# folder name in Latin-1 (a byte that is not UTF-8) is carried through as it
# is (surrogateescape) and names the same folder; without it the read raised
# UnicodeDecodeError.  Lines end at a line feed only (newline='\n'): a lone
# carriage return is part of a value, as it is to Perl.
_IO = {'errors': 'surrogateescape'}

def _canonpath(path):
    # File::Spec::Unix->canonpath: the tidying catfile does to a path.
    path = re.sub(r'/{2,}', '/', path)                    # xx////xx  -> xx/xx
    path = re.sub(r'(?:/\.)+(?:/|\Z)', '/', path)         # xx/././xx -> xx/xx
    if path != './':
        path = re.sub(r'\A(?:\./)+', '', path)            # ./xx      -> xx
    path = re.sub(r'\A/(?:\.\./)*\.\.\Z', '/', path)      # /../..    -> /
    path = re.sub(r'\A/(?:\.\./)+', '/', path)            # /../xx    -> /xx
    if path != '/':
        path = re.sub(r'/\Z', '', path)                   # xx/       -> xx
    return path

def _catfile(*parts):
    # File::Spec->catfile.  Elsewhere than Windows it tidies the path it
    # joins (~/.config//phcp is ~/.config/phcp, HOME=. gives .config/...,
    # an empty HOME gives /.config/...), and the path is printed in a
    # message (hardycross.pipedata), so it is tidied the same way here.
    if os.name == 'nt':
        return os.path.join(*parts)
    f = _canonpath(parts[-1])
    d = _canonpath('/'.join(parts[:-1]) + '/')
    if not d.endswith('/'):
        d += '/'
    return d + f

def file():
    # A Perl truth test: PHCP_SETTINGS set to nothing, or to 0, is not set.
    env = os.environ.get('PHCP_SETTINGS')
    if env and env != '0':
        return env
    # "//" below: a variable that is set, even to nothing, is used.
    if os.name == 'nt':
        base = os.environ.get('APPDATA')
        if base is None:
            base = os.environ.get('USERPROFILE')
        if base is None:
            base = '.'
        return _catfile(base, 'PHCP', 'settings.ini')
    home = os.environ.get('HOME')
    return _catfile('.' if home is None else home, '.config', 'phcp', 'settings.ini')

# re.A: \s is the ASCII white space, as it is to Perl on the file's bytes.
# Without it a no-break space or a control character (\x1c-\x1f) at the end
# of a value was taken off it.
_BLANK = re.compile(r'^\s*(#|;|$)', re.A)
_LINE = re.compile(r'^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*\Z', re.A)
_EOL = re.compile(r'\r?\n\Z')

def all():
    s = {}
    try:
        fh = open(file(), 'r', newline='\n', **_IO)
    except OSError:
        return s
    with fh:
        for l in fh:
            l = _EOL.sub('', l)
            if _BLANK.match(l):
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
        with open(f, 'r', newline='\n', **_IO) as fh:
            lines = [_EOL.sub('', l) for l in fh]
    except OSError:
        pass
    lines = [l for l in lines if not re.match(r'^\s*' + re.escape(key) + r'\s*=', l, re.I | re.A)]
    if not lines:
        lines.insert(0, '# PHCP settings - see HardyCross/Settings.pm')
    if value is not None and len(value):
        lines.append(key + '=' + value)
    d = os.path.dirname(f)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    try:
        out = open(f, 'w', **_IO)
    except OSError as e:
        # The Perl's own words (die "cannot write the settings file ...").
        raise OSError('cannot write the settings file %s: %s\n' % (f, e.strerror)) from e
    with out:
        for l in lines:
            out.write(l + '\n')
    return 1

def database_dir():
    # "//": PHCP_DATABASE_DIR set to nothing is still set -- it means the
    # program's own database, and the file's DATABASE_DIR is not read.
    d = os.environ.get('PHCP_DATABASE_DIR')
    if d is None:
        d = get('DATABASE_DIR')
    return d if d is not None and len(d) else None
