"""isometric -- an isometric drawing of a network: a port of
HardyCross/Isometric.pm.

WHAT THIS IS
    The other way to enter a calculation, used by phcp_isometric.py.
    The text editor types the model as commands.  This draws the same
    model: nodes on a 30-degree grid, pipes along the grid axes, the
    elevation on the vertical axis.  A pipe is two clicks, and the
    length is the grid distance, or a length (and a size, fittings and
    C) typed first, and the click only chooses the direction.  Drawing
    writes .phc.  Nothing here solves, sizes or checks; the reader and
    the solver do, on the text this writes.

    The drawing is a view, not a second model.  A length and an
    elevation stay as they were typed until a point is moved; the move
    then sets them from the grid, in the model's units.  Positions live
    in comments the reader skips, so a file saved from the drawing
    calculates exactly as the same commands calculate without them:

        //ISO GRID 1
        //ISO N1 0 0 0
        //ISO N2 6 0 4.5

    GRID is the metres of one grid step, on every axis.  The three
    numbers are the point's steps along the two plan axes and the
    vertical.  A point with no //ISO line is placed from the pipes and
    the elevations.

    Copies are written out in full (a PC or NC line becomes the pipes
    or nodes it means) because a drawing has no source to copy.  A
    CHANGEPIPE is applied to the one pipe it names, and a copy keeps
    the source's original, which is what the reader does.  Lines the
    drawing does not edit -- AREA, PUMPDUTY, SUPPLYGRAPH, and any
    comment that is not //ISO -- are kept and written back after the
    network.

THIS MODULE HAS NO TK.  The window is hardycross/window/isometric.py.
tools/test_isometric.py drives what is here.
"""

import math
import re

from hardycross import phc
from hardycross import pipedata
from hardycross.parse import is_num

# The same metres factors as hardycross.phc.  Duplicated because that
# table is private; tools/test_isometric.py checks a value converted
# and read back.
TO_METRE = {'MM': 0.001, 'CM': 0.01, 'M': 1, 'IN': 0.0254, 'FT': 0.3048}

# 30 degrees: the two plan axes of an isometric, equally foreshortened,
# with the vertical upright.  One grid step is SCALE pixels along each
# axis.
COS30 = 0.8660254037844386
SIN30 = 0.5

NODE_KIND = ('NODE', 'WATER', 'SPRINKLER', 'HYDRANT', 'HREEL')


def _s(value):
    """A field value as text: Perl's regexes and sprintf stringified a
    number, so a caller may hand one where the window hands a string."""
    if value is None:
        return ''
    if not isinstance(value, str):
        value = str(value)
    return value
DEVICE = ('BP', 'BFP', 'PRV', 'OPP', 'OFD', 'PRA')

_ISO_GRID = re.compile(r'^\s*//ISO\s+GRID\s+(\S+)\s*$', re.I)
_ISO_POINT = re.compile(
    r'^\s*//ISO\s+(\S+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+(?:\.\d+)?)\s*$', re.I)
_ISO_OTHER = re.compile(r'^\s*//ISO\b', re.I)


#------------------------------------------------------------------------------
# read_network -- a drawing from the editor's network text.
#
# units is the PROJECT tab's units (LENGTH, ELEVATION, ...).  Anything
# not given takes the office default.  The text is the network only:
# settings have already been taken out by the editor.  A line this
# does not understand is kept, not dropped.
#------------------------------------------------------------------------------
def read_network(text, units=None):
    u = dict(phc.UNIT_DEFAULT)
    u.update(units or {})
    d = {'units': u, 'grid': 1, 'nodes': {}, 'node_order': [],
         'pipes': [], 'pumps': [], 'flows': [], 'extras': [],
         'warnings': [], 'occ': {}, 'pin': {}}
    use = {'type': 'BORE', 'c': None}    # pipes before any USE
    pipe = {}
    pc, nc, change, eqv, device = [], [], [], [], []

    n = 0
    for line in (text or '').split('\n'):
        n += 1
        if line.endswith('\r'):
            line = line[:-1]
        if not line.strip():
            continue
        if line.lstrip().startswith('//'):
            iso_line(d, line)
            continue
        m = re.search(r'//(.*)$', line)
        note = m.group(1) if m else None
        if note is not None:
            note = note.lstrip()
        a = phc.analyse(line)
        if a['status'] != 'ok':
            d['extras'].append(line)
            continue
        spec = phc.command_spec(a['key'])
        if spec and spec.get('kind') == 'setting':
            d['extras'].append(line)
            continue
        k = a['key']
        p = a['pos']

        if k == 'USE':
            use = {'type': p[0], 'c': a['opt'][0] if a['opt'] else None}
        elif k == 'PIPE':
            p_ = pipe_rec(p[0], p[1], p[2], p[3], p[4], a['rest'], use, note)
            pipe[p[0]] = p_
            d['pipes'].append(p_)
        elif k == 'PC':
            pc.append((line, p[0], list(a['rest']), note))
        elif k == 'CHANGEPIPE':
            change.append((line, p[0], p[1], p[2], list(a['rest'])))
        elif k == 'EQV':
            eqv.append((line, p[0], p[1], note))
        elif k in NODE_KIND:
            add_read_node(d, k, p, a, note)
        elif k == 'NC':
            nc.append((line, p[0], list(a['rest'])))
        elif k == 'FIXEDFLOW':
            d['flows'].append({'name': p[0], 'node': p[1], 'flow': p[2],
                               'minp': a['opt'][0] if a['opt'] else None,
                               'note': note})
        elif k == 'PUMP':
            d['pumps'].append({'name': p[0], 'in': p[1], 'out': p[2],
                               'churn': p[3], 'pairs': list(a['rest']),
                               'note': note})
        elif k in DEVICE:
            if k in ('BFP', 'PRV'):
                args = list(a['rest'])
            else:
                args = [p[1]] + (list(a['opt']) if k in ('OPP', 'OFD', 'PRA')
                                 else list(a['rest']))
            device.append((line, k, p[0], args))
        else:
            d['extras'].append(line)    # AREA, PUMPDUTY, SUPPLYGRAPH

    resolve_copies(d, pipe, nc, pc)
    apply_pins(d)
    # A change applies to the named pipe after copying, so a copy still
    # has the source's original.  The snapshot was taken in
    # resolve_copies.
    for (line, name, ln, size, fits) in change:
        p = pipe.get(name)
        if p is None:
            d['extras'].append(line)
            continue
        p['len'] = ln
        p['size'] = size
        p['fits'] = list(fits)
    for (line, name, ln, note_) in eqv:
        p = pipe.get(name)
        if p is None or p.get('eqv') is not None:
            d['extras'].append(line)
            continue
        p['eqv'] = ln
        p['eqv_note'] = note_
    for (line, kind, name, args) in device:
        p = pipe.get(name)
        if p is None or p.get('device'):
            d['extras'].append(line)
            continue
        p['device'] = {'kind': kind, 'args': args}

    layout(d)
    rebuild_occ(d)
    return d


