#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_isometric.py -- the isometric drawing (hardycross.isometric),
# headless: a port of tools/test_isometric.pl.
#
#   python3 tools/test_isometric.py
#
# The drawing writes .phc.  What it must prove:
#
#   1. A grid point drawn and picked again is the same point.
#   2. A length converted to the model's unit reads back as the same
#      metres.
#   3. Placing a supply, a sprinkler and a pipe writes a model that
#      solves, and a pipe that is not on one axis is refused.
#   4. Moving a point sets the pipe's length from the grid.  A length
#      already typed is left alone until then.  A comment, an //AS
#      note and an AREA line survive, and renaming a point renames it
#      in the AREA line.
#   5. Every example but the 1000-node grid, written back from the
#      drawing, solves to the same pipe flows and node pressures.  A
#      copy keeps the source's original when the source is changed.
#      Writing twice is the same text, and //ISO positions are kept.
#==============================================================================

import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from hardycross import GAMMA_W, solve_model
from hardycross import editor
from hardycross import isometric
from hardycross import phc

PASS = [0]
FAIL = [0]
EX = os.path.join(os.path.dirname(__file__), '..', 'examples')


def is_(name, ok, why=None):
    print('  %-68s %s' % (name, 'ok' if ok else '*** FAIL'))
    if not ok and why is not None:
        print('      %s' % (why,))
    if ok:
        PASS[0] += 1
    else:
        FAIL[0] += 1


def slurp(p):
    with open(p, 'r') as f:
        return f.read()


def units():
    u = dict(phc.UNIT_DEFAULT)
    u['LENGTH'] = 'M'
    u['ELEVATION'] = 'M'
    return u


def draw_of(text, u=None):
    return isometric.read_network(text, u or units())


# flows and gauge pressures, as test_phc.py reads them.
def results(text):
    try:
        net = phc.read_string(text)
    except Exception as e:
        return (None, getattr(e, 'msg', None) or str(e))
    try:
        solve_model(net)
    except Exception as e:
        return (None, getattr(e, 'msg', None) or str(e))
    q = {}
    p = {}
    for el in net['elems'][1:]:
        if (el.get('kind') or '') == 'PIPE':
            q[el['id']] = el['q']
    for n in net['nodes'][1:]:
        if n['id'] != 'REF':
            p[n['id']] = n['h'] - GAMMA_W * n['z']
    return (q, p)


def worst(a, b):
    w = 0.0
    for k in a:
        if k not in b:
            return (1e30, k)
        d = abs(a[k] - b[k])
        if d > w:
            w = d
    return (w, '')


#==============================================================================
print('1. THE GRID')
#==============================================================================
v = {'ox': 12.5, 'oy': -7, 'scale': 17}
bad = 0
for ix in range(-4, 5):
    for iy in range(-4, 5):
        for iz in (-2, 0, 2.5, 4.5):
            (x, y) = isometric.project(ix, iy, iz, v)
            (a, b, c) = isometric.cell_at(x, y, v, iz)
            if a != ix or b != iy or abs(c - iz) > 1e-9:
                bad += 1
is_('a point drawn and picked again is the same point, including a '
    'fractional height', not bad, '%d missed' % bad)
d = draw_of('NODE A 0\nNODE B 0\nPIPE P1 A B 4 25\n')
# Give them a known picture so the hit is not the auto layout's.
isometric.move_node(d, 'A', 0, 0, 0)
isometric.move_node(d, 'B', 4, 0, 0)
(x, y) = isometric.project(4, 0, 0, v)
h = isometric.hit(d, x, y, v)
is_('a click on a point hits that point',
    h and h['kind'] == 'node' and h['name'] == 'B',
    '%s %s' % (h['kind'], h['name']) if h else 'nothing')
(fx, fy) = isometric.project(40, 40, 0, v)
is_('a click on empty grid hits nothing', not isometric.hit(d, fx, fy, v))

