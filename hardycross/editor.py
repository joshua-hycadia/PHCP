#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# editor.py -- everything the .phc text editor decides, without Tk.
#
# phcp_editor.py is the window: it draws text and tables, takes keys and calls
# this module for every decision.  Keeping the decisions here means each one
# can be tested headless and the window stays thin enough to check by
# reading.  Nothing in this module knows a widget exists.
#
# What it answers:
#
#   check_buffer   every line's status (ok / incomplete / error) and message
#   diagnostics    the ERRORS, WARNINGS and NODES lists beside the editor
#   context_at     what is in force at a line: USE, UNITS, METHOD, options,
#                  defined nodes -- what phc.check_line needs
#   proposal       the likely next line after the one just finished
#   choices        the pick list for the cursor's field
#   status_at      the status bar: the field template and the line's message
#   colour_spans   where on a line the command word and the comment are
#   solve_text     solve the buffer; the report, or the error and its line
#   results_at     the solved figures for the element on a line
#   result_tables  the PIPES, NODES and OUTLETS tables under the editor
#   pipe_columns   every pipe column, with which are shown by default
#   sort_rows      a table sorted on one column, as a click on its heading does
#   units_of       the file's units, defaults filled in
#   load_file / write_report_file
#
# And for the window, which keeps the settings apart from the network:
#
#   split_file     a .phc file as { settings, network }: TITLE, PROJECT,
#                  UNITS, METHOD and OPTION lines go to the PROJECT tab, the
#                  rest is the network the editor shows
#   join_file      settings and network back into one .phc text
#   doc_check / doc_diagnostics / doc_choices / doc_status / doc_solve
#                  the checks above, on the network with the settings in force,
#                  numbered by network line
#   validate       every problem before a calculation: what is wrong, why,
#                  and where - the line, the field and its columns, or the
#                  PROJECT tab field
#
# Every check is made by phc.py, the code that reads a .phc file for
# a solve, so the editor cannot call a line good that the solver refuses.

import math
import os
import re

from . import GAMMA_W, ModelError, is_model_error
from . import phc, report, results, sizing, areas
from . import validate as _validate
from . import build_tree, solve_model, elem_hf, pipe_velocity, dw_friction
from . import outlet_pressure

GW = GAMMA_W


# _true -- Perl's truth of a name: undef, '' and '0' are false.  An element or
# node named 0 is therefore left out wherever the Perl tests the name itself.
def _true(v):
    return v is not None and v != '' and v != '0' and v != 0

_NUMBER = re.compile(r'^-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\Z')
_ON_LINE = re.compile(r'\bON LINE (\d+)')
_LINE_N = re.compile(r'^line (\d+): ')
_IS_MODEL_ERROR = is_model_error

# Perl's \s and Python's differ on four characters: the separators FS, GS, RS
# and US (\x1c-\x1f) are white space to Python's \s, str.split and str.strip,
# and are not to Perl's.  _WS and _NWS are Perl's two classes, so a word, a
# blank line and a trimmed cell are what they are in the Perl.
_WS = r'[^\S\x1c-\x1f]'
_NWS = r'[\S\x1c-\x1f]'
_WORD = re.compile('(' + _NWS + '+)')
_BLANK = re.compile('^' + _WS + '*$')


# lines -- the buffer as lines, numbered from 1 (l[0] is unused).
def lines(text):
    # Perl's split gives no line at all for an empty buffer, not one empty line.
    if text is None or text == '':
        return [None]
    return [None] + text.split('\n')


#==============================================================================
# The buffer as a whole.
#==============================================================================

#------------------------------------------------------------------------------
# scan -- one pass over the buffer: each line's analysis and what is in force.
#
# Returns {
#   a       => [ per line, phc.analyse result ],
#   use_at  => [ per line, the USE in force: { type, c } ],
#   units   => { LENGTH => 'MM', ... }   the file's UNITS, defaults filled in
#   options => { NAME => value }         the file's OPTION lines
#   method  => 'HW' or 'DW'
#   nodes   => { name => first line defining it }
#   names   => { name => first line } for every pipe, element and node name
#   used    => { node => first line using it }
# }
# Settings are file-wide in .phc, so a UNITS line at the bottom applies to the
# line at the top; that is why this is a pass over the whole buffer.  USE is
# the exception, and use_at follows it line by line.
#------------------------------------------------------------------------------
def scan(text):
    l = lines(text)[1:]
    s = {'a': [None], 'use_at': [None], 'units': dict(phc.UNIT_DEFAULT),
         'options': {}, 'method': 'HW', 'nodes': {}, 'names': {}, 'used': {}}
    unit_seen = {}
    use = {'type': 'BORE'}
    for i in range(1, len(l) + 1):
        a = phc.analyse(l[i - 1])
        s['a'].append(a)
        if a['status'] == 'ok':
            k = a['key']
            p = list(a['pos'])
            if k == 'USE':
                use = {'type': p[0], 'c': (a['opt'][0] if a['opt'] else None)}
            if k == 'UNITS' and not unit_seen.get(p[0]):
                unit_seen[p[0]] = 1
                s['units'][p[0]] = p[1]
            if k == 'OPTION' and p[0] not in s['options']:
                s['options'][p[0]] = p[1]
            if k == 'METHOD':
                s['method'] = p[0]
            for n in phc.nodes_defined(a):
                if n not in s['nodes']:
                    s['nodes'][n] = i
                if n not in s['names']:
                    s['names'][n] = i
            for n in phc.names_defined(a):
                if n not in s['names']:
                    s['names'][n] = i
            for n in phc.nodes_used(a):
                if n not in s['used']:
                    s['used'][n] = i
        s['use_at'].append(use)
    return s


# context_at -- the check_line context for line n.
def context_at(text, n, _scan=None):
    if _scan is None:
        _scan = scan(text)
    # A line outside the buffer has no USE (Perl: undef, so the default).
    ua = _scan['use_at']
    use = ua[n] if -len(ua) <= n < len(ua) else None
    return {'use': use or {'type': 'BORE'},
            'units': _scan['units'], 'options': _scan['options'],
            'method': _scan['method'], 'nodes': _scan['nodes']}


#------------------------------------------------------------------------------
# check_buffer -- every line checked.
#
#   editing  the line the cursor is on (optional): an incomplete line there
#             is still being typed and is not listed as a problem
#
# Returns {
#   lines     => [ per line (from 1): { status, message } ]
#   problems  => [ { line, message } ] in line order
#   undefined => [ { node, line } ]  nodes used but defined nowhere
#   unused    => [ { node, line } ]  nodes defined that nothing connects to
# }
# A line's status is check_line's, except that a setting given twice, a node
# defined twice or a name used twice is an error on the later line -- the
# same rules, in the same words, as the reader.
#------------------------------------------------------------------------------
def check_buffer(text, editing=None):
    l = lines(text)[1:]
    _scan = scan(text)
    set_, node, name = {}, {}, {}
    r = {'lines': [None]}
    for i in range(1, len(l) + 1):
        chk = cached_check(l[i - 1], context_at(text, i, _scan))
        st, msg = chk['status'], chk['message']
        a = _scan['a'][i]
        if st == 'ok' and a.get('key'):
            for k in ([phc.setting_keys(a)] if phc.setting_keys(a) else []):
                if set_.get(k):
                    st, msg = 'error', '%s IS ALREADY SET ON LINE %s' % (k, set_[k])
                else:
                    set_[k] = i
            for n in phc.nodes_defined(a):
                if node.get(n):
                    st, msg = 'error', 'NODE %s IS ALREADY DEFINED ON LINE %s' % (n, node[n])
                else:
                    node[n] = i
            for n in phc.names_defined(a):
                if name.get(n):
                    st, msg = 'error', 'THE NAME %s IS ALREADY USED ON LINE %s' % (n, name[n])
                else:
                    name[n] = i
        r['lines'].append({'status': st, 'message': msg})
        if st != 'ok':
            if not (st == 'incomplete' and editing is not None and editing == i):
                r.setdefault('problems', []).append({'line': i, 'message': msg})
    r.setdefault('problems', [])
    u, d = _scan['used'], _scan['nodes']
    r['undefined'] = [{'node': n, 'line': u[n]}
                      for n in sorted((x for x in u if x not in d), key=lambda x: u[x])]
    r['unused'] = [{'node': n, 'line': d[n]}
                   for n in sorted((x for x in d if x not in u), key=lambda x: d[x])]
    return r


