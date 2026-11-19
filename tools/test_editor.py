#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_editor.py -- the text editor's logic, hardycross.editor, without Tk.
#
#   python3 tools/test_editor.py
#
# A line-for-line port of tools/test_editor.pl: every check the Perl suite
# makes, against the Python module, with the same model and the same
# expectations.  Keeping the two suites identical makes any drift between
# the ports show up as a failure here.
#==============================================================================
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

from hardycross import is_model_error
from hardycross import editor

EX = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'examples')
TMP = tempfile.mkdtemp()
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


# A small model, its lines numbered in the comments for the checks below.
# The 50 and 32 mm pipes are deliberately too small, so the solve has
# velocity warnings to list.
M = '\n'.join([
    'TITLE     EDITOR TEST',                  #  1
    'UNITS     LENGTH M',                     #  2
    'NODE      A 0',                          #  3
    'NODE      B 0',                          #  4
    'NODE      C 4.5',                        #  5
    'WATER     S1 0 700',                     #  6
    'USE       ASAM',                         #  7
    'PIPE      P1 S1 A 12 100 1T 2E 1GV',     #  8
    'PIPE      P2 A B 6 50 1E',               #  9
    'PIPE      P3 B C 3 50',                  # 10
    'SPRINKLER H1 4.5 -50 80',                # 11
    'PIPE      P4 C H1 2 32',                 # 12
    'FIXEDFLOW F1 B 100 150',                 # 13
    '',
])

#==============================================================================
print('1. CHECKING THE BUFFER - statuses, problems, undefined and unused nodes')
#==============================================================================
if True:
    r = editor.check_buffer(M)
    is_('a good model: no problems, no undefined or unused nodes',
       not r['problems'] and not r['undefined'] and not r['unused'])
    is_('every line ok', not [l for l in r['lines'][1:] if l and l['status'] != 'ok'])

    bad = M + "PIPE P5 C X 5 50\nPIPE P6 X Y 5 50\nSPRINKLER H2 0\nPIPX P9\n" \
            "METHOD HW\nMETHOD DW\nNODE A 1\nPIPE P1 A B 1 50\nNODE D 0\n"
    r = editor.check_buffer(bad)
    u = {x['node']: x['line'] for x in r['undefined']}
    is_('undefined nodes X and Y listed with the first line using each',
       u.get('X', 0) == 14 and u.get('Y', 0) == 15 and len(u) == 2,
       ' '.join('%s:%s' % (k, u[k]) for k in sorted(u)))
    p = {x['line']: x['message'] for x in r['problems']}
    is_('an incomplete line is a problem (line 16, needs MINFLOW)',
       p.get(16, '') == 'SPRINKLER NEEDS MINFLOW')
    is_('an unknown command is a problem (line 17)', p.get(17, '') == 'UNKNOWN COMMAND PIPX')
    is_('a second METHOD is a problem naming the first (line 19)',
       p.get(19, '') == 'METHOD IS ALREADY SET ON LINE 18')
    is_('a second NODE A is a problem naming the first (line 20)',
       p.get(20, '') == 'NODE A IS ALREADY DEFINED ON LINE 3')
    is_('a pipe name used twice is a problem (line 21)',
       p.get(21, '') == 'THE NAME P1 IS ALREADY USED ON LINE 8')
    is_('undefined nodes are not problems on their lines', 14 not in p and 15 not in p)
    is_('the line statuses agree: 16 incomplete, 17 and 19 error',
       r['lines'][16]['status'] == 'incomplete' and r['lines'][17]['status'] == 'error'
       and r['lines'][19]['status'] == 'error')
    un = {x['node']: x['line'] for x in r['unused']}
    is_('a node nothing connects to is listed as unused (D, line 22)',
       un.get('D', 0) == 22 and len(un) == 1)
    r = editor.check_buffer(bad, 16)
    is_('the line being edited is not listed while incomplete',
       not [x for x in r['problems'] if x['line'] == 16])
    r = editor.check_buffer("WATER S 0 600\nPIPE P S B 1 47\nUSE ASAM\nPIPE Q B C 1 47\n")
    is_('USE applies from its line on: 47 mm fine as a bore, an error under ASAM',
       r['lines'][2]['status'] == 'ok' and r['lines'][4]['status'] == 'error',
       r['lines'][4]['message'])
    is_('every message is in capitals',
       not [x for x in editor.check_buffer(bad)['problems'] if re.search(r'[a-z]', x['message'])])

