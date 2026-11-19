#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# check_lisp.py -- structural checks on the AutoCAD exporter, without AutoCAD.
# Python port of check_lisp.pl, check for check.
#
#   python3 tools/check_lisp.py [autocad/phcp_export.lsp]
#
# No AutoLISP interpreter runs here, so the exporter cannot be executed until
# it is loaded in AutoCAD.  What can be checked is checked: the file is read
# as the Lisp reader reads it -- strings ("..." with \ escapes) and comments
# (; to the end of the line) skipped -- and
#   - every bracket is matched, and no top-level form is left open;
#   - every phcp:... function called is defined (a typo in a helper's name is
#     otherwise found only when that line runs in AutoCAD);
#   - every command c:... named in the load message exists.
#==============================================================================
import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))


def main():
    file = sys.argv[1] if len(sys.argv) > 1 else os.path.join(TOOLS, '..', 'autocad', 'phcp_export.lsp')
    try:
        # One character per byte, as the Perl reads it (no decoding layer).
        # Text mode in the Perl, so on Windows its CRLF is read as LF.
        with open(file, 'rb') as fh:
            src = fh.read()
        if os.name == 'nt':
            src = src.replace(b'\r\n', b'\n')
        src = src.decode('latin-1')
    except OSError as e:
        sys.exit('%s: %s' % (file, e.strerror))

    # The code with strings and comments blanked out, so brackets and names
    # are seen as the reader sees them.  Line breaks are kept for the line
    # numbers.
    code = []
    strings = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == ';':
            e = src.find('\n', i)
            i = n if e < 0 else e
            continue
        if c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == '\\' else 1
            strings.append(src[i + 1:j])
            code.append('""')
            code.append('\n' * src[i:j + 1].count('\n'))
            i = j + 1
            continue
        code.append(c)
        i += 1
    code = ''.join(code)

    count = {'pass': 0, 'fail': 0}

    def is_(name, ok, why=None):
        print('  %-66s %s' % (name, 'ok' if ok else '*** FAIL'))
        if not ok and why is not None:
            print('      %s' % why)
        count['pass' if ok else 'fail'] += 1

    # Brackets.
    depth, line, bad = 0, 1, ''
    for ch in code:
        if ch == '\n':
            line += 1
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth < 0 and not bad:
                bad = 'a ) with nothing open, line %d' % line
    is_('every bracket matched', not bad and depth == 0, bad or '%d left open at the end' % depth)

    # Functions.
    defs = {d.lower(): 1 for d in re.findall(r'\(defun\s+([^\s()]+)', code, re.I)}
    called = {}
    for m in re.findall(r'\(\s*(phcp:[A-Za-z0-9\-]+)', code):
        called[m.lower()] = called.get(m.lower(), 0) + 1
    # 'phcp:x quoted as a function argument, as in (mapcar 'phcp:x ...)
    for m in re.findall(r"'(phcp:[A-Za-z0-9\-]+)", code):
        called[m.lower()] = called.get(m.lower(), 0) + 1
    undef = [f for f in sorted(called) if f not in defs]
    is_('every phcp: function called is defined (%d called)' % len(called), not undef, ' '.join(undef))
    unused = [f for f in sorted(defs) if f not in called and not f.startswith('c:')]
    is_('every phcp: function defined is used', not unused, ' '.join(unused))

    # Commands named in the load message.
    msg = ([s for s in strings if 'Commands:' in s] or [None])[0]
    cmds = re.findall(r'\b(PHCP[A-Z]+)\b', msg) if msg else []
    missing = [c for c in cmds if ('c:' + c).lower() not in defs]
    is_('the %d commands in the load message all exist' % len(cmds), cmds and not missing,
        ' '.join(missing))

    # The model it writes is .phc: no .hcx section words remain.  (Perl's $
    # also matches before a final newline, hence \n?\Z.)
    hcx = [s for s in strings
           if re.match(r'^(NODES|PIPES|SUPPLIES|DISCHARGES|END|OPTIONS)\n?\Z', s)
           or re.search(r'TYPE=|FIT=|\bK=', s)]
    is_('it writes .phc, not .hcx (no .hcx block words or KEY= fields)', not hcx, ' | '.join(hcx))

    print('\n%d passed, %d failed' % (count['pass'], count['fail']))
    sys.exit(1 if count['fail'] else 0)


if __name__ == '__main__':
    main()
