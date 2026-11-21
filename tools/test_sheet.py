#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_sheet.py -- the spreadsheet model, hardycross.sheet, without Tk.
# Python port of test_sheet.pl, check for check.
#
#   python3 tools/test_sheet.py
#
# The sheet is the other window's network: pipes, the nodes taken from them,
# supplies, and a table for each pressure device.  It has no Tk.  What is
# checked here is that the grids follow the rules, and that a .phc file read
# into the grids and written out again solves to the same pipe flows and node
# pressures.  The text editor is not loaded.
#==============================================================================
import glob
import os
import re
import sys
import traceback

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

import hardycross
from hardycross import phc
from hardycross import sheet as SH

_pass, _fail = 0, 0


def is_(name, ok, why=None):
    global _pass, _fail
    print('  %-66s %s' % (name, 'ok' if ok else '*** FAIL'))
    if not ok and why is not None:
        print('      %s' % why)
    if ok:
        _pass += 1
    else:
        _fail += 1


def slurp(p):
    # As the Perl's open '<': text mode, so CRLF is read as LF on Windows.
    with open(p, 'rb') as f:
        b = f.read()
    if os.name == 'nt':
        b = b.replace(b'\r\n', b'\n')
    return b.decode('utf-8', 'replace')


EX = os.path.join(ROOT, 'examples')


def pipe(**f):
    p = SH.empty_pipe()
    p.update(f)
    return p


def M(pat, text):
    return re.search(pat, text, re.M) is not None


# Solved pipe flows by id, and gauge pressures by node id.  The same
# comparison the .phc tests use.
def results(net):
    q = {e['id']: e['q'] for e in net['elems'][1:] if e['kind'] == 'PIPE'}
    p = {n['id']: n['h'] - hardycross.GAMMA_W * n['z']
         for n in net['nodes'][1:] if n['id'] != 'REF'}
    return q, p


def worst(a, b):
    w = 0
    for k in a:
        if k not in b:
            return 1e30
        d = abs(a[k] - b[k])
        if d > w:
            w = d
    return w


def read_net(text):
    try:
        return phc.read_string(text), ''
    except Exception as e:
        return None, (e.msg if hardycross.is_model_error(e) else str(e))


def ids(net):
    p = [e['id'] for e in net['elems'][1:] if e['kind'] == 'PIPE']
    n = [x['id'] for x in net['nodes'][1:] if x['id'] != 'REF']
    return ' '.join(sorted(p)), ' '.join(sorted(n))


#==============================================================================
print('1. NODES COME FROM THE PIPES, AND A BLANK TYPE IS A NODE')
#==============================================================================
if True:
    s = SH.new_sheet()
    s['pipes'].append(pipe(pipe='P1', **{'from': 'A'}, to='B', length='10', type='BORE', diam='100'))
    s['pipes'].append(pipe(pipe='P2', **{'from': 'B'}, to='C', length='4', type='BORE', diam='50'))
    n = SH.node_rows(s)
    is_('nodes in the order the pipes introduce them', ' '.join(n) == 'A B C', ' '.join(n))
    is_("a new node's type is blank: a node, not the word",
        not [i for i in n if len(SH.normal_type(s['nodes'][i]['type']))])
    is_('NODE, A NODE and ANODE are that same blank',
        SH.normal_type('anode') == '' and SH.normal_type('A NODE') == ''
        and SH.normal_type('NODE') == '')

    s['nodes']['C']['elev'] = '4.5'
    s['nodes']['C']['type'] = 'SPRINKLER'
    s['nodes']['C']['min_p'] = '50'
    s['nodes']['C']['k'] = '80'
    # C drops out of the system.  Its values stay, and come back with it.
    s['pipes'][:] = [s['pipes'][0]]
    n = SH.node_rows(s)
    is_('a node no pipe names leaves the grid', 'C' not in n, ' '.join(n))
    s['pipes'].append(pipe(pipe='P2', **{'from': 'B'}, to='C', length='4', type='BORE', diam='50'))
    n = SH.node_rows(s)
    is_('typing the node again brings its elevation and type back',
        'C' in n and s['nodes']['C']['elev'] == '4.5' and s['nodes']['C']['type'] == 'SPRINKLER')

    text = SH.to_text(s)
    is_('a blank type is written as NODE, a sprinkler as SPRINKLER',
        M(r'^NODE\s+A\s', text) and M(r'^NODE\s+B\s', text)
        and M(r'^SPRINKLER\s+C\s+\S+\s+-50\s+80', text), text)
    is_('the negative minimum is the MIN P column, not a negative flow stored as such',
        s['nodes']['C']['min_flow'] == '' and s['nodes']['C']['min_p'] == '50')