#------------------------------------------------------------------------------
# cached_check -- check_line for check_buffer, remembered between calls.
#
# The window re-checks the whole buffer after each pause in typing; on a
# 3000-line model that took a second, every line parsed again although only
# one had changed.  A line's verdict depends only on its text and the USE,
# UNITS, METHOD and options in force, so that is the key (the defined nodes
# are left out: check_buffer works out undefined nodes itself).  The cache is
# emptied when it grows past a limit.
#------------------------------------------------------------------------------
CHECK_CACHE = {}
CACHE_LIMIT = 50000


# clear_cache -- forget every remembered verdict: after the pipe and fitting
# database changes, a line that was good may not be, and the other way about.
def clear_cache():
    CHECK_CACHE.clear()


def cached_check(line, ctx):
    u = ctx.get('use') or {}
    key = '\x00'.join([line or '', u.get('type') or '', str(u.get('c') or ''),
                       ctx.get('method') or '']
                      + ['%s=%s' % (k, ctx['units'][k]) for k in sorted(ctx.get('units') or {})]
                      + ['%s=%s' % (k, ctx['options'][k])
                         for k in sorted(ctx.get('options') or {})])
    if len(CHECK_CACHE) > CACHE_LIMIT:
        CHECK_CACHE.clear()
    if key not in CHECK_CACHE:
        c = dict(ctx)
        c.pop('nodes', None)
        r = phc.check_line(line, c)
        CHECK_CACHE[key] = {'status': r['status'], 'message': r['message']}
    return CHECK_CACHE[key]


#------------------------------------------------------------------------------
# diagnostics -- the three lists beside the editor.
#
# Returns {
#   errors   => [ { line, message } ]  lines the reader refuses
#   warnings => [ { line, message } ]  what the last solve found: no
#                                      convergence, a pipe over the velocity
#                                      limit, an outlet or fixed flow short of
#                                      its requirement, the engine's warnings
#   nodes    => [ { line, message } ]  nodes used but not defined, and nodes
#                                      defined that nothing connects to
# }
# net is the last solve, or None; warnings need one.  Each entry carries the
# .phc line it belongs to, so a click can go there.
#------------------------------------------------------------------------------
def diagnostics(text, net=None, editing=None):
    chk = check_buffer(text, editing)
    _scan = scan(text)
    d = {'errors': chk['problems'], 'warnings': [], 'nodes': []}
    for x in chk['undefined']:
        d['nodes'].append({'line': x['line'],
                           'message': '%s - USED, BUT NOT DEFINED' % x['node']})
    for x in chk['unused']:
        d['nodes'].append({'line': x['line'],
                           'message': '%s - DEFINED, BUT NOTHING CONNECTS TO IT' % x['node']})
    if not net:
        return d

    # A device's id is "<pipe>.<kind>" and its node "<pipe>~": either leads
    # back to the pipe's line.
    def line_of(id_):
        id_ = re.sub(r'[.~].*$', '', id_ or '')
        return _scan['names'].get(id_)

    if not net.get('converged'):
        d['warnings'].append({'line': None,
                               'message': 'THE SOLVE DID NOT CONVERGE: THE RESULTS MUST NOT BE USED'})
    # The calculation's acceptance and every mandatory failure, from the same
    # validation the report and the JSON print (validate.assess; the report
    # written with the solve has already worked it out).
    va = _validate.assess(net, net.get('converged'))['validation']
    if va.get('acceptance') != 'ACCEPTED':
        d['warnings'].append({'line': None,
                              'message': 'CALCULATION ' + _validate.acceptance_text(va['acceptance']).upper()})
        for f in va.get('findings') or []:
            if f.get('severity') == 'error' and f.get('category') != 'design':
                d['warnings'].append({'line': line_of(f.get('item') or ''),
                                      'message': ('%s: %s' % (f['code'], f['message'])).upper()})
    vl = net['opts'].get('vel_limit') or 6
    for e in net['elems'][1:]:
        if e.get('kind') != 'PIPE':
            continue
        v = abs(pipe_velocity(e['q'], e['dia']))
        if v > vl:
            d['warnings'].append({'line': line_of(e['id']),
                                  'message': '%s - VELOCITY %.2f M/S IS OVER THE LIMIT OF %g M/S'
                                             % (e['id'], v, vl)})
    t = result_tables(net)
    for r in t['outlets']['rows']:
        if r['keys'][-1] != 'FAIL':
            continue
        d['warnings'].append({'line': line_of(r['keys'][0]),
                              'message': '%s - BELOW ITS REQUIREMENT: %s AGAINST %s REQUIRED'
                                         % (r['keys'][0], r['cells'][7], r['cells'][6])})
    for w in net.get('warnings') or []:
        d['warnings'].append({'line': None, 'message': str(w).upper()})
    return d


#==============================================================================
# The cursor's line.
#==============================================================================

#------------------------------------------------------------------------------
# proposal -- the line to offer after line n, or None.
#
# phc.propose steps the names (P7 -> P8; a pipe starts where the last ended).
# Here the name is stepped again, as often as needed, past any name the
# buffer already uses, so accepting a proposal never makes a duplicate.
#------------------------------------------------------------------------------
def proposal(text, n):
    l = lines(text)[1:]
    if not (1 <= n <= len(l)):
        return None
    p = phc.propose(l[n - 1])
    if p is None:
        return None
    _scan = scan(text)
    parts = p.split(' ')
    word, id_ = parts[0], parts[1]
    rest = parts[2:]
    for _ in range(1000):
        if not _scan['names'].get(id_):
            break
        id_ = phc.step_id(id_)
    return ' '.join([word, id_] + rest)


# choices -- the pick list at column col of line n: [ [code, description] ].
def choices(text, n, col):
    l = lines(text)[1:]
    if not (1 <= n <= len(l)):
        return []
    ctx = context_at(text, n)
    ctx['cursor'] = col
    return phc.check_line(l[n - 1], ctx).get('choices') or []


# status_at -- the status bar for the cursor at line n, column col:
# { template => { command, text, fields, current }, status, message }.
def status_at(text, n, col):
    l = lines(text)[1:]
    if not (1 <= n <= len(l)):
        return {'status': 'ok', 'message': '', 'template': None}
    ctx = context_at(text, n)
    ctx['cursor'] = col
    r = phc.check_line(l[n - 1], ctx)
    return {'status': r['status'], 'message': r['message'],
            'template': r.get('template')}


#------------------------------------------------------------------------------
# colour_spans -- the syntax colouring of one line: ( [start, end, kind] ... ),
# columns, end exclusive.  The kinds:
#
#   command   the command word, when it IS a command
#   name      a name the line defines: a new pipe, node or element
#   ref       a name the line refers to: a node or pipe defined elsewhere
#   number    a number in a numeric field
#   keyword   a pipe type, fitting code, unit, method or option name
#   comment   from // to the end of the line
#
# The kind of each field comes from the command's field list, so P1 is a name
# after PIPE and a reference after BFP.  Nothing is coloured on a line whose
# first word is not a command.
#------------------------------------------------------------------------------
KEYWORD_TYPE = {'pipetype': 1, 'quantity': 1, 'unit': 1, 'method': 1, 'option': 1, 'field': 1}


def colour_spans(line):
    line = line or ''
    s = []
    cpos = line.find('//')
    code = line[:cpos] if cpos >= 0 else line
    tok = [[m.start(), m.end(), m.group(1)] for m in _WORD.finditer(code)]
    c = phc.command_spec(tok[0][2]) if tok else None
    if c:
        s.append([tok[0][0], tok[0][1], 'command'])
        if c['name'] not in ('TITLE', 'PROJECT'):
            types = [fd[1] for fd in c['fixed']] + \
                   [fd[1] for fd in c.get('opt') or []]
            rest = c.get('rest') or ''
            for i in range(1, len(tok)):
                a, b, t = tok[i]
                type_ = types[i - 1] if i - 1 < len(types) else None
                j = i - 1 - len(types)                     # index into the rest
                if type_ is not None:
                    if type_ == 'new':
                        kind = 'name'
                    elif type_ in ('node', 'pipe'):
                        kind = 'ref'
                    elif type_ in KEYWORD_TYPE:
                        kind = 'keyword'
                    elif re.match(r'^[-+.]?\d', t):
                        kind = 'number'
                    else:
                        kind = None
                elif rest == 'fittings':
                    kind = 'keyword'
                elif rest == 'pairs':
                    kind = 'number'
                elif rest == 'copies':
                    kind = 'ref' if j % 3 else 'name'
                elif rest == 'names':
                    kind = 'name'
                else:
                    kind = None
                if kind:
                    s.append([a, b, kind])
    if cpos >= 0:
        s.append([cpos, len(line), 'comment'])
    return s