# iso_line -- one //ISO comment.  Anything else that starts with // is
# kept.
def iso_line(d, line):
    m = _ISO_GRID.match(line)
    if m:
        g = m.group(1)
        if is_num(g) and float(g) > 0:
            d['grid'] = float(g)
        else:
            d['warnings'].append('ISO GRID MUST BE A LENGTH GREATER THAN ZERO')
        return
    m = _ISO_POINT.match(line)
    if m:
        d['pin'][m.group(1)] = [int(m.group(2)), int(m.group(3)),
                                float(m.group(4))]
        return
    if _ISO_OTHER.match(line):
        d['warnings'].append(
            'AN ISO LINE WAS NOT GRID OR A POINT, AND WAS IGNORED')
        return
    d['extras'].append(line)


def pipe_rec(name, start, end, ln, size, fits, use, note):
    return {'name': name, 'start': start, 'end': end, 'len': ln,
            'size': size, 'fits': list(fits), 'use_type': use['type'],
            'use_c': use['c'], 'note': note}


def add_read_node(d, kind, p, a, note):
    name = p[0]
    node = {'name': name, 'kind': kind, 'elev': p[1], 'note': note,
            'pairs': []}
    if kind == 'WATER':
        node['static'] = p[2]
        node['pairs'] = list(a['rest'])
    elif kind != 'NODE':
        node['minflow'] = p[2]
        node['k'] = p[3]
    if name in d['pin']:
        node['ix'], node['iy'], node['iz'] = d['pin'][name]
        node['pinned'] = 1
    d['nodes'][name] = node
    d['node_order'].append(name)


# resolve_copies -- NC and PC, in the reader's order: copy first, from
# the source as it was typed, and only then does the caller apply
# CHANGEPIPE.
def resolve_copies(d, pipe, nc, pc):
    # A copy may name a copy, so walk until nothing further resolves.
    # What is left names a source the file never defines; the line is
    # kept for the reader to refuse.
    left = list(nc)
    while left:
        nxt = []
        moved = False
        for row in left:
            (line, src, names) = row
            s = d['nodes'].get(src)
            if s is None:
                nxt.append(row)
                continue
            moved = True
            for name in names:
                d['nodes'][name] = {
                    'name': name, 'kind': s['kind'], 'elev': s['elev'],
                    'static': s.get('static'), 'minflow': s.get('minflow'),
                    'k': s.get('k'), 'pairs': list(s.get('pairs') or [])}
                d['node_order'].append(name)
        if not moved:
            d['extras'].extend(r[0] for r in nxt)
            break
        left = nxt
    # The original of each real pipe, before any change and before
    # copies read it.  A copy of a copy reads that original, not a
    # later change.
    for p in pipe.values():
        p['orig'] = {'len': p['len'], 'size': p['size'],
                     'fits': list(p['fits']),
                     'use_type': p['use_type'], 'use_c': p['use_c']}
    left = list(pc)
    while left:
        nxt = []
        moved = False
        for row in left:
            (line, src, rest) = row[0], row[1], row[2]
            source = pipe.get(src)
            if source is None or 'orig' not in source:
                nxt.append(row)
                continue
            moved = True
            r = list(rest)
            o = source['orig']
            while len(r) >= 3:
                name, s, e = r[0], r[1], r[2]
                del r[0:3]
                p_ = pipe_rec(name, s, e, o['len'], o['size'], o['fits'],
                              {'type': o['use_type'], 'c': o['use_c']},
                              None)
                p_['orig'] = {'len': o['len'], 'size': o['size'],
                              'fits': list(o['fits']),
                              'use_type': o['use_type'],
                              'use_c': o['use_c']}
                pipe[name] = p_
                d['pipes'].append(p_)
            if r:      # a short tail is the reader's error to show
                d['extras'].append(line)
        if not moved:
            d['extras'].extend(r[0] for r in nxt)
            break
        left = nxt