#==============================================================================
print('2. PROPOSALS - after each kind of line')
#==============================================================================
if True:
    def prop(n):
        return editor.proposal(M, n) or '(NONE)'
    is_('after a pipe: next free name, starts at its end, keeps length and size',
       prop(10) == 'PIPE P5 C C2 3 50', prop(10))
    is_('after P1 the next free name is P5, as P2 to P4 are taken',
       prop(8) == 'PIPE P5 A A2 12 100', prop(8))
    is_('after a node: next name, same elevation', prop(5) == 'NODE C2 4.5', prop(5))
    is_('after a sprinkler: name stepped, the rest kept',
       prop(11) == 'SPRINKLER H2 4.5 -50 80', prop(11))
    is_('after a water supply', prop(6) == 'WATER S2 0 700', prop(6))
    is_('after a fixed flow', prop(13) == 'FIXEDFLOW F2 B2 100 150', prop(13))
    is_('after a setting: none', prop(2) == '(NONE)')
    is_('after a USE line: none', prop(7) == '(NONE)')
    is_('after a line with an error: none',
       (editor.proposal("PIPE P1 A\n", 1) or '(NONE)') == '(NONE)')

#==============================================================================
print('3. PICK LISTS AND THE STATUS BAR')
#==============================================================================
if True:
    c = {x[0]: 1 for x in editor.choices(M + "\nUSE \n", 15, 10)}
    is_('USE type field: the database pipe types and BORE',
       all(k in c for k in ('ASAM', 'ASAH', 'S20', 'S40', 'CPVC', 'PE11', 'BORE')))
    f = {x[0]: x[1] for x in editor.choices(M + "PIPE P5 C A 3 50 \n", 14, 27)}
    is_('fitting field under USE ASAM, DN50: the codes with descriptions',
       all(k in f for k in ('E', 'T', 'GV', 'CV')) and 'ELBOW' in f.get('E', ''))
    is_('   and the short forms G and C',
       'SHORT FOR GV' in f.get('G', '') and 'SHORT FOR CV' in f.get('C', ''))
    is_('a WATER line: no pick list', not editor.choices(M, 6, 14))

    st = editor.status_at(M, 8, 19)
    is_('status bar on line 8 at the length: the PIPE template, LENGTH current',
       st['template']['command'] == 'PIPE'
       and st['template']['fields'][st['template']['current']] == 'LENGTH')
    is_('   the template text',
       st['template']['text'] == 'PIPE <NAME> <START> <END> <LENGTH> <SIZE> [FITTINGS ...]',
       st['template']['text'])
    st = editor.status_at('PIPE P1 A', 1, 9)
    is_('a half-typed line: incomplete, needs END',
       st['status'] == 'incomplete' and st['message'] == 'PIPE NEEDS END')

