#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# report.py -- Python port of HardyCross/Report.pm.
#
# The calculation report, in monospace ASCII.  The full report writer is
# ported stage by stage; the unit helpers (sym and the decimal-place
# tables) are here from the first, because the JSON output prints them.
#
# WHY PLAIN ASCII
#   The report has to survive being printed, emailed, pasted into a
#   submission, diffed against last week's run and read on whatever a
#   certifier happens to have open.  Box-drawing characters, degree signs
#   and multiplication crosses all turn into question marks somewhere along
#   that chain.  Every character written here is 7-bit printable ASCII, and
#   the last thing the writer does is enforce that.
#
# THE RULE FOR EVERY NUMBER
#   It must be reproducible by hand from other numbers on the page.  So the
#   fitting table shows the base length, both multipliers and the product; the
#   pipe schedule shows loss per metre, total length and their product; and the
#   two end pressures differ by exactly the loss plus the elevation term.
#

import math
import re

from . import (VERSION, GAMMA_W, elem_hf, pipe_velocity, outlet_pressure,
               solve_model, curve_eval)
from . import pipedata
from .phc import read_string
from .parse import ensure_db

# 132 columns: the standard width of a monospace engineering listing, and what
# a 17-column pipe schedule actually needs.  118 was tried first and the pipe
# schedule ran to 136 -- the schedule is the content, so the page grew rather
# than the schedule being split across two tables a checker has to cross-read.
W = 132

#------------------------------------------------------------------------------
# Page furniture.  rule() is the heavy line around a section title, thin() the
# light line under a table's headings, title() a complete section heading with
# an optional clause reference pushed to the right-hand edge.  The PDF writer
# recognises these patterns to decide where pages break, so they are the only
# way section and table boundaries are drawn.
#------------------------------------------------------------------------------
def rule():
    return '=' * W + '\n'

def thin():
    return '-' * W + '\n'

def title(t, ref=None):
    line = (' %-*s%s' % (W - 1 - len(ref), t, ref)) if ref is not None else ' ' + t
    return '\n' + rule() + line + '\n' + rule()

def sub_t(t):
    return '\n ' + t + '\n' + thin()

# Anything the data carries that is not ASCII -- the database's degree signs,
# multiplication crosses and em dashes -- is spelled out rather than dropped.
def ascii_(t):
    t = t or ''
    t = t.replace('\xb0', ' deg')
    t = t.replace('\xd7', 'x')
    for ch in '\u2012\u2013\u2014\u2015':
        t = t.replace(ch, '-')
    for ch in '\u2018\u2019\u2032':
        t = t.replace(ch, "'")
    for ch in '\u201c\u201d':
        t = t.replace(ch, '"')
    t = re.sub(r'[^\x20-\x7E\n]', '?', t)
    return t

# A number as Perl stringifies it for a hash key or a %s field: 120.0 is "120".
def _s(v):
    if v is None:
        return ''
    if isinstance(v, float) and v == int(v) and abs(v) < 1e15:
        return str(int(v))
    return str(v)

# A number to a fixed number of places, or '-' when there is none.  A dash is
# an absence; a zero is a measurement.  They must never look alike in a
# schedule a checker is reading.
def fx(v, d):
    return ('%.*f' % (d, v)) if v is not None else '-'

# The model file uses upper-case unit CODES (KPA, LPM).  A certified report
# uses SI SYMBOLS: "KPA" is not a unit, "kPa" is, and the case carries meaning
# (mPa and MPa differ by nine orders of magnitude).
SYM = {'KPA': 'kPa', 'BAR': 'bar', 'MPA': 'MPa', 'PSI': 'psi', 'M': 'm',
       'MH2O': 'm H2O', 'MWC': 'm H2O', 'FTH2O': 'ft H2O', 'FT': 'ft',
       'LPM': 'L/min', 'L/MIN': 'L/min', 'LPS': 'L/s', 'L/S': 'L/s',
       'M3H': 'm3/h', 'M3/H': 'm3/h', 'GPM': 'US gpm', 'USGPM': 'US gpm',
       'IGPM': 'Imp gpm', 'MM': 'mm', 'IN': 'in'}

def sym(u):
    u = u or ''
    return SYM.get(u.upper(), u)

# Decimal places per unit, chosen so every printed value resolves 0.1 kPa and
# 0.1 L/min or better.  A fixed two decimals was fine in kPa and quietly
# useless in bar: 0.01 bar is 1 kPa, and the stress test found the same model
# reported 0.5 kPa apart in kPa and in bar purely from print rounding.
PDP = {'KPA': 1, 'BAR': 3, 'MPA': 4, 'PSI': 2, 'M': 2, 'MH2O': 2, 'MWC': 2,
       'FTH2O': 2, 'FT': 2}
QDP = {'LPM': 1, 'L/MIN': 1, 'LPS': 3, 'L/S': 3, 'M3H': 3, 'M3/H': 3,
       'GPM': 2, 'USGPM': 2, 'IGPM': 2}

def pdp(u):
    return PDP.get((u or '').upper(), 2)

def qdp(u):
    return QDP.get((u or '').upper(), 2)

#------------------------------------------------------------------------------
# wrap -- a paragraph, word-wrapped to the page width, with a hanging indent.
# $lead is printed on the first line and its width in spaces on the rest, so a
# numbered note reads as one item however many lines it takes.
#------------------------------------------------------------------------------
def wrap(lead, text):
    w = W - len(lead)
    lines = []
    cur = ''
    for word in re.split(r'\s+', ascii_(text)):
        if not len(word):
            continue
        if len(cur) + len(word) + 1 > w and len(cur):
            lines.append(cur)
            cur = word
        else:
            cur = (cur + ' ' + word) if len(cur) else word
    if len(cur):
        lines.append(cur)
    pad = ' ' * len(lead)
    return lead + ('\n' + pad).join(lines) + '\n'