# apply_pins -- //ISO may sit above or below the point it names.
def apply_pins(d):
    for name in d['node_order']:
        if name not in d['pin']:
            continue
        n = d['nodes'][name]
        n['ix'], n['iy'], n['iz'] = d['pin'][name]
        n['pinned'] = 1
    for name in d.get('pin') or {}:
        if name not in d['nodes']:
            d['warnings'].append('ISO NAMES %s, WHICH IS NOT A POINT' % name)


#------------------------------------------------------------------------------
# layout -- plan positions for every point that has none.
#
# The vertical is the elevation, in grid steps, unless a //ISO line
# gave one.  Each new point is put along a grid axis from the point it
# is piped to, by the pipe's length, so a tree reads as an isometric.
# A loop joins points already placed; that pipe is drawn straight
# between them even when it is not on one axis.  A pipe of no length
# (a device sat at a point) is drawn one step away so the two points
# can be told apart; its length is not changed.
#------------------------------------------------------------------------------
def layout(d):
    g = d['grid'] or 1
    for name in d['node_order']:
        n = d['nodes'][name]
        if not n.get('pinned'):
            m = elev_metres(d, n)
            n['iz'] = m / g
    rebuild_occ(d)

    adj = {}

    def link(a, b, ln):
        if a in d['nodes'] and b in d['nodes']:
            adj.setdefault(a, []).append((b, ln))
            adj.setdefault(b, []).append((a, ln))

    for p in d['pipes']:
        m = phc.length_metres(p['len'], d['units']['LENGTH'])
        link(p['start'], p['end'], m if m is not None else 0)
    for p in d['pumps']:
        link(p['in'], p['out'], 2 * g)

    seen = {}
    cursor = 0
    for name in d['node_order']:
        if seen.get(name):
            continue
        n = d['nodes'][name]
        if n.get('ix') is None:
            ix = cursor
            while not cell_free(d, ix, 0, n['iz']):
                ix += 1
            set_cell(d, n, ix, 0)
            cursor = ix + 4
        q = [name]
        seen[name] = 1
        while q:
            p = q.pop(0)
            slot = 0
            for (c, ln) in adj.get(p) or []:
                if seen.get(c):
                    continue
                if d['nodes'][c].get('ix') is None:
                    place_child(d, d['nodes'][p], d['nodes'][c], ln, slot)
                seen[c] = 1
                slot += 1
                q.append(c)


def place_child(d, parent, child, len_m, slot):
    g = d['grid'] or 1
    vert = abs(child['iz'] - parent['iz']) * g
    horiz = math.sqrt(len_m * len_m - vert * vert) if len_m > vert else 0
    # No length, or the whole length is the rise: keep the plan point,
    # unless that cell is this point's own (a device in a pipe of no
    # length).
    if len_m <= 0:
        steps = 1
    elif horiz < 0.25 * g:
        steps = 0
    else:
        steps = iround(horiz / g)
    if steps < 1 and len_m <= 0:
        steps = 1
    if steps == 0 and cell_free(d, parent['ix'], parent['iy'],
                               child['iz']):
        set_cell(d, child, parent['ix'], parent['iy'])
        return
    if steps < 1:
        steps = 1
    dirs = [(1, 0), (0, 1), (-1, 0), (0, -1)]
    if slot % 4:
        m = slot % 4
        dirs = dirs[m:] + dirs[:m]
    for (dx, dy) in dirs:
        ix = parent['ix'] + dx * steps
        iy = parent['iy'] + dy * steps
        if cell_free(d, ix, iy, child['iz']):
            set_cell(d, child, ix, iy)
            return
    for k in range(1, 500):
        ix = parent['ix'] + steps + k
        if cell_free(d, ix, parent['iy'], child['iz']):
            set_cell(d, child, ix, parent['iy'])
            return


def cell_free(d, ix, iy, iz):
    return not d['occ'].get(occ_key(ix, iy, iz))


def set_cell(d, n, ix, iy):
    n['ix'] = iround(ix)
    n['iy'] = iround(iy)
    d['occ'][occ_key(n['ix'], n['iy'], n['iz'])] = n['name']


def rebuild_occ(d):
    d['occ'] = {}
    for name in d['node_order']:
        n = d['nodes'][name]
        if n.get('ix') is None:
            continue
        d['occ'][occ_key(n['ix'], n['iy'], n['iz'])] = name


def occ_key(ix, iy, iz):
    return '%d,%d,%.4f' % (iround(ix), iround(iy), iz)


def iround(x):
    return int(x + 0.5) if x >= 0 else int(x - 0.5)


def elev_metres(d, n):
    m = phc.length_metres(n['elev'], d['units']['ELEVATION'])
    return m if m is not None else 0