#==============================================================================
print('4. SYNTAX COLOURING')
#==============================================================================
if True:
    s = editor.colour_spans('  PIPE P1 A B 1 50 2E  // MAIN')
    k = {'%d-%d' % (x[0], x[1]): x[2] for x in s}
    is_('command word', k.get('2-6', '') == 'command')
    is_("the new pipe's name, its two nodes",
       k.get('7-9', '') == 'name' and k.get('10-11', '') == 'ref' and k.get('12-13', '') == 'ref')
    is_('length and size are numbers, the fitting a keyword',
       k.get('14-15', '') == 'number' and k.get('16-18', '') == 'number'
       and k.get('19-21', '') == 'keyword')
    is_('comment span to the end of the line', k.get('23-30', '') == 'comment')
    b = {'%d-%d' % (x[0], x[1]): x[2] for x in editor.colour_spans('BFP P1 0 10 500 40')}
    is_('after BFP the pipe is a reference, the curve numbers',
       b['4-6'] == 'ref' and b['9-11'] == 'number')
    is_('USE: the pipe type a keyword',
       len([x for x in editor.colour_spans('USE ASAM') if x[2] == 'keyword']) == 1)
    is_('an alias is a command word (P)',
       any(x[2] == 'command' for x in editor.colour_spans('P P1 A B 1 50')))
    is_('an unknown word: nothing coloured', not editor.colour_spans('PIPX P1 A'))
    is_('a comment-only line', editor.colour_spans('// NOTE')[0][2] == 'comment')

#==============================================================================
print('5. SOLVE AND RESULTS ON THE CURSOR')
#==============================================================================
net = None
if True:
    r = editor.solve_text(M, 'TEST.PHC')
    is_('the model solves and converges', r['ok'] and r['converged'], r.get('error'))
    is_('the report is the full report',
       'PIPE SCHEDULE' in (r.get('report') or '').upper()
       and 'OUTLET COMPLIANCE' in r['report'].upper())
    net = r['net']
    l = M.split('\n')

    def res(n):
        return editor.results_at(net, l[n - 1]) or '(NONE)'
    p1 = [e for e in net['elems'] if e and (e.get('id') or '') == 'P1'][0]
    q = '%.1f' % abs(p1['q'])
    is_('pipe P1: flow %s L/MIN, velocity, end pressures' % q,
       re.match(r'^P1  Q %s L/MIN  V [\d.]+ M/S  S1 700\.0 KPA -> A [\d.]+ KPA$'
               % re.escape(q), res(8)) is not None, res(8))
    # Velocity checked by hand: Q / A with the ASAM DN100 bore of 105.1 mm.
    v = re.search(r'V ([\d.]+)', res(8)).group(1)
    vh = abs(p1['q']) / 60000 / (3.14159265358979 * 0.1051 ** 2 / 4)
    is_('   velocity %.2f M/S agrees with Q/A by hand' % vh, abs(float(v) - vh) < 0.006)
    is_('sprinkler H1: discharge and pressure, with the required',
       re.match(r'^H1  DISCHARGE [\d.]+ L/MIN AT [\d.]+ KPA \(REQUIRED 50\.0\)$',
                res(11)) is not None, res(11))
    is_('node C: pressure and elevation',
       re.match(r'^C  PRESSURE [\d.]+ KPA, ELEVATION 4\.500 M$', res(5)) is not None, res(5))
    is_('water supply S1',
       re.match(r'^S1  SUPPLIES [\d.]+ L/MIN AT 700\.0 KPA$', res(6)) is not None, res(6))
    is_('fixed flow F1: flow, pressure, required',
       re.match(r'^F1  FIXED 100\.0 L/MIN AT [\d.]+ KPA \(REQUIRED 150\.0\)$',
                res(13)) is not None, res(13))
    is_('a setting line: no results', res(2) == '(NONE)')
    is_('a line added since the solve: no results',
       editor.results_at(net, 'PIPE P99 A B 1 50') is None)

    r = editor.solve_text(M + "PIPE P9 A Z 3 50\n", 'TEST.PHC')
    is_('an error stops the solve and gives its line (14)',
       not r['ok'] and (r.get('line') or 0) == 14, r.get('error'))
    is_('   the error is in capitals', not re.search(r'[a-z]', r.get('error') or 'x'),
       r.get('error'))
    lps = "UNITS FLOW LPS\nUNITS PRESSURE BAR\nWATER S 0 7\nPIPE P1 S B 10 100\nSPRINKLER B 0 0 1.2\n"
    r = editor.solve_text(lps, None)
    is_("results are in the model's own units (L/S and BAR)",
       re.search(r'L/S .* BAR -> B [\d.]+ BAR$',
                  editor.results_at(r['net'], 'PIPE P1 S B 10 100') or '') is not None)