#==============================================================================
# write_report -- the whole calculation as 132-column ASCII text.
#
#   net     a network that has been read AND solved
#   ok      whether it converged; a report of an unconverged model says so on
#           the cover and again in the notes, in capitals
#   path    the model file, printed on the cover for traceability
#
# The report is assembled top to bottom: cover sheet, then numbered sections.
# Each section is written so that every figure can be reproduced by hand from
# others on the same page, and says which check to make.  The same text feeds
# the PDF writer, so the two formats can never disagree.
#==============================================================================
def write_report(net, ok, path):
    from . import demand, validate
    uf, up, ul = net['f_flow'], net['f_pres'], net['f_len']
    pj = net.get('project') or {}
    o = net['opts']
    out = ''

    # Whether any pipe takes its data from the pipe database; Sections 2
    # and 4 word their provenance statements on it.
    uses_db = [e for e in net['elems'][1:] if e.get('ptype')]

    #----------------------------------------------------------- cover sheet
    out += cover_sheet(net, ok, path)

    #------------------------------------------------------------ 1. basis
    # Method, friction equation, units, tolerances and the result: what a
    # reviewer needs before any number in the report means anything.
    out += title('1. BASIS OF CALCULATION')
    dw = (o.get('method') or 'HW') == 'DW'
    out += ' %-26s %s\n' % ('Friction method',
                            'Darcy-Weisbach, Colebrook-White friction factor'
                            if dw else 'Hazen-Williams, AS 2118.1:2017 Clause 14.10')
    if not dw:
        out += (' %-26s P = %.4g x Q^%.3f / (C^%.3f x d^%.3f)   kPa/m, Q L/min, d mm\n'
                % ('Friction equation', o['hwk'], o['hwq'], o['hwq'], o['hwd']))
    if dw:
        # Where each pipe's roughness came from; an assumed one is never
        # passed off as data.
        src = {}
        for e in net['elems'][1:]:
            if e['kind'] == 'PIPE':
                src[e.get('eps_src') or 'GIVEN'] = src.get(e.get('eps_src') or 'GIVEN', 0) + 1
        parts = []
        for k in ('GIVEN', 'DATABASE'):
            if src.get(k):
                parts.append('%d %s' % (src[k], {'GIVEN': 'as given in the model',
                                                 'DATABASE': 'from the database for the pipe type'}[k]))
        if src.get('DEFAULT'):
            parts.append('%d ASSUMED 0.045 mm, the program default - see Warnings' % src['DEFAULT'])
        out += wrap(' %-26s ' % 'Pipe roughness', 'Pipes: ' + '; '.join(parts) + '.')
    out += (' %-26s flow %s, pressure %s, length %s, diameter %s\n' % ('Units',
            sym(net['u_flow']), sym(net['u_pres']), sym(net['u_len']), sym(net['u_dia'])))
    out += (' %-26s flow %.2g %s, loop %.2g %s, %d iterations maximum  (when the iteration stops)\n'
            % ('Solver tolerance', o['tol_flow'] / uf, sym(net['u_flow']),
               o['tol_loop'] / up, sym(net['u_pres']), o['maxiter']))
    # The limits the answer is checked to: PHCP's own, whatever the solver
    # tolerance (hardycross.validate).
    out += (' %-26s loop closure and element equations %.3g %s; continuity %g of the largest flow\n'
            % ('Verification limit', validate.VERIFY_P / up, sym(net['u_pres']),
               validate.VERIFY_Q_REL))
    if [e for e in net['elems'][1:] if e['kind'].startswith('ORIFICE')]:
        out += (' %-26s %g %% of the target drop (ORIF_DP_TOL%s)\n'
                % ('Orifice duty tolerance',
                   o.get('orif_dp_tol') if o.get('orif_dp_tol') is not None else validate.ORIF_DP_TOL,
                   ', set in the model' if o.get('orif_dp_tol_set') else ', default'))
    if [e for e in net['elems'][1:] if e.get('curve')]:
        out += (' %-26s %g x the highest flow of a curve; beyond its points a value is EXTRAPOLATED\n'
                % ('Curve extrapolation limit', validate.EXTRAP_MAX))
    # Printed whether or not it was set, and says which: a default the
    # designer never chose must not read as a requirement of the Standard.
    out += (' %-26s %g m/s  (%s)\n' % ('Velocity limit', o.get('vel_limit') if o.get('vel_limit') is not None else 6,
                                       'set in the model OPTIONS' if o.get('vel_limit_set')
                                       else 'program default - not set in the model, not from a standard'))
    # The pressure every outlet discharges on: OPTION VELOCITY_PRESSURE.
    out += ' %-26s %s\n' % ('Outlet discharge',
        'q = K x sqrt(Pn), Pn = Pt - Pv, in-line sprinklers (AS 2118.1 Cl 14.15); '
        'end sprinklers and other outlets on Pt'
        if o.get('vel_press') else
        'q = K x sqrt(Pt), total pressure, every outlet (velocity pressure not included)')
    out += ' %-26s %s\n' % ('Result',
        'CONVERGED in %d iterations, %d loops' % (net['iters'], len(net['loops']))
        if ok else '*** NOT CONVERGED - NOTHING IN THIS REPORT IS USABLE ***')
    acc1 = validate.assess(net, ok)['validation']['acceptance']
    out += ' %-26s %s\n' % ('Acceptance', ('' if acc1 == 'ACCEPTED' else '*** ')
                            + validate.acceptance_text(acc1) + ' (Sections 11 and 14)')
    out += '\n Node head is total head referred to datum: H = p + 9.80665 z  (kPa, m).\n'
    out += ' Loops are fundamental loops of a spanning tree; supplies and outlets are\n'
    out += ' edges to a reference node at datum, so pseudo-loops tie fixed-grade points.\n'
    if net.get('areas'):
        out += design_areas(net)
    if net.get('sizing'):
        out += auto_sizing(net)

    #-------------------------------------------------------- 2. pipe data
    # Which pipe types were used, the standard each is made to, the C factors
    # in force, and the database the dimensions came from.
    out += title('2. PIPE DATA')
    used = {}
    for e in net['elems'][1:]:
        if e['kind'] != 'PIPE':
            continue
        k = e.get('ptype') or '(untyped)'
        used.setdefault(k, {'c': {}, 'n': 0})
        used[k]['c'][_s(e['c'])] = 1
        used[k]['n'] += 1
    out += ' %-10s %-40s %-14s %-10s %6s\n' % ('CODE', 'PIPE TYPE', 'STANDARD', 'C', 'PIPES')
    out += thin()
    for k in sorted(used):
        info = None if k == '(untyped)' else pipedata.pipe_type(k)
        out += ' %-10s %-40s %-14s %-10s %6d\n' % (k,
            ascii_(info['name']) if info else 'bore entered directly',
            ascii_(info['std']) if info else '-',
            '/'.join(sorted(used[k]['c'], key=float)), used[k]['n'])

    #--------------------------------------------------- 3. fitting allowances
    # Every fitting on every pipe, with its source, base length, both
    # multipliers and the product, so each allowance can be recomputed from
    # the page.
    out += title('3. FITTING ALLOWANCES')
    fitted = [e for e in net['elems'][1:]
              if e['kind'] == 'PIPE' and e.get('fitres') and e['fitres'].get('records')]
    if not len(fitted):
        out += ' No fitting strings in this model.  Any fitting allowance was entered directly\n'
        out += ' as an equivalent length and carries no database provenance.\n'
    else:
        out += (' %-7s %-4s %3s %-5s %-36s %-4s %6s %8s %6s %6s %7s %7s  %s\n'
                % ('PIPE', 'DN', 'QTY', 'CODE', 'FITTING', 'SRC', 'BASE m', 'BASIS mm',
                   'C MUL', 'D MUL', 'EACH m', 'TOTAL m', 'STATUS'))
        out += thin()
        for e in fitted:
            for r in e['fitres']['records']:
                src = ('n/c' if (r.get('method') == 'NOT_COUNTED')
                       else 'PPI' if r.get('method') == 'LE_OVER_D'
                       else 'AS' if re.search(r'14\.11\.1', r.get('doc') or '')
                       else 'FM' if re.search(r'Table 12', r.get('doc') or '')
                       else 'CPVC' if re.search(r'BlazeMaster', r.get('doc') or '')
                       else '?')
                # 36 characters for the label: the longest status,
                # ASSUMPTION_REQUIRED, otherwise ran the row to 138 columns.
                out += (' %-7s %-4s %3d %-5s %-36s %-4s %6s %8s %6s %6s %7s %7s  %s\n'
                        % (e['id'], _s(e.get('dn')), r['count'], r['code'],
                           ascii_(r.get('label') or '')[:36], src,
                           fx(r.get('base'), 2), fx(r.get('basis_bore'), 2),
                           fx(r.get('cmult'), 3), fx(r.get('dmult'), 3),
                           fx(r.get('each'), 3), fx(r.get('total'), 3), r['status']))
            fs = (e.get('fitspec') or '').replace('+', ',')
            out += ' %-7s %-100s %7s\n' % ('', 'allowance for ' + e['id']
                                          + ' (' + ascii_(fs) + ')', fx(e['fitres'].get('total'), 3))
        out += thin()
        out += ' SOURCE  AS   AS 2118.1:2017 Table 14.11.1, DN20-DN150, C = 120, AS 1074 Medium basis\n'
        out += '         FM   FM Global DS 3-0 (March 2010) Table 12(a), DN200-DN600, C = 120, Sch 40 basis\n'
        out += '         CPVC TYCO/BlazeMaster IH-1900 Table F2 - no corrections applied\n'
        out += '         PPI  PPI Handbook of PE Pipe Ch.6, Le = K\'d, actual bore - no corrections\n'
        out += '         n/c  published but not counted - does not turn the flow\n'
        out += ' C MUL   (C / 120)^1.85\n'
        out += ' D MUL   (d installed / d basis)^4.87\n'
        out += ' EACH  = BASE x C MUL x D MUL.   TOTAL = QTY x EACH.\n'

    #--------------------------------------------- 4. assumptions and elections
    # Anything the calculation assumed rather than read from a governing
    # document, stated so it can be challenged.
    out += title('4. ASSUMPTIONS AND ELECTIONS')
    notes = []
    if uses_db:
        # The database is user editable, so name the exact file and its
        # fingerprint: a later edit to the data cannot pass for this one.
        # The program's own database is named by its file name alone; one in
        # a team folder or beside the program by its full path and where it
        # came from, so a reader can tell the shared data from a local copy.
        db = pipedata.path()
        frm = pipedata.origin(db)
        if frm == 'BUILT-IN':
            db = re.sub(r'.*[\\/]', '', db)
        else:
            db = db + ' (' + frm.lower() + ')'
        iss = pipedata.issued()
        notes.append('Pipe dimensions and fitting allowances are taken from the database: '
                     + pipedata.dataset() + (' (%s)' % iss if iss != '' else '')
                     + ', file %s, SHA-256 %s.' % (db, pipedata.sha256()))
    if [r for e in fitted for r in e['fitres'].get('records') or []
            if re.search(r'14\.11\.1', r.get('doc') or '') and (r.get('dmult') or 1) != 1]:
        notes.append('AS 2118.1 does not state a basis bore for Table 14.11.1. AS 1074 Medium '
                     'is adopted as that basis (an office assumption); AS 2118.1 values on '
                     'other pipe are corrected against it.')
    fallback = [r for e in fitted for r in e['fitres'].get('records') or []
                if r.get('status') == 'ASSUMPTION_REQUIRED']
    if fallback:
        p = sorted({'%s DN%s' % (r['type'], _s(r['dn'])) for r in fallback})
        notes.append('ASSUMPTION_REQUIRED: generic equivalent-length fallback used for '
                     + ', '.join(p) + '. No product-specific hydraulic data are held for '
                     'these fittings.')
    if (o.get('fitting_basis') or '') == 'STANDARD':
        notes.append('ELECTION: calculated to the published Standard alone. AS 2118.1 Table '
                     '14.11.1 is applied unmodified and the diameter modifier was NOT applied.')
    if o.get('vel_press'):
        spk = [e for e in net['elems'][1:]
               if e['kind'] == 'DISCHARGE' and (e.get('otype') or '').upper() == 'SPRINKLER']
        inl = [e for e in spk if e.get('pv')]
        notes.append('ELECTION: velocity pressures included (OPTION VELOCITY_PRESSURE ON), at the '
                     'discretion of the designer under AS 2118.1:2017 Clause 14.15, for range pipes and '
                     'distribution mains alike.  An in-line sprinkler discharges on the normal pressure '
                     'Pn = Pt - Pv, Pv = rho v^2 / 2 in the pipe bringing the most water into its node.  An '
                     'end sprinkler (no pipe carrying water on beyond it), hydrants, hose reels and fixed '
                     'flows discharge on total pressure.  No normal pressure is taken at a branch take-off: '
                     'every branch is solved in full.  %d sprinkler(s), %d in-line '
                     'and on Pn.' % (len(spk), len(inl)))
    for e in [x for x in net['elems'][1:]
              if x['kind'] == 'PIPE' and x.get('ptype') and x.get('c_given')]:
        tc = pipedata.pipe_type(e['ptype'])['c']
        if e['c'] != tc:
            notes.append("Pipe %s: C = %s used in place of %s's C = %s."
                         % (e['id'], _s(e['c']), e['ptype'], _s(tc)))
    untyped = [x for x in net['elems'][1:] if x['kind'] == 'PIPE' and not x.get('ptype')]
    if untyped:
        first = [x['id'] for x in untyped[:8]]
        notes.append('%d pipe(s) have a bore entered directly rather than a '
                     'pipe type, and so carry no database provenance: %s%s.'
                     % (len(untyped), ', '.join(first), ' ...' if len(untyped) > 8 else ''))
    if not dw and [x for x in net['elems'][1:]
                   if x['kind'] == 'PIPE' and (x.get('kfit') or 0) > 0]:
        notes.append('Minor-loss K values are present on a Hazen-Williams calculation. Under '
                     'AS 2118.1 fitting allowances are equivalent lengths; K belongs with '
                     'Darcy-Weisbach. The K terms have been applied as entered.')
    # How a curve is drawn between the points entered changes the answer, so
    # it is stated whenever the model has one.
    curved = [x for x in net['elems'][1:] if x.get('curve')]
    if curved:
        notes.append('Supply, pump and loss-device curves (' + ', '.join(x['id'] for x in curved[:8])
                     + (' ...' if len(curved) > 8 else '') + ') pass through every point entered, with pressure '
                     'linear in Q^1.85 between points and continued linearly beyond the last.')
    notes.append('No project-specific manufacturer data are relied upon.')
    for i in range(len(notes)):
        out += wrap(' %2d  ' % (i + 1), notes[i])

    #----------------------------------------------------- 5. node schedule
    # Every node's elevation, pressure and total head, and the outlet at it.
    out += title('5. NODE SCHEDULE')
    out += (' %-10s %10s %12s %12s %12s %12s %11s  %s\n'
            % ('NODE', 'ELEV ' + sym(net['u_len']), 'ELEV HEAD', 'PRESSURE', 'TOTAL HEAD',
               'DISCHARGE', 'REQUIRED P', 'OUTLET'))
    out += (' %-10s %10s %12s %12s %12s %12s %11s\n'
            % ('', '', sym(net['u_pres']), sym(net['u_pres']), sym(net['u_pres']),
               sym(net['u_flow']), sym(net['u_pres'])))
    out += thin()
    for i in range(1, len(net['nodes'])):
        n = net['nodes'][i]
        if n['id'] == 'REF':
            continue
        q, preq, tag = n['demand'], 0, ''
        for e in net['elems'][1:]:
            if e['kind'] == 'DISCHARGE' and e['n1'] == i:
                q += e['q']
                preq = e['preq']
                tag = e['id']
        # A fixed flow's minimum pressure is a requirement at its node too.
        # Its flow is already in the node's demand above.
        for f in [f for f in (net.get('fixed') or []) if f['n1'] == i]:
            if f.get('preq') is not None and f['preq'] > preq:
                preq = f['preq']
            tag = (tag + ' ' + f['id']) if tag else f['id']
        pd, qd = pdp(net['u_pres']) + 1, qdp(net['u_flow'])
        out += (' %-10s %10.3f %12.*f %12.*f %12.*f %12.*f %11s  %s\n'
                % (n['id'], n['z'] / ul, pd, GAMMA_W * n['z'] / up,
                   pd, (n['h'] - GAMMA_W * n['z']) / up, pd, n['h'] / up, qd, q / uf,
                   fx(preq / up, pd) if preq else '-', tag))
    out += thin()
    out += ' Check: PRESSURE + ELEV HEAD = TOTAL HEAD on every row.\n'

    #----------------------------------------------------- 6. pipe schedule
    #
    # NFPA worksheet layout: four lines per pipe, laid out the way a checker
    # works a pipe by hand, and the form fire authorities are used to reading.
    #
    #   line 1  BEG node, elevation, q and K of an outlet there, L, and Pt
    #   line 2  pipe, Q in the pipe, fitting string, F, C, Pe and Pv
    #   line 3  pipe type, velocity, bore, TL, friction per length, Pf, Pn
    #   line 4  DN, END node, elevation, q and K of an outlet there, Pt
    #
    # Each pipe is written in the direction its water flows, so BEG is the
    # upstream end, Q is positive and Pt falls along the pipe by Pe + Pf --
    # the sum a checker does first.  A pipe drawn against the flow is turned round
    # for the schedule only; the model is not changed.
    out += title('6. PIPE SCHEDULE')
    pd, qd = pdp(net['u_pres']), qdp(net['u_flow'])
    pu, qu, lu = sym(net['u_pres']), sym(net['u_flow']), sym(net['u_len'])
    # Headings are placed at measured column positions, taken from the data
    # lines below, rather than by a second format string -- two format
    # strings kept in step by eye drifted a column apart on the first try.
    #   PIPE 1  BEG 10  ELEV ends 26  q= 30  K= 43  L= 62  C 75  Pt 89
    def place(*args):
        line = [' '] * 120
        for i in range(0, len(args), 3):
            col, txt, right = args[i], args[i + 1], args[i + 2]
            if right:
                col = col - len(txt) + 1
            line[col:col + len(txt)] = list(txt)
        return ''.join(line).rstrip() + '\n'

    out += place(1, 'PIPE', 0, 10, 'BEG', 0, 26, 'ELEV', 1, 30, 'FLOW', 0,
                 43, 'K-FACTOR', 0, 62, 'LENGTH', 0, 75, 'C-FACTOR', 0, 89, 'PRESSURE', 0)
    out += place(1, 'NO.', 0, 26, '(%s)' % lu, 1, 30, qu, 0,
                 43, 'FITTINGS', 0, 62, 'FTG %s' % lu, 0, 75, 'FRI-LOSS', 0, 89, '(%s)' % pu, 0)
    out += place(1, 'TYPE', 0, 10, 'END', 0, 26, 'ELEV', 1,
                 43, 'DIAMETER mm', 0, 62, 'TOTAL %s' % lu, 0, 75, '(%s/%s)' % (pu, lu), 0)
    out += thin()

    # Outlets and fixed demands by node, so q and K can be printed beside
    # the node they belong to.
    at = {}
    for e in net['elems'][1:]:
        if e['kind'] != 'DISCHARGE':
            continue
        at[e['n1']] = {'q': e['q'], 'k': e['k'] * math.sqrt(up) / uf}
    for i in range(1, len(net['nodes'])):
        d = net['nodes'][i]['demand']
        if not d:
            continue
        if i not in at:
            at[i] = {'q': d, 'k': None}
    # Each outlet's q is printed exactly once, on the first pipe listed that
    # touches its node.  Printing it on every pipe from a node would invite
    # someone to add the same discharge up two or three times.
    shown = {}

    def qk(node):
        oo = at.get(node)
        if oo is None or node in shown:
            return '-', '-'
        shown[node] = 1
        return ('%.*f' % (qd, oo['q'] / uf),
                '%.3f' % oo['k'] if oo['k'] is not None else 'fixed')

    pipes = [e for e in net['elems'][1:] if e['kind'] == 'PIPE']
    for n in range(len(pipes)):
        e = pipes[n]
        hf_raw = elem_hf(e, e['q'], o)[0]
        fwd = e['q'] >= 0
        ib, ie = (e['n1'], e['n2']) if fwd else (e['n2'], e['n1'])
        nb, ne = net['nodes'][ib], net['nodes'][ie]
        q = abs(e['q'])
        pf = hf_raw if fwd else -hf_raw                # loss in the flow direction
        pe = GAMMA_W * (ne['z'] - nb['z'])              # rise costs pressure
        ptb = nb['h'] - GAMMA_W * nb['z']
        pte = ne['h'] - GAMMA_W * ne['z']
        v = abs(pipe_velocity(q, e['dia']))
        pv = 0.5 * v ** 2                               # rho v^2 / 2, kPa
        lt = e['len'] + e['eqv']
        qb, kb = qk(ib)
        qe, ke = qk(ie)
        fit = (e.get('fitspec') or '').replace('+', ',')
        if not len(fit):
            fit = 'EQV' if e['eqv'] > 0 else '-'

        out += (' %-8s %-8s %8.3f   q=%9s  K= %-14s  L= %8.2f  %-12s  Pt %8.*f  Pt %8.*f\n'
                % ('', nb['id'], nb['z'] / ul, qb, kb, e['len'] / ul, '',
                   pd, ptb / up, pd, ptb / up))
        out += (' %-8s %-8s %8s   Q=%9.*f  F= %-14s  F= %8.2f  %-12s  Pe %8.*f  Pv %8.*f\n'
                % (e['id'], '', '', qd, q / uf, fit[:14], e['eqv'] / ul,
                   'C= %.0f' % e['c'], pd + 1, pe / up, pd + 1, pv / up))
        out += (' %-8s %-8s %8s Vel=%9.2f  D= %-14s TL= %8.2f  %-12s  Pf %8.*f  Pn %8.*f\n'
                % (e.get('ptype') or '', '', '', v, '%.2f' % e['dia'], lt / ul,
                   ('%.*f' % (pd + 3, abs(pf) / lt / up * ul)) if lt > 0 else '-',
                   pd + 1, pf / up, pd, (ptb - pv) / up))
        # The END line names q and K only when it has an outlet to report.
        # Dashes on every END line are noise the NFPA form does not carry.
        qkseg = (' ' * 30) if qe == '-' else ('q=%9s  K= %-14s' % (qe, ke))
        out += (' %-8s %-8s %8.3f   %s  %-11s  %-12s  Pt %8.*f\n'
                % (('DN%s' % _s(e['dn'])) if e.get('dn') is not None else '',
                   ne['id'], ne['z'] / ul, qkseg, '', '', pd, pte / up))
        if n < len(pipes) - 1:
            out += '      ' + '-' * (W - 6) + '\n'
    out += thin()
    out += wrap(' ', "Each pipe is written in the direction of flow: BEG is upstream, and Pt falls "
               "along the pipe by Pe + Pf.  q and K are the outlet at that node, printed once, on the "
               "first pipe that reaches it; '-' means no outlet, or one already shown.")
    out += wrap(' ', 'Check: TL = L + F.   Pf = FRI-LOSS x TL.   Pt END = Pt BEG - Pe - Pf.   '
               'Pn = Pt BEG - Pv.')
    out += wrap(' ',
        'Pv, the velocity pressure (rho v^2 / 2), and Pn, the normal pressure, are shown for '
        'every pipe.  Velocity pressures are INCLUDED (OPTION VELOCITY_PRESSURE ON, AS 2118.1 '
        'Clause 14.15): an in-line sprinkler discharges on q = K x sqrt(Pn), with Pv from the '
        'pipe bringing the most water into its node - Section 7 gives each one.  Pipe friction '
        'and every other pressure in this report are total pressure.  Fittings are equivalent '
        'lengths from the pipe and fitting database; see Section 3.'
        if o.get('vel_press') else
        'Pv, the velocity pressure (rho v^2 / 2), and Pn, the normal pressure, are '
        'shown in the NFPA manner for reference only.  This calculation works in TOTAL pressure '
        'throughout, as FM Global DS 3-0 does: every outlet discharge is q = K x sqrt(Pt), not '
        'K x sqrt(Pn).  Fittings are equivalent lengths from the pipe and fitting database; '
        'see Section 3.')

    #-------------------------------------------------- 7. outlet compliance
    # Each outlet's required and achieved flow and pressure, PASS or FAIL.
    # Fixed flows with a minimum pressure are listed after the outlets: their
    # flow is set, so only the pressure can fail, and K is shown as "fixed".
    dis = [e for e in net['elems'][1:] if e['kind'] == 'DISCHARGE']
    fix = [f for f in (net.get('fixed') or []) if f.get('preq') is not None]
    if dis or fix:
        out += title('7. OUTLET COMPLIANCE')
        # With velocity pressure ON, ACT P is the pressure each outlet
        # discharges on, and the total pressure and the Pv taken off it are
        # given beside it.  OFF, the table is as it always was.
        vp = o.get('vel_press')

        def vpx(*a):
            return (' %9s %9s' % a) if vp else ''
        out += (' %-12s %-8s %9s %11s %11s %11s %11s%s   %s\n'
                % ('OUTLET', 'NODE', 'K', 'REQ Q', 'ACT Q', 'REQ P', 'ACT P',
                   vpx('PT', 'PV'), 'RESULT'))
        out += thin()
        fails = 0
        for e in dis:
            q = e['q']        # signed: an outlet discharging backwards never passes
            p = outlet_pressure(net, e)
            pas = q >= e['qreq'] - 1e-6 and p >= e['preq'] - 1e-6
            if not pas:
                fails += 1
            pd, qd = pdp(net['u_pres']), qdp(net['u_flow'])
            out += (' %-12s %-8s %9.3f %11.*f %11.*f %11.*f %11.*f%s   %s\n'
                    % (e['id'], net['nodes'][e['n1']]['id'],
                       e['k'] * math.sqrt(up) / uf, qd, e['qreq'] / uf, qd, q / uf,
                       pd, e['preq'] / up, pd, p / up,
                       vpx('%.*f' % (pd, (net['nodes'][e['n1']]['h'] - GAMMA_W * e['z']) / up),
                           '%.*f' % (pd + 1, e['pv'] / up) if e.get('pv') else '-'),
                       'PASS' if pas else '*** FAIL'))
        for f in fix:
            p = net['nodes'][f['n1']]['h'] - GAMMA_W * f['z']
            pas = p >= f['preq'] - 1e-6
            if not pas:
                fails += 1
            pd, qd = pdp(net['u_pres']), qdp(net['u_flow'])
            out += (' %-12s %-8s %9s %11.*f %11.*f %11.*f %11.*f%s   %s\n'
                    % (f['id'], net['nodes'][f['n1']]['id'], 'fixed',
                       qd, f['qreq'] / uf, qd, f['q'] / uf,
                       pd, f['preq'] / up, pd, p / up,
                       vpx('%.*f' % (pd, p / up), '-'), 'PASS' if pas else '*** FAIL'))
        out += thin()
        if dis and not fix:
            out += ' Check: ACT Q = K x sqrt(ACT P) on every row (AS 2118.1 Appendix B, eqn B1).\n'
        if fix:
            out += (' Check: ACT Q = K x sqrt(ACT P) on every row with a K (AS 2118.1 Appendix B,\n'
                    ' eqn B1).  A fixed flow\'s Q is set by the model; only its pressure is checked.\n')
        if vp:
            out += wrap(' ', 'Velocity pressure included: ACT P is the pressure each outlet discharges on - '
                       'ACT P = PT - PV for an in-line sprinkler, PV from the pipe bringing the most water into '
                       "its node; ACT P = PT, PV '-', for an end sprinkler and every other outlet.")
        out += (' *** %d OUTLET(S) BELOW REQUIREMENT ***\n' % fails) if fails \
            else ' All outlets meet their requirement.\n'

    #------------------------------------------------- 8. flow path worksheet
    gov, gmargin = demand.governing_outlet(net)
    if gov:
        out += title('8. FLOW PATH TO THE GOVERNING OUTLET')
        out += wrap('    ', ('Governing outlet: %s at node %s - the outlet with the least '
                    'pressure to spare over its requirement (%.2f %s), and so the first to fail as the '
                    'supply weakens.  It is not necessarily the one furthest away on the drawing.'
                    % (gov['id'], net['nodes'][gov['n1']]['id'], gmargin / up, sym(net['u_pres']))))
        steps, perr = demand.flow_path(net, gov)
        if not steps:
            out += ' Path could not be traced: %s\n' % perr
        else:
            out += '\n'
            pf = ' %3s %-8s %-7s %-6s %-6s %4s %6s %9s %7s %8s %8s %8s %8s %9s %9s %7s\n'
            out += pf % ('STEP', 'ELEMENT', 'TYPE', 'FROM', 'TO', 'DN', 'T', 'PF/M',
                         'Q', 'PF', 'PE', 'P FROM', 'P TO', 'P SOLVED', 'DIFF', '')
            out += pf % ('', '', '', '', '', '', sym(net['u_len']),
                         sym(net['u_pres']) + '/' + sym(net['u_len']), sym(net['u_flow']),
                         sym(net['u_pres']), sym(net['u_pres']), sym(net['u_pres']),
                         sym(net['u_pres']), sym(net['u_pres']), sym(net['u_pres']),
                         '')
            out += thin()
            nm = {'PIPE': 'PIPE', 'PUMP': 'PUMP', 'SUPPLY_STATIC': 'SUPPLY',
                  'SUPPLY_CURVE': 'SUPPLY', 'FIXED_DROP': 'PRV', 'ORIFICE': 'ORIFICE',
                  'ORIFICE_REQUIRED': 'ORIF_P', 'BFP': 'BFP', 'RATIO': 'PRA'}
            p = None           # running pressure, carried forward by hand
            worst = 0
            k = 0
            for st in steps:
                e = st['elem']
                if e['kind'].startswith('SUPPLY_'):
                    # The path starts at the supply connection, at its solved pressure.
                    p = demand.gauge(net, st['to'])
                    out += (' %3s %-8s %-7s %-6s %-6s %4s %6s %9s %7.1f %8s %8s %8s %8.1f %9.1f %9s\n'
                            % ('', e['id'], 'SUPPLY', '-', net['nodes'][st['to']]['id'],
                               '-', '-', '-', st['q'] / uf, '-', '-', '-', p / up, p / up, 'start'))
                    continue
                k += 1
                hf = elem_hf(e, e['q'], o)[0]
                # Loss in the direction walked.  The path follows the flow, so for
                # a pipe it is positive; a pump shows as a negative loss -- a gain.
                loss = hf if e['n1'] == st['from'] else -hf
                a, b = net['nodes'][st['from']], net['nodes'][st['to']]
                pe = GAMMA_W * (b['z'] - a['z'])
                pfrom = p
                p = p - loss - pe
                solved = demand.gauge(net, st['to'])
                diff = p - solved
                if abs(diff) > worst:
                    worst = abs(diff)
                pipe = e['kind'] == 'PIPE'
                lt = e['len'] + e['eqv'] if pipe else 0
                out += (' %3d %-8s %-7s %-6s %-6s %4s %6s %9s %7.1f %8.2f %8.2f %8.1f %8.1f %9.1f %9.2e\n'
                        % (k, e['id'], nm.get(e['kind'], e['kind']), a['id'], b['id'],
                           (_s(e['dn']) if e.get('dn') is not None else '-') if pipe else '-',
                           '%.2f' % (lt / ul) if pipe else '-',
                           ('%.*f' % (pdp(net['u_pres']) + 3, loss / lt / up * ul))
                           if (pipe and lt > 0) else '-',
                           st['q'] / uf, loss / up, pe / up, pfrom / up, p / up,
                           solved / up, diff / up))
            out += thin()
            pgo = demand.gauge(net, gov['n1'])
            if gov['kind'] == 'FIXEDFLOW':
                # A fixed flow has no K: its discharge is set by the model.
                out += (' Fixed flow %s: pressure %.1f %s, required %.1f, margin %.1f.   '
                        'Discharge %.1f %s, fixed.\n'
                        % (gov['id'], pgo / up, sym(net['u_pres']), gov['preq'] / up,
                           (pgo - gov['preq']) / up, gov['q'] / uf, sym(net['u_flow'])))
            elif gov.get('pv'):
                # An in-line sprinkler under OPTION VELOCITY_PRESSURE ON: the
                # path lands on its total pressure, and it discharges on Pn.
                pn = pgo - gov['pv']
                out += (' Outlet %s: total pressure Pt %.1f %s, velocity pressure Pv %.2f (pipe %s), '
                        'normal pressure Pn %.1f, required %.1f, margin %.1f.\n'
                        ' Discharge %.1f %s = K %.3f x sqrt(Pn %.1f).\n'
                        % (gov['id'], pgo / up, sym(net['u_pres']), gov['pv'] / up, gov['pv_pipe'],
                           pn / up, gov['preq'] / up, (pn - gov['preq']) / up,
                           abs(gov['q']) / uf, sym(net['u_flow']), gov['k'] * math.sqrt(up) / uf, pn / up))
            else:
                out += (' Outlet %s: pressure %.1f %s, required %.1f, margin %.1f.   '
                        'Discharge %.1f %s = K %.3f x sqrt(%.1f).\n'
                        % (gov['id'], pgo / up, sym(net['u_pres']), gov['preq'] / up,
                           (pgo - gov['preq']) / up, abs(gov['q']) / uf, sym(net['u_flow']),
                           gov['k'] * math.sqrt(up) / uf, pgo / up))
            # The basis, said on the worksheet either way: a checker working
            # the discharge by hand needs to know which pressure to use.
            if not o.get('vel_press'):
                out += (' Discharge basis: total pressure; velocity pressure not included '
                        '(OPTION VELOCITY_PRESSURE OFF).\n')
            elif not gov.get('pv'):
                out += (' Velocity pressure included (OPTION VELOCITY_PRESSURE ON); this outlet discharges on total\n'
                        ' pressure, being an end sprinkler or not a sprinkler.\n')
            out += ' Check: P TO = P FROM - PF - PE on every row.  PF = PF/M x T.\n'
            out += (' Check: P TO worked by hand agrees with P SOLVED at every node, '
                    'worst difference %.1e %s.\n' % (worst / up, sym(net['u_pres'])))
            out += wrap(' ', 'On a looped network water reaches an outlet by more than one '
                       'route.  This path follows the element bringing the most water into each node, '
                       'traced back from the outlet.  Pressure at a node is the same by any route, '
                       'which is why the hand-worked P TO must land on the solved value.')

    #--------------------------------------------------- 9. supply and demand
    out += title('9. SUPPLY AND DEMAND')
    dm = demand.demand_point(net)
    if dm.get('reason'):
        out += wrap(' ', 'A demand point is not reported: %s.' % dm['reason'])
        sup = [e for e in net['elems'][1:] if e['kind'].startswith('SUPPLY_')]
        for s in sup:
            out += (' %-12s operating at %9.1f %s and %8.1f %s\n'
                    % (s['id'], s['q'] / uf, sym(net['u_flow']),
                       demand.gauge(net, s['n2']) / up, sym(net['u_pres'])))
        # With more than one supply: what each must give, on one common
        # pressure; a graph of each; then all of them combined.
        cd = demand.combined_demand(net) if (len(sup) > 1 and net.get('source_text')) else None
        if cd and cd.get('reason'):
            out += wrap(' ', 'The supplies are not graphed: %s.' % cd['reason'])
        elif cd:
            qu, pu = sym(net['u_flow']), sym(net['u_pres'])
            out += '\n' + wrap(' ', 'Each supply is graphed below with the other supplies connected as '
                       'modelled.  Its system curve is the whole network re-solved with this supply held at '
                       'a range of pressures, the others unchanged, and its flow read from each solve; only '
                       'solves that converge with water leaving this supply are plotted.  The operating '
                       'point O is where that curve meets the supply.')
            q_all = 0
            for s in sup:
                if s['q'] > 0:
                    q_all += s['q']
            for s in sup:
                out += supply_graph(net, {'supply': s, 'shared': 1, 'q_oper': s['q'],
                                          'p_oper': demand.gauge(net, s['n2']),
                                          'q_all': q_all})
            # Then all of them together: the curves added in flow at equal
            # pressure, and the required flows added at the common pressure.
            out += '\n' + wrap(' ', ('ALL SUPPLIES COMBINED.  The supply curves are added in flow '
                        'at equal pressure - at each pressure, the flows the supplies give are summed; pressures '
                        'are not adjusted.  The COMBINED DUTY is found on the same basis, as for pumps on one '
                        'header: every supply held at one common pressure, raised until the governing outlet, %s, '
                        'receives exactly its minimum; the flows of all the supplies then, added, at that '
                        'pressure.  Where the supplies connect at different points the modelled network runs '
                        'each at its own pressure, as listed above, so the combined figures describe the '
                        'supplies taken together and each supply is also shown on its own graph.'
                        % cd['governing']['id'])
                        + ('  The supplies operate at one pressure in the modelled network, so their operating '
                           'flows, added, are the combined operating point O.' if cd['one_pressure'] else ''))
            if cd.get('q_hose'):
                out += '   %-30s %10.1f %-7s\n' % ('SYSTEM FLOW at the duty', cd['q_system'] / uf, qu)
                out += '   %-30s %10.1f %-7s\n' % ('HOSE ALLOWANCE, added', cd['q_hose'] / uf, qu)
            out += ('   %-30s %10.1f %-7s at %9.1f %s\n'
                    % ('COMBINED DUTY', cd['q_demand'] / uf, qu, cd['p_demand'] / up, pu))
            out += ('   %-30s %10s %-7s    %9.1f %s\n'
                    % ('COMBINED SUPPLY at that flow', '', '', cd['p_avail'] / up, pu))
            out += ('   %-30s %10s %-7s    %9.1f %s\n'
                    % ('MARGIN' if cd['margin'] >= 0 else 'SHORTFALL', '', '',
                       abs(cd['margin']) / up, pu))
            if cd['one_pressure']:
                out += ('   %-30s %10.1f %-7s at %9.1f %s\n'
                        % ('COMBINED OPERATING POINT', cd['q_oper'] / uf, qu, cd['p_oper'] / up, pu))
            out += (' The supplies combined MEET the combined duty.\n' if cd['margin'] >= 0
                    else ' *** THE SUPPLIES COMBINED DO NOT MEET THE COMBINED DUTY ***\n')
            out += supply_graph(net, cd)
    else:
        s = dm['supply']
        qu, pu = sym(net['u_flow']), sym(net['u_pres'])
        out += (' Supply %s at node %s, %s\n\n'
                % (s['id'], net['nodes'][s['n2']]['id'],
                   'static pressure' if s['kind'] == 'SUPPLY_STATIC' else 'flow/pressure curve'))
        # A hose allowance is added at the supply: the system's own flow, the
        # allowance, then the demand the supply must meet.
        if dm.get('q_hose'):
            out += '   %-30s %10.1f %-7s\n' % ('SYSTEM FLOW at the demand point', dm['q_system'] / uf, qu)
            out += '   %-30s %10.1f %-7s\n' % ('HOSE ALLOWANCE, added', dm['q_hose'] / uf, qu)
        out += ('   %-30s %10.1f %-7s at %9.1f %s\n'
                % ('DEMAND', dm['q_demand'] / uf, qu, dm['p_demand'] / up, pu))
        out += ('   %-30s %10s %-7s    %9.1f %s\n'
                % ('AVAILABLE at the demand flow', '', '', dm['p_avail'] / up, pu))
        out += ('   %-30s %10s %-7s    %9.1f %s   (%.1f %% of available)\n'
                % ('MARGIN', '', '', dm['margin'] / up, pu,
                   100 * dm['margin'] / dm['p_avail'] if dm['p_avail'] > 0 else 0))
        out += ('   %-30s %10.1f %-7s at %9.1f %s\n\n'
                % ('OPERATING POINT', dm['q_oper'] / uf, qu, dm['p_oper'] / up, pu))
        # The demand search does not go below 0 kPa gauge (demand.demand_point):
        # a supply cannot be below atmosphere.  Met there, the outlets are met
        # by the supply's elevation alone, and the demand is stated as 0,
        # which overstates it -- a conservative figure.
        if dm.get('at_floor'):
            out += wrap('   ', 'The governing outlet is met with the supply at 0 gauge pressure: its elevation alone '
                       'meets the demand, and the demand is stated as 0, the least pressure a supply can have.  The true '
                       'requirement is lower, so the margin shown is conservative.') + '\n'
        out += wrap(' ', ('DEMAND is the pressure the system needs at the supply connection '
                    'for the governing outlet, %s, to receive exactly its minimum - found by re-solving '
                    'the whole network at trial supply pressures until its margin is zero.  The '
                    'OPERATING POINT is what actually happens with this supply: every outlet receives more '
                    'than its minimum, and the supply meets the system exactly.  The difference between '
                    'available and demand is the margin.' % dm['governing']['id']))
        out += (' The supply MEETS the demand.\n' if dm['margin'] >= 0
                else ' *** THE SUPPLY DOES NOT MEET THE DEMAND ***\n')
        out += supply_graph(net, dm)

    #---------------------------------------------- 10. supplies and devices
    sup = [e for e in net['elems'][1:]
           if re.match(r'^(SUPPLY_|PUMP|FIXED_DROP|ORIFICE|BFP|RATIO|DPV)', e['kind'])]
    if sup:
        out += title('10. SUPPLIES, PUMPS AND PRESSURE DEVICES')
        out += ' %-12s %-11s %-8s %-8s %11s %11s   %s\n' % (
            'ELEMENT', 'TYPE', 'FROM', 'TO', 'FLOW', 'HEAD/LOSS', 'NOTE')
        out += thin()
        nm = {'SUPPLY_STATIC': 'STATIC', 'SUPPLY_CURVE': 'CURVE', 'PUMP': 'PUMP',
              'FIXED_DROP': 'PRV', 'ORIFICE': 'ORIFICE', 'ORIFICE_REQUIRED': 'ORIFICE_P',
              'BFP': 'BFP', 'RATIO': 'PRA', 'DPV': 'DPV'}
        for e in sup:
            hf = 0 if e.get('closed') else elem_hf(e, e['q'], o)[0]
            if e.get('isolated'):
                note = 'LOSS OF SUPPLY - cut off with its supply'
            elif e.get('closed'):
                note = 'CHECK VALVE CLOSED - would run backwards'
            elif e['kind'] == 'ORIFICE' and e.get('bore'):
                note = 'bore %.2f mm in %.2f mm pipe, beta %.3f' % (
                    e['bore'], e['pipedia'], e['bore'] / e['pipedia'])
            elif e['kind'] == 'RATIO':
                # Outlet = inlet x (1/ratio - band), so the reader
                # can check it: the bottom of the valve's band.
                band = e.get('band') if e.get('band') is not None else 0.05
                pin = e.get('pin') if e.get('pin') is not None else 0
                note = ('ratio %g:1 +/-%g%%, inlet %.1f, outlet %.1f (band %.1f to %.1f)'
                        % (e['ratio'], 100 * band, pin / up, (pin - e['dp']) / up,
                           pin * (1 / e['ratio'] - band) / up,
                           pin * (1 / e['ratio'] + band) / up))
            else:
                note = ''
            out += (' %-12s %-11s %-8s %-8s %11.*f %11.*f   %s\n'
                    % (e['id'], nm.get(e['kind'], e['kind']),
                       net['nodes'][e['n1']]['id'], net['nodes'][e['n2']]['id'],
                       qdp(net['u_flow']), e['q'] / uf, pdp(net['u_pres']) + 1, hf / up, note))
        if [e for e in sup if e.get('nrv')]:
            out += check_valve_table(net)
        if [e for e in sup if e['kind'] == 'RATIO']:
            out += ratio_band_note(net)
        if [e for e in sup if e['kind'] == 'PUMP']:
            out += pump_curves(net)

    #------------------------------------- 11. hydraulic validation summary
    # Worked again from the final network by validate, after every
    # outer-loop adjustment: what a reviewer checks before believing any
    # number above.  The same result the JSON and the editor give.
    as_ = validate.assess(net, ok)
    va = as_['validation']
    out += validation_summary(net, va)

    #------------------------------------------ 12. multiple water supplies
    if as_.get('supplies'):
        out += supply_schedule(net, as_['supplies'])

    #------------------------------------------------- 13. dry pipe valves
    if [e for e in net['elems'][1:] if e['kind'] == 'DPV']:
        out += dry_pipe_valves(net, va, as_.get('dry'))

    #---------------------------------------------- 14. calculation acceptance
    out += acceptance_section(net, va)

    #--------------------------------------------------------- 15. warnings
    out += title('15. NOTES AND WARNINGS')
    w = []
    if not ok:
        w.append('THE SOLUTION DID NOT CONVERGE. Every figure in this report is provisional.')
    # One finding, not one per pipe.  Five identical sentences bury whatever
    # else is on the list; the pipes and their velocities are the information.
    vl = o.get('vel_limit') if o.get('vel_limit') is not None else 6
    fast = sorted([x for x in ((e['id'], abs(pipe_velocity(e['q'], e['dia'])))
                               for e in net['elems'][1:] if e['kind'] == 'PIPE')
                   if x[1] > vl], key=lambda t: -t[1])
    if fast:
        w.append('%d pipe(s) exceed the velocity limit of %g m/s, fastest first (m/s): %s.'
                 % (len(fast), vl, ', '.join('%s %.2f' % t for t in fast)))
    w.extend(net.get('warnings') or [])
    if not w:
        w.append('No warnings.')
    for i in range(len(w)):
        out += wrap(' %2d  ' % (i + 1), w[i])

    #------------------------------------------- appendices: supply graphs
    # A water supply graph made by hand (SUPPLYGRAPH): its figures and duty
    # points; the PDF draws the sheet as well, on a page of its own.
    gs = net.get('graph_sheets') or []
    for i in range(len(gs)):
        from . import graph
        out += title('APPENDIX %s. SUPPLY GRAPH - %s' % (chr(65 + i), gs[i]['file'].upper()))
        out += wrap(' ', 'A Q^1.85 water supply graph from %s, attached by SUPPLYGRAPH on line '
                   '%d of the model.  The PDF report draws the sheet on a page of its own, after this text.'
                   % (gs[i]['file'], gs[i]['line'])) + '\n'
        out += ''.join(l + '\n' for l in graph.text_sheet(gs[i]['graph']))

    out += '\n' + rule() + ' END OF CALCULATION\n' + rule()

    # The guarantee: nothing but printable ASCII leaves this module.
    return ascii_(out)