#==============================================================================
print("2. A DEVICE TYPE ADDS THAT DEVICE'S ROW, AND ONLY THAT TABLE")
#==============================================================================
if True:
    s = SH.new_sheet()
    s['pipes'].append(pipe(pipe='1', **{'from': '2'}, to='101', length='20', type='S20', c='120',
                           diam='100', fittings='2E T GV'))
    SH.node_rows(s)
    s['nodes']['101']['type'] = 'PRV'
    s['nodes']['101']['elev'] = '3'
    SH.reconcile(s)
    prv = SH.device_rows(s, 'PRV')
    bfp = SH.device_rows(s, 'BFP')
    is_('choosing PRV adds one PRV row and no other device', len(prv) == 1 and not bfp)
    is_('the row is tied to that node, on the pipe that arrives there',
        prv[0]['node'] == '101' and prv[0]['tied'] and prv[0]['pipe'] == '1')
    heads = ' '.join(c['head'] for c in SH.device_columns(s, 'PRV'))
    is_('a PRV table has the columns a PRV needs',
        'NODE' in heads and 'PIPE' in heads and 'FLOW 1' in heads and 'LOSS 1' in heads)
    opp = [c['key'] for c in SH.device_columns(s, 'OPP')]
    is_('an orifice plate sized for a drop has DROP and CD, not a loss curve',
        'drop' in opp and 'cd' in opp and 'q1' not in opp)

    prv[0]['pairs'] = ['0', '35']
    text = SH.to_text(s)
    is_('the PRV is written on its pipe, and the node stays a node',
        M(r'^NODE\s+101\s+3', text) and M(r'^PRV\s+1\s+0\s+35', text), text)

    s['nodes']['101']['type'] = ''
    SH.reconcile(s)
    is_('clearing the type takes the PRV off its table', not SH.device_rows(s, 'PRV'))
    s['nodes']['101']['type'] = 'PRV'
    SH.reconcile(s)
    back = (SH.device_rows(s, 'PRV') or [None])[0]
    is_('choosing it again brings the loss back', back and ' '.join(back['pairs']) == '0 35')

    s['nodes']['2']['type'] = 'SUPPLY'
    s['nodes']['2']['elev'] = '0'
    s['nodes']['2']['static'] = '900'
    sup = SH.supply_rows(s)
    is_('SUPPLY puts the node on the supplies grid', len(sup) == 1 and sup[0] == '2')
    text = SH.to_text(s)
    is_('and writes it as WATER, with the elevation from the nodes grid',
        M(r'^WATER\s+2\s+0\s+900', text), text)

#==============================================================================
print('3. A FITTING STRING, A FIXED FLOW, AND BOTH MINIMUMS')
#==============================================================================
if True:
    s = SH.new_sheet()
    s['pipes'].append(pipe(pipe='P1', **{'from': 'S'}, to='H', length='12', type='ASAM', diam='100',
                           fittings='1T 2E 1GV', eqv='2.5'))
    SH.node_rows(s)
    s['nodes']['S']['type'] = 'SUPPLY'
    s['nodes']['S']['elev'] = '0'
    s['nodes']['S']['static'] = '700'
    s['nodes']['H']['type'] = 'HYDRANT'
    s['nodes']['H']['elev'] = '1'
    s['nodes']['H']['min_flow'] = '600'
    s['nodes']['H']['min_p'] = '200'
    s['nodes']['H']['k'] = '80'
    s['nodes']['H']['fixed_flow'] = '100'
    bad = SH.problems(s)
    # problems() looks at the line map to_text builds.
    SH.to_text(s)
    bad = SH.problems(s)
    is_('an outlet with MIN FLOW and MIN P both filled is refused',
        len(bad) == 1 and re.search(r'NOT BOTH', bad[0]['what']) and bad[0]['loc']['col'] == 'min_p')
    s['nodes']['H']['min_p'] = ''
    text = SH.to_text(s)
    is_('fittings and the equivalent length are written on the pipe',
        M(r'^PIPE\s+P1\s+S\s+H\s+12\s+100\s+1T\s+2E\s+1GV', text) and M(r'^EQV\s+P1\s+2\.5', text), text)
    is_('the fixed flow is written, and the hydrant keeps its minimum flow',
        M(r'^HYDRANT\s+H\s+1\s+600\s+80', text) and M(r'^FIXEDFLOW\s+\S+\s+H\s+100', text))
    is_('with the pressure cleared, that outlet has no sheet problem', not SH.problems(s))