#------------------------------------------------------------------------------
# write_network -- the network text of a drawing, //ISO lines first.
#
# Empty is an empty string, as a new editor buffer is.  Otherwise the
# text ends with a newline.
#------------------------------------------------------------------------------
def write_network(d):
    out = []
    out.append('//ISO GRID ' + clean_num(d['grid'] or 1))
    for name in d['node_order']:
        n = d['nodes'][name]
        if n.get('ix') is None:
            continue
        out.append('//ISO %s %d %d %s' % (name, n['ix'], n['iy'],
                                         clean_num(n['iz'])))
    for name in d['node_order']:
        n = d['nodes'][name]
        f = [n['name'], n['elev']]
        if n['kind'] == 'WATER':
            f += [n['static']] + list(n.get('pairs') or [])
        elif n['kind'] != 'NODE':
            f += [n['minflow'], n['k']]
        out.append(emit('%-9s %s' % (n['kind'], ' '.join(str(x) for x in f)),
                       n.get('note')))
    for f in d['flows']:
        f_ = [f['name'], f['node'], f['flow']]
        if f.get('minp') is not None and f['minp'] != '':
            f_.append(f['minp'])
        out.append(emit('%-9s %s' % ('FIXEDFLOW',
                                     ' '.join(str(x) for x in f_)),
                        f.get('note')))
    prev = 'BORE\0'        # the use a pipe has when no USE was written
    for p in d['pipes']:
        key = p['use_type'] + '\0' + (p['use_c'] if p.get('use_c') is not None
                                      else '')
        if key != prev:
            u = [p['use_type']]
            if p.get('use_c') is not None and p['use_c'] != '':
                u.append(p['use_c'])
            out.append('%-9s %s' % ('USE', ' '.join(str(x) for x in u)))
            prev = key
        out.append(emit('%-9s %s' % ('PIPE', ' '.join(str(x) for x in
            [p['name'], p['start'], p['end'], p['len'], p['size']] +
            list(p.get('fits') or []))), p.get('note')))
        if p.get('eqv') is not None:
            out.append(emit('%-9s %s %s' % ('EQV', p['name'], p['eqv']),
                            p.get('eqv_note')))
        if p.get('device'):
            out.append('%-9s %s' % (p['device']['kind'],
                ' '.join(str(x) for x in
                         [p['name']] + list(p['device'].get('args') or []))))
    for p in d['pumps']:
        out.append(emit('%-9s %s' % ('PUMP', ' '.join(str(x) for x in
            [p['name'], p['in'], p['out'], p['churn']] +
            list(p.get('pairs') or []))), p.get('note')))
    if d['extras']:
        out.extend(d['extras'])
    return '\n'.join(out) + '\n' if out else ''


def emit(line, note):
    if note is not None and note != '':
        line += '  //' + note
    return line


#------------------------------------------------------------------------------
# The picture.  project and cell_at are inverses: a grid point drawn
# and picked again is the same point.  hit is what a click lands on.
#
# LOCK uses a whole-pixel step on each axis.  A floating cos(30) makes
# a long pipe's slope drift off the grid's, so the pipe looks bent
# beside the grid.  The same integer step for every pipe on an axis
# keeps them parallel and straight.  Unlocked, the true 30 degrees is
# used, and a pipe is the one straight line between its ends even when
# that line is on no axis.
#------------------------------------------------------------------------------
def _basis(view):
    if not view or not view.get('lock'):
        return None
    s = view.get('scale') or 1
    dx = int(s * COS30 + 0.5)
    dy = int(s * SIN30 + 0.5)
    dz = int(s + 0.5)
    dx = max(dx, 1)
    dy = max(dy, 1)
    dz = max(dz, 1)
    return (dx, dy, dz)


def project(ix, iy, iz, view):
    b = _basis(view)
    if b:
        (dx, dy, dz) = b
        return (view['ox'] + (ix - iy) * dx,
                view['oy'] + (ix + iy) * dy - iz * dz)
    s = view['scale']
    sx = view['ox'] + (ix - iy) * s * COS30
    sy = view['oy'] + (ix + iy) * s * SIN30 - iz * s
    return (sx, sy)


def cell_at(sx, sy, view, iz=None):
    if iz is None:
        iz = 0
    b = _basis(view)
    if b:
        (dx, dy, dz) = b
        u = (sx - view['ox']) / dx
        v = (sy - view['oy'] + iz * dz) / dy
    else:
        s = view.get('scale') or 1
        u = (sx - view['ox']) / (s * COS30)
        v = (sy - view['oy'] + iz * s) / (s * SIN30)
    return (iround((u + v) / 2), iround((v - u) / 2), iz)


# axis_run -- the corners of a pipe drawn only along the grid axes, X
# then Y then Z.  A pipe already on one axis is just its two ends.
# Each leg changes one coordinate, so each leg is straight on the
# isometric.
def axis_run(ax, ay, az, bx, by, bz):
    p = [(ax, ay, az)]
    if abs(bx - ax) > 1e-9:
        ax = bx
        p.append((ax, ay, az))
    if abs(by - ay) > 1e-9:
        ay = by
        p.append((ax, ay, az))
    if abs(bz - az) > 1e-6:
        az = bz
        p.append((ax, ay, az))
    return p