#------------------------------------------------------------------------------
# COVER SHEET
#
# Modelled on the NFPA-style submittal cover, adapted for Australia: design data
# in AS 2118.1 terms (hazard class, design density in mm/min, area of operation
# in m2), and NO hose stream allowance, which Australian practice does not add
# to a sprinkler calculation.
#
# PHCP solves with the supply connected, so its schedules show the OPERATING
# point, where every head receives more than its minimum.  A submittal cover is
# normally read at the DEMAND point, where the governing head receives exactly
# its minimum.  The flow and density figures are given at BOTH, side by side and
# labelled, rather than one quietly standing in for the other.
#------------------------------------------------------------------------------
def flow_stats(n):
    if not n:
        return None
    s = {'spk': 0, 'other': 0, 'nspk': 0, 'supply': 0}
    for e in n['elems'][1:]:
        if e['kind'] == 'DISCHARGE':
            q = abs(e['q'])
            if (e.get('otype') or 'SPRINKLER').upper() == 'SPRINKLER':
                s['spk'] += q
                s['nspk'] += 1
                if 'low' not in s or q < s['low']:
                    s['low'], s['low_id'] = q, e['id']
            else:
                s['other'] += q
        if e['kind'].startswith('SUPPLY_'):
            s['supply'] += abs(e['q'])
    # Fixed-flow demands are water the system needs too.
    for i in range(1, len(n['nodes'])):
        s['other'] += n['nodes'][i]['demand'] or 0
    return s