#==============================================================================
# Solving and results.
#==============================================================================

#------------------------------------------------------------------------------
# solve_text -- read and solve the buffer.
#
# Returns { ok, converged, net, report, error, line }: ok when it was read and
# solved (converged or not); error and its .phc line when it was not.
#------------------------------------------------------------------------------
def solve_text(text, path, **o):
    # A supply graph (SUPPLYGRAPH) is found from the model's folder, or the
    # current one for a model not yet saved.
    try:
        net = phc.read_string(text, os.path.dirname(path) if path else '.')
    except Exception as e:
        return error_result(e)
    try:
        conv = solve_model(net)
    except Exception as e:
        return error_result(e)
    # Pipes given size 0 are sized (sizing).
    if net.get('auto_sizing'):
        try:
            net, conv = sizing.size(net, conv, progress=o.get('progress'))
        except Exception as e:
            return error_result(e)
    # With design areas (AREA), each is solved and the governing one shown.
    if net.get('areas'):
        try:
            net, conv = areas.governing(net, conv, progress=o.get('progress'))
        except Exception as e:
            return error_result(e)
    net['converged'] = conv
    return {'ok': 1, 'converged': conv, 'net': net,
            'report': report.write_report(net, conv, path or 'UNTITLED.PHC')}


# error_result -- a model error as { error, line }; anything else is a bug and
# is passed on, so it is seen rather than shown as a model problem.
def error_result(e):
    if not _IS_MODEL_ERROR(e):
        raise e
    r = {'ok': 0, 'error': str(e.msg).upper()}
    m = _LINE_N.match(str(e.msg))
    if m:
        r['line'] = int(m.group(1))
    return r


#------------------------------------------------------------------------------
# display_units -- how figures are shown: flows and pressures in the file's
# units, lengths in its LENGTH unit, elevations in its ELEVATION unit,
# velocity in m/s.  The network holds metres, L/min and kPa internally.
#------------------------------------------------------------------------------
TO_METRE = {'MM': 0.001, 'CM': 0.01, 'M': 1, 'IN': 0.0254, 'FT': 0.3048}
LABEL = {'LPM': 'L/MIN', 'LPS': 'L/S', 'M3H': 'M3/H', 'GPM': 'GPM',
         'KPA': 'KPA', 'BAR': 'BAR', 'MPA': 'MPA', 'PSI': 'PSI', 'M': 'M HEAD'}


def display_units(net):
    u = net.get('phc_units') or {'LENGTH': net['u_len'].upper(),
                                 'ELEVATION': net['u_len'].upper()}
    return {
        'qf': net['f_flow'], 'pf': net['f_pres'],
        'q': LABEL.get(net['u_flow'].upper(), net['u_flow'].upper()),
        'p': LABEL.get(net['u_pres'].upper(), net['u_pres'].upper()),
        'lf': TO_METRE.get(u.get('LENGTH'), 1), 'l': u.get('LENGTH'),
        'ef': TO_METRE.get(u.get('ELEVATION'), 1), 'e': u.get('ELEVATION'),
        'qdp': 3 if net['f_flow'] > 1.5 else 1,
        'pdp': 3 if net['f_pres'] > 1.5 else 1,
    }


#------------------------------------------------------------------------------
# results_at -- the solved figures for the element or node on a line, as one
# line of text in the model's units, or None when the line names nothing in
# the solved network (a setting, a blank, an element added since the solve).
#------------------------------------------------------------------------------
def results_at(net, line):
    if not net:
        return None
    a = phc.analyse(line or '')
    if a['status'] != 'ok' or not a.get('key'):
        return None
    u = display_units(net)
    k, id_ = a['key'], a['pos'][0]
    el = {e['id']: e for e in net['elems'][1:] if e and _true(e.get('id'))}
    ni = {net['nodes'][i]['id']: i for i in range(1, len(net['nodes']))}

    def p(i):
        return (net['nodes'][i]['h'] - GW * net['nodes'][i]['z']) / u['pf']

    def nm(i):
        return net['nodes'][i]['id']

    def qs(v):
        return '%.*f %s' % (u['qdp'], v / u['qf'], u['q'])

    def ps(v):
        return '%.*f %s' % (u['pdp'], v, u['p'])

    if k in ('PIPE', 'CHANGEPIPE', 'EQV'):
        e = el.get(id_)
        if e is None:
            return None
        v = abs(pipe_velocity(e['q'], e['dia']))
        b, t = (e['n1'], e['n2']) if e['q'] >= 0 else (e['n2'], e['n1'])
        return '%s  Q %s  V %.2f M/S  %s %s -> %s %s' % (
            id_, qs(abs(e['q'])), v, nm(b), ps(p(b)), nm(t), ps(p(t)))
    if k == 'FIXEDFLOW':
        f = None
        for x in net.get('fixed') or []:
            if x['id'] == id_:
                f = x
                break
        if f is None:
            return None
        req = (' (REQUIRED %.*f)' % (u['pdp'], f['preq'] / u['pf'])
               if f.get('preq') is not None else '')
        return '%s  FIXED %s AT %s%s' % (id_, qs(f['q']), ps(p(f['n1'])), req)
    if k in ('SPRINKLER', 'HYDRANT', 'HREEL') and id_ in el:
        e = el[id_]
        # With velocity pressure ON, an in-line sprinkler discharges on Pn,
        # and the line says so; otherwise the line reads as it always has.
        pn = (', PN %s' % ps(outlet_pressure(net, e) / u['pf'])
              if e.get('pv') else '')
        return '%s  DISCHARGE %s AT %s%s (REQUIRED %.*f)' % (
            id_, qs(abs(e['q'])), ps(p(e['n1'])), pn, u['pdp'], e['preq'] / u['pf'])
    if k == 'WATER' and id_ in el:
        return '%s  SUPPLIES %s AT %s' % (id_, qs(abs(el[id_]['q'])), ps(p(el[id_]['n2'])))
    if phc.command_spec(k)['kind'] == 'device' or k == 'PUMP':
        e = el.get(id_ if k == 'PUMP' else '%s.%s' % (id_, k))
        if e is None:
            return None
        return '%s  Q %s  %s %s -> %s %s' % (
            e['id'], qs(e['q']), nm(e['n1']), ps(p(e['n1'])), nm(e['n2']), ps(p(e['n2'])))
    if id_ in ni:
        z = net['nodes'][ni[id_]]['z'] / u['ef']
        return '%s  PRESSURE %s, ELEVATION %.3f %s' % (id_, ps(p(ni[id_])), z, u['e'])
    return None


#==============================================================================
# The results tables.
#
# Each table is { columns => [ { head, unit, align, ... } ],
#                 rows    => [ { cells => [text, ...], keys => [sort value, ...],
#                               active => 0|1 } ] }
# cells are what is shown, already formatted; keys are what a column sorts on
# (numbers as numbers).  active is false for a pipe carrying no flow or a node
# no water passes through, which the HIDE boxes leave out.
#==============================================================================