#==============================================================================
print('1b. LOCKED, THE PIPES ARE STRAIGHT')
#==============================================================================
v = {'ox': 40, 'oy': 80, 'scale': 36, 'lock': 1}
bad = 0
for ix in range(-3, 4):
    for iy in range(-3, 4):
        for iz in (-1, 0, 2.5):
            (x, y) = isometric.project(ix, iy, iz, v)
            (a, b, c) = isometric.cell_at(x, y, v, iz)
            if a != ix or b != iy or abs(c - iz) > 1e-9:
                bad += 1
is_('a locked point drawn and picked again is the same point', not bad,
    '%d missed' % bad)
(x0, y0) = isometric.project(0, 0, 0, v)
(x4, y4) = isometric.project(4, 0, 0, v)
(x9, y9) = isometric.project(9, 0, 0, v)
s4 = (y4 - y0) / (x4 - x0)
s9 = (y9 - y0) / (x9 - x0)
is_('two locked pipes on one axis are the same straight slope, in whole '
    'pixels',
    abs(s4 - s9) < 1e-9 and x4 != x0 and
    abs((x4 - x0) - int(x4 - x0)) < 1e-9 and
    abs((y4 - y0) - int(y4 - y0)) < 1e-9,
    'slope %s %s dx %s' % (s4, s9, x4 - x0))
run = isometric.axis_run(0, 0, 0, 3, 2, 1)
legs = 0
for i in range(len(run) - 1):
    (a, b) = (run[i], run[i + 1])
    changed = ((1 if abs(a[0] - b[0]) > 1e-9 else 0) +
               (1 if abs(a[1] - b[1]) > 1e-9 else 0) +
               (1 if abs(a[2] - b[2]) > 1e-6 else 0))
    if changed == 1:
        legs += 1
is_('a locked pipe that is not on one axis is drawn as straight legs, '
    'one axis each', len(run) == 4 and legs == 3,
    '%d points, %d legs' % (len(run), legs))
d = draw_of('NODE A 0\nNODE B 0\nPIPE P1 A B 1 25\n')
isometric.move_node(d, 'A', 0, 0, 0)
isometric.move_node(d, 'B', 3, 2, 0)
(mx, my) = isometric.project(1, 0, 0, v)
h = isometric.hit(d, mx, my, v)
is_('a click on a locked leg hits the pipe',
    h and h['kind'] == 'pipe' and h['name'] == 'P1',
    '%s %s' % (h['kind'], h['name']) if h else 'nothing')
(cx, cy) = isometric.project(1, 1, 0, v)
is_('a click off those legs does not hit the pipe',
    not isometric.hit(d, cx, cy, v))

#==============================================================================
print("2. LENGTHS AND THE MODEL'S UNITS")
#==============================================================================
u = dict(phc.UNIT_DEFAULT)
d = draw_of('', u)              # length defaults to millimetres
tok = isometric.metres_to_token(d, 4, 'LENGTH')
back = phc.length_metres(tok, 'MM')
is_('4 m is 4000 mm, and reads back as 4 m',
    tok == '4000' and abs(back - 4) < 1e-6, '%s -> %s' % (tok, back))
d['units']['LENGTH'] = 'IN'
tok = isometric.metres_to_token(d, 0.0254, 'LENGTH')
back = phc.length_metres(tok, 'IN')
is_('one inch written and read back', abs(back - 0.0254) < 1e-6, tok)

#==============================================================================
print('3. DRAWING WRITES A MODEL')
#==============================================================================
u = units()
d = draw_of('', u)
(e, w) = isometric.add_node(d, 'WATER', 0, 0, 0, '0')
(e2, s) = isometric.add_node(d, 'SPRINKLER', 4, 0, 0, '0')
(e3, p) = isometric.add_pipe(d, w, s)
is_('a supply, a sprinkler and a pipe',
    not e and not e2 and not e3 and w == 'W1' and s == 'S1' and p == 'P1',
    ' '.join(x or '' for x in (e, e2, e3, w, s, p)))
(e4, n) = isometric.add_node(d, 'NODE', 1, 1, 0, '0')
(e5, _n5) = isometric.add_pipe(d, w, n)
is_('a pipe not on one axis is refused',
    bool(e5) and 'ONE GRID AXIS' in e5, e5 or '')