# Flow through a node: the sum of everything arriving at it.
def node_throughput(n, i):
    inp = 0
    for e in n['elems'][1:]:
        if e.get('closed'):
            continue
        if e['n2'] == i and e['q'] > 0:
            inp += e['q']
        if e['n1'] == i and e['q'] < 0:
            inp += -e['q']
    return inp

def node_index_by_id(n, id_):
    if id_ is None or not len(id_ or ''):
        return None
    for i in range(1, len(n['nodes'])):
        if n['nodes'][i]['id'] == id_:
            return i
    return None

def num_or_undef(v):
    m = re.match(r'^\s*([\d.]+)', v or '')
    return float(m.group(1)) if m else None

def cover_sheet(net, ok, path):
    from . import demand, validate
    pj = net.get('project') or {}
    uf, up = net['f_flow'], net['f_pres']
    qu, pu = sym(net['u_flow']), sym(net['u_pres'])
    qd, pd = qdp(net['u_flow']), pdp(net['u_pres'])
    out = ''

    def ns(v):
        return v if (v is not None and len(str(v))) else 'not stated'
    out += rule()
    out += ' %-*s%s\n' % (W - 1 - len('PHCP'), 'HYDRAULIC CALCULATION', 'PHCP')
    out += rule() + '\n'

    # --- the design data, from the PROJECT block and the solved network
    dm = demand.demand_point(net)
    sd = flow_stats(dm['net']) if dm.get('net') else None
    so = flow_stats(net)
    dens = num_or_undef(pj.get('DENSITY'))            # mm/min
    aps = num_or_undef(pj.get('AREA_PER_SPRINKLER'))  # m2
    aoo = num_or_undef(pj.get('AREA_OF_OPERATION'))   # m2
    if aoo is not None:
        aoo_txt = '%.1f m2' % aoo
    elif aps is not None and so['nspk']:
        aoo_txt = '%.1f m2  (%d sprinklers x %.1f m2)' % (so['nspk'] * aps, so['nspk'], aps)
    else:
        aoo_txt = 'not stated'
    uses_db = [e for e in net['elems'][1:] if e.get('ptype')]

    left = [
        ['COMPANY', ns(pj.get('COMPANY'))],
        ['ADDRESS', ns(pj.get('ADDRESS'))],
        ['LICENCE', ns(pj.get('LICENCE'))],
        ['DESIGNER', ns(pj.get('DESIGNER'))],
        ['CHECKER', ns(pj.get('CHECKER'))],
        ['DATE', ns(pj.get('DATE'))],
        ['REVISION', ns(pj.get('REVISION'))],
        ['', ''],
        ['JOB NAME', ns(pj.get('TITLE'))],
        ['PROJECT', ns(pj.get('PROJECT'))],
        ['JOB NUMBER', ns(pj.get('JOB'))],
        ['LOCATION', ns(pj.get('LOCATION'))],
        ['MODEL FILE', path],
    ]
    right = [
        ['DESIGN DATA', None],
        ['Standard', ns(pj.get('STANDARD'))],
        ['Hazard class', ns(pj.get('HAZARD'))],
        ['Design density', '%.2f mm/min' % dens if dens is not None else 'not stated'],
        ['Area per sprinkler', '%.1f m2' % aps if aps is not None else 'not stated'],
        ['Area of operation', aoo_txt],
        ['Sprinklers flowing', so['nspk']],
        # Whether velocity pressure was included is a designer's election
        # (AS 2118.1 Cl 14.15), so the cover states it either way.
        ['Velocity pressure', 'INCLUDED, Cl 14.15' if net['opts'].get('vel_press') else 'NOT INCLUDED'],
        ['Pipe data', pipedata.dataset() if uses_db else (pj.get('DATA_SOURCE') or 'not stated')],
        ['Program', 'PHCP %s' % VERSION],
    ]
    # A long value WRAPS within its column rather than being cut off: an
    # address or a licence number truncated on a certified cover sheet is
    # worse than a longer cover.  Continuation lines hang under the value.
    lcol = []
    for f in left:
        if f[0] == '':
            lcol.append('')
            continue
        words = re.split(r'\s+', f[1])
        line = '%-11s : ' % f[0]
        indent = ' ' * len(line)
        cur = line
        for word in words:
            if len(cur) + len(word) > 64 and cur != line:
                lcol.append(cur)
                cur = indent
            cur += ('' if (cur == line or cur == indent) else ' ') + word
        lcol.append(cur)
    rcol = [r[0] if r[1] is None else '  %-19s : %s' % (r[0], r[1]) for r in right]
    for i in range(max(len(lcol), len(rcol))):
        line = (' %-64s %s' % (lcol[i] if i < len(lcol) else '',
                               rcol[i] if i < len(rcol) else '')).rstrip()
        out += line + '\n'

    # --- flow data, at the demand point and at the operating point
    def col(v, d):
        return '%.*f' % (d, v) if v is not None else '-'

    ri = node_index_by_id(net, pj.get('BASE_OF_RISER'))
    rid = node_index_by_id(dm['net'], pj.get('BASE_OF_RISER')) if (ri and dm.get('net')) else None

    def gauge(n, i):
        return n['nodes'][i]['h'] - GAMMA_W * n['nodes'][i]['z']

    out += '\n'
    tf = ' %-44s %-8s %16s %18s\n'
    out += tf % ('FLOW DATA', '', 'DEMAND POINT', 'OPERATING POINT')
    out += tf % ('  Total sprinkler flow', qu,
                 col(sd['spk'] / uf if sd else None, qd), col(so['spk'] / uf, qd))
    if so['other'] > 1e-9:
        out += tf % ('  Hydrant, hose reel and fixed flow', qu,
                     col(sd['other'] / uf if sd else None, qd), col(so['other'] / uf, qd))
    out += tf % ('  Total water required at the supply', qu,
                 col(sd['supply'] / uf if sd else None, qd), col(so['supply'] / uf, qd))
    if ri:
        out += tf % ('  Base of riser, node %s - flow' % pj['BASE_OF_RISER'], qu,
                     col(node_throughput(dm['net'], rid) / uf if rid else None, qd),
                     col(node_throughput(net, ri) / uf, qd))
        out += tf % ('                              pressure', pu,
                     col(gauge(dm['net'], rid) / up if rid else None, pd),
                     col(gauge(net, ri) / up, pd))
    elif pj.get('BASE_OF_RISER') is not None and len(pj['BASE_OF_RISER'] or ''):
        out += '  Base of riser: node %s is not in the model\n' % pj['BASE_OF_RISER']
    out += tf % ('  Pressure at the supply connection', pu,
                 col(dm['p_demand'] / up if dm.get('p_demand') else None, pd),
                 col(dm['p_oper'] / up if dm.get('p_oper') else None, pd))

    # --- density check.  Every sprinkler must deliver at least the design
    # density over the area it protects: q >= density x area per sprinkler.
    out += '\n'
    out += tf % ('DENSITY CHECK', '', 'DEMAND POINT', 'OPERATING POINT')
    if dens is not None and aps is not None and aps > 0 and so['nspk']:
        qmin = dens * aps                            # L/min
        dd = sd['low'] / aps if (sd and sd.get('low') is not None) else None
        do = so['low'] / aps if so.get('low') is not None else None
        out += tf % ('  Min. flow per sprinkler, density x area', 'L/min',
                     '%.1f' % qmin, '%.1f' % qmin)
        out += tf % ('  Lowest sprinkler flow', 'L/min',
                     '%.1f (%s)' % (sd['low'], sd['low_id']) if sd else '-',
                     '%.1f (%s)' % (so['low'], so['low_id']))
        out += tf % ('  Computed density (lowest flow / area)', 'mm/min', col(dd, 2), col(do, 2))
        out += tf % ('  Result against the design density', '',
                     'MEETS' if dd >= dens - 1e-9 else '*** FAILS' if dd is not None else '-',
                     'MEETS' if do >= dens - 1e-9 else '*** FAILS' if do is not None else '-')
    else:
        out += '  Not checked: the design density and area per sprinkler must both be entered.\n'

    # --- supply
    out += '\n SUPPLY\n'
    if dm.get('reason'):
        out += wrap('   ', 'Not reported: %s.  See Section 9.' % dm['reason'])
    else:
        out += ('   %-44s %10.*f %s\n' % ('Supply pressure available at the demand flow',
                                          pd, dm['p_avail'] / up, pu))
        out += ('   %-44s %10.*f %s\n' % ('Demand pressure required', pd, dm['p_demand'] / up, pu))
        out += ('   %-44s %10.*f %s   (%.1f %% of available)%s\n'
                % ('Pressure cushion', pd, dm['margin'] / up, pu,
                   100 * dm['margin'] / dm['p_avail'] if dm['p_avail'] > 0 else 0,
                   '' if dm['margin'] >= 0 else '   *** SUPPLY INSUFFICIENT'))
    vmax, vid = 0, ''
    for e in net['elems'][1:]:
        if e['kind'] != 'PIPE':
            continue
        v = abs(pipe_velocity(e['q'], e['dia']))
        if v > vmax:
            vmax, vid = v, e['id']
    out += '   %-44s %10.2f m/s in pipe %s (operating point)\n' % ('Maximum velocity', vmax, vid)
    out += '   %-44s %10s\n' % ('Result',
                                'CONVERGED' if ok else '*** NOT CONVERGED - NOTHING IN THIS REPORT IS USABLE ***')
    # The acceptance, from validate: converged is not accepted.
    acc = validate.assess(net, ok)['validation']['acceptance']
    out += '   %-44s %s\n' % ('CALCULATION ACCEPTANCE',
                              ('' if acc == 'ACCEPTED' else '*** ')
                              + validate.acceptance_text(acc) + ' (Section 14)')

    out += '\n'
    out += (' %-30s : %-40s  PHONE : %s\n'
            % ('AUTHORITY HAVING JURISDICTION', ns(pj.get('AUTHORITY')), ns(pj.get('AUTHORITY_PHONE'))))
    out += '\n'
    out += wrap(' ', 'DEMAND POINT: the governing outlet receives exactly its minimum - the design '
               'condition.  OPERATING POINT: this supply connected, every outlet at or above its '
               'minimum; the schedules in this report are at the operating point.  '
               + ((('A hose stream allowance of %.1f %s is added at the supply to the demand (OPTION '
                    'HOSE_ALLOWANCE).' % (net['opts']['hose'] / net['f_flow'], sym(net['u_flow'])))
                   if (net['opts'].get('hose') or 0) > 0 else
                   'No hose stream allowance is included (OPTION HOSE_ALLOWANCE adds one).')))
    return out