def hit(d, sx, sy, view, node_r=None, pipe_r=None):
    if node_r is None:
        node_r = 14
    if pipe_r is None:
        pipe_r = 8
    best = None
    bestd = None
    for name in d['node_order']:
        n = d['nodes'][name]
        if n.get('ix') is None:
            continue
        (x, y) = project(n['ix'], n['iy'], n['iz'], view)
        dist = hypot(sx - x, sy - y)
        if dist > node_r:
            continue
        if bestd is None or dist < bestd:
            bestd = dist
            best = {'kind': 'node', 'name': name}
    if best:
        return best
    links = list(d['pipes']) + [{'name': p['name'], 'start': p['in'],
                                 'end': p['out'], 'pump': 1}
                                for p in d['pumps']]
    for p in links:
        a = d['nodes'].get(p['start'])
        b = d['nodes'].get(p['end'])
        if not (a and b and a.get('ix') is not None and b.get('ix')
                is not None):
            continue
        if view.get('lock'):
            run = axis_run(a['ix'], a['iy'], a['iz'], b['ix'], b['iy'],
                           b['iz'])
        else:
            run = [(a['ix'], a['iy'], a['iz']), (b['ix'], b['iy'], b['iz'])]
        dist = None
        for i in range(len(run) - 1):
            (x1, y1) = project(run[i][0], run[i][1], run[i][2], view)
            (x2, y2) = project(run[i + 1][0], run[i + 1][1],
                               run[i + 1][2], view)
            dd = seg_dist(sx, sy, x1, y1, x2, y2)
            if dist is None or dd < dist:
                dist = dd
        if dist is None or dist > pipe_r:
            continue
        if bestd is None or dist < bestd:
            bestd = dist
            best = {'kind': 'pump' if p.get('pump') else 'pipe',
                    'name': p['name']}
    return best


def hypot(x, y):
    return math.sqrt(x * x + y * y)


def seg_dist(px, py, x1, y1, x2, y2):
    (dx, dy) = (x2 - x1, y2 - y1)
    l2 = dx * dx + dy * dy
    if l2 < 1e-9:
        return hypot(px - x1, py - y1)
    t = ((px - x1) * dx + (py - y1) * dy) / l2
    t = max(0.0, t)
    t = min(1.0, t)
    return hypot(px - (x1 + t * dx), py - (y1 + t * dy))


# snap_axis -- the grid point on one axis from node, nearest the click.
# A pipe is drawn along one axis; the click chooses which, and how far.
def snap_axis(node, ix, iy, iz):
    (dx, dy, dz) = (ix - node['ix'], iy - node['iy'], iz - node['iz'])
    (ax, ay, az) = (abs(dx), abs(dy), abs(dz))
    if ax < 1e-9 and ay < 1e-9 and az < 1e-9:
        return (node['ix'], node['iy'], node['iz'])
    if ax >= ay and ax >= az:
        return (iround(ix), node['iy'], node['iz'])
    if ay >= ax and ay >= az:
        return (node['ix'], iround(iy), node['iz'])
    return (node['ix'], node['iy'], iz)


# steps_for_length -- how many grid steps a typed length is.
# Blank is None: the click chooses the cell, and the length follows
# it.  A length that is not a length is None as well; known_ok says
# which.  Zero stays zero (a device, not a point stacked on its
# start).  Anything shorter than half a step is still one step, so the
# two ends do not sit on top of each other; the typed length is what
# gets stored.
def steps_for_length(d, token):
    token = _s(token)
    if not re.search(r'\S', token):
        return None
    m = phc.length_metres(token, d['units']['LENGTH'])
    if m is None or m < 0:
        return None
    if m == 0:
        return 0
    steps = iround(m / (d['grid'] or 1))
    return steps if steps >= 1 else 1


# cell_along -- steps from node, on the one axis the click chose.
# (ix, iy, iz) is only the direction.  A click with no direction
# comes back as the node's own cell, and the window asks for a click
# along an axis.
def cell_along(node, ix, iy, iz, steps):
    (sx, sy, sz) = snap_axis(node, ix, iy, iz)
    (dx, dy, dz) = (sx - node['ix'], sy - node['iy'], sz - node['iz'])
    steps = iround(steps or 0)
    if steps < 0:
        steps = 0
    if abs(dx) >= 1e-9:
        s = steps if dx > 0 else -steps
        return (node['ix'] + s, node['iy'], node['iz'])
    if abs(dy) >= 1e-9:
        s = steps if dy > 0 else -steps
        return (node['ix'], node['iy'] + s, node['iz'])
    if abs(dz) > 1e-6:
        s = steps if dz > 0 else -steps
        return (node['ix'], node['iy'], node['iz'] + s)
    return (node['ix'], node['iy'], node['iz'])


# known_ok -- a length, size and C typed ahead of the click, or a
# blank.  Blank means "use what the click, or the last pipe, would
# have used".
def known_ok(d, known):
    if not known or not isinstance(known, dict):
        return ''
    if known.get('len') is not None and re.search(r'\S', _s(known['len'])):
        m = phc.length_metres(known['len'], d['units']['LENGTH'])
        if m is None:
            return 'LENGTH IS NOT A LENGTH'
        if m < 0:
            return 'A LENGTH CANNOT BE NEGATIVE'
    if known.get('size') is not None and re.search(r'\S', _s(known['size'])):
        if not (is_num(_s(known['size'])) and float(known['size']) >= 0):
            return 'SIZE IS NOT A NUMBER'
    if known.get('c') is not None and re.search(r'\S', _s(known['c'])):
        if not (is_num(_s(known['c'])) and float(known['c']) >= 0):
            return 'C IS NOT A NUMBER'
    return ''