#==============================================================================
print('6. THE LISTS BESIDE THE EDITOR')
#==============================================================================
if True:
    d = editor.diagnostics(M, net)
    is_('a good model: no errors, no node notes', not d['errors'] and not d['nodes'])
    w = {x['line']: x['message'] for x in d['warnings'] if x.get('line') is not None}
    is_('velocity warnings for P2, P3 and P4, on their lines',
       re.match(r'^P2 - VELOCITY [\d.]+ M/S IS OVER THE LIMIT OF 6 M/S$',
                w.get(9, '')) is not None and w.get(10) and w.get(12) and not w.get(8),
       ' / '.join('%s: %s' % (k, w[k]) for k in sorted(w)))
    d = editor.diagnostics(M + "NODE D 0\nPIPE P5 C X 1 50\n")
    n = ['%s %s' % (x['line'], x['message']) for x in d['nodes']]
    is_('NODES: used but not defined, and defined but unconnected',
       ' '.join(n) == '15 X - USED, BUT NOT DEFINED 14 D - DEFINED, BUT NOTHING CONNECTS TO IT',
       ' '.join(n))
    is_('no solve, no warnings', not d['warnings'])

    f = "WATER S 0 300\nPIPE P1 S H 30 50\nSPRINKLER H 0 2000 80\n"
    s = editor.solve_text(f, None)
    d = editor.diagnostics(f, s['net'])
    is_('an outlet short of its requirement is a warning on its line',
       any((x.get('line') or 0) == 3
           and x['message'].startswith('H - BELOW ITS REQUIREMENT') for x in d['warnings']))