(e6, _n6) = isometric.add_node(d, 'NODE', 0, 0, 0, '0')
is_('a second point on the same cell is refused',
    bool(e6) and 'ALREADY USED' in e6, e6 or '')
isometric.delete_item(d, 'node', n)   # the off-axis point is not part of the
                                      # branch
text = isometric.write_network(d)
is_('the text is the commands, with the positions as //ISO comments',
    re.search(r'^//ISO GRID 1$', text, re.M) is not None and
    re.search(r'^//ISO W1 0 0 0$', text, re.M) is not None and
    re.search(r'^WATER\s+W1 0 500$', text, re.M) is not None and
    re.search(r'^SPRINKLER\s+S1 0 -50 80$', text, re.M) is not None and
    re.search(r'^PIPE\s+P1 W1 S1 4 25$', text, re.M) is not None and
    re.search(r'^USE\s+BORE 120$', text, re.M) is not None, text)
settings = editor.new_settings()
settings['units']['LENGTH'] = 'M'
full = editor.join_file(settings, text)[0]
(q, err) = results(full)
is_('and it solves', bool(q) and q.get('P1', 0) > 0, err or 'no flow')

#==============================================================================
print('4. A MOVE, AND WHAT IS KEPT')
#==============================================================================
raw = '\n'.join([
    '// KEEP THIS',
    'NODE A 0',
    'NODE B 0',
    'SPRINKLER S 0 -50 80',
    'USE ASAM',
    'PIPE P1 A B 10 50 T  //AS - 40',
    'PIPE P2 B S 3 32',
    'AREA NEAR S',
    ''])
d = draw_of(raw)
before = d['pipes'][0]['len']
isometric.set_grid(d, '2')       # the step changes; typed lengths do not
is_('changing the grid leaves a length that was typed',
    d['pipes'][0]['len'] == before, d['pipes'][0]['len'])
err = isometric.move_node(d, 'B', 6, 0, 0)
is_('moving a point sets its pipes from the grid',
    not err and d['pipes'][0]['len'] == '12' and d['pipes'][1]['len'] != '3',
    'P1 %s P2 %s' % (d['pipes'][0]['len'], d['pipes'][1]['len']))
err = isometric.set_node(d, 'S', 'NAME', 'S9')
text = isometric.write_network(d)
is_('a comment, an //AS note and an AREA line survive, and the new name '
    'is in the AREA',
    not err and
    re.search(r'^// KEEP THIS$', text, re.M) is not None and
    '//AS - 40' in text and
    re.search(r'^AREA\s+NEAR S9$', text, re.M) is not None and
    re.search(r'^PIPE\s+P2 B S9 ', text, re.M) is not None, text)
# Positions come back.
d2 = draw_of(text)
is_('//ISO positions are kept',
    d2['nodes']['B'].get('pinned') and d2['nodes']['B']['ix'] == 6 and
    not d2['nodes']['B']['iy'],
    'ix %s' % d2['nodes']['B'].get('ix'))
again = isometric.write_network(d2)
is_('writing the drawing twice gives the same text', again == text, again)

#==============================================================================
print('5. THE EXAMPLES, AND A COPY')
#==============================================================================
copy = '\n'.join([
    'NODE A 0', 'NODE B 0', 'NODE C 0',
    'USE BORE 120',
    'PIPE P1 A B 10 50',
    'PC P1 P2 B C',
    'CHANGEPIPE P1 12 40 E',
    ''])
d = draw_of(copy)
p1 = [x for x in d['pipes'] if x['name'] == 'P1']
p2 = [x for x in d['pipes'] if x['name'] == 'P2']
p1 = p1[0] if p1 else None
p2 = p2[0] if p2 else None
is_('a change applies to the named pipe; the copy keeps the original',
    p1 and p2 and p1['len'] == '12' and p1['size'] == '40' and
    ' '.join(p1['fits']) == 'E' and p2['len'] == '10' and
    p2['size'] == '50' and not p2['fits'],
    ('P1 %s %s %s / P2 %s %s' % (p1['len'], p1['size'],
                                 ' '.join(p1['fits']), p2['len'], p2['size']))
    if p1 else 'missing')