#------------------------------------------------------------------------------
# pipe_columns -- every pipe column, in order: key, heading, the description
# the column chooser shows, unit, alignment, and whether it is shown by
# default.  NAME is always shown (fixed).
#------------------------------------------------------------------------------
def pipe_columns(u):
    q, p, l = u['q'], u['p'], u['l']

    def col(key, head, desc, unit, align, show):
        return {'key': key, 'head': head, 'desc': desc, 'unit': unit,
                'align': align, 'show': show}

    return [
        dict(col('NAME', 'NAME', 'PIPE NAME', '', 'w', 1), fixed=1),
        col('SNODE', 'SNODE', 'START NODE', '', 'w', 1),
        col('ENODE', 'ENODE', 'END NODE', '', 'w', 1),
        col('NOM', 'NOM', 'NOMINAL SIZE', 'MM', 'e', 1),
        col('ID', 'I.D.', 'ID - INTERNAL DIAMETER', 'MM', 'e', 1),
        col('MAT', 'MAT', 'MAT - PIPE MATERIAL', '', 'w', 1),
        col('C', 'C', 'C - C FACTOR OR ABSOLUTE ROUGHNESS', '', 'e', 1),
        col('L', 'L', 'L - PIPE LENGTH', l, 'e', 1),
        col('F', 'F', 'F - FITTING EQV LENGTH', l, 'e', 1),
        col('T', 'T', 'T - TOTAL LENGTH', l, 'e', 1),
        col('K', 'FIT K', 'K - FITTING LOSS CONSTANT', '', 'e', 1),
        col('Q', 'Q', 'Q - FLOW', q, 'e', 1),
        col('PF', 'PF', 'PF - FRICTION LOSS', p, 'e', 1),
        col('PFX', 'PF/M', 'PF/X - FRICTION LOSS/DISTANCE', p + '/M', 'e', 0),
        col('PE', 'PE', 'PE - ELEVATION LOSS', p, 'e', 0),
        col('PS', 'PS', 'PS - DEVICE PRESSURE LOSS', p, 'e', 1),
        col('PV', 'PV', 'PV - VELOCITY PRESSURE', p, 'e', 0),
        col('VEL', 'VEL', 'VEL - VELOCITY', 'M/S', 'e', 1),
        col('RE', 'RE', 'RE - REYNOLDS NUMBER', '', 'e', 0),
        col('FD', 'F', 'F - DARCY FRICTION FACTOR', '', 'e', 0),
        col('FORMULA', 'FORMULA', 'FRICTION FORMULA', '', 'w', 0),
    ]


def result_tables(net):
    if not net:
        return {}
    u = display_units(net)
    o = net['opts']
    dw = (o.get('method') or 'HW') == 'DW'

    def node(i):
        return net['nodes'][i]

    def gauge(i):
        n = node(i)
        return (n['h'] - GW * n['z']) / u['pf']

    def num(v, dp):
        return ['%.*f' % (dp, v), v]

    def txt(t):
        t = str(t).upper() if t is not None else ''
        return [t, t]

    none = ['-', -1e300]

    def row(cells, act):
        return {'cells': [c[0] for c in cells],
                'keys': [c[1] for c in cells], 'active': act}

    el = {e['id']: e for e in net['elems'][1:] if e and _true(e.get('id'))}
    t = {}

    #------------------------------------------------------------ PIPES
    # Written in the direction of flow, as the report's pipe schedule is:
    # SNODE upstream, Q positive, PE the pressure lost climbing to ENODE.  PF
    # is friction alone (a K-factor loss is shown through FIT K); PS is the
    # loss across a device placed in the pipe -- a BFP, PRV, plate or ratio
    # valve, or a pump's gain, which is negative.
    t['pipes'] = {'columns': pipe_columns(u), 'rows': []}
    for e in net['elems'][1:]:
        if e.get('kind') != 'PIPE':
            continue
        fwd = e['q'] >= 0
        b, f = (e['n1'], e['n2']) if fwd else (e['n2'], e['n1'])
        hf = elem_hf(e, e['q'], o)[0]
        v = abs(pipe_velocity(e['q'], e['dia']))
        pv = 0.5 * v ** 2                              # rho v^2 / 2, kPa
        pk = (e.get('kfit') or 0) * pv                 # the K-factor part
        pf = (abs(hf) - pk) / u['pf']
        lt = e['len'] + e['eqv']                       # metres
        pe = GW * (node(f)['z'] - node(b)['z']) / u['pf']
        re = v * e['dia'] / 1000 / (o.get('nu') or 1.004e-6)
        fd = dw_friction(re, e['eps'], e['dia']) if dw else None
        dev = None
        for key in el:
            if key.startswith(e['id'] + '.'):
                dev = key
        ps = None
        if dev:
            d = el[dev]
            ps = 0 if d.get('closed') else elem_hf(d, d['q'], o)[0]
            ps /= u['pf']
        t['pipes']['rows'].append(row([
            txt(e['id']), txt(node(b)['id']), txt(node(f)['id']),
            (num(e['dn'], 0) if e.get('dn') is not None else none), num(e['dia'], 1),
            txt(e.get('ptype') or 'BORE'),
            (num(e['eps'], 3) if dw else num(e['c'], 0)),
            num(e['len'] / u['lf'], 2), num(e['eqv'] / u['lf'], 2), num(lt / u['lf'], 2),
            num(e.get('kfit') or 0, 2), num(abs(e['q']) / u['qf'], u['qdp']),
            num(pf, u['pdp'] + 1), (num(pf / lt, u['pdp'] + 3) if lt > 0 else none),
            num(pe, u['pdp'] + 1), (num(ps, u['pdp'] + 1) if ps is not None else none),
            num(pv / u['pf'], u['pdp'] + 1), num(v, 2), num(re, 0),
            (num(fd, 5) if fd is not None else none), txt('DW' if dw else 'HW'),
        ], abs(e['q']) > 1e-6))

    #------------------------------------------------------------ NODES
    t['nodes'] = {'columns': [
        {'head': 'NAME', 'unit': '', 'align': 'w'}, {'head': 'TYPE', 'unit': '', 'align': 'w'},
        {'head': 'ELEV', 'unit': u['e'], 'align': 'e'}, {'head': 'PRESSURE', 'unit': u['p'], 'align': 'e'},
        {'head': 'DISCHARGE', 'unit': u['q'], 'align': 'e'}, {'head': 'REQUIRED', 'unit': u['p'], 'align': 'e'},
        {'head': 'MARGIN', 'unit': u['p'], 'align': 'e'}], 'rows': []}
    type_, out, req = {}, {}, {}
    for e in el.values():
        if e.get('kind') == 'DISCHARGE':
            type_[e['n1']] = 'HREEL' if e.get('otype') == 'HOSEREEL' else e['otype']
            out[e['n1']] = out.get(e['n1'], 0) + abs(e['q'])
            if e['preq'] > req.get(e['n1'], -1):
                req[e['n1']] = e['preq']
        if str(e.get('kind', '')).startswith('SUPPLY_'):
            type_[e['n2']] = 'WATER'
    for f in net.get('fixed') or []:
        type_.setdefault(f['n1'], 'FIXEDFLOW')
        if f.get('preq') is not None and f['preq'] > req.get(f['n1'], -1):
            req[f['n1']] = f['preq']
    for i in range(1, len(net['nodes'])):
        n = node(i)
        if n['id'] == 'REF':
            continue
        d = out.get(i, 0) + (n.get('demand') or 0)
        pg = gauge(i)
        t['nodes']['rows'].append(row([
            txt(n['id']), txt(type_.get(i) or ('DEVICE' if n['id'].endswith('~') else 'NODE')),
            num(n['z'] / u['ef'], 3), num(pg, u['pdp']), num(d / u['qf'], u['qdp']),
            (num(req[i] / u['pf'], u['pdp']) if i in req else none),
            (num(pg - req[i] / u['pf'], u['pdp']) if i in req else none),
        ], report.node_throughput(net, i) > 1e-6 or d > 0))

    #------------------------------------------------------------ OUTLETS
    # Required and achieved flow and pressure, the margin, PASS or FAIL: the
    # report's outlet compliance, sortable -- sort on MARGIN to see what
    # governs.  K is in the file's KFACTOR unit.  Fixed flows have K "FIXED".
    t['outlets'] = {'columns': [
        {'head': 'NAME', 'unit': '', 'align': 'w'}, {'head': 'NODE', 'unit': '', 'align': 'w'},
        {'head': 'TYPE', 'unit': '', 'align': 'w'}, {'head': 'K', 'unit': '', 'align': 'e'},
        {'head': 'REQ Q', 'unit': u['q'], 'align': 'e'}, {'head': 'ACT Q', 'unit': u['q'], 'align': 'e'},
        {'head': 'REQ P', 'unit': u['p'], 'align': 'e'}, {'head': 'ACT P', 'unit': u['p'], 'align': 'e'},
        {'head': 'MARGIN', 'unit': u['p'], 'align': 'e'}, {'head': 'RESULT', 'unit': '', 'align': 'w'}],
        'rows': []}
    # K held internally in L/min per kPa^0.5; one K unit of the file in those.
    kunit = (phc.k_factor_to_model(1, net['phc_units']) * u['qf'] / math.sqrt(u['pf'])
             if net.get('phc_units') else 1)
    for e in net['elems'][1:]:
        if e.get('kind') != 'DISCHARGE':
            continue
        # The pressure the outlet discharges on: Pn for an in-line sprinkler
        # under OPTION VELOCITY_PRESSURE ON, the gauge pressure otherwise.
        p = outlet_pressure(net, e) / u['pf']
        pass_ = abs(e['q']) >= e['qreq'] - 1e-6 and p >= e['preq'] / u['pf'] - 1e-6
        t['outlets']['rows'].append(row([
            txt(e['id']), txt(node(e['n1'])['id']),
            txt('HREEL' if e['otype'] == 'HOSEREEL' else e['otype']), num(e['k'] / kunit, 3),
            num(e['qreq'] / u['qf'], u['qdp']), num(abs(e['q']) / u['qf'], u['qdp']),
            num(e['preq'] / u['pf'], u['pdp']), num(p, u['pdp']),
            num(p - e['preq'] / u['pf'], u['pdp']), txt('PASS' if pass_ else 'FAIL'),
        ], 1))
    for f in net.get('fixed') or []:
        if f.get('preq') is None:
            continue
        p = (node(f['n1'])['h'] - GW * f['z']) / u['pf']
        t['outlets']['rows'].append(row([
            txt(f['id']), txt(node(f['n1'])['id']), txt('FIXEDFLOW'), ['FIXED', -1],
            num(f['qreq'] / u['qf'], u['qdp']), num(f['q'] / u['qf'], u['qdp']),
            num(f['preq'] / u['pf'], u['pdp']), num(p, u['pdp']),
            num(p - f['preq'] / u['pf'], u['pdp']),
            txt('PASS' if p >= f['preq'] / u['pf'] - 1e-6 else 'FAIL'),
        ], 1))
    for key in t:
        t[key].setdefault('rows', [])
    return t


