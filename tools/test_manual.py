#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_manual.py -- docs/PHC_REFERENCE.md checked against the program.
# Python port of test_manual.pl, check for check.
#
#   python3 tools/test_manual.py
#
# The manual is written by hand; this keeps it from falling behind the reader.
#
#   1. EVERYTHING DESCRIBED.  Every command and short form, option, unit and
#      unit spelling, cover-sheet field, pipe type and fitting code the program
#      knows appears in the manual.
#   2. THE EXAMPLES.  Every example line in the manual is a line the reader
#      accepts, and every complete model (a ```phc block) reads, solves and
#      converges.
#   3. PLAIN TEXT.  The manual is 7-bit ASCII.
#==============================================================================
import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

import hardycross
from hardycross import phc, editor, pipedata

_pass, _fail = 0, 0


def is_(name, ok, why=None):
    global _pass, _fail
    print('  %-68s %s' % (name, 'ok' if ok else '*** FAIL'))
    if not ok and why is not None:
        print('      %s' % why)
    if ok:
        _pass += 1
    else:
        _fail += 1


path = os.path.join(ROOT, 'docs', 'PHC_REFERENCE.md')
# Read as bytes, one character per byte, as the Perl reads it (no decoding
# layer), so the 7-bit check below sees every byte.
# Text mode in the Perl, so on Windows its CRLF is read as LF.
with open(path, 'rb') as f:
    doc = f.read()
if os.name == 'nt':
    doc = doc.replace(b'\r\n', b'\n')
doc = doc.decode('latin-1')
# Words the manual marks as code: `WORD`.
code = {w: 1 for w in re.findall(r'`([^`\s]+)`', doc)}


def missing(*words):
    m = [w for w in words if w not in code]
    return (not m, ('not in the manual: ' + ' '.join(m)) if m else None)


def has_section(c):
    return re.search(r'^### \d+\.\d+ (?:\S+, )*' + re.escape(c) + r'\b', doc, re.M)


print('1. EVERYTHING DESCRIBED')
is_('every command (%d) has its own section' % len(phc.COMMANDS),
    not [c for c in phc.COMMANDS if not has_section(c)],
    ' '.join(c for c in phc.COMMANDS if not has_section(c)))
is_('   and a row in the summary', *missing(*phc.COMMANDS))
alias = [w for w in ('P', 'U', 'N', 'W', 'CHP')
         if phc.command_spec(w) and phc.command_spec(w)['name'] != w]
is_('every short form (%s)' % ' '.join(alias), *missing(*alias))
is_('every option (%d)' % len(phc.OPTIONS), *missing(*phc.OPTIONS))
is_('every units quantity', *missing(*phc.UNIT_QUANTITIES))
is_('every unit of every quantity', *missing(*[u for v in phc.UNIT_CHOICES.values() for u in v]))
spell = {w: phc.unit_code(w) for w in ('L/MIN', 'L/S', 'M3/H', 'USGPM', 'L/MIN/KPA', 'L/MIN/BAR')}
is_('every other spelling of a unit, and what it is read as',
    missing(*spell.keys())[0]
    and not [w for w in spell
             if not re.search(r'`' + re.escape(w) + r'` \| `' + re.escape(spell[w]) + r'`', doc)])
is_('every cover-sheet field', *missing(*editor.PROJECT_FIELDS))
pipedata.load()
is_('every pipe type in the database', *missing(*pipedata.pipe_types()))
c = {}
with open(pipedata.path(), 'rb') as f:
    for l in f.read().replace(b'\r\n', b'\n').decode('latin-1').split('\n'):
        m = re.match(r'^(?:FIT\|[^|]*|KPRIME)\|([^|]+)\|', l)
        if m:
            c[m.group(1)] = 1
fits = sorted(c)
is_('every fitting code in the database (%d)' % len(fits), *missing(*fits))
is_('every fitting short form', *missing(*(list(phc.FIT_SHORT.keys()) + list(phc.FIT_SHORT.values()))))

print('2. THE EXAMPLES')
lines, models = [], []
for m in re.finditer(r'^```(\w*)\n(.*?)^```', doc, re.M | re.S):
    lang, body = m.group(1), m.group(2)
    if lang == 'phc':
        models.append(body)
        continue
    # A syntax line (<FIELD>) shows the form, not an example.
    lines += [l for l in body.split('\n') if re.search(r'\S', l) and '<' not in l]
bad = [l for l in lines if phc.analyse(l)['status'] not in ('ok', 'blank')]
is_('every example line (%d) is one the reader accepts' % len(lines), not bad,
    ' | '.join('%s -> %s' % (l, phc.analyse(l)['msg']) for l in bad))
is_('there is a complete model', len(models))
for i, body in enumerate(models):
    net, err = None, None
    try:
        net = phc.read_string(body)
    except Exception as e:
        err = e
    ok = False
    if net:
        try:
            ok = hardycross.solve_model(net)
        except Exception as e:
            err = e
    is_('   complete model %d: reads, solves and converges' % (i + 1), ok,
        'did not converge' if net else
        (err.msg if hardycross.is_model_error(err) else str(err)))

print('3. PLAIN TEXT')
dl = doc.split('\n')
is_('the manual is 7-bit ASCII', not re.search(r'[^\x0A\x20-\x7E]', doc),
    ' '.join('line %d' % n for n in range(1, len(dl) + 1) if re.search(r'[^\x20-\x7E]', dl[n - 1])))

print('\n%d passed, %d failed' % (_pass, _fail))
sys.exit(1 if _fail else 0)