def axis_aligned(a, b):
    if a.get('ix') is None or b.get('ix') is None:
        return False
    n = ((1 if abs(a['ix'] - b['ix']) > 1e-9 else 0) +
         (1 if abs(a['iy'] - b['iy']) > 1e-9 else 0) +
         (1 if abs(a['iz'] - b['iz']) > 1e-6 else 0))
    return n == 1


def node_at(d, ix, iy, iz):
    return d['occ'].get(occ_key(ix, iy, iz))


# geom_metres -- the length a pipe has on the grid, in metres.
def geom_metres(d, p):
    a = d['nodes'].get(p['start'])
    b = d['nodes'].get(p['end'])
    if not (a and b and a.get('ix') is not None and b.get('ix')
            is not None):
        return None
    g = d['grid'] or 1
    (dx, dy, dz) = ((a['ix'] - b['ix']) * g, (a['iy'] - b['iy']) * g,
                    (a['iz'] - b['iz']) * g)
    return math.sqrt(dx * dx + dy * dy + dz * dz)


#------------------------------------------------------------------------------
# Editing.  Each returns an empty string, or the reason it refused, in
# capitals, for the status line.  add_node and add_pipe and add_pump
# also return the new name: (err, name).
#------------------------------------------------------------------------------
def add_node(d, kind, ix, iy, iz=None, elev=None):
    if kind not in NODE_KIND:
        return ('UNKNOWN POINT', None)
    ix = iround(ix)
    iy = iround(iy)
    if iz is None:
        iz = 0
    if node_at(d, ix, iy, iz):
        return ('THAT POINT IS ALREADY USED', None)
    if elev is None or elev == '':
        elev = metres_to_token(d, iz * (d['grid'] or 1), 'ELEVATION')
    m = phc.length_metres(elev, d['units']['ELEVATION'])
    if m is None:
        return ('ELEVATION IS NOT AN ELEVATION', None)
    prefix = {'NODE': 'N', 'WATER': 'W', 'SPRINKLER': 'S',
              'HYDRANT': 'H', 'HREEL': 'R'}.get(kind)
    name = fresh_node(d, prefix)
    n = {'name': name, 'kind': kind, 'elev': elev, 'ix': ix, 'iy': iy,
         'iz': iz, 'pairs': []}
    if kind == 'WATER':
        n['static'] = '500'
    elif kind == 'SPRINKLER':
        n['minflow'] = '-50'
        n['k'] = '80'
    elif kind == 'HYDRANT':
        n['minflow'] = '400'
        n['k'] = '80'
    elif kind == 'HREEL':
        n['minflow'] = '20'
        n['k'] = '30'
    d['nodes'][name] = n
    d['node_order'].append(name)
    rebuild_occ(d)
    return ('', name)


# known, when given, is what was typed before the click: len, size,
# fits, c.  A blank field is the ordinary default (the grid distance,
# the office size, no fittings, the previous pipe's C).  A filled
# field is stored as typed, including a length that the grid had to
# round to whole steps.
def add_pipe(d, start, end, known=None):
    err = ends_ok(d, start, end)
    if err:
        return (err, None)
    err = known_ok(d, known)
    if err:
        return (err, None)
    a = d['nodes'][start]
    b = d['nodes'][end]
    if not axis_aligned(a, b):
        return ('A PIPE RUNS ALONG ONE GRID AXIS', None)
    known = known or {}
    name = fresh_link(d, 'P')
    use = d['pipes'][-1] if d['pipes'] else {'use_type': 'BORE',
                                             'use_c': '120'}
    size = '1' if d['units']['SIZE'] == 'IN' else '25'
    if known.get('size') is not None and re.search(r'\S', _s(known['size'])):
        size = known['size']
    if known.get('fits') is not None and re.search(r'\S', _s(known['fits'])):
        fits = [t for t in _s(known['fits']).split() if t]
    else:
        fits = []
    c = use['use_c']
    if known.get('c') is not None and re.search(r'\S', _s(known['c'])):
        c = known['c']
    p = {'name': name, 'start': start, 'end': end, 'size': size,
         'fits': fits, 'use_type': use['use_type'], 'use_c': c}
    if known.get('len') is not None and re.search(r'\S', _s(known['len'])):
        p['len'] = known['len']
    else:
        p['len'] = metres_to_token(d, geom_metres(d, p), 'LENGTH')
    d['pipes'].append(p)
    return ('', name)


def add_pump(d, in_, out):
    err = ends_ok(d, in_, out)
    if err:
        return (err, None)
    if not axis_aligned(d['nodes'][in_], d['nodes'][out]):
        return ('A PUMP RUNS ALONG ONE GRID AXIS', None)
    name = fresh_link(d, 'PU')
    d['pumps'].append({'name': name, 'in': in_, 'out': out,
                       'churn': '800', 'pairs': ['1000', '700']})
    return ('', name)


def add_fixedflow(d, node):
    if node not in d['nodes']:
        return ('CHOOSE A POINT FOR THE FIXED FLOW', None)
    name = fresh_link(d, 'F')
    d['flows'].append({'name': name, 'node': node, 'flow': '100'})
    return ('', name)