#------------------------------------------------------------------------------
# sort_rows -- a table's rows sorted on column col, descending if desc.
#
# Numbers sort as numbers and text as text; ties keep their order, so sorting
# on one column and then another groups as expected.  "-" sorts first.
#------------------------------------------------------------------------------
def sort_rows(rows, col, desc):
    numeric = all(_NUMBER.match(str(r['keys'][col])) for r in rows)
    idx = list(range(len(rows)))
    if numeric:
        s = sorted(idx, key=lambda i: (float(rows[i]['keys'][col]), i))
    else:
        s = sorted(idx, key=lambda i: (str(rows[i]['keys'][col]), i))
    if desc:
        s.reverse()
    return [rows[i] for i in s]


#==============================================================================
# Units and files.
#==============================================================================

# units_of -- the file's units, defaults filled in: { LENGTH => 'MM', ... }.
def units_of(text):
    return dict(scan(text)['units'])


#------------------------------------------------------------------------------
# load_file -- { text, path } for a .phc file.  The editor works in .phc only;
# a .hcx is refused with the reason.
#------------------------------------------------------------------------------
def load_file(path):
    if not re.search(r'\.phc\Z', path or '', re.I):
        raise ModelError('THE EDITOR WORKS IN .PHC FILES; %s IS NOT ONE' % path)
    # The Perl reads the file as bytes, each byte one character, and writes
    # each character back as one byte: so does this (latin-1), and a file in
    # any encoding comes back from a save with the bytes it had.  The savers
    # write with file_encoding(text).
    try:
        with open(path, 'r', encoding='latin-1', newline='') as fh:
            text = fh.read()
    except OSError as e:
        raise ModelError('CANNOT OPEN %s: %s' % (path, (e.strerror or str(e)).upper()))
    text = text.replace('\r\n', '\n')
    # The results block a solve saved at the end of the file
    # (results.strip) is not part of the model: it is left out of the
    # editor, and written again, fresh, when a calculated model is saved.
    text = results.strip(text)
    return {'text': text, 'path': path}


# file_encoding -- the encoding a text is written to a file in, as Perl's
# print writes a string: one byte a character while every character fits in
# one (latin-1, which gives back the bytes load_file read), and UTF-8 for the
# whole text as soon as one character does not.
def file_encoding(text):
    try:
        (text or '').encode('latin-1')
    except UnicodeEncodeError:
        return 'utf-8'
    return 'latin-1'


# write_report_file -- the report of a solved network to a .pdf or .txt file.
def write_report_file(net, ok, model_path, out):
    if re.search(r'\.pdf\Z', out, re.I):
        report.write_pdf_report(net, ok, model_path, out)
    else:
        # Text mode, as the Perl's open '>': CRLF on Windows, LF elsewhere.
        try:
            fh = open(out, 'w', encoding='utf-8', errors='surrogateescape')
        except OSError as e:
            raise ModelError('CANNOT WRITE %s: %s' % (out, (e.strerror or str(e)).upper()))
        fh.close()
        text = report.write_report(net, ok, model_path)
        with open(out, 'w', encoding=file_encoding(text), errors='surrogateescape') as fh:
            fh.write(text)
    return 1


#==============================================================================
# The document: settings kept apart from the network.
#
# The window shows only the network in its editor.  The title, the project
# details, the units, the method and the options are set in the PROJECT tab.
# The .phc file still holds them all, as lines at its head, so a file is
# complete on its own and phcp reads it unchanged.
#
# A document is { settings => {...}, network => text }.  The functions below
# build the whole .phc text from it (join_file) and run the checks of this
# module on that, then number what they find by NETWORK line - the line the
# user sees in the editor - or, for a setting, by its PROJECT tab field.
#==============================================================================

# The PROJECT tab's fields, in the order shown: the report's cover sheet.
PROJECT_FIELDS = ['PROJECT', 'JOB', 'COMPANY', 'ADDRESS', 'LICENCE', 'LOCATION',
                  'DESIGNER', 'CHECKER', 'REVISION', 'DATE', 'STANDARD',
                  'HAZARD', 'DENSITY', 'AREA_PER_SPRINKLER', 'AREA_OF_OPERATION',
                  'BASE_OF_RISER', 'AUTHORITY', 'AUTHORITY_PHONE', 'DATA_SOURCE']
PROJECT_LABEL = {'DENSITY': 'DENSITY (MM/MIN)',
                 'AREA_PER_SPRINKLER': 'AREA PER SPRINKLER (M2)',
                 'AREA_OF_OPERATION': 'AREA OF OPERATION (M2)',
                 'BASE_OF_RISER': 'BASE OF RISER (NODE)',
                 'AUTHORITY_PHONE': 'AUTHORITY PHONE',
                 'DATA_SOURCE': 'PIPE DATA SOURCE'}


def project_label(f):
    return PROJECT_LABEL.get(f, f.replace('_', ' '))


#------------------------------------------------------------------------------
# The PROJECT tab's UNITS and CALCULATION fields in plain words.  Each option
# keeps its .phc name (written in the file, and shown small beside the label
# for anyone reading a file by hand), and gets a label and one line saying what
# it does and what it is when left blank.  The defaults quoted are the
# reader's own (parse.new_net).  Options a user rarely needs come
# last, under SOLVER - ADVANCED.
#------------------------------------------------------------------------------
UNIT_LABEL = {'LENGTH': 'PIPE LENGTH', 'ELEVATION': 'ELEVATION',
              'SIZE': 'PIPE SIZE AND BORE', 'PRESSURE': 'PRESSURE',
              'FLOW': 'FLOW', 'KFACTOR': 'K-FACTOR'}