#==============================================================================
print('7. THE RESULTS TABLES')
#==============================================================================
if True:
    t = editor.result_tables(net)
    cols = t['pipes']['columns']
    is_('21 pipe columns, NAME first and fixed',
       len(cols) == 21 and cols[0]['key'] == 'NAME' and cols[0].get('fixed'))
    shown = [x['key'] for x in cols if x['show']]
    is_('shown by default: NAME to PF, PS and VEL',
       ' '.join(shown) == 'NAME SNODE ENODE NOM ID MAT C L F T K Q PF PS VEL', ' '.join(shown))
    is_('every heading and description in capitals',
       not [x for x in cols if re.search(r'[a-z]', x['head'] + x['desc'])])
    col = {cols[i]['key']: i for i in range(len(cols))}
    row = {x['cells'][0]: x for x in t['pipes']['rows']}

    def c(p, k):
        return row[p]['cells'][col[k]]
    is_('P1: S1 to A, DN100, 105.1 mm, ASAM, C 120',
       c('P1', 'SNODE') == 'S1' and c('P1', 'ENODE') == 'A' and c('P1', 'NOM') == '100'
       and c('P1', 'ID') == '105.1' and c('P1', 'MAT') == 'ASAM' and c('P1', 'C') == '120')
    is_('P1: L + F = T',
       abs(float(c('P1', 'L')) + float(c('P1', 'F')) - float(c('P1', 'T'))) < 0.006
       and float(c('P1', 'F')) > 0)
    is_('P3 climbs 4.5 m: PE = 9.807 x 4.5 = 44.13 KPA', c('P3', 'PE') == '44.13', c('P3', 'PE'))
    is_('PF/M is PF over the total length',
       abs(float(c('P2', 'PFX')) - float(c('P2', 'PF')) / float(c('P2', 'T'))) < 1e-3)
    is_('no device in a pipe: PS is -', c('P1', 'PS') == '-')
    is_('Hazen-Williams: no Darcy factor, formula HW',
       c('P1', 'FD') == '-' and c('P1', 'FORMULA') == 'HW')
    is_('every pipe flowing is active', not [x for x in t['pipes']['rows'] if not x['active']])

    n = {x['cells'][0]: x['cells'] for x in t['nodes']['rows']}
    is_('NODES: types WATER, FIXEDFLOW, SPRINKLER and NODE',
       n['S1'][1] == 'WATER' and n['B'][1] == 'FIXEDFLOW' and n['H1'][1] == 'SPRINKLER'
       and n['C'][1] == 'NODE')
    is_('   B: 100 L/MIN, 150 required, margin = pressure - 150',
       n['B'][4] == '100.0' and n['B'][5] == '150.0'
       and abs(float(n['B'][6]) - (float(n['B'][3]) - 150)) < 0.06)
    o = {x['cells'][0]: x['cells'] for x in t['outlets']['rows']}
    is_('OUTLETS: H1, K 80, PASS', 'H1' in o and o['H1'][3] == '80.000' and o['H1'][9] == 'PASS')
    is_('   the minimum flow of a sprinkler set by pressure is K x sqrt(50) = 565.7',
       o['H1'][4] == '565.7', o['H1'][4])
    is_('   the fixed flow is listed, K FIXED',
       'F1' in o and o['F1'][3] == 'FIXED' and o['F1'][9] == 'PASS')

    rows = t['pipes']['rows']
    q_ = [x['keys'][col['Q']] for x in editor.sort_rows(rows, col['Q'], 0)]
    is_('sorting on Q: ascending as numbers',
       not [i for i in range(len(q_) - 1) if q_[i] > q_[i + 1]])
    names = [x['cells'][0] for x in editor.sort_rows(rows, col['VEL'], 1)]
    is_('sorting on VEL descending: P4, the smallest pipe, first',
       names[0] == 'P4', ' '.join(names))
    names = [x['cells'][0] for x in editor.sort_rows(rows, col['ENODE'], 0)]
    is_('sorting on ENODE: as text', ' '.join(names) == 'P1 P2 P3 P4', ' '.join(names))
    tie = [{'keys': [1, i]} for i in range(1, 6)]
    is_('ties keep their order',
       ''.join(str(x['keys'][1]) for x in editor.sort_rows(tie, 0, 0)) == '12345')

    mm = editor.solve_text("UNITS LENGTH MM\n" + '\n'.join(
        x for x in M.split('\n') if 'UNITS' not in x), None)
    tm = editor.result_tables(mm['net'])
    lc = [x for x in tm['pipes']['columns'] if x['key'] == 'L'][0]
    r1 = [x for x in tm['pipes']['rows'] if x['cells'][0] == 'P1'][0]
    is_("lengths in the file's LENGTH unit: MM",
       lc['unit'] == 'MM' and r1['cells'][col['L']] == '12.00',
       '%s %s' % (lc['unit'], r1['cells'][col['L']]))