#------------------------------------------------------------------------------
# The report as a PDF: the same text, paginated.  Made from the same call to
# write_report, so the PDF and the text file cannot say different things.  The
# supply graph's numbers, worked out by that call, are passed on so the PDF can
# draw the graph with lines where the text report draws it in characters.
#------------------------------------------------------------------------------
def write_pdf_report(net, ok, model_path, pdf_path):
    from . import graph, pdfout
    net.pop('supply_graphs', None)
    text = write_report(net, ok, model_path)
    pj = net.get('project') or {}
    model = re.sub(r'.*[/\\]', '', model_path or '')
    program = 'PHCP %s - Perl Hydraulic Calculation Program' % VERSION

    def sheet_fn(g, model=model, program=program):
        def draw(w, h):
            return graph.sheet(g, w, h, model=model, program=program)[0]
        return draw

    return pdfout.write_pdf(text, pdf_path,
                            title=pj.get('TITLE') or 'Hydraulic calculation',
                            job=pj.get('JOB') or '',
                            revision=pj.get('REVISION') or '',
                            date=pj.get('DATE') or '',
                            designer=pj.get('DESIGNER') or '',
                            model=model,
                            program=program,
                            graphs=net.get('supply_graphs') or [],
                            # Each supply graph sheet (SUPPLYGRAPH) drawn on a page after the text.
                            sheets=[sheet_fn(x['graph']) for x in (net.get('graph_sheets') or [])])

#------------------------------------------------------------------------------
# Supply graph on an N^1.85 flow axis.
#
# Water-supply curves are drawn with flow to the power 1.85 along the bottom
# because a Hazen-Williams system curve then comes out close to a straight line
# -- which is what lets an engineer read margin off it by eye.  The system curve
# is not sketched: each dot is a full solve of the network at a different supply
# pressure.  The operating point is where it crosses the supply.
#
# The graph is worked out once, by supply_graph_data, and drawn twice from the
# same numbers: in characters here for the text report (which is 7-bit ASCII),
# and as lines and text by the PDF writer.  So the two cannot disagree, and the
# ten extra solves run once.
#------------------------------------------------------------------------------

#------------------------------------------------------------------------------
# supply_graph_data -- everything either drawing needs, in the network's
# internal units (L/min, kPa); the display factors and unit names come with it.
#------------------------------------------------------------------------------
def supply_graph_data(net, dm):
    from . import demand
    uf, up = net['f_flow'], net['f_pres']
    s = dm['supply']
    # A supply's pressure at a flow, from its curve or its static pressure.

    def curve_of(e):
        if e['kind'] == 'SUPPLY_STATIC':
            return lambda q: e['pstat']
        return lambda q: curve_eval(e['curve'], q)

    combined = 1 if dm.get('combined') else 0
    avail = dm['avail'] if combined else curve_of(s)
    shared = 1 if dm.get('shared') else 0

    # The system curve, one full solve per point.
    sys = []
    if shared:
        # From half the operating pressure to a tenth above the supply's
        # highest.  Near no flow, with the other supplies pushing back, the
        # network may not settle; such solves, and any with water running
        # back into this supply, are left off.
        a0 = avail(0)
        plo, phi = dm['p_oper'] * 0.5, (a0 if a0 > dm['p_oper'] else dm['p_oper']) * 1.1
        for i in range(12):
            p = plo + (phi - plo) * i / 11
            ok, n = demand.solve_at(net['source_text'], s['id'], p)
            if not ok:
                continue
            x = next((e for e in n['elems'][1:] if (e.get('id') or '') == s['id']), None)
            if x and not x.get('closed') and x['q'] > 0:
                sys.append([x['q'], p])
    elif not combined:
        ptop = dm['p_oper'] if dm['p_oper'] > dm['p_demand'] else dm['p_demand']
        for i in range(10):
            p = dm['p_demand'] * 0.5 + (ptop * 1.05 - dm['p_demand'] * 0.5) * i / 9
            r = demand.margin_at(net['source_text'], s['id'], p)
            n = r[1] if r else None
            if not n:
                continue
            x = next((e for e in n['elems'][1:] if (e.get('id') or '') == s['id']), None)
            if x:
                sys.append([abs(x['q']), p])
    sys.sort(key=lambda a: a[0])

    # Flows to fit: the demand (or required) point, and the operating point
    # where there is one.
    fit = [x for x in (dm.get('q_demand'),
                       None if (combined and not dm.get('one_pressure')) else dm.get('q_oper'))
           if x is not None]
    qmax = max(fit) if fit else None
    for pt in sys:
        if qmax is None or pt[0] > qmax:
            qmax = pt[0]
    if qmax is None:
        qmax = 0
    qmax *= 1.2
    pmax = avail(0)
    for v in ([x for x in (dm.get('p_oper'), dm.get('p_demand')) if x is not None]
              + [pt[1] for pt in sys]
              + [curve_of(p_)(0) for p_ in (dm.get('parts') or [])]):
        if v > pmax:
            pmax = v
    pmax *= 1.1
    if not (qmax > 0 and pmax > 0):
        return None

    # The supply, sampled evenly along the q^1.85 axis: within the entered
    # points it is straight on this paper; beyond them the curve continues
    # linearly in q, which on this paper bends, so it is sampled throughout.
    supply = []
    for k in range(201):
        q = qmax * (k / 200) ** (1 / 1.85)
        supply.append([q, avail(q)])
    tests = ([] if s['kind'] != 'SUPPLY_CURVE'
            else [[s['curve']['q'][i], s['curve']['p'][i]] for i in range(len(s['curve']['q']))])
    # For the combined graph, each supply's own curve, on the same samples,
    # to draw lightly under the combined one.
    parts = [[e['id'], [[pt[0], curve_of(e)(pt[0])] for pt in supply]]
             for e in (dm.get('parts') or [])]

    qu, pu = sym(net['u_flow']), sym(net['u_pres'])

    def at(v, k, u):
        return '%.1f %s' % (v / k, u)

    return {
        'qmax': qmax, 'pmax': pmax, 'avail': avail, 'supply': supply,
        'tests': [t for t in tests if t[0] <= qmax], 'sys': sys, 'shared': shared,
        'combined': combined, 'parts': parts,
        'demand': [dm['q_demand'], dm['p_demand']] if dm.get('q_demand') is not None else None,
        'oper': None if (combined and not dm.get('one_pressure')) else [dm['q_oper'], dm['p_oper']],
        'p_avail': dm.get('p_avail'), 'margin': dm.get('margin'),
        'xticks': [x * uf for x in nice_ticks(qmax / uf, 10)],
        'yticks': [x * up for x in nice_ticks(pmax / up, 8)],
        'uf': uf, 'up': up, 'qu': qu, 'pu': pu,
        'kind': s['kind'], 'id': s['id'],
        'node': '' if combined else net['nodes'][s['n2']]['id'],
        # The key figures as Section 9 prints them, for the key beside the
        # drawn graph: [ label, flow or '', pressure ].
        'figures': (
            [
                ['COMBINED DUTY', at(dm['q_demand'], uf, qu), at(dm['p_demand'], up, pu)],
                ['COMBINED SUPPLY', '', at(dm['p_avail'], up, pu)],
                ['MARGIN' if dm['margin'] >= 0 else 'SHORTFALL', '', at(abs(dm['margin']), up, pu)],
                (['OPERATING', at(dm['q_oper'], uf, qu), at(dm['p_oper'], up, pu)]
                 if dm.get('one_pressure') else []),
            ] if combined else
            [
                ['OPERATING', at(dm['q_oper'], uf, qu), at(dm['p_oper'], up, pu)],
                ['SHARE OF ALL SUPPLIES', '',
                 '%.1f %%' % (100 * dm['q_oper'] / dm['q_all'] if dm['q_all'] > 0 else 0)],
            ] if shared else
            [
                ['DEMAND', at(dm['q_demand'], uf, qu), at(dm['p_demand'], up, pu)],
                ['AVAILABLE', '', at(dm['p_avail'], up, pu)],
                ['MARGIN' if dm['margin'] >= 0 else 'SHORTFALL', '', at(abs(dm['margin']), up, pu)],
                ['OPERATING', at(dm['q_oper'], uf, qu), at(dm['p_oper'], up, pu)],
            ]),
    }