OPTION_FORM = [
    ['VEL_LIMIT', 'VELOCITY LIMIT',
     'A DESIGN LIMIT, IN M/S: A PIPE FASTER THAN THIS FAILS THE DESIGN (NONCOMPLIANT). '
     'BLANK: 6 M/S, AS A WARNING ONLY.'],
    ['FITTING_BASIS', 'FITTING LENGTHS',
     'CORRECTED: ADJUSTED FOR THE C-FACTOR AND THE INSTALLED BORE. STANDARD: AS PUBLISHED '
     'IN AS 2118.1. BLANK: CORRECTED.', ['', 'CORRECTED', 'STANDARD']],
    ['VELOCITY_PRESSURE', 'VELOCITY PRESSURE',
     "ON: IN-LINE SPRINKLERS DISCHARGE ON THE NORMAL PRESSURE PN = PT - PV, PV FROM THE PIPE "
     "FEEDING THE HEAD; END SPRINKLERS, HYDRANTS AND HOSE REELS STAY ON TOTAL PRESSURE "
     "(AS 2118.1 CL 14.15, AT THE DESIGNER'S DISCRETION). OFF: EVERY OUTLET ON TOTAL "
     'PRESSURE. BLANK: OFF.', ['', 'OFF', 'ON']],
    ['ORIF_STEP', 'ORIFICE PLATE BORE STEP',
     'A BORE SIZED FOR AN OPP PLATE IS ROUNDED TO THIS STEP, IN THE PIPE SIZE UNIT. '
     'MORE THAN 0. BLANK: 0.5 MM.'],
    ['ORIF_DP_TOL', 'ORIFICE DUTY TOLERANCE',
     "HOW FAR, IN PER CENT OF ITS TARGET, AN OPP PLATE'S FINAL DROP MAY BE FROM ITS DUTY; "
     'FURTHER FAILS THE DESIGN (NONCOMPLIANT). BLANK: 10 %.'],
    ['HOSE_ALLOWANCE', 'HOSE STREAM ALLOWANCE',
     'A FLOW, IN THE FLOW UNIT, ADDED AT THE SUPPLY FOR HOSE STREAMS: THE DEMAND IS '
     "CHECKED AT THE SYSTEM'S FLOW PLUS THIS. BLANK: NONE."],
    ['SIZING_GOAL', 'AUTO SIZING GOAL',
     'FOR PIPES GIVEN SIZE 0: SMALLEST - THE SMALLEST PIPES THAT WILL DO; VOLUME - THE '
     'LEAST WATER HELD IN THEM (A DRY SYSTEM). BLANK: SMALLEST.',
     ['', 'SMALLEST', 'VOLUME']],
    ['SIZING_MARGIN', 'AUTO SIZING MARGIN',
     'HOW FAR UNDER THE SUPPLY THE SIZED SYSTEM MUST BE: A PERCENTAGE OF THE SUPPLY '
     'PRESSURE (10%) OR A PRESSURE, IN THE PRESSURE UNIT (50). BLANK: NO MARGIN.'],
    ['SIZING_TRIALS', 'AUTO SIZING TRIALS',
     'HOW MANY TRIALS THE SIZING SEARCH MAKES, EACH FROM A DIFFERENT START; THE BEST WINS. '
     'MORE TRIALS CAN FIND SMALLER PIPES BUT TAKE LONGER. 1 TO 50. BLANK: 5.'],
    ['DESIGN_AREA', 'DESIGN AREA',
     'THE ONE DESIGN AREA (AREA) TO SOLVE AND REPORT. BLANK: EVERY AREA IS SOLVED AND THE '
     'ONE THAT GOVERNS IS REPORTED. NOT USED WITHOUT AREA LINES.'],
    ['SUPPLY_MARGIN', 'SUPPLY MARGIN',
     'THE LEAST PRESSURE, IN THE PRESSURE UNIT, THE SUPPLY MUST HAVE OVER THE DEMAND; LESS '
     'FAILS THE DESIGN. WITH SEVERAL SUPPLIES, THE MARGIN AT THEIR JOINT DEMAND. BLANK: 0.'],
    ['SUPPLY_SCENARIOS', 'SUPPLY SCENARIOS',
     'WITH MORE THAN ONE SUPPLY: ON - EACH SUPPLY ALONE AND EACH OUT OF SERVICE ARE SOLVED '
     'AND REPORTED, FOR INFORMATION. OFF: NOT. SCENARIO LINES ARE ALWAYS SOLVED. BLANK: ON.',
     ['', 'ON', 'OFF']],
    ['JOINT_BASIS', 'JOINT DEMAND BASIS',
     'WITH MORE THAN ONE SUPPLY, HOW THEY ARE REDUCED TOGETHER TO FIND THE JOINT DEMAND: '
     'DERATE - EVERY SUPPLY LOWERED BY ONE PRESSURE; SCALE - BY ONE FACTOR. BLANK: DERATE.',
     ['', 'DERATE', 'SCALE']],
    'SOLVER - ADVANCED',
    ['TOL_FLOW', 'FLOW TOLERANCE',
     "THE SOLVE ENDS WHEN EVERY LOOP'S FLOW CORRECTION IS SMALLER THAN THIS, IN THE FLOW "
     'UNIT. MORE THAN 0. BLANK: 0.05 L/MIN.'],
    ['TOL_LOOP', 'PRESSURE TOLERANCE',
     'AND EVERY LOOP BALANCES TO WITHIN THIS, IN THE PRESSURE UNIT. MORE THAN 0. IT ONLY '
     'SAYS WHEN THE SOLVE STOPS: THE ANSWER IS CHECKED TO 0.1 KPA WHATEVER IT IS. '
     'BLANK: 0.01 KPA.'],
    ['MAXITER', 'MAXIMUM ITERATIONS',
     'THE SOLVE STOPS AFTER THIS MANY ROUNDS AND REPORTS THAT IT DID NOT CONVERGE. '
     'BLANK: 50000.'],
    ['HW_CONST', 'HAZEN-WILLIAMS CONSTANT',
     'THE CONSTANT OF THE HAZEN-WILLIAMS FORMULA, FOR KPA PER METRE, L/MIN AND MM. '
     'WITHIN 2 % OF 6.05E7, ITS PUBLISHED FORMS; A CONSTANT FOR OTHER UNITS IS '
     'REFUSED. BLANK: 6.05E7, AS IN AS 2118.1.'],
    ['NU', 'KINEMATIC VISCOSITY',
     'OF THE WATER, IN M2/S, FOR DARCY-WEISBACH ONLY. 0.28E-6 TO 1.8E-6 (WATER AT '
     '100 C TO 0 C). BLANK: 1.004E-6, WATER AT 20 C.'],
    ['RELAX', 'RELAXATION',
     'NOT USED BY THE SOLVER. ACCEPTED SO THAT OLDER FILES STILL READ.'],
]

# new_settings -- an empty document's settings: the office defaults.
def new_settings():
    return {'title': '', 'project': {}, 'extra': [],
            'units': dict(phc.UNIT_DEFAULT), 'method': 'HW', 'options': {}}


#------------------------------------------------------------------------------
# split_file -- a .phc text as { settings, network }.
#
# Every TITLE, PROJECT, UNITS, METHOD and OPTION line that reads cleanly goes
# into the settings and out of the network.  A setting line in error, or one
# repeating a setting already taken, stays in the network, where the checks
# mark it, so nothing in the file is lost without the user seeing it.  Blank
# lines left at the head and foot of the network are trimmed.
#------------------------------------------------------------------------------
def split_file(text):
    text = text if text is not None else ''
    s = new_settings()
    net = []
    seen = {}

    def seen_before(key):
        if key is None:
            return False
        if seen.get(key):
            return True
        seen[key] = 1
        return False

    for line in text.split('\n'):
        a = phc.analyse(line)
        c = phc.command_spec(a['key']) if a['status'] == 'ok' and a.get('key') else None
        if c and c['kind'] == 'setting' and not seen_before(phc.setting_keys(a)):
            k, p = a['key'], list(a['pos'])
            if k == 'TITLE':
                s['title'] = a['text'].upper()
            elif k == 'PROJECT':
                s['project'][p[0]] = a['text'].upper()
                if p[0] not in PROJECT_FIELDS and p[0] not in s['extra']:
                    s['extra'].append(p[0])
            elif k == 'UNITS':
                s['units'][p[0]] = p[1]
            elif k == 'METHOD':
                s['method'] = p[0]
            elif k == 'OPTION':
                s['options'][p[0]] = str(p[1]).upper() if len(p) > 1 else ''
            continue
        net.append(line)
    while net and _BLANK.match(net[0]):
        net.pop(0)
    while net and _BLANK.match(net[-1]):
        net.pop()
    return {'settings': s, 'network': '\n'.join(net) + ('\n' if net else '')}


#------------------------------------------------------------------------------
# header_lines -- the settings as .phc lines, each with the PROJECT tab field
# it came from: ( [ line, field ] ... ).  Every unit is written, defaults
# included, so a file says its units plainly.  Values are in capitals.
#------------------------------------------------------------------------------
def header_lines(s):
    out = []

    def row(a, b, f):
        out.append(['%-9s %s' % (a, b), f])

    if len(s.get('title') or ''):
        row('TITLE', s['title'].upper(), 'TITLE')
    for f in PROJECT_FIELDS + list(s.get('extra') or []):
        v = s['project'].get(f) or ''
        if len(v):
            row('PROJECT', '%s %s' % (f, v.upper()), f)
    for q in phc.UNIT_QUANTITIES:
        u = s['units'].get(q)
        row('UNITS', '%s %s' % (q, u if u is not None else ''), q)
    row('METHOD', s['method'] if s.get('method') is not None else 'HW', 'METHOD')
    for o in phc.OPTIONS:
        v = s['options'].get(o) or ''
        if len(v):
            row('OPTION', '%s %s' % (o, v.upper()), o)
    return out