back = isometric.write_network(d)
is_('the copy is written as its own pipe, and the change is not applied '
    'twice',
    re.search(r'^PIPE\s+P2 B C 10 50$', back, re.M) is not None and
    re.search(r'^PIPE\s+P1 A B 12 40 E$', back, re.M) is not None and
    re.search(r'^PC\b', back, re.M) is None and
    re.search(r'^CHANGEPIPE\b', back, re.M) is None, back)

for fname in sorted(os.listdir(EX)):
    if not fname.endswith('.phc') or '04_grid' in fname:
        continue
    doc = editor.split_file(slurp(os.path.join(EX, fname)))
    drawing = isometric.read_network(doc['network'],
                                     doc['settings']['units'])
    missing = [name for name in drawing['node_order']
               if drawing['nodes'][name].get('ix') is None]
    cell = {}
    overlap = None
    for name in drawing['node_order']:
        n = drawing['nodes'][name]
        k = '%d,%d,%.4f' % (n['ix'], n['iy'], n['iz'])
        if k in cell:
            overlap = name
        cell[k] = name
    once = isometric.write_network(drawing)
    twice = isometric.write_network(
        isometric.read_network(once, doc['settings']['units']))
    orig = editor.join_file(doc['settings'], doc['network'])[0]
    rewritten = editor.join_file(doc['settings'], once)[0]
    (a, pa) = results(orig)
    (b, pb) = results(rewritten)
    ok_solve = bool(a) and bool(b) and isinstance(pa, dict) \
        and isinstance(pb, dict)
    if ok_solve:
        (flow, _f) = worst(a, b)
        (press, _p) = worst(pa, pb)
    else:
        flow = press = 1e30
    err = '' if ok_solve else (
        pa if not isinstance(pa, dict) else
        (pb if not isinstance(pb, dict) else 'did not solve'))
    is_('%s: every point placed, none on top of another, same flows and '
        'pressures' % fname,
        not missing and not overlap and twice == once and
        flow < 0.05 and press < 0.05,
        err or 'unplaced %d overlap %s flow %s pressure %s' % (
            len(missing), overlap or '', flow, press))

#==============================================================================
print('6. CLICK AND CLICK, OR A KNOWN LENGTH')
#==============================================================================
u = units()
d = draw_of('', u)
is_('a blank length does not choose a step count',
    isometric.steps_for_length(d, '  ') is None)
is_('12 m on a 1 m grid is 12 steps',
    isometric.steps_for_length(d, '12') == 12, '')
(e, w) = isometric.add_node(d, 'WATER', 0, 0, 0, '0')
(e2, s) = isometric.add_node(d, 'SPRINKLER', 4, 0, 0, '0')
n = d['nodes'][w]
(ix, iy, iz) = isometric.cell_along(n, 3, 1, 0, 12)
is_('the click chooses the axis and the length chooses the steps',
    ix == 12 and iy == 0 and not iz, '%s %s %s' % (ix, iy, iz))
(ix, iy, iz) = isometric.cell_along(n, 1, -4, 0, 12)
is_('the other click chooses that axis and that sign',
    not ix and iy == -12 and not iz, '%s %s %s' % (ix, iy, iz))
(bad, _b) = isometric.add_pipe(d, w, s, {'len': 'no'})
is_('a length that is not a length is refused',
    bool(bad) and 'NOT A LENGTH' in bad, bad or '')
(e3, p) = isometric.add_pipe(d, w, s, {'len': '12', 'size': '50',
                                       'fits': '2E 1T', 'c': '110'})
pipe = d['pipes'][0]
is_('joining an existing point keeps the typed length and does not '
    'move it',
    not e3 and pipe['len'] == '12' and pipe['size'] == '50' and
    ' '.join(pipe['fits']) == '2E 1T' and pipe['use_c'] == '110' and
    d['nodes'][s]['ix'] == 4,
    '%s len %s ix %s' % (e3 or '', pipe['len'], d['nodes'][s]['ix']))