def ends_ok(d, a, b):
    if not (a in d['nodes'] and b in d['nodes']):
        return 'CHOOSE TWO POINTS'
    if a == b:
        return 'A PIPE NEEDS TWO POINTS'
    return ''


def move_node(d, name, ix, iy, iz=None):
    n = d['nodes'].get(name)
    if n is None:
        return 'NO SUCH POINT'
    ix = iround(ix)
    iy = iround(iy)
    if iz is None:
        iz = n['iz']
    at = node_at(d, ix, iy, iz)
    if at and at != name:
        return 'THAT POINT IS ALREADY USED'
    z_moved = abs(iz - n['iz']) > 1e-9
    n['ix'] = ix
    n['iy'] = iy
    n['iz'] = iz
    if z_moved:
        n['elev'] = metres_to_token(d, iz * (d['grid'] or 1), 'ELEVATION')
    rebuild_occ(d)
    retouch(d, name)
    return ''


# retouch -- pipes on a point take their length from the grid.  The
# typed length was a picture of the old geometry; the point has moved.
def retouch(d, name):
    for p in d['pipes']:
        if p['start'] != name and p['end'] != name:
            continue
        m = geom_metres(d, p)
        if m is not None:
            p['len'] = metres_to_token(d, m, 'LENGTH')


def delete_item(d, kind, name):
    if kind == 'node':
        if name not in d['nodes']:
            return 'NO SUCH POINT'
        d['pipes'] = [p for p in d['pipes']
                      if p['start'] != name and p['end'] != name]
        d['pumps'] = [p for p in d['pumps']
                      if p['in'] != name and p['out'] != name]
        d['flows'] = [f for f in d['flows'] if f['node'] != name]
        del d['nodes'][name]
        d['node_order'] = [x for x in d['node_order'] if x != name]
        # An AREA line naming it stays, and VALIDATE will say so.
    elif kind == 'pipe':
        if not any(p['name'] == name for p in d['pipes']):
            return 'NO SUCH PIPE'
        d['pipes'] = [p for p in d['pipes'] if p['name'] != name]
    elif kind == 'pump':
        if not any(p['name'] == name for p in d['pumps']):
            return 'NO SUCH PUMP'
        d['pumps'] = [p for p in d['pumps'] if p['name'] != name]
    else:
        return 'NOTHING TO DELETE'
    rebuild_occ(d)
    return ''


def set_node(d, name, field, value):
    n = d['nodes'].get(name)
    if n is None:
        return 'NO SUCH POINT'
    if value is None:
        value = ''
    value = value.strip()
    if field == 'NAME':
        if value == name:
            return ''
        if value.upper() == 'END':
            return 'END CANNOT BE A NAME'
        if re.search(r'\s|~', value) or value == '':
            return 'A NAME CANNOT CONTAIN A SPACE OR ~'
        if value in d['nodes']:
            return 'THAT NAME IS USED'
        d['nodes'][value] = n
        del d['nodes'][name]
        n['name'] = value
        d['node_order'] = [value if x == name else x
                           for x in d['node_order']]
        for p in d['pipes']:
            if p['start'] == name:
                p['start'] = value
            if p['end'] == name:
                p['end'] = value
        for p in d['pumps']:
            if p['in'] == name:
                p['in'] = value
            if p['out'] == name:
                p['out'] = value
        for f in d['flows']:
            if f['node'] == name:
                f['node'] = value
        d['extras'] = [rename_token(x, name, value) for x in d['extras']]
        rebuild_occ(d)
        return ''
    if field == 'ELEVATION':
        m = phc.length_metres(value, d['units']['ELEVATION'])
        if m is None:
            return 'ELEVATION IS NOT AN ELEVATION'
        iz = m / (d['grid'] or 1)
        at = node_at(d, n['ix'], n['iy'], iz)
        if at and at != name:
            return 'THAT POINT IS ALREADY USED'
        n['elev'] = value
        n['iz'] = iz
        rebuild_occ(d)
        retouch(d, name)
        return ''
    if field == 'STATIC':
        if not (is_num(value) and float(value) >= 0):
            return 'STATIC IS NOT A PRESSURE'
        n['static'] = value
        return ''
    if field == 'MINFLOW':
        if not is_num(value):
            return 'MIN FLOW IS NOT A NUMBER'
        n['minflow'] = value
        return ''
    if field == 'K':
        if not (is_num(value) and float(value) >= 0):
            return 'K IS NOT A K-FACTOR'
        n['k'] = value
        return ''
    return 'NO SUCH FIELD'