#------------------------------------------------------------------------------
# join_file -- the document as one .phc text.  Returns (text, H): H is the
# number of lines before the network (the settings and one blank line), so
# network line n is line n + H of the text.
#------------------------------------------------------------------------------
def join_file(s, network):
    h = [x[0] for x in header_lines(s)]
    text = '\n'.join(h + ['', '']) + (network or '')
    return (text, len(h) + 1)


# doc_text -- join_file for a document.
def doc_text(d):
    return join_file(d['settings'], d['network'])


# shift_lines -- "ON LINE n" in a message, renumbered from file to network line.
def shift_lines(msg, h):
    return _ON_LINE.sub(lambda m: 'ON LINE %d' % (int(m.group(1)) - h), msg or '')


#------------------------------------------------------------------------------
# doc_check -- check_buffer for a document, by network line.
#
# Returns check_buffer's result for the network lines, plus settings_problems
# [ { field, message } ] for any setting the reader refuses.  A setting command
# typed into the network is an error there: settings belong in the PROJECT tab.
#------------------------------------------------------------------------------
def doc_check(d, editing=None):
    full, h = doc_text(d)
    r = check_buffer(full, editing + h if editing is not None else None)
    hdr = header_lines(d['settings'])
    nl = lines(d['network'])[1:]
    # The network's closing newline does not make a line of its own.
    if nl and nl[-1] == '' and (d['network'] or '').endswith('\n'):
        nl.pop()
    o = {'lines': [None], 'problems': [], 'settings_problems': []}
    for i in range(1, len(nl) + 1):
        l = r['lines'][i + h] if i + h < len(r['lines']) else None
        l = dict(l) if l else {'status': 'ok', 'message': ''}
        a = phc.analyse(nl[i - 1])
        c = phc.command_spec(a['key']) if a.get('key') else None
        if c and c['kind'] == 'setting':
            l = {'status': 'error',
                 'message': '%s IS SET IN THE PROJECT TAB, NOT IN THE NETWORK' % c['name']}
        l['message'] = shift_lines(l['message'], h)
        o['lines'].append(l)
        if l['status'] == 'ok':
            continue
        if l['status'] == 'incomplete' and editing is not None and editing == i:
            continue
        o['problems'].append({'line': i, 'message': l['message']})
    for p in r['problems']:
        if p['line'] <= h and p['line'] <= len(hdr):
            o['settings_problems'].append({'field': hdr[p['line'] - 1][1],
                                            'message': p['message']})
    for k in ('undefined', 'unused'):
        o[k] = [{'node': x['node'], 'line': x['line'] - h}
                for x in r[k] if x['line'] > h]
    return o


#------------------------------------------------------------------------------
# doc_diagnostics -- the ERRORS, WARNINGS and NODES lists, by network line.
# A setting the reader refuses is listed in ERRORS with no line, naming its
# PROJECT tab field.
#------------------------------------------------------------------------------
def doc_diagnostics(d, net=None, editing=None):
    full, h = doc_text(d)
    chk = doc_check(d, editing)
    dg = diagnostics(full, net, editing + h if editing is not None else None)

    def mv(l):
        return l - h if l is not None and l > h else None

    return {
        'errors': [{'line': None, 'field': p['field'],
                    'message': 'PROJECT TAB, %s: %s' % (p['field'], p['message'])}
                   for p in chk['settings_problems']] + list(chk['problems']),
        'warnings': [{'line': mv(x['line']), 'message': x['message']}
                     for x in dg['warnings']],
        'nodes': [{'line': mv(x['line']), 'message': x['message']}
                  for x in dg['nodes']],
    }


# doc_choices / doc_status -- choices and status_at for network line n, with
# the settings in force (the fittings offered depend on the SIZE unit).
def doc_choices(d, n, col):
    t, h = doc_text(d)
    return choices(t, n + h, col)


def doc_status(d, n, col):
    t, h = doc_text(d)
    return status_at(t, n + h, col)


# doc_solve -- solve_text for a document; an error's line is a network line,
# or None with the error in a setting.
def doc_solve(d, path, **o):
    t, h = doc_text(d)
    r = solve_text(t, path, **o)
    # Each sized pipe's size, written into the network as a comment after
    # its line (//AS - 25), for the window to put in the editor.
    if r.get('ok') and r['net'].get('sizing'):
        r['network'] = sizing.annotate(d['network'], r['net']['sizing'], h)
    if not r.get('ok'):
        if r.get('line') is not None:
            n = r['line'] - h
            if n > 0:
                r['error'] = re.sub(r'^LINE \d+: ', 'LINE %d: ' % n, r['error'])
            else:
                r['error'] = re.sub(r'^LINE \d+: ', 'PROJECT TAB: ', r['error'])
            r['error'] = shift_lines(r['error'], h)
            r['line'] = n if n > 0 else None
    return r


#==============================================================================
# Validation: every problem, with what is wrong, why, and where.
#==============================================================================

#------------------------------------------------------------------------------
# validate -- check a document fully before a calculation.
#
# Returns { ok, items => [ { what, why, line, start, end, field, tab } ] }.
#   line, start, end  the network line and the columns of the word at fault
#                     (end exclusive); the whole line when no one word is
#   field             the field's name: SIZE, START, ... or the PROJECT tab
#                     field for a setting
#   tab               'PROJECT' for a setting, otherwise None
#
# In order: the settings; every network line (an incomplete line is an error
# here, wherever the cursor is); nodes used but not defined; nodes nothing
# connects to; then, when every line is good, the network read whole and its
# structure checked as the solver will - one supply or outlet anchoring it,
# every node connected.  ok is true only when nothing is found, and only then
# may the window calculate.
#------------------------------------------------------------------------------
def validate(d):
    full, h = doc_text(d)
    chk = doc_check(d)
    nl = lines(d['network'])[1:]
    u = d['settings']['units']
    it = []
    for p in chk['settings_problems']:
        it.append({'what': p['message'], 'tab': 'PROJECT', 'field': p['field'],
                   'why': why(p['message'], None, u)})
    for p in chk['problems']:
        line = nl[p['line'] - 1]
        a, b, field, key = fault_span(line, p['message'])
        it.append({'what': p['message'], 'line': p['line'], 'start': a, 'end': b,
                    'field': field, 'why': why(p['message'], key, u)})
    for n in chk['undefined']:
        a, b = word_span(nl[n['line'] - 1], n['node'])
        it.append({'what': 'NODE %s IS USED, BUT NOT DEFINED' % n['node'],
                   'line': n['line'], 'start': a, 'end': b, 'field': 'NODE',
                   'why': why('NOT DEFINED', None, u)})
    for n in chk['unused']:
        a, b = word_span(nl[n['line'] - 1], n['node'])
        it.append({'what': 'NOTHING CONNECTS TO NODE %s' % n['node'],
                   'line': n['line'], 'start': a, 'end': b, 'field': 'NAME',
                   'why': why('NOTHING CONNECTS', None, u)})
    if not it:
        try:
            build_tree(phc.read_string(full))
        except ModelError as e:
            msg = str(e.msg).upper()
            line = None
            m = re.match(r'^LINE (\d+): ', msg)
            if m:
                line = int(m.group(1)) - h
                msg = msg[m.end():]
            elif re.match(r'^NODE (\S+) IS NOT CONNECTED', msg):
                line = (scan(full)['nodes'].get(re.match(r'^NODE (\S+) IS NOT CONNECTED', msg).group(1)) or 0) - h
            msg = shift_lines(msg, h)
            if line is not None and line <= 0:
                line = None
            m = re.match(r'^NODE (\S+)', msg)
            node = m.group(1) if m else None
            a, b = word_span(nl[line - 1], node) if line is not None else (None, None)
            it.append({'what': msg, 'line': line, 'start': a, 'end': b,
                        'field': 'NAME' if node is not None else None,
                        'why': why(msg, None, u)})
    it.sort(key=lambda x: (0 if x.get('tab') else 1, x.get('line') or 0))
    return {'ok': not it, 'items': it}


# words -- the words of a line's code part: ( [start, end, text] ... ).
def words(line):
    line = line or ''
    cpos = line.find('//')
    code = line[:cpos] if cpos >= 0 else line
    return [[m.start(), m.end(), m.group(1)] for m in _WORD.finditer(code)]