#==============================================================================
print('4. EVERY EXAMPLE SURVIVES THE GRIDS')
#==============================================================================
# Example 04 is a thousand nodes: it is read and written, not solved.
# The others are solved both ways and compared.
SOLVE = dict((x, 1) for x in (
    '01_single_branch', '02_full_network', '03_dw_altunits', '05_crosscheck',
    '06_orifice', '07_pipe_database_demo', '08_autocad_export_format', '09_parallel_pumps',
    '11_design_areas', '12_auto_sizing'))
for path in sorted(glob.glob(os.path.join(EX, '*.phc'))):
    base = re.search(r'([^/\\]+)\.phc\Z', path).group(1)
    text = slurp(path)
    try:
        sheet, err = SH.read_text(text), ''
    except Exception:
        sheet, err = None, traceback.format_exc()
    is_('%s reads into the grids' % base, sheet, err)
    if not sheet:
        continue
    try:
        out, err = SH.to_text(sheet), ''
    except Exception:
        out, err = None, traceback.format_exc()
    is_('   writes .phc', out, err)
    if not out:
        continue
    a, ea = read_net(text)
    b, eb = read_net(out)
    is_('   the written file reads', b, eb or ea)
    if not (a and b):
        continue
    ap, an = ids(a)
    bp, bn = ids(b)
    is_('   the same pipes and nodes', ap == bp and an == bn,
        'nodes differ' if ap == bp else 'pipes differ')
    sys_ = SH.system_columns(sheet)
    keys = [c['key'] for c in sys_]
    is_('   the system columns are the pipe, its ends, length, type, diameter and fittings',
        'pipe' in keys and 'from' in keys and 'fittings' in keys and 'diam' in keys)
    if not SOLVE.get(base):
        continue
    oka = hardycross.solve_model(a)
    okb = hardycross.solve_model(b)
    qa, pa = results(a)
    qb, pb = results(b)
    wq, wp = worst(qa, qb), worst(pa, pb)
    is_('   same result (%.2g L/min, %.2g kPa), both %s'
        % (wq, wp, 'solved' if (oka and okb) else 'unsolved'),
        oka and okb and wq < 0.2 and wp < 0.2)

#==============================================================================
print('5. WHAT EXAMPLE 02 PUTS ON EACH GRID')
#==============================================================================
if True:
    s = SH.read_text(slurp(os.path.join(EX, '02_full_network.phc')))
    n = SH.node_rows(s)
    is_('every pipe end is a node, and the tank the pump draws from is kept',
        'T1' in n and 'J2' in n and 'A' in n)
    is_('the tank is a supply, and its type is not the word NODE', s['nodes']['T1']['type'] == 'SUPPLY')
    is_('the hose reel keeps a minimum pressure in MIN P',
        s['nodes']['A']['type'] == 'HREEL' and s['nodes']['A']['min_p'] == '220'
        and s['nodes']['A']['min_flow'] == '')
    is_('the fixed flow is on its node',
        s['nodes']['B']['fixed_flow'] == '300' and s['nodes']['B']['min_p'] == '200')

    def first(t):
        return (SH.device_rows(s, t) or [None])[0]
    pmp, bfp, prv, opp, ofd = first('PUMP'), first('BFP'), first('PRV'), first('OPP'), first('OFD')
    is_('the pump, the backflow preventer, the reducing valve and both plates are listed',
        bool(pmp and bfp and prv and opp and ofd))
    is_("the pump is the delivery node's type",
        pmp['tied'] and s['nodes'][pmp['node']]['type'] == 'PUMP')
    is_('a plate upstream of a sprinkler stays a plate, and the sprinkler stays a sprinkler',
        not opp['tied'] and s['nodes']['X2']['type'] == 'SPRINKLER')
    m1 = ([p for p in s['pipes'] if p['pipe'] == 'M1'] or [None])[0]
    is_('the fitting string is empty there and the equivalent length is kept',
        m1 and m1['fittings'] == '' and m1['eqv'] == '8.0')
    areas = [x for x in s['extras'] if re.match(r'^AREA\b', x)]
    is_('example 02 has no design areas to keep', not areas)
if True:
    s = SH.read_text(slurp(os.path.join(EX, '11_design_areas.phc')))
    areas = [x for x in s['extras'] if re.match(r'^AREA\b', x)]
    is_('design areas are kept and written back', len(areas) == 4)
    out = SH.to_text(s)
    is_('all four AREA lines are in the file', len(re.findall(r'^AREA\s', out, re.M)) == 4)