#------------------------------------------------------------------------------
# nice_ticks -- round gridline values from 0 to $max: a step of 1, 2, 2.5 or 5
# times a power of ten, giving about $n divisions or fewer.
#------------------------------------------------------------------------------
def nice_ticks(mx, n):
    if not mx > 0:
        return [0]
    raw = mx / n
    mag = 10 ** int(math.log(raw) / math.log(10) - (1 if raw < 1 else 0))
    step = next(s for s in (1, 2, 2.5, 5, 10) if s * mag >= raw)
    step *= mag
    t = []
    v = 0
    while v <= mx * (1 + 1e-9):
        t.append(float('%.10g' % v))
        v += step
    return t

#------------------------------------------------------------------------------
# supply_graph -- the graph in characters, for the text report.  The PDF draws
# the same data with lines instead (pdfout.draw_graph).
#------------------------------------------------------------------------------
def supply_graph(net, dm):
    d = supply_graph_data(net, dm)
    if not d:
        return ''
    net.setdefault('supply_graphs', []).append(d)   # for the PDF, drawn from the same numbers
    qmax, pmax, uf, up = d['qmax'], d['pmax'], d['uf'], d['up']
    GW, GH = 64, 16

    g = [[' '] * GW for _ in range(GH)]

    def col(x):
        return int((x / qmax) ** 1.85 * (GW - 1) + 0.5)

    def row(pp):
        r = int((1 - pp / pmax) * (GH - 1) + 0.5)
        return 0 if r < 0 else (GH - 1 if r > GH - 1 else r)

    def put(q, pp, ch):
        c, r = col(q), row(pp)
        if 0 <= c < GW:
            g[r][c] = ch

    # Combined: each supply's own curve first, numbered, under the combined one.
    parts = d.get('parts') or []
    for i in range(len(parts)):
        ch = '+' if i + 1 > 9 else str(i + 1)
        for pt in parts[i][1]:
            if 0 <= pt[1] <= pmax:
                put(pt[0], pt[1], ch)
    for c in range(GW):                             # the supply, a continuous line
        q = qmax * (c / (GW - 1)) ** (1 / 1.85)
        pa = d['avail'](q)
        if pa >= 0:
            put(q, pa, '*')
    for pt in d['sys']:                             # the system, solved point by point
        put(pt[0], pt[1], '.')
    if d['demand']:
        put(d['demand'][0], d['demand'][1], 'D')
    if d['oper']:
        put(d['oper'][0], d['oper'][1], 'O')

    pu, qu = d['pu'], d['qu']
    out = ('\n SUPPLY GRAPH - ALL SUPPLIES COMBINED, FLOWS ADDED AT EQUAL PRESSURE - pressure against flow^1.85\n\n'
           if d['combined'] else
           ('\n SUPPLY GRAPH - %s AT NODE %s, THE OTHER SUPPLIES CONNECTED - pressure against flow^1.85\n\n'
            % (d['id'], d['node']) if d['shared'] else
            '\n SUPPLY GRAPH - pressure against flow^1.85\n\n'))
    for r in range(GH):
        label = ('%8.0f' % (pmax * (1 - r / (GH - 1)) / up)
                 if r in (0, (GH - 1) // 2, GH - 1) else ' ' * 8)
        out += ' %s |%s\n' % (label, ''.join(g[r]))
    out += ' ' * 10 + '+' + '-' * GW + '\n'
    at = [0, (GW - 1) // 3, 2 * (GW - 1) // 3, GW - 1]
    line = [' '] * (GW + 12)
    for c in at:
        q = qmax * (c / (GW - 1)) ** (1 / 1.85)
        t = '%.0f' % (q / uf)
        start = 11 + c - len(t) // 2
        line[start:start + len(t)] = list(t)
    out += ''.join(line) + '\n'
    out += ' %8s   flow, %s, on a flow^1.85 scale\n\n' % (pu, qu)
    if d['combined']:
        out += ('   *  the supplies combined     '
                + '  '.join(('%s %s' % ('+' if i + 1 > 9 else i + 1, parts[i][0]))
                             for i in range(len(parts))) + '\n')
        if d['oper']:
            out += '   O  combined operating point: %s at %s\n' % (d['figures'][3][1], d['figures'][3][2])
        out += ('   D  combined duty: %s at %s; combined supply there %s; %s %s\n'
                % (d['figures'][0][1], d['figures'][0][2], d['figures'][1][2],
                   d['figures'][2][0].lower(), d['figures'][2][2]))
        return out
    out += '   *  supply available          .  system curve, each point a full solve\n'
    if d['shared']:
        out += ('   O  operating point: %s at %s, %s of the flow of all the supplies\n'
                % (d['figures'][-2][1], d['figures'][-2][2], d['figures'][-1][2]))
    else:
        out += '   D  demand point              O  operating point\n'
    return out

#------------------------------------------------------------------------------
# pump_curves -- what the report says under Section 10 about each pump's
# curve against its rated duty (pumpcheck).
#------------------------------------------------------------------------------
def pump_curves(net):
    from . import pumpcheck
    uf, up = net['f_flow'], net['f_pres']
    qu, pu = sym(net['u_flow']), sym(net['u_pres'])
    chk = pumpcheck.check(net)
    out = '\n PUMP CURVES - each against its rated duty (PUMPDUTY)\n'
    out += (' %-12s %-22s %-22s %-24s %s\n' % ('PUMP', 'DUTY', 'CURVE AT DUTY FLOW',
                                               'SHUT-OFF, <= 140% DUTY', 'AT 150% FLOW, >= 65% DUTY'))
    out += thin()
    for p in chk:
        if not p.get('duty'):
            out += (' %-12s %-22s %-22s %-24s %s\n'
                    % (p['id'], 'NONE GIVEN', '-', '%.1f %s' % (p['shutoff'] / up, pu), '-'))
            continue
        q, pd = p['duty']
        out += (' %-12s %-22s %-22s %-24s %s\n'
                % (p['id'], '%.1f %s at %.1f' % (q / uf, qu, pd / up),
                   '%.1f %s' % (p['at_duty']['p'] / up, 'PASS' if p['at_duty']['ok'] else 'FAIL'),
                   '%.1f (max %.1f) %s' % (p['shutoff'] / up, pumpcheck.SHUTOFF_MAX * pd / up,
                                            'PASS' if p['shutoff_ok'] else 'FAIL'),
                   '%.1f (min %.1f) %s%s' % (p['over']['p'] / up, pumpcheck.OVERLOAD_P * pd / up,
                                             'MEETS' if p['over']['ok'] else 'BELOW',
                                             ', EXTRAPOLATED' if p['over']['extrapolated'] else '')))
    out += wrap(' ', 'Each curve is read as the solver reads it: through every point entered, straight in Q^1.85 '
               'between them.  SHUT-OFF at most 140% of the duty pressure is the AS 2941-2013 check as the Pump '
               'Industry Australia checklist states it.  150% of the duty flow at not less than 65% of the duty '
               'pressure is NFPA 20, 6.2; that AS 2941 states the same was not confirmed, so it is shown for '
               'information only.  EXTRAPOLATED: beyond the last point of the curve entered.  A pump with no duty '
               'is not checked: give PUMPDUTY <pump> <flow> <pressure>.')
    return out

#------------------------------------------------------------------------------
# design_areas -- Section 1's list of the design areas (AREA): each area's
# governing outlet and, with one supply, its demand point; which area governs
# and why.  Or, with OPTION DESIGN_AREA, the one area this report is for.
#------------------------------------------------------------------------------
def design_areas(net):
    uf, up = net['f_flow'], net['f_pres']
    fu, pu = sym(net['u_flow']), sym(net['u_pres'])
    qd, pd = qdp(net['u_flow']), pdp(net['u_pres'])
    out = sub_t('DESIGN AREAS')
    res = net.get('area_results')
    if not res:
        a = next((x for x in net['areas'] if x['name'] == net['design_area']), None)
        return out + wrap(' ', ('This report is for design area %s (%d outlets), chosen by OPTION '
                       'DESIGN_AREA.  The other areas (%s) were not solved.  Outlets in no area flow in every area.'
                       % (a['name'], len(a['outlets']),
                          ', '.join(x['name'] for x in net['areas'] if x is not a) or 'none')))
    out += (' %-12s %7s  %-14s %14s %14s %14s %14s\n'
            % ('AREA', 'OUTLETS', 'GOVERNING', 'MARGIN %s' % pu, 'DEMAND %s' % fu,
               'DEMAND %s' % pu, 'SUPPLY MARGIN'))
    out += thin()
    for r in res:
        d = r.get('demand')
        out += (' %-12s %7d  %-14s %14s %14s %14s %14s%s\n'
                % (r['name'], r['outlets'], r.get('governing') or '-',
                   fx(r['margin'] / up, pd) if r.get('margin') is not None else '-',
                   fx(d['q'] / uf, qd) if d else '-',
                   fx(d['p'] / up, pd) if d else '-',
                   fx(d['margin'] / up, pd) if d else '-',
                   ('  NOT CONVERGED' if not r['ok'] else ('  <- GOVERNS' if r.get('governs') else ''))))
    g = next((r for r in res if r.get('governs')), None)
    why = {'SUPPLY': 'it has the least margin at the supply: available minus demand',
           'OUTLET': 'its governing outlet has the least pressure to spare at the operating point',
           }.get(net.get('area_basis')) or 'its solve did not converge, so nothing about it can be relied on'
    out += '\n' + wrap(' ', ('Each area is solved with only its own outlets flowing, and those in no area.  '
                 'This report is for area %s, which governs: %s.  MARGIN is the governing outlet\'s '
                 'pressure over its requirement; DEMAND is the supply flow and pressure at which that outlet has '
                 'exactly its requirement.' % (g['name'], why)))
    return out

#------------------------------------------------------------------------------
# auto_sizing -- Section 1's list of the pipes PHCP sized (size 0 in the
# model): the size chosen for each, its velocity, and the margin the sized
# system has under the supply against the margin asked for.
#------------------------------------------------------------------------------
def auto_sizing(net):
    s = net['sizing']
    up = net['f_pres']
    pu = sym(net['u_pres'])
    out = sub_t('AUTO PIPE SIZING')
    out += ' %-6s %-11s %-8s %-40s %8s %10s\n' % ('LINE', 'COMMAND', 'TYPE', 'PIPES', 'SIZE', 'VEL m/s')
    out += thin()
    for u in s['units']:
        pipes = ' '.join(u['pipes'])
        if len(pipes) > 40:
            pipes = pipes[:37] + '...'
        out += (' %-6d %-11s %-8s %-40s %8s %10s\n'
                % (u['line'], u['kind'], u['type'], pipes, 'DN%s' % _s(u['dn']),
                   fx(u['velocity'], 2) if u.get('velocity') is not None else '-'))
    goal = ('the least water held in the sized pipes (SIZING_GOAL VOLUME)' if s['goal'] == 'VOLUME'
            else 'the smallest pipes that will do (SIZING_GOAL SMALLEST)')
    if not s['passes']:
        res = ('NOT MET: even the largest sizes in the database do not meet the demand with '
               'the margin asked for.')
    elif s.get('demand_margin') is not None:
        res = ('Met: at the demand point the supply has %.1f %s to spare, against %.1f %s asked for.'
               % (s['demand_margin'] / up, pu, s['required'] / up, pu))
    else:
        res = 'Met: every outlet has its requirement from each supply reduced by the margin.'
    if s.get('trials'):
        out += '\n %-6s %-28s %-8s %16s %8s\n' % ('TRIAL', 'STARTING FROM', 'RESULT',
                                                 'WATER, L' if s['goal'] == 'VOLUME' else 'SUM L x BORE, m2',
                                                 'SOLVES')
        for t in s['trials']:
            out += (' %-6d %-28s %-8s %16s %8d%s\n'
                    % (t['trial'], t['from'], 'PASSES' if t['passes'] else 'FAILS',
                       '%.3f' % (1000 * t['objective'] if s['goal'] == 'VOLUME' else t['objective'])
                       if t['passes'] else '-',
                       t['solves'], '  <- CHOSEN' if t.get('best') else ('  SAME' if t.get('same') else '')))
    out += '\n' + wrap(' ', ('Pipes given size 0 in the model were sized by PHCP from the sizes the database has for '
                 'their pipe type, for %s, keeping a margin under the supply of %s and no sized pipe faster '
                 'than %s m/s.  A PIPE line sizes its pipe and its unchanged copies (PC).  %s  The search made '
                 '%d trial(s) (OPTION SIZING_TRIALS), each from a different start, and kept the best that passes: a '
                 'good answer, not always the least possible.  The model keeps size 0, with each size after its line as '
                 '//AS - <size>.' % (goal, s['margin'], _s(s['vel_limit']), res, s['ntrials'])))
    return out

#------------------------------------------------------------------------------
# ratio_band_note -- what the report says under Section 10 about pressure
# ratio valves and their band.
#
# The calculation uses the bottom of each valve's band (ratio_valves): every
# outlet is checked against the least pressure the valve can be relied on to
# give.  The top of the band is what pipe, fitting and head ratings downstream
# must stand, so the network is solved once more with every valve at the top
# of its band, and the highest pressure that solve gives at a node the valves
# raise is stated -- with each valve's outlet.
#------------------------------------------------------------------------------
def ratio_band_note(net):
    from . import demand
    up = net['f_pres']
    pu = sym(net['u_pres'])
    out = '\n' + wrap(' ', 'Each pressure ratio valve holds its outlet at inlet / ratio to within a '
               'band: +/-5% of the inlet pressure, from the manufacturer\'s data, unless the model gives another.  '
               'The calculation uses the BOTTOM of each band, outlet = inlet x (1/ratio - band), so every outlet '
               'is checked against the least pressure the valve can be relied on to give.')
    try:
        h = read_string(net['source_text'])
        h['opts']['pra_side'] = 'HIGH'
        high = h if solve_model(h) else None
    except Exception:
        high = None
    if not high:
        return out + wrap(' ', 'The network was not solved with the valves at the top of their bands, '
                         'so the highest pressures downstream are not stated: check the pressure ratings by hand.')
    # The highest pressure at a node the valves raise: one whose pressure is
    # higher with the valves at the top of their bands than at the bottom.
    low = {net['nodes'][i]['id']: demand.gauge(net, i) for i in range(1, len(net['nodes']))}
    top, at_ = None, None
    for i in range(1, len(high['nodes'])):
        id_ = high['nodes'][i]['id']
        if id_ == 'REF' or id_ not in low:
            continue
        gg = demand.gauge(high, i)
        if not gg > low[id_] + 0.01:
            continue
        if top is None or gg > top:
            top, at_ = gg, id_
    v = ['%s outlet %.1f %s' % (e['id'], demand.gauge(high, e['n2']) / up, pu)
         for e in high['elems'][1:] if e['kind'] == 'RATIO']
    return out + wrap(' ', 'With every valve at the TOP of its band (' + ', '.join(v) + ')'
                      + ((', the highest pressure downstream is %.1f %s at node %s' % (top / up, pu, at_))
                         if top is not None else '')
                      + ': the pipes, fittings and heads downstream must be rated for it.')

#------------------------------------------------------------------------------
# validation_summary -- Section 11, HYDRAULIC VALIDATION SUMMARY: the checks
# validate works again from the final network, each with its value and
# tolerance so a reviewer can see what was measured.
#------------------------------------------------------------------------------
STATUS_WORD = {'PASS': 'PASS', 'FAIL': '*** FAIL', 'INDETERMINATE': '*** INDETERMINATE',
               'NOT_ASSESSED': 'NOT ASSESSED'}

def validation_summary(net, va):
    from . import validate
    s = va['solver']
    out = title('11. HYDRAULIC VALIDATION SUMMARY')
    out += wrap(' ', 'Every figure below is worked again from the final network - its flows, its node '
               'heads and each element\'s own equation - after every orifice plate, pump check valve, ratio '
               'valve and velocity pressure has been settled.  None is the residual the solver reported '
               'about itself.') + '\n'
    out += ' %-44s %s\n' % ('Calculation method', 'sequential Hardy Cross, loop by loop')
    out += ' %-44s %s\n' % ('Hardy Cross iteration',
        'converged in %d iterations (limit %d)' % (s['iterations'], s['maxiter'])
        if s['hc_converged'] else
        '*** NOT CONVERGED after %d iterations%s' % (s['iterations'],
                                                    ' (%s)' % s['diagnosis'] if s.get('diagnosis') else ''))
    out += ' %-44s %s\n' % ('Device states (outer loop)',
        'settled after %d pass(es)' % s['outer_passes'] if s['outer_settled'] else
        ('*** NOT SETTLED - stopped on an unconverged solve' if s.get('outer_stop') == 'inner_not_converged'
         else '*** NOT SETTLED after %d passes' % s['outer_passes']))
    out += (' %-44s %g %s flow, %g %s loop  (when the iteration stops)\n'
            % ('Solver tolerances', s['tol_flow'], sym(net['u_flow']),
               s['tol_loop'], sym(net['u_pres'])))
    out += wrap(' ', 'The LIMIT column is the verification limit the answer is checked to.  It is fixed by '
               'PHCP, not by the solver tolerances: a loose TOL_LOOP lets the iteration stop early, and the answer '
               'is then refused if it is not within the limit.')
    out += '\n'
    out += ' %-38s %12s %12s %-7s %s\n' % ('CHECK', 'WORST', 'LIMIT', 'UNIT', 'RESULT')
    out += thin()
    lab = {'continuity': 'Continuity at a node', 'balance': 'Supplies against demands, overall',
           'loop': 'Loop closure, sum of signed losses', 'element': 'Element pressure equation'}
    for k in ('continuity', 'balance', 'loop', 'element'):
        r = va.get('residuals', {}).get(k)
        if not r:
            continue
        out += (' %-38s %12.3e %12.3e %-7s %s%s\n'
                % (lab[k], r['value'], r['tolerance'], sym(r['unit']),
                   'PASS' if r['pass'] else '*** FAIL',
                   '  at %s' % r['at'] if r.get('at') is not None else ''))
    out += thin()
    out += ' %-38s %s\n' % ('NUMERICAL CONVERGENCE', STATUS_WORD[va['numerical']['status']])
    out += ' %-38s %s%s\n' % ('PHYSICAL VALIDITY (device states)', STATUS_WORD[va['physical']['status']],
                              '  (%d error(s))' % va['physical']['errors'] if va['physical'].get('errors') else '')
    out += ' %-38s %s%s\n' % ('DESIGN COMPLIANCE', STATUS_WORD[va['design']['status']],
                              '  (%d error(s))' % va['design']['errors'] if va['design'].get('errors') else '')
    da = va.get('demand_assessment') or {}
    out += ' %-38s %s%s\n' % ('SUPPLY DEMAND', da.get('status') or 'NOT_ASSESSED',
                              '  (%s)' % da['basis'] if da.get('basis') else '')
    if (da.get('status') or '') == 'UNRESOLVED':
        out += wrap('   ', 'UNRESOLVED: the search for the demand failed - a trial solve was physically invalid or '
                   'did not converge - so the supplies were neither shown adequate nor found inadequate.  '
                   + (da.get('message') or ''))
    out += '\n'
    out += wrap(' ', 'The element pressure equation is checked on every element: the head difference '
               'between its ends, from the recovered node heads, against what the element gives at its own '
               'flow, elevation heads included.  On a spanning-tree element it is exact, the heads being '
               'recovered along it; on a chord it equals the closure of that chord\'s loop.')
    for f in [x for x in va.get('findings') or [] if x['severity'] == 'info']:
        out += wrap('  -  ', f['message'])
    return out

#------------------------------------------------------------------------------
# check_valve_table -- Section 10: every water supply's check valve (NRV).
#------------------------------------------------------------------------------
def check_valve_table(net):
    from . import demand, supplies as _supplies
    uf, up = net['f_flow'], net['f_pres']
    qd, pd = qdp(net['u_flow']), pdp(net['u_pres'])
    out = '\n SUPPLY CHECK VALVES (NRV)\n'
    out += ('   %-10s %-14s %11s %11s %9s %9s %8s\n'
            % ('SUPPLY', 'STATE', 'FLOW', 'PRESSURE', 'LOSS', 'BASIS', 'OPENS AT'))
    models = []
    iso = None
    for s in demand.supplies(net):
        v = _supplies.valve_of(s)
        st = _supplies.state_of(s) if v else 'NONE'
        if st == 'ISOLATED':
            iso = 1
        q = 0 if s.get('closed') else s['q']
        out += ('   %-10s %-14s %11.*f %11.*f %9s %7s %8s\n'
                % (s['id'], 'ISOLATED' if st == 'ISOLATED' else st,
                   qd, q / uf, pd, demand.gauge(net, s['n2']) / up,
                   ('%.*f' % (pd + 1, v['loss'] / up)) if (v and not s.get('closed')) else '-',
                   ('CV %.0f' % v['cv']) if (v and v.get('basis') == 'CV') else (v.get('basis') if v else '-'),
                   ('%.*f%s' % (pd, v['crack'] / up, '' if v.get('crack_given') else '*'))
                   if v else '-'))
        if v:
            models.append('%s: %s' % (s['id'], v.get('model') or 'make and model not stated'))
    out += wrap('   ', 'PRESSURE is gauge at the supply\'s connection; LOSS is the valve\'s at the flow shown. '
               'BASIS: CV means opening pressure plus (Q gpm / Cv)^2 psi; CURVE uses manufacturer flow/loss points '
               'and is rejected outside their tested range; PIPEWORK means flow loss is separately allowed in '
               'the model, not zero. CLOSED gives zero flow. * opening pressure not specified: 0 assumed.')
    if models:
        out += wrap('   ', 'Valve data: ' + '; '.join(models) + '.')
    if iso:
        i = net.get('supply_isolated')
        out += wrap('   ', ('*** LOSS OF SUPPLY: the check valve%s of %s shut and no other supply reaches '
                     '%s.  Nothing there receives water; the outlets cut off are %s.  This is the operating state the '
                     'model gives, not a solver failure, and the design is not met.'
                     % ('s' if len(i['supplies']) > 1 else '', ', '.join(i['supplies']),
                        ', '.join(i['nodes']),
                        ', '.join(i['outlets']) if i.get('outlets') else 'none')))
    return out

#------------------------------------------------------------------------------
# supply_schedule -- Section 12, MULTIPLE WATER SUPPLIES (supplies).
#------------------------------------------------------------------------------
def supply_schedule(net, s):
    uf, up = net['f_flow'], net['f_pres']
    qu, pu = sym(net['u_flow']), sym(net['u_pres'])
    qd, pd = qdp(net['u_flow']), pdp(net['u_pres'])

    def f(v, d, k):
        return '%.*f' % (d, v / k) if v is not None else '-'

    out = title('12. MULTIPLE WATER SUPPLIES')
    out += wrap(' ', ('Each supply below keeps its own connection, elevation and curve or static '
               'pressure.  Flows are signed: positive into the network.  Pressures are gauge, at the supply\'s '
               'own elevation.  Units %s and %s.' % (qu, pu))) + '\n'

    # A. Operating.
    out += ' A. OPERATING - every supply as modelled\n'
    out += ('   %-10s %-8s %-6s %11s %11s %7s  %s\n'
            % ('SUPPLY', 'NODE', 'TYPE', 'FLOW', 'PRESSURE', 'SHARE', 'STATUS'))
    for r in s['operating']:
        out += ('   %-10s %-8s %-6s %11s %11s %6.1f%%  %s%s\n'
                % (r['id'], r['node'], r['kind'], f(r['flow'], qd, uf), f(r['pressure'], pd, up),
                   r['share'],
                   ('*** REVERSE FLOW' if r['status'] == 'REVERSE'
                    else 'CLOSED (check valve)' if r['status'] == 'CLOSED'
                    else '*** LOSS OF SUPPLY' if r['status'] == 'ISOLATED' else r['status']),
                   ', curve extrapolated' if r.get('extrapolated') else ''))
    out += ('   %-25s %11s   net demand %s, difference %.2e %s\n'
            % ('SIGNED SUM OF SUPPLIES', f(s['supply_sum'], qd, uf), f(s['net_demand'], qd, uf),
               s['balance'] / uf, qu))
    out += '   %-25s %s\n' % ('GOVERNING OUTLET', s.get('governing') or '-')

    if not s.get('conditional'):
        out += '\n' + wrap('   ', 'The conditional and joint demands are not worked out: the solve did not '
                     'converge, or the model has no outlet with a requirement.')
        return out

    # B. Conditional.
    out += '\n B. CONDITIONAL MINIMUM - each supply on its own, THE OTHERS AS MODELLED\n'
    out += ('   %-10s %-12s %11s %11s %11s %11s  %-8s %s\n'
            % ('SUPPLY', 'RESULT', 'REQ FLOW', 'REQ PRES', 'AVAILABLE', 'MARGIN', 'GOVERNS', 'VALIDATION'))
    for c in s['conditional']:
        if c['status'] in ('UNRESOLVED', 'INADEQUATE'):
            out += wrap('   %-10s %-12s ' % (c['id'], c['status']), c['reason'])
            continue
        out += ('   %-10s %-12s %11s %11s %11s %11s  %-8s %s%s\n'
                % (c['id'], 'NOT REQUIRED' if c['status'] == 'NOT_REQUIRED' else 'REQUIRED',
                   f(c['flow'], qd, uf), f(c['pressure'], pd, up), f(c['available'], pd, up),
                   f(c['margin'], pd, up), c.get('governing') or '-', c['acceptance'],
                   ('; reverse flow in ' + ' '.join(c['others_reverse']))
                   if c.get('others_reverse') else ''))
    out += wrap('   ', 'Each conditional minimum is the least pressure at that supply for the governing '
               'outlet to receive exactly its minimum, every OTHER supply on its modelled curve.  It is '
               'conditional on the others: the conditional minima of different supplies are not a condition '
               'they can all be at together, and they are not added.  NOT REQUIRED: the other supplies meet '
               'every outlet with this one giving no water.  Every trial solve of the search is validated: '
               'INADEQUATE, every valid solve fell short; UNRESOLVED, a trial was physically invalid (another '
               'supply taking water in, say) or did not converge, so the minimum is not known.')

    # C. Joint.
    j = s.get('joint')
    out += '\n C. JOINT DEMAND - every supply together, in ONE solve\n'
    if not j or (j.get('status') or '') != 'FOUND':
        out += wrap('   ', '%s: %s.' % ((j['status'] or 'NOT FOUND') if j else 'NOT FOUND',
                                         (j.get('reason') or '') if j else 'not worked out'))
        if j and (j.get('status') or '') == 'UNRESOLVED':
            out += wrap('   ', 'UNRESOLVED is not a supply found too weak: on this basis the supplies reach a state '
                       'that cannot exist, or a solve does not converge, before the governing outlet reaches its minimum, '
                       'so no joint demand exists on it and the supplies\' adequacy is not demonstrated.  A non-return '
                       'valve at a supply that would take water in is not modelled.')
    else:
        out += wrap('   ', ('Basis (OPTION JOINT_BASIS %s): %s.  This is an ASSUMPTION about how the '
                   'supplies share the load; another basis gives another split.' % (j['basis'], j['assumption'])))
        out += '   %-38s %s\n' % ('Common derating D' if j['basis'] == 'DERATE' else 'Common factor F',
                                  ('%.*f %s' % (pd, j['delta'] / up, pu)) if j['basis'] == 'DERATE'
                                  else '%.4f' % j['factor'])
        out += '   %-38s %s\n' % ('Governing outlet at the joint demand', j.get('governing') or '-')
        out += '   %-38s %s\n' % ('Validation of the joint solve', j['acceptance'])
        out += ('   %-10s %-8s %7s %11s %11s %11s %11s %11s %7s  %s\n'
                % ('SUPPLY', 'NODE', 'ELEV', 'JOINT FLOW', 'JOINT PRES', 'NODE PRES',
                   'AVAILABLE', 'MARGIN', 'SHARE', 'STATUS'))
        for r in j['supplies']:
            out += ('   %-10s %-8s %7.2f %11s %11s %11s %11s %11s %6.1f%%  %s%s\n'
                    % (r['id'], r.get('node') or '-', r.get('z') or 0,
                       f(r['flow'], qd, uf), f(r['pressure'], pd, up), f(r['node_pressure'], pd, up),
                       f(r['available'], pd, up), f(r['margin'], pd, up), r['share'],
                       '*** REVERSE FLOW' if r['status'] == 'REVERSE' else r['status'],
                       ', curve EXTRAPOLATED' if r.get('extrapolated') else ''))
        out += ('   %-10s %-8s %7s %11s   net demand %s, difference %.2e %s%s\n'
                % ('SIGNED SUM', '', '', f(j['q_total'], qd, uf), f(j['net_demand'], qd, uf),
                   (j.get('balance') or 0) / uf, qu,
                   '' if j.get('balance_pass') else '  *** DOES NOT BALANCE'))
        out += wrap('   ', 'JOINT PRES is the pressure each supply gives, on the basis above, at its flow in '
                   'that solve; NODE PRES the gauge pressure at its node in that solve; AVAILABLE what it gives at '
                   'that flow as modelled; MARGIN the difference, both at the supply\'s own connection and '
                   'elevation.  Every figure is from the one solve.  '
                   'A supply\'s joint contribution is NOT its conditional minimum (B): the two answer different '
                   'questions.')

    # D. Scenarios.
    if s.get('scenarios'):
        out += '\n D. SUPPLY SCENARIOS - each solved and validated on its own\n'
        out += ('   %-14s %-4s %-13s %-8s %11s  %s\n'
                % ('SCENARIO', 'REQ', 'RESULT', 'GOVERNS', 'MARGIN', 'SUPPLIES (FLOW AT PRESSURE)'))
        for sc in s['scenarios']:
            sup = ' '.join(('%s OUT' % x['id']) if x['status'] == 'OUT_OF_SERVICE'
                           else '%s %s@%s%s' % (x['id'], f(x['flow'], 0, uf), f(x['pressure'], 0, up),
                                                '(REV)' if x['status'] == 'REVERSE' else '')
                           for x in sc['supplies'])
            out += ('   %-14s %-4s %-13s %-8s %11s  %s\n'
                    % (sc['name'], 'YES' if sc.get('required') else 'no', sc['acceptance'],
                       sc.get('governing') or '-', f(sc['margin'], pd, up), sup))
        out += wrap('   ', 'REQ YES: a SCENARIO line of the model, a requirement - one that is not ACCEPTED fails '
                   'the design.  The others (each supply alone, each out of service in turn) are for information.  '
                   'MARGIN is the governing outlet\'s.')
    return out

#------------------------------------------------------------------------------
# dry_pipe_valves -- Section 13, DRY PIPE VALVES.
#------------------------------------------------------------------------------
def dry_pipe_valves(net, va, dry):
    from . import demand
    uf, up = net['f_flow'], net['f_pres']
    qu, pu = sym(net['u_flow']), sym(net['u_pres'])
    drymap = {d['id']: d for d in (dry or [])}
    out = title('13. DRY PIPE VALVES')
    out += wrap(' ', 'Each dry pipe valve is solved TRIPPED AND FULLY OPEN: the steady state after it has '
               'operated and the system has filled.  The trip, transit and delivery times given below are '
               'ESTIMATES (drytime): they change no other figure in this report, they do not decide '
               'its acceptance, and they are not a water delivery time calculation by a listed method.  The '
               'accelerator is not modelled.') + '\n'
    for e in [x for x in net['elems'][1:] if x['kind'] == 'DPV']:
        hf = elem_hf(e, e['q'], net['opts'])[0]
        errs = [x for x in (va.get('findings') or [])
                if x.get('item') == e['id'] and x['severity'] == 'error']

        def row(k, v):
            return '   %-30s %s\n' % (k, v)
        out += ' %s\n' % e['id']
        out += row('Location', 'pipe %s, from node %s' % (e.get('host_id') or '-',
                                                          net['nodes'][e['n1']]['id']))
        out += row('Nominal size', 'DN%d' % (e.get('size') or 0))
        out += row('Make and model', e.get('model') or e.get('db_model') or 'not given')
        out += row('Trip method',
                   'differential ratio %.2f:1 (water to air pressure at the clapper)' % (e.get('trip_ratio') or 0)
                   if (e.get('trip_mode') or '') == 'RATIO' else
                   ('air-side trip pressure %.1f %s' % ((e.get('trip_pressure') or 0) / up, pu)
                    if (e.get('trip_mode') or '') == 'TRIP' else 'not given'))
        out += row('Accelerator', '%s (not modelled: no effect on trip time is assumed)'
                   % (e.get('accelerator') or '-'))
        tr = e.get('transient') or {}
        out += row('Set air pressure',
                   '%.1f %s (used for the trip time estimate only)' % (tr['air_initial'] / up, pu)
                   if tr.get('air_initial') is not None else 'not given')
        basis = e.get('loss') or 'NONE'
        if basis == 'CURVE':
            if e.get('fixed_loss') is not None:
                out += row('Loss basis', 'fixed loss %.2f %s, as entered' % (e['fixed_loss'] / up, pu))
            else:
                c = e['curve']
                out += row('Loss basis', 'flow/loss points as entered (%s)'
                           % ', '.join('%g@%g' % (c['q'][i] / uf, c['p'][i] / up)
                                       for i in range(len(c['q']))))
        elif basis == 'EQL':
            host = e.get('host')
            out += row('Loss basis', 'equivalent length %.2f m of pipe %s (bore %.1f mm, %s)'
                       % (e['eql'], e['host_id'], host['dia'] if host else 0,
                          'its roughness' if (net['opts'].get('method') or 'HW') == 'DW'
                          else 'C %g' % (host.get('c') if host and host.get('c') is not None else 0)))
        elif basis == 'DB' and e.get('cv'):
            db = e['db']
            out += row('Loss basis', 'the pipe and fitting database: %s %s DN%d, flow '
                      'coefficient Cv %g (gpm at 1 psi, loss = (Q/Cv)^2) - %s'
                      % (db['maker'], db['model'], db['dn'], e['cv'], db['source']))
        elif basis == 'DB':
            db = e['db']
            out += row('Loss basis', 'the pipe and fitting database: %s %s DN%d, %s %s of %s pipe '
                      '(bore %.2f mm) at C %g, by Hazen-Williams - %s'
                      % (db['maker'], db['model'], db['dn'], db['eql'], db['eql_unit'].lower(),
                         'Schedule 40' if db['ref'].upper() == 'S40' else '%s bore' % db['ref'],
                         e.get('ref_bore') or 0, e.get('ref_c') or 0, db['source']))
        elif e.get('db'):
            db = e['db']
            out += row('Loss basis', '*** DATA_REQUIRED - the database record for the %s %s DN%d gives no usable '
                      'loss; the calculation is rejected' % (db['maker'], db['model'], db['dn']))
        else:
            out += row('Loss basis', '*** NONE GIVEN - DATA_REQUIRED; the calculation is rejected')
        # Where the loss came from: manufacturer data, or a figure entered in
        # the model -- a constant loss is said to be a simplification.
        out += row('Loss source',
                   {'MANUFACTURER_DB': 'MANUFACTURER DATA, from the database',
                    'USER_CURVE': 'USER ENTERED flow/loss points - check against the data sheet',
                    'USER_EQL': 'USER ENTERED equivalent length - check against the data sheet',
                    'USER_FIXED': 'USER ENTERED CONSTANT LOSS - a SIMPLIFICATION, valid only near the flow it '
                                  'was taken at',
                    'NONE': 'NONE - DATA_REQUIRED'}.get(e.get('loss_source') or 'NONE')
                   or e.get('loss_source'))
        out += row('Steady-state flow', '%.*f %s' % (qdp(net['u_flow']), e['q'] / uf, qu))
        out += row('Hydraulic loss', '%.*f %s' % (pdp(net['u_pres']) + 1, hf / up, pu))
        out += row('Inlet / outlet pressure', '%.*f / %.*f %s'
                   % (pdp(net['u_pres']), demand.gauge(net, e['n1']) / up,
                      pdp(net['u_pres']), demand.gauge(net, e['n2']) / up, pu))
        out += row('Validation', '*** ' + '; '.join(x['code'] for x in errs) if errs else 'PASS')
        if e['id'] in drymap:
            out += dry_time_rows(net, drymap[e['id']], row)
        out += '\n'
    return out

#------------------------------------------------------------------------------
# dry_time_rows -- a dry pipe valve's ESTIMATED times (drytime), each with
# what it was worked from, so it can be checked by hand.
#------------------------------------------------------------------------------
def dry_time_rows(net, d, row):
    up = net['f_pres']
    pu = sym(net['u_pres'])
    out = ''
    if d.get('error'):
        row('Trip and transit times', 'NOT ESTIMATED: %s' % d['error'])
        return out
    row('Dry system volume', '%.4f m3 in %d pipes downstream of the valve' % (d['volume'], d['pipes']))
    t = d.get('trip') or {}
    if (t.get('status') or '') == 'ESTIMATE':
        row('TRIP TIME, ESTIMATE', '%.1f s' % t['seconds'])
        row('   worked from',
            't = 0.0352 V / (An sqrt T0) ln(pa0/pa) (FM Global, SFPE Handbook): '
            'V %.3f ft3, An %d x %.2f mm orifice = %.6f ft2, T0 %.1f C = %.1f R, pa0 %.2f psia (set air %.1f %s), '
            'pa %.2f psia (trip %.1f %s%s)'
            % (d['volume'] / 0.028316846592, t['open_count'], t['orifice_mm'],
               t['area'] / 0.09290304, t['air_temp_c'], (t['air_temp_c'] + 273.15) * 1.8,
               (t['air_gauge'] + 101.325) / 6.894757, t['air_gauge'] / up, pu,
               (t['trip_gauge'] + 101.325) / 6.894757, t['trip_gauge'] / up, pu,
               (', from %.1f %s static water%s' % (t['static'] / up, pu,
                 ' as given' if t.get('static_given') else ' from the supplies, pumps not included'))
               if t.get('static') is not None else ''))
        if t.get('accelerator_ignored'):
            row('   accelerator', 'ON, but not modelled: the time is without it')
        if not t.get('choked'):
            row('   choked flow', 'NO - the trip pressure is below 1.893 atm, so the estimate is less reliable')
    else:
        row('TRIP TIME', ('*** %s' % t['reason']) if (t.get('status') or 'NOT_CALCULATED') == 'ERROR'
            else 'not estimated: %s' % t.get('reason'))
    x = d.get('transit') or {}
    if (x.get('status') or '') == 'ESTIMATE':
        row('TRANSIT TIME, ESTIMATE', '%.1f s, the larger of:' % x['seconds'])
        if x.get('path_seconds') is not None:
            row('   water front to the remote head',
                '%.1f s along %.1f m (%s) to %s, sum of L / v at the %s flows'
                % (x['path_seconds'], x['path_length'], ' '.join(x['path_pipes']), x['remote'], x['basis']))
        else:
            row('   water front to the remote head', 'not traced')
        if x.get('fill_seconds') is not None:
            row('   filling the dry volume',
                '%.1f s: dry volume / %.1f %s through the valve at the %s'
                % (x['fill_seconds'], x['flow'] / net['f_flow'], sym(net['u_flow']), x['basis']))
        else:
            row('   filling the dry volume', 'no flow')
        row('   ignoring', 'the air the water has to compress and expel: a lower bound')
    else:
        row('TRANSIT TIME', 'not estimated: %s' % x.get('reason'))
    if d.get('delivery') is not None:
        row('DELIVERY TIME, ESTIMATE',
            '%.1f s = trip + transit (not a listed method: check with one, or a test)' % d['delivery'])
    return out

#------------------------------------------------------------------------------
# acceptance_section -- Section 14, CALCULATION ACCEPTANCE: the result and
# every mandatory failure, listed apart from the ordinary notes.
#------------------------------------------------------------------------------
def acceptance_section(net, va):
    from . import validate
    out = title('14. CALCULATION ACCEPTANCE')
    out += ' %-26s %s\n' % ('RESULT', validate.acceptance_text(va['acceptance']))
    out += ' %-26s %s\n' % ('Numerical convergence', STATUS_WORD[va['numerical']['status']])
    out += ' %-26s %s\n' % ('Physical validity', STATUS_WORD[va['physical']['status']])
    out += ' %-26s %s\n' % ('Design compliance', STATUS_WORD[va['design']['status']])
    err = [x for x in va.get('findings') or [] if x['severity'] == 'error']
    if err:
        out += '\n MANDATORY FAILURES\n'
        for i in range(len(err)):
            out += wrap(' %2d  %-9s ' % (i + 1, err[i]['category'].upper()),
                        '[%s] %s' % (err[i]['code'], err[i]['message']))
    wn = [x for x in va.get('findings') or [] if x['severity'] == 'warning']
    if wn:
        out += '\n FOR CHECKING (do not decide the result)\n'
        for i in range(len(wn)):
            out += wrap(' %2d  ' % (i + 1), '[%s] %s' % (wn[i]['code'], wn[i]['message']))
    out += '\n' + wrap(' ', 'ACCEPTED means the network balances, every device is in a state it can be in, '
               'and the design requirements in the model are met, as checked by PHCP.  It is not an '
               'independent certification of the design.')
    return out