#==============================================================================
print('8. THE DOCUMENT - settings in the PROJECT tab, the network in the editor')
#==============================================================================
EX7 = slurp(os.path.join(EX, '07_pipe_database_demo.phc'))
if True:
    d = editor.split_file(EX7)
    s = d['settings']
    is_('the title and project details go to the settings',
       s['title'] == 'LEVEL 2 SPRINKLER RANGE - DEMONSTRATION'
       and s['project']['JOB'] == 'HYC-DEMO-017'
       and s['project']['AUTHORITY_PHONE'] == '02 9265 2999')
    is_('   and the units and method',
       s['units']['LENGTH'] == 'M' and s['units']['FLOW'] == 'LPM' and s['method'] == 'HW')
    is_('the network holds no setting line',
       not re.search(r'^(TITLE|PROJECT|UNITS|METHOD|OPTION)\b', d['network'], re.M)
       and re.search(r'^WATER     SUP 0 650$', d['network'], re.M)
       and re.search(r'^PIPE      X1 R1 H3 9\.0 65 2E\n\Z', d['network'], re.M),
       d['network'][:40])
    full, h = editor.join_file(s, d['network'])
    fl = full.split('\n')
    is_('join_file: the settings at the head, then a blank line, then the network',
       fl[0] == 'TITLE     LEVEL 2 SPRINKLER RANGE - DEMONSTRATION' and fl[h - 1] == ''
       and fl[h] == 'WATER     SUP 0 650', 'H %d: %s' % (h, fl[h]))
    is_('   every unit written, defaults included',
       len([x for x in fl if x.startswith('UNITS ')]) == 6)
    r1 = editor.solve_text(EX7, None)
    r2 = editor.solve_text(full, None)
    q1 = [e['q'] for e in r1['net']['elems'] if e and (e.get('id') or '') == 'M1'][0]
    q2 = [e['q'] for e in r2['net']['elems'] if e and (e.get('id') or '') == 'M1'][0]
    is_('the joined file solves exactly as the original', abs(q1 - q2) < 1e-9)
    again = editor.split_file(full)
    is_('split, join and split again: the same settings and network',
       again['network'] == d['network']
       and editor.join_file(again['settings'], again['network'])[0] == full)
    d = editor.split_file("UNITS FLOW LPS\nUNITS FLOW LPM\nUNITS SIZE XX\nNODE A 0\n")
    is_('a repeated or bad setting stays in the network, to be seen and fixed',
       d['settings']['units']['FLOW'] == 'LPS'
       and d['network'] == "UNITS FLOW LPM\nUNITS SIZE XX\nNODE A 0\n", d['network'])
    c = editor.doc_check(d)
    is_('   where it is an error: settings are set in the PROJECT tab',
       c['lines'][1]['message'] == 'UNITS IS SET IN THE PROJECT TAB, NOT IN THE NETWORK'
       and c['lines'][3]['status'] == 'ok')
    from hardycross import phc
    form = [x for x in editor.OPTION_FORM if not isinstance(x, str)]
    seen = {}
    for x in form:
        seen[x[0]] = seen.get(x[0], 0) + 1
    is_('every option has a plain label and a line of help in the PROJECT tab, once',
       all(seen.get(o, 0) == 1 for o in phc.OPTIONS) and len(form) == len(phc.OPTIONS)
       and not [x for x in form if not x[1] or not x[2]
                or re.search(r'[a-z]', x[1] + x[2])])
    is_('   each says what a blank means (or that it is not used)',
       not [x for x in form if not re.search(r'BLANK|NOT USED', x[2])])
    is_('every unit quantity has a plain label',
       not [q_ for q_ in phc.UNIT_QUANTITIES if not editor.UNIT_LABEL.get(q_)])
    new = editor.new_settings()
    is_('new settings: the office default units, HW',
       new['units']['LENGTH'] == 'MM' and new['units']['KFACTOR'] == 'LPM/KPA'
       and new['method'] == 'HW')