if True:
    s = SH.read_text(slurp(os.path.join(EX, '12_auto_sizing.phc')))
    is_("a copied sprinkler is a sprinkler of its own, with the source's K",
        s['nodes']['A4']['type'] == 'SPRINKLER' and s['nodes']['A4']['k'] == '80'
        and s['nodes']['B1']['min_p'] == '100')
    sized = ([p for p in s['pipes'] if p['pipe'] == 'H2'] or [None])[0]
    is_('a size of 0 stays 0, so the pipe is still one to be sized', sized and sized['diam'] == '0')

#==============================================================================
print('6. PIPE TYPE AND DIAMETER ARE LISTS')
#==============================================================================
if True:
    types = SH.pipe_type_choices()
    is_('the pipe type list is the database, then BORE', 'ASAM' in types and types[-1] == 'BORE')
    s = SH.new_sheet()
    mm = SH.diam_choices(s, 'ASAM')
    is_('a database type lists 0 and its nominal sizes',
        mm[0] == '0' and '100' in mm and '20' in mm)
    is_('BORE is not a list: the bore is typed', not SH.diam_choices(s, 'BORE'))
    is_('a blank type is not a list either', not SH.diam_choices(s, ''))
    s['settings']['units']['SIZE'] = 'IN'
    inch = SH.diam_choices(s, 'ASAM')
    is_('in inches the list is the inch nominal, and still has 0',
        inch[0] == '0' and '4' in inch and '100' not in inch)
    # Perl assigns $s->{pipes}[0] and [1], growing the list.
    s['pipes'][0:2] = [SH.empty_pipe(), SH.empty_pipe()]
    s['pipes'][0]['type'] = 'ASAM'
    is_('a blank pipe type inherits the row above it', SH.effective_type(s, 1) == 'ASAM')
    s['pipes'][1]['type'] = 'BORE'
    is_('its own type wins over the one above', SH.effective_type(s, 1) == 'BORE')
    sys_ = SH.system_columns(s)
    is_('the system columns name those two as lists',
        [c for c in sys_ if c['key'] == 'type' and (c.get('kind') or '') == 'pipetype']
        and [c for c in sys_ if c['key'] == 'diam' and (c.get('kind') or '') == 'diam'])
    nd = SH.node_columns(s)
    is_('node type is a list too',
        [c for c in nd if c['key'] == 'type' and (c.get('kind') or '') == 'type'])


#------------------------------------------------------------------------------
# The audit of the port against the Perl, 20 November 2026: differences found
# by running HardyCross::Sheet and this module on the same input.  Each
# expectation is the Perl's answer.
#------------------------------------------------------------------------------
print('\nPort audit: the Perl\'s answers')
s = SH.new_sheet()
is_('the PRA band hint ends BLANK: 5.',
    [c for c in SH.device_columns(s, 'PRA') if c['key'] == 'band'][0]['hint'].endswith('BLANK: 5.'))
is_('FS to US are not white space to trim', SH.trim(' \x1fa\x1f ') == '\x1fa\x1f')

# A name of 0 is false to Perl.
s = SH.read_text('NODE A 0\nNODE S2 0\nPIPE 0 W A 10 25 2E\nPC 0 P9 A S2\n')
is_('a copy of a pipe named 0 is left unresolved, as in the Perl',
    s['pipes'][1]['length'] == '' and s['pipes'][1].get('copy_of') == '0'
    and 'PIPE      P9 A S2\n' in SH.to_text(s))
s = SH.read_text('NODE 0 0\nNODE A 0\nPIPE P1 0 A 5 25\nPUMP 0 0 A 800 100 700\nPUMPDUTY 0 100 700\n')
t = SH.to_text(s)
is_('the duty of a pump named 0 is written under P- and its node',
    'PUMPDUTY  P-A 100 700' in t and 'PUMP      0 0 A 800 100 700' in t, t)
line = s['at']['node']['0']
is_('a node named 0: an ELEVATION message stays on the line\'s own cell',
    SH.locate(s, {'line': line, 'what': 'X ELEVATION Y'}) == s['map'][line]
    and SH.locate(s, {'line': line, 'what': 'MINFLOW'})['col'] == 'min_flow')

# A tied device is matched on its node as stored, not trimmed.
s = SH.read_text('NODE A 0\nNODE B 0\nPIPE P1 A B 5 25\nBFP P1 0 20\n')
s['devices'][0]['node'] = ' B '
is_('a device whose node text is not the node\'s is not shown',
    len(SH.device_rows(s, 'BFP')) == 0)
SH.reconcile(s)
is_('and the node type gets a row of its own',
    [[x['node'], x['tied']] for x in s['devices']] == [[' B ', 1], ['B', 1]])

print('\n%d passed, %d failed' % (_pass, _fail))
sys.exit(1 if _fail else 0)