# word_span -- the columns of a word on a line (the whole line if not found).
def word_span(line, word):
    w = words(line)
    if word is not None:
        for m in w[1:]:
            if m[2].upper() == word.upper():
                return (m[0], m[1])
    return (w[0][0] if w else 0, w[-1][1] if w else len(line or ''))


#------------------------------------------------------------------------------
# fault_span -- where on a line its problem is: (start, end, field, command).
#
# An unknown command is its first word.  A line that stops short points just
# past its end, at the field it needs.  A value quoted in the message ('X')
# is that word.  Otherwise the reader accepted as many fields as it put in
# pos and opt, so the next one is at fault.  Failing all of those, the whole
# line.
#------------------------------------------------------------------------------
def fault_span(line, msg):
    w = words(line)
    a = phc.analyse(line)
    c = phc.command_spec(a['key']) if a.get('key') else None
    fields = phc.template_fields(c) if c else []

    def fname(i):
        if i >= 1 and fields:
            return fields[i - 1 if i - 1 < len(fields) else len(fields) - 1]
        return None

    if w and not c:
        return (w[0][0], w[0][1], 'COMMAND', None)
    key = c['name'] if c else None
    if c and c['kind'] == 'setting':
        return (w[0][0], w[0][1], 'COMMAND', key)
    if a['status'] == 'incomplete':
        e = w[-1][1] if w else 0
        return (e, e + 1, a['msg'], key)
    m = re.match(r'^(?:NODE|THE NAME) (\S+) IS ALREADY', msg or '')
    if m:
        x, y = word_span(line, m.group(1))
        return (x, y, 'NAME', key)
    m = re.search(r"'([^']+)'", msg or '')
    if m:
        q = m.group(1)
        for i in range(1, len(w)):
            if w[i][2].upper() == q.upper():
                return (w[i][0], w[i][1], fname(i), key)
    if a['status'] == 'error':
        i = 1 + len(a['pos']) + len(a['opt'])
        if i < len(w):
            return (w[i][0], w[i][1], fname(i), key)
    if key == 'PIPE' and re.search(r'DATA_REQUIRED|NOT IN THE DATABASE', msg or '') \
            and len(w) - 1 >= 5:
        return (w[5][0], w[5][1], 'SIZE', key)
    return (w[0][0] if w else 0, w[-1][1] if w else len(line or ''), None, key)


#------------------------------------------------------------------------------
# why -- the reason behind a problem, in plain words: what the program needs
# and why, so the user can put it right without the manual.  Matched on the
# message; a message not listed gets the command's field template, which says
# what the line should hold.
#------------------------------------------------------------------------------
NETWORK_COMMANDS = [c for g in phc.COMMAND_GROUPS[1:] for c in g]


def why(msg, key, u=None):
    u = u or phc.UNIT_DEFAULT

    def tpl(k):
        return ('%s IS WRITTEN: %s.' % (k, phc.template_text(k))) if k else ''

    cases = [
        (r'^UNKNOWN COMMAND',
         'EVERY LINE STARTS WITH A COMMAND. THE NETWORK COMMANDS ARE: '
         + ' '.join(NETWORK_COMMANDS) + '.'),
        (r'IS SET IN THE PROJECT TAB',
         'THE TITLE, PROJECT DETAILS, UNITS, METHOD AND OPTIONS ARE KEPT IN THE PROJECT TAB '
         'SO THE EDITOR HOLDS ONLY THE NETWORK. SET IT THERE AND DELETE THIS LINE.'),
        (r'^(\S+) NEEDS (.+)', None),      # handled below (uses the match)
        (r'^NODE \S+ IS ALREADY DEFINED',
         'A NODE IS DEFINED ONCE: A SECOND DEFINITION WOULD GIVE IT TWO ELEVATIONS. '
         'RENAME ONE OR DELETE THE REPEAT.'),
        (r'^THE NAME \S+ IS ALREADY USED',
         'PIPES, NODES AND ELEMENTS SHARE ONE SET OF NAMES, SO EVERY RESULT AND MESSAGE '
         'POINTS TO ONE THING. GIVE THIS ONE A NAME OF ITS OWN.'),
        (r'IS ALREADY SET ON LINE',
         'A SETTING IS GIVEN ONCE; A SECOND WOULD SILENTLY REPLACE THE FIRST.'),
        (r'IS NOT A LENGTH',
         'A LENGTH IS A NUMBER IN THE LENGTH UNIT (%s), OR CARRIES ITS OWN UNIT: '
         "3.2M, 3200MM, 10'6\"." % u['LENGTH']),
        (r'RATIO .* IS NOT A RATIO|RATIO MUST BE',
         'A PRESSURE RATIO VALVE DIVIDES ITS INLET PRESSURE BY THE RATIO, SO IT IS WRITTEN '
         '3:1 OR 3, AND IS MORE THAN 1.'),
        (r'IS NOT A NUMBER',
         'THIS FIELD TAKES A NUMBER, IN THE UNIT SET IN THE PROJECT TAB.'),
        (r'CANNOT BE NEGATIVE',
         "A NEGATIVE VALUE HAS NO MEANING HERE. (AN OUTLET'S MINIMUM FLOW IS THE ONE FIELD "
         'THAT TAKES A NEGATIVE NUMBER: -50 MEANS A MINIMUM PRESSURE OF 50.)'),
        (r'FIELDS GO BY POSITION',
         'EACH FIELD IS KNOWN BY ITS PLACE ON THE LINE, AS THE STATUS BAR SHOWS: WRITE THE '
         'VALUE ALONE, WITHOUT KEY=.'),
        (r'IS NOT A FITTING|CANNOT READ FITTING',
         'AFTER ITS SIZE A PIPE TAKES FITTING CODES, EACH WITH AN OPTIONAL COUNT (2E IS '
         'TWO ELBOWS). CTRL+SPACE LISTS THE CODES FOR THE PIPE TYPE AND SIZE.'),
        (r'FITTINGS NEED A PIPE TYPE',
         'FITTING LOSSES COME FROM THE DATABASE FOR A PIPE TYPE; A PLAIN BORE HAS NONE TO '
         'LOOK UP. PUT A USE LINE ABOVE, OR GIVE THE ALLOWANCE AS A LENGTH WITH EQV.'),
        (r'DATA_REQUIRED|NOT IN THE DATABASE',
         'THE PIPE TYPE IN FORCE (THE USE LINE ABOVE) HAS NO PIPE OF THIS SIZE IN THE '
         'DATABASE, AND A BORE IS NEVER GUESSED. CHECK THE SIZE, OR THE USE LINE.'),
        (r'UNEXPECTED FIELD',
         'THE LINE HAS MORE FIELDS THAN ITS COMMAND TAKES. ' + tpl(key)),
        (r'CANNOT BE USED IN A .PHC LINE',
         'THE CHARACTER IS RESERVED. A COMMENT STARTS WITH //.'),
        (r'NOT DEFINED',
         'A PIPE OR ELEMENT JOINS NODES THAT ARE DEFINED BY NODE, NC, WATER, SPRINKLER, '
         'HYDRANT OR HREEL. DEFINE THE NODE, OR CORRECT THE NAME.'),
        (r'NOTHING CONNECTS|NOT CONNECTED',
         'EVERY NODE MUST BE JOINED TO THE REST OF THE NETWORK, OR ITS FLOWS CANNOT BE '
         'BALANCED. CONNECT IT WITH A PIPE, OR DELETE IT.'),
        (r'NO SUPPLY AND NO DISCHARGE',
         'PRESSURES ARE WORKED OUT FROM A KNOWN PRESSURE. ADD A WATER SUPPLY, OR AN OUTLET.'),
        (r'UNKNOWN OPTION|VALUE .* IS NOT A NUMBER|FITTING_BASIS|VELOCITY_PRESSURE',
         'CHECK THE OPTION IN THE PROJECT TAB: LEAVE A FIELD BLANK FOR THE DEFAULT.'),
    ]
    for i, (pat, text) in enumerate(cases):
        if not re.search(pat, msg or ''):
            continue
        if pat == r'^(\S+) NEEDS (.+)':
            m2 = re.match(r'^(\S+) NEEDS (.+)', msg)
            return 'THE LINE ENDS BEFORE ITS %s. %s' % (m2.group(2), tpl(m2.group(1)))
        return text
    return tpl(key) or 'THE SOLVER CANNOT READ THIS AS WRITTEN.'