def set_pipe(d, name, field, value):
    p = None
    for q in d['pipes']:
        if q['name'] == name:
            p = q
            break
    if p is None:
        return 'NO SUCH PIPE'
    if value is None:
        value = ''
    value = value.strip()
    if field == 'NAME':
        if value == name:
            return ''
        if value.upper() == 'END':
            return 'END CANNOT BE A NAME'
        if re.search(r'\s|~', value) or value == '':
            return 'A NAME CANNOT CONTAIN A SPACE OR ~'
        if link_taken(d, value):
            return 'THAT NAME IS USED'
        p['name'] = value
        return ''
    if field == 'LENGTH':
        m = phc.length_metres(value, d['units']['LENGTH'])
        if m is None:
            return 'LENGTH IS NOT A LENGTH'
        if m < 0:
            return 'A LENGTH CANNOT BE NEGATIVE'
        # An axis pipe's end slides so the picture matches the typed
        # length.  Zero is stored and the end stays: a device is not
        # two stacked points.  retouch would replace the typed token
        # with the grid distance, so the token is put back after the
        # move.  A length that is not a whole number of steps stays as
        # typed.
        a = d['nodes'].get(p['start'])
        b = d['nodes'].get(p['end'])
        if m > 0 and a and b and axis_aligned(a, b):
            steps = steps_for_length(d, value)
            (nx, ny, nz) = cell_along(a, b['ix'], b['iy'], b['iz'],
                                     steps)
            same = (abs(nx - b['ix']) < 1e-9 and
                    abs(ny - b['iy']) < 1e-9 and
                    abs(nz - b['iz']) < 1e-6)
            if not same:
                at = node_at(d, nx, ny, nz)
                if at and at != p['end']:
                    return 'THAT POINT IS ALREADY USED'
                move = move_node(d, p['end'], nx, ny, nz)
                if move:
                    return move
        p['len'] = value
        return ''
    if field == 'SIZE':
        if not (is_num(value) and float(value) >= 0):
            return 'SIZE IS NOT A NUMBER'
        p['size'] = value
        if (p.get('note') is not None and
                re.match(r'^AS\b', p['note'], re.I)):
            del p['note']
        return ''
    if field == 'FITTINGS':
        p['fits'] = [t for t in value.split() if t]
        return ''
    if field == 'TYPE':
        t = value.upper()
        if t == '':
            return 'GIVE A PIPE TYPE, OR BORE'
        if not known_type(t):
            return 'UNKNOWN PIPE TYPE'
        p['use_type'] = t
        return ''
    if field == 'C':
        if value == '':
            p['use_c'] = None
            return ''
        if not (is_num(value) and float(value) >= 0):
            return 'C IS NOT A NUMBER'
        p['use_c'] = value
        return ''
    if field == 'EQV':
        if value == '':
            p.pop('eqv', None)
            return ''
        m = phc.length_metres(value, d['units']['LENGTH'])
        if m is None or m < 0:
            return 'EQV IS NOT A LENGTH'
        p['eqv'] = value
        return ''
    return 'NO SUCH FIELD'


def set_pump(d, name, field, value):
    p = None
    for q in d['pumps']:
        if q['name'] == name:
            p = q
            break
    if p is None:
        return 'NO SUCH PUMP'
    if value is None:
        value = ''
    value = value.strip()
    if field == 'NAME':
        if value == name:
            return ''
        if value.upper() == 'END':
            return 'END CANNOT BE A NAME'
        if re.search(r'\s|~', value) or value == '':
            return 'A NAME CANNOT CONTAIN A SPACE OR ~'
        if link_taken(d, value):
            return 'THAT NAME IS USED'
        p['name'] = value
        return ''
    if field == 'CHURN' and not (is_num(value) and float(value) >= 0):
        return 'NOT A PRESSURE'
    if field in ('FLOW', 'PRESSURE') and not (is_num(value) and
                                               float(value) >= 0):
        return 'NOT A NUMBER'
    if field == 'CHURN':
        p['churn'] = value
    elif field == 'FLOW':
        p['pairs'][0] = value
    elif field == 'PRESSURE':
        p['pairs'][1] = value
    if field not in ('CHURN', 'FLOW', 'PRESSURE'):
        return 'NO SUCH FIELD'
    return ''


def set_grid(d, value):
    value = _s(value)
    if not (is_num(value) and float(value) > 0):
        return 'GRID MUST BE METRES GREATER THAN ZERO'
    d['grid'] = float(value)
    # Points keep their steps.  A length already typed is left until a
    # point is moved; a new pipe uses the new step.
    return ''


def known_type(t):
    if t == 'BORE':
        return True
    try:
        pipedata.load()
    except Exception:
        pass
    return t in pipedata.pipe_types()


def fresh_node(d, prefix):
    i = 1
    while (prefix + str(i)) in d['nodes']:
        i += 1
    return prefix + str(i)


def fresh_link(d, prefix):
    i = 1
    while link_taken(d, prefix + str(i)):
        i += 1
    return prefix + str(i)


def link_taken(d, name):
    if (any(p['name'] == name for p in d['pipes']) or
            any(p['name'] == name for p in d['pumps']) or
            any(f['name'] == name for f in d['flows'])):
        return True
    return False


# rename_token -- a whole field equal to the old name.  A comment is
# left, apart from a token of its own, so a note that names the point
# follows it.
def rename_token(line, old, new):
    parts = line.split('//', 1)
    code = parts[0]
    tk = re.split(r'(\s+)', code)
    out = ''.join(new if t == old else t for t in tk)
    if len(parts) == 2:
        out += '//' + parts[1]
    return out


def metres_to_token(d, metres, quantity):
    unit = d['units'].get(quantity) or 'M'
    f = TO_METRE.get(unit) or 1
    return clean_num(metres / f)


def clean_num(x):
    s = '%.6f' % (x + 0)
    s = re.sub(r'0+\Z', '', s)
    s = re.sub(r'\.\Z', '', s)
    return s