if True:
    d = editor.split_file(EX7)
    net_ = d['network']
    d['network'] = net_ + "PIPE Z1 H3 ZZ 3 32\nPIPE M2 R1 R2 3 50\n"
    c = editor.doc_check(d)
    p = {x['line']: x['message'] for x in c['problems']}
    is_('doc_check numbers by network line, messages included',
       p.get(17, '') == 'THE NAME M2 IS ALREADY USED ON LINE 10',
       ' / '.join('%s: %s' % (k, p[k]) for k in sorted(p)))
    is_('   undefined nodes by network line',
       c['undefined'][0]['node'] == 'ZZ' and c['undefined'][0]['line'] == 16)
    d['settings']['options']['VEL_LIMIT'] = 'FAST'
    c = editor.doc_check(d)
    is_('a bad option is a settings problem, named by its PROJECT tab field',
       c['settings_problems'][0]['field'] == 'VEL_LIMIT'
       and 'NOT A NUMBER' in c['settings_problems'][0]['message'],
       c['settings_problems'][0]['message'])
    dg = editor.doc_diagnostics(d)
    is_('   listed in ERRORS with its field and no line',
       dg['errors'][0]['line'] is None and dg['errors'][0]['field'] == 'VEL_LIMIT'
       and dg['errors'][0]['message'].startswith('PROJECT TAB, VEL_LIMIT: '))
    d['settings']['options']['VEL_LIMIT'] = ''
    d['network'] = net_
    st = editor.doc_status(d, 9, 22)
    is_('doc_status: the PIPE template on network line 9', st['template']['command'] == 'PIPE')
    d['network'] = net_ + "PIPE Q1 R1 R2 3 50 \n"
    f = {x[0]: 1 for x in editor.doc_choices(d, 16, 27)}
    is_("doc_choices: the fittings, with the settings' SIZE unit in force",
       'E' in f and 'GV' in f)
    d['network'] = net_ + "PIPE Q2 R1 NOWHERE 3 50\n"
    r = editor.doc_solve(d, None)
    is_("doc_solve: an error's line is the network line",
       not r['ok'] and (r.get('line') or 0) == 16
       and re.match(r'^LINE 16: ', r.get('error') or ''), r.get('error'))
    d['network'] = net_
    r = editor.doc_solve(d, None)
    is_('doc_solve: the network with its settings solves', r['ok'] and r['converged'])

#==============================================================================
print('9. VALIDATE - what is wrong, why, and where')
#==============================================================================
if True:
    d = editor.split_file(EX7)
    v = editor.validate(d)
    is_('a good model validates with nothing to report', v['ok'] and not v['items'])
    net_ = d['network']
    d['network'] = net_ + '\n'.join([
        'PIPE Z1 H3 ZZ 3 32', 'SPRINKLER S9 0', 'PIPX', 'NODE LONE 0',
        'UNITS FLOW LPS', 'PIPE Q1 R1 R2 3 47', 'PIPE Q2 R1 R2 3 50 ZZ',
        'PIPE M2 R1 R2 3 50', 'PIPE Q3 R1 R2 3X 50', ''])
    v = editor.validate(d)
    it = {x['line']: x for x in v['items']}
    is_('nine problems found, in line order, and not valid',
       not v['ok'] and len(v['items']) == 9
       and ' '.join(str(x['line']) for x in v['items']) == '16 17 18 19 20 21 22 23 24',
       ' '.join(str(x['line']) for x in v['items']))

    def at(n):
        i = it[n]
        l = d['network'].split('\n')
        return l[n - 1][i['start']:i['end']]
    is_('an undefined node: the node itself, with why',
       it[16]['what'] == 'NODE ZZ IS USED, BUT NOT DEFINED' and at(16) == 'ZZ'
       and 'DEFINED BY NODE' in it[16]['why'])
    is_('a short line: just past its end, naming the field it needs, and the template',
       it[17]['what'] == 'SPRINKLER NEEDS MINFLOW' and it[17]['field'] == 'MINFLOW'
       and it[17]['start'] == 14
       and 'SPRINKLER <NAME> <ELEVATION> <MINFLOW> <K>' in it[17]['why'],
       '%s %s' % (it[17]['start'], it[17]['why']))
    is_('an unknown command: the command word, and the commands listed',
       at(18) == 'PIPX' and it[18]['field'] == 'COMMAND' and 'USE PIPE PC' in it[18]['why'])
    is_('a node nothing connects to',
       it[19]['what'] == 'NOTHING CONNECTS TO NODE LONE' and at(19) == 'LONE')
    is_('a setting in the network: the command word, and where it belongs',
       at(20) == 'UNITS' and 'PROJECT TAB' in it[20]['why'])
    is_('a size not in the database: the SIZE field, and why a bore is not guessed',
       at(21) == '47' and it[21]['field'] == 'SIZE' and 'NEVER GUESSED' in it[21]['why'])
    is_('a bad fitting: the fitting code', at(22) == 'ZZ' and 'FITTING CODES' in it[22]['why'])
    is_('a name used twice: the name, and why names are unique',
       at(23) == 'M2' and it[23]['what'] == 'THE NAME M2 IS ALREADY USED ON LINE 10'
       and 'ONE SET OF NAMES' in it[23]['why'])
    is_("a bad length: the length field, and how a length is written, in the file's unit",
       at(24) == '3X' and it[24]['field'] == 'LENGTH' and 'LENGTH UNIT (M)' in it[24]['why'])
    is_('every what and why in capitals',
       not [x for x in v['items'] if re.search(r'[a-z]', x['what'] + x['why'])])

    # Structure: lines all good, but part of the network is cut off.
    island = editor.split_file(
        "WATER S 0 500\nNODE A 0\nNODE B 0\nNODE C 0\n"
        "PIPE P1 S A 1 50\nPIPE P2 B C 1 50\nSPRINKLER H 0 0 80\nPIPE P3 A H 1 50\n")
    v = editor.validate(island)
    is_('a part of the network cut off from the rest: found before any calculation',
       not v['ok'] and re.match(r'^NODE [BC] IS NOT CONNECTED', v['items'][0]['what'])
       and re.match(r'^[34]$', str(v['items'][0]['line'])), v['items'][0]['what'])
    d = editor.split_file(EX7)
    d['settings']['options']['TOL_FLOW'] = 'TIGHT'
    v = editor.validate(d)
    is_('a bad option: in the PROJECT tab, its field named',
       not v['ok'] and v['items'][0]['tab'] == 'PROJECT'
       and v['items'][0]['field'] == 'TOL_FLOW' and v['items'][0].get('line') is None)