err = isometric.set_pipe(d, p, 'LENGTH', '7')
is_('typing a length slides the end along the pipe',
    not err and d['nodes'][s]['ix'] == 7 and pipe['len'] == '7',
    '%s ix %s len %s' % (err or '', d['nodes'][s]['ix'], pipe['len']))
(e4, block) = isometric.add_node(d, 'NODE', 9, 0, 0, '0')
err = isometric.set_pipe(d, p, 'LENGTH', '9')
is_('a length that lands on a point is refused, and the pipe stays',
    bool(err) and 'ALREADY USED' in err and d['nodes'][s]['ix'] == 7 and
    pipe['len'] == '7',
    '%s ix %s' % (err or '', d['nodes'][s]['ix']))
isometric.delete_item(d, 'node', block)
(e5, c) = isometric.add_node(d, 'NODE', 10, 0, 0, '0')
(e6, p2) = isometric.add_pipe(d, s, c)
err = isometric.set_pipe(d, p, 'LENGTH', '12.4')
others = [x for x in d['pipes'] if x['name'] == p2]
other = others[0] if others else None
is_('the end moves to the rounded steps, the typed length stays, the '
    'other pipe follows the grid',
    not err and not e5 and not e6 and d['nodes'][s]['ix'] == 12 and
    pipe['len'] == '12.4' and other and other['len'] == '2',
    '%s ix %s P1 %s P2 %s' % (err or '', d['nodes'][s]['ix'], pipe['len'],
                              other['len'] if other else ''))
err = isometric.set_pipe(d, p, 'LENGTH', '0')
is_('a zero length is stored and the end stays where it is',
    not err and pipe['len'] == '0' and d['nodes'][s]['ix'] == 12,
    '%s ix %s' % (err or '', d['nodes'][s]['ix']))


#------------------------------------------------------------------------------
# The audit of the port against the Perl, 20 November 2026: differences found
# by running HardyCross::Isometric and this module on the same input.  Each
# expectation is the Perl's answer.
#------------------------------------------------------------------------------
print('\nPort audit: the Perl\'s answers')
# A cell holds its point's name and the Perl tests the name: a point named 0
# does not take up its cell.
d = isometric.read_network('WATER 0 0 500 1000 400\nNODE A 0\nNODE B 0\nNODE C 0\n'
                           'SPRINKLER D 0 -50 80\nPIPE P1 0 A 1 25\nPIPE P2 A B 1 25\n'
                           'PIPE P3 A C 1 25\nPIPE P4 A D 1 25\n', {'LENGTH': 'M'})
is_('a point named 0 does not hold its cell in the layout',
    (d['nodes']['D']['ix'], d['nodes']['D']['iy']) == (0, 0)
    and '//ISO D 0 0 0' in isometric.write_network(d), isometric.write_network(d))
d = isometric.read_network('NODE 0 0\nNODE A 0\nPIPE P1 0 A 2 25\nPUMP PU 0 A 800 100 700\n',
                           {'LENGTH': 'M'})
(err, name) = isometric.add_node(d, 'NODE', 0, 0, 0)
is_('nor against a new point', err == '' and name == 'N1', err)
d['pumps'][0]['pairs'] = []
err = isometric.set_pump(d, 'PU', 'PRESSURE', '5')
is_('a pump curve grows to the pair set, as a Perl array does',
    err == '' and d['pumps'][0]['pairs'] == [None, '5']
    and 'PUMP      PU 0 A 800  5\n' in isometric.write_network(d))
d = isometric.read_network('NODE A 0\nNODE B 0\n', {})
is_('FS to US are not white space in a name',
    isometric.set_node(d, 'A', 'NAME', 'X\x1fY') == '' and 'X\x1fY' in d['nodes']
    and isometric.steps_for_length(d, '\x1f') is None)

print('\n%d passed, %d failed' % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
