#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# areas.py -- Python port of HardyCross/Areas.pm.
#
# The design areas (AREA lines) of a model, each solved on its own, and
# which of them governs.  See Areas.pm for the rationale; the port follows
# it line for line.
#

from . import solve_model
from .phc import read_string
from . import demand


def governing(net, ok, **arg):
    if not (net.get('areas') and net.get('design_area') is None):
        return net, ok
    text = net['source_text']
    if not text.endswith('\n'):
        text += '\n'
    res = []
    k = 0
    for a in net['areas']:
        # progress -- a line saying where it is, for a window to show.
        if arg.get('progress'):
            arg['progress']('DESIGN AREA %s - %d OF %d'
                             % (a['name'], k + 1, len(net['areas'])))
        k += 1
        n = read_string(text + 'OPTION DESIGN_AREA %s\n' % a['name'], net.get('model_dir'))
        c = solve_model(n)
        n['converged'] = c
        go, m = demand.governing_outlet(n)
        d = demand.demand_point(n) if c else None
        res.append({'name': a['name'], 'line': a['line'], 'outlets': len(a['outlets']),
                    'ok': c, 'governing': go['id'] if go else None, 'margin': m,
                    'demand': ({'q': d['q_demand'], 'p': d['p_demand'],
                                'avail': d['p_avail'], 'margin': d['margin']}
                               if d and d.get('margin') is not None else None),
                    'net': n})
    # Which governs: see Areas.pm.
    g = next((r for r in res if not r['ok']), None)
    if not g:
        all_demand = all(r.get('demand') for r in res)
        key = (lambda r: r['demand']['margin']) if all_demand else (lambda r: r['margin'])
        for r in [x for x in res if key(x) is not None]:
            if g is None or key(r) < key(g):
                g = r
        if g is None:
            g = res[0]
        g['basis'] = 'SUPPLY' if all_demand else 'OUTLET'
    g['governs'] = 1
    out = g['net']
    # The summaries keep no network: each holds the whole model.
    out['area_results'] = [{k: v for k, v in r.items() if k != 'net'} for r in res]
    out['area_basis'] = g.get('basis') or 'NOT CONVERGED'
    return out, g['ok']
