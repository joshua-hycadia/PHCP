#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# pumpcheck.py -- Python port of HardyCross/PumpCheck.pm.
#
# Each pump's curve checked against its rated duty: AT DUTY (the curve at the
# duty flow gives at least the duty pressure), SHUT-OFF (no more than 140 % of
# the duty pressure, AS 2941-2013 fire pump checklist) and 150 % FLOW (at
# least 65 % of the duty pressure, NFPA 20 6.2 -- for information only).
#

from . import curve_eval

SHUTOFF_MAX = 1.40     # shut-off / duty pressure, at most
OVERLOAD_Q  = 1.50     # the overload flow, as a multiple of duty flow
OVERLOAD_P  = 0.65     # its pressure / duty pressure, at least

def check(net):
    duty = net['opts'].get('pump_duty') or {}
    out = []
    for e in net['elems'][1:]:
        if e['kind'] != 'PUMP':
            continue
        c = e['curve']
        p = {'id': e['id'], 'kind': 'BP' if e['id'].endswith('.BP') else 'PUMP',
             'shutoff': curve_eval(c, 0)}
        d = duty.get(e['id'])
        if d:
            q, pd = d
            p['duty'] = [q, pd]
            at = curve_eval(c, q)
            p['at_duty'] = {'p': at, 'ok': at >= pd - 1e-9}
            p['shutoff_ok'] = p['shutoff'] <= SHUTOFF_MAX * pd + 1e-9
            qo = OVERLOAD_Q * q
            po = curve_eval(c, qo)
            p['over'] = {'q': qo, 'p': po, 'ok': po >= OVERLOAD_P * pd - 1e-9,
                         'extrapolated': qo > c['qhi'] + 1e-9}
            p['ok'] = p['at_duty']['ok'] and p['shutoff_ok']
        out.append(p)
    return out

def warnings(net):
    uf, up = net['f_flow'], net['f_pres']
    w = []
    for p in [x for x in check(net) if x.get('duty') and not x.get('ok')]:
        q, pd = p['duty']
        if not p['at_duty']['ok']:
            w.append('pump %s does not deliver its duty: %.1f at %.1f, its curve gives %.1f'
                     % (p['id'], q / uf, pd / up, p['at_duty']['p'] / up))
        if not p['shutoff_ok']:
            w.append('pump %s shut-off %.1f is above 140%% of its duty pressure %.1f (%.1f) - AS 2941 '
                     '(Pump Industry Australia checklist)'
                     % (p['id'], p['shutoff'] / up, pd / up, SHUTOFF_MAX * pd / up))
    return w