#==============================================================================
print('10. FILES - open .phc only, write the report')
#==============================================================================
if True:
    r = editor.load_file(os.path.join(EX, '01_single_branch.phc'))
    is_('a .phc opens as it is, with its path',
       r['path'].endswith('01_single_branch.phc')
       and r['text'] == slurp(os.path.join(EX, '01_single_branch.phc')))
    with open(os.path.join(TMP, 'crlf.phc'), 'wb') as fh:
        fh.write(b"TITLE A\r\nNODE B 0\r\n")
    is_('Windows line endings are read as plain lines',
       editor.load_file(os.path.join(TMP, 'crlf.phc'))['text'] == "TITLE A\nNODE B 0\n")
    try:
        editor.load_file(os.path.join(TMP, 'old.hcx'))
        ok = True
    except Exception as e:
        ok = False
        err = e
    is_('any other file is refused, with the reason',
       not ok and is_model_error(err)
       and 'THE EDITOR WORKS IN .PHC FILES' in err.msg)

    s = editor.solve_text(M, 'TEST.PHC')
    editor.write_report_file(s['net'], s['converged'], 'TEST.PHC', os.path.join(TMP, 'r.txt'))
    editor.write_report_file(s['net'], s['converged'], 'TEST.PHC', os.path.join(TMP, 'r.pdf'))
    txt = slurp(os.path.join(TMP, 'r.txt'))
    is_('WRITE REPORT .txt is the ASCII report',
       os.path.getsize(os.path.join(TMP, 'r.txt')) and 'PIPE SCHEDULE' in txt.upper()
       and not re.search(r'[^\x00-\x7f]', txt))
    with open(os.path.join(TMP, 'r.pdf'), 'rb') as fh:
        pdf_head = fh.read(5)
    is_('WRITE REPORT .pdf is a PDF',
       os.path.getsize(os.path.join(TMP, 'r.pdf')) and pdf_head == b'%PDF-')

print('\n%d passed, %d failed' % (_pass, _fail))
sys.exit(1 if _fail else 0)
