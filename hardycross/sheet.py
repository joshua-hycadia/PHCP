"""sheet -- the spreadsheet's model, a port of HardyCross/Sheet.pm.

THIS MODULE HAS NO TK IN IT.  It holds the rows the spreadsheet window
draws: the pipes, the nodes and the pressure devices, in the order the
grids show them, and the text of the .phc file they read from and are
written back to.  Every decision -- is this cell's type a device, does
this row belong on the NODES grid, how many flow/pressure pairs does a
curve need, which column does a validation message point at -- is made
here.  What the window draws is hardycross.sheetwindow, which calls
this module and paints what it returns.

A node in the grids is a dict of strings, the cell's text, not the
numbers the engine works in.  A pipe is the same.  A device is one row
of that device's table, its own kind of dict.  A sheet is

    { settings, pipes, nodes, devices, notes, extras, map, at, seq,
      network, text }

`settings` is the PROJECT tab's hash: the sheet holds that same hash,
so a unit changed on the PROJECT tab is the unit the file is written
with.  `notes` are // comment lines from the file, kept where they
were.  `extras` are the lines the grids have no cell for -- AREA,
SUPPLYGRAPH, a PUMPDUTY that named nothing -- kept so a file does not
lose them when it is saved from the sheet.  `map` records, for each
line `to_text` wrote, the cell it came from, so a problem the reader
reports can be shown there; `at` is the same by node and by pipe.
`seq` is the order the nodes were introduced in, which node_rows
sorts the file-only nodes by.

The counterpart of this file on the Perl side is HardyCross/Sheet.pm;
this port keeps that module's function names and the same order, so a
reader who knows one can find the other.
"""

import re

from hardycross import editor
from hardycross import phc
from hardycross import tools as _tools

# The NODE TYPE list.  A blank type is the default, a plain node, and
# is not written in the cell.  The three outlets and the supply have
# full names; the seven pressure devices are their codes.  The first
# is the default: a node, stored as a blank.  'A NODE' is the words the
# menu shows for that blank, not a value.
TYPE_CHOICES = [
    ('', 'A NODE'),
    ('SPRINKLER', 'SPRINKLER'),
    ('HYDRANT', 'HYDRANT'),
    ('HREEL', 'HREEL'),
    ('SUPPLY', 'SUPPLY'),
    ('PUMP', 'PUMP'),
    ('BP', 'BP'),
    ('BFP', 'BFP'),
    ('PRV', 'PRV'),
    ('OPP', 'OPP'),
    ('OFD', 'OFD'),
    ('PRA', 'PRA'),
]

DEVICE_TYPES = ['PUMP', 'BP', 'BFP', 'PRV', 'OPP', 'OFD', 'PRA']
_DEVICE = dict((t, 1) for t in DEVICE_TYPES)
_OUTLET = {'SPRINKLER': 1, 'HYDRANT': 1, 'HREEL': 1}

# How many flow/pressure pairs a supply or a device curve shows at
# least.  One more than the pairs already typed is added on top, so the
# next point has a cell.  Example 02's backflow preventer has four
# pairs.
MIN_PAIRS = 4


#------------------------------------------------------------------------------
# trim / normal_type -- a cell's text, and a node type brought to the words
# the sheet stores.  NODE, A NODE and ANODE are the default, so they become
# a blank: the type is not written down when it is only "a node".
#------------------------------------------------------------------------------
def trim(v):
    if v is None:
        return ''
    return re.sub(r'^\s+|\s+\Z', '', str(v))


def normal_type(t):
    t = trim(t).upper()
    if t in ('', 'NODE', 'A NODE', 'ANODE'):
        return ''
    if t in ('SUPPLY', 'WATER'):
        return 'SUPPLY'
    if t in ('HREEL', 'HOSEREEL', 'HOSE REEL'):
        return 'HREEL'
    return t


def is_device(t):
    return 1 if _DEVICE.get(normal_type(t)) else 0


def is_outlet(t):
    return 1 if _OUTLET.get(normal_type(t)) else 0


#------------------------------------------------------------------------------
# Empty records.  Every field is a string the grid can show, except pairs
# (a flat list of flow, pressure or flow, loss) and the flags.
#------------------------------------------------------------------------------
def empty_pipe():
    return {'pipe': '', 'from': '', 'to': '', 'length': '', 'type': '',
            'c': '', 'diam': '', 'fittings': '', 'eqv': '', 'note': '',
            'use_note': ''}


def empty_node():
    return {'type': '', 'elev': '', 'fixed_flow': '', 'fixed_name': '',
            'fixed_min_p': '', 'min_flow': '', 'min_p': '', 'k': '',
            'static': '', 'pairs': [], 'keep': 0, 'defined_in_file': 0,
            'seq': 0, 'note': ''}


def empty_device(type_):
    return {'type': type_, 'node': '', 'tied': 0, 'name': '', 'pipe': '',
            'in': '', 'out': '', 'churn': '', 'drop': '', 'bore': '',
            'cd': '', 'ratio': '', 'min_inlet': '', 'band': '',
            'duty_flow': '', 'duty_p': '', 'pairs': [], 'note': ''}


def pipe_is_blank(p):
    if not p:
        return 1
    for f in ('pipe', 'from', 'to', 'length', 'type', 'c', 'diam',
              'fittings', 'eqv'):
        if len(trim(p.get(f))):
            return 0
    return 1


# new_sheet -- an empty sheet.  `settings` is the PROJECT tab's hash when the
# window has one, so the fields and the file stay the same hash.
def new_sheet(settings=None):
    if settings is None:
        settings = editor.new_settings()
    return {'settings': settings, 'pipes': [], 'nodes': {}, 'devices': [],
            'notes': [], 'extras': [], 'map': {}, 'at': {}, 'seq': 0,
            'network': '', 'text': ''}


def ensure_node(sheet, id_):
    id_ = trim(id_)
    if not len(id_):
        return None
    n = sheet['nodes'].get(id_)
    if n is not None:
        return n
    n = empty_node()
    sheet['seq'] = sheet['seq'] + 1
    n['seq'] = sheet['seq']
    sheet['nodes'][id_] = n
    return n


#==============================================================================
# Which rows the grids show.
#==============================================================================

# node_rows -- the node numbers, in the order the SYSTEM grid introduces
# them, then any node a file defined that no pipe names.
def node_rows(sheet):
    ids, seen = [], {}
    for p in sheet['pipes']:
        if pipe_is_blank(p):
            continue
        for end in ('from', 'to'):
            id_ = trim(p.get(end))
            if not len(id_):
                continue
            if seen.get(id_):
                continue
            seen[id_] = 1
            ensure_node(sheet, id_)
            ids.append(id_)
    rest = [k for k in sheet['nodes'] if not seen.get(k) and sheet['nodes'][k]['keep']]
    rest.sort(key=lambda k: sheet['nodes'][k].get('seq') or 0)
    return ids + rest


# supply_rows -- the nodes whose type is SUPPLY, in node_rows order.
def supply_rows(sheet):
    return [i for i in node_rows(sheet)
            if normal_type(sheet['nodes'][i]['type']) == 'SUPPLY']


# device_rows -- the devices of one type that the PRESSURE DEVICES tab shows.
# A tied device is shown only while its node is on the grid and still of
# that type.  An untied device (one the file had, whose node is something
# else) is always shown.
def device_rows(sheet, type_):
    live = dict((i, 1) for i in node_rows(sheet))
    out = []
    for d in sheet['devices']:
        if d['type'] != type_:
            continue
        if d['tied']:
            node = trim(d.get('node'))
            if not live.get(node):
                continue
            if normal_type(sheet['nodes'].get(node, {}).get('type')) != type_:
                continue
        out.append(d)
    return out


# pair_slots -- how many flow/pressure pairs to show.  At least MIN_PAIRS,
# and always one empty pair past the last one that has a number in it.
def pair_slots(sheet, which):
    used = [0]

    def count(pairs):
        pairs = pairs or []
        n = 0
        for i in range(len(pairs)):
            if len(trim(pairs[i])):
                n = int(i / 2) + 1
        if n > used[0]:
            used[0] = n

    if which == 'SUPPLY':
        for i in supply_rows(sheet):
            count(sheet['nodes'][i].get('pairs'))
    else:
        for d in device_rows(sheet, which):
            count(d.get('pairs'))
    n = used[0] + 1
    return n if n >= MIN_PAIRS else MIN_PAIRS


# default_pipe -- the pipe a device at this node most likely sits in: the
# pipe that arrives there, else the pipe that leaves.
def default_pipe(sheet, id_):
    for p in sheet['pipes']:
        if trim(p.get('to')) == id_ and len(trim(p.get('pipe'))):
            return trim(p['pipe'])
    for p in sheet['pipes']:
        if trim(p.get('from')) == id_ and len(trim(p.get('pipe'))):
            return trim(p['pipe'])
    return ''


#------------------------------------------------------------------------------
# reconcile -- make the device list follow the node types.
#
# Choosing PRV on a node adds one PRV row, tied to that node, the first
# time.  Choosing something else hides it (the record stays, so choosing
# PRV again brings the numbers back).  Called when a type changes and
# before the file is written, so a type cannot be saved without its
# device.
#------------------------------------------------------------------------------
def reconcile(sheet):
    for id_ in node_rows(sheet):
        n = sheet['nodes'][id_]
        t = normal_type(n['type'])
        n['type'] = t
        if not is_device(t):
            continue
        d = None
        for cand in sheet['devices']:
            if trim(cand.get('node')) == id_ and cand['type'] == t:
                d = cand
                break
        if d is None:
            d = empty_device(t)
            d['node'] = id_
            if t == 'PUMP':
                d['name'] = 'P-' + id_
                d['out'] = id_
            else:
                d['pipe'] = default_pipe(sheet, id_)
            sheet['devices'].append(d)
        d['tied'] = 1
    return sheet


#==============================================================================
# The columns.  The window paints these; the tests read the same list, so a
# heading cannot drift away from the field the file is built from.
#
# C and EQV are the two columns the SYSTEM grid adds to the ones asked
# for.  C is the figure on the USE line: a Hazen-Williams C, or under
# Darcy-Weisbach the roughness in the size unit.  Without it a bore pipe
# opened from a file would be written back as the reader's default (120,
# or the database's roughness) and a model that had stated another
# figure would change.
# EQV is an equivalent length added to the pipe, the EQV command.  The
# fitting string is the fittings; EQV is the extra length a file can
# carry.
#==============================================================================
def _col(key, head, width, hint, **o):
    c = {'key': key, 'head': head, 'width': width, 'hint': hint}
    c.update(o)
    return c


def system_columns(sheet):
    u = sheet['settings']['units']
    ln = u.get('LENGTH') or 'MM'
    sz = u.get('SIZE') or 'MM'
    return [
        _col('pipe', 'PIPE', 12, 'THE PIPE NUMBER. EACH NUMBER IS USED ONCE.'),
        _col('from', 'FROM NODE', 12, 'THE NODE THE PIPE LEAVES. THE NODES TAB IS FILLED FROM THESE, AND FROM TO NODE.'),
        _col('to', 'TO NODE', 12, 'THE NODE THE PIPE ARRIVES AT.'),
        _col('length', 'LENGTH (%s)' % ln, 12, 'THE PIPE LENGTH, IN THE LENGTH UNIT SET IN THE PROJECT TAB.'),
        _col('type', 'PIPE TYPE', 12, 'A TYPE FROM THE DATABASE, OR BORE WHEN THE DIAMETER IS A BORE. BLANK INHERITS THE PREVIOUS ROW. CHOOSE IT FROM THE LIST.', kind='pipetype'),
        _col('c', 'C / ROUGHNESS', 14, "THE USE FIGURE: HAZEN-WILLIAMS C, OR ROUGHNESS IN THE SIZE UNIT UNDER DARCY-WEISBACH. BLANK: THE DATABASE'S, OR 120 FOR A BORE."),
        _col('diam', 'PIPE DIAM (%s)' % sz, 14, 'THE NOMINAL SIZE FOR THAT TYPE, IN THE SIZE UNIT. 0 ASKS FOR THE PIPE TO BE SIZED. A BORE IS TYPED, NOT CHOSEN.', kind='diam'),
        _col('fittings', 'FITTING STRING', 22, 'FITTINGS AFTER THE SIZE, ONE CODE EACH, A COUNT OPTIONAL: 2E T GV. G, C AND B ARE THE GATE, CHECK AND BUTTERFLY VALVES.'),
        _col('eqv', 'EQV (%s)' % ln, 10, 'AN EQUIVALENT LENGTH ADDED TO THE PIPE. THE FITTING STRING IS THE FITTINGS; THIS IS EXTRA.'),
    ]


# pipe_type_choices -- the PIPE TYPE list: every type in the database, then
# BORE.  BORE means the diameter is a bore the user types, not a nominal
# size.  The codes are the ones a USE line already accepts.
def pipe_type_choices():
    return list(_tools.pipe_types())


# effective_type -- the pipe type a row is using.  A blank cell inherits
# the nearest row above that names one, the same way a USE line covers
# the pipes under it until the next USE.  The diameter list is that
# type's.
def effective_type(sheet, r):
    if not sheet or r is None:
        return ''
    i = int(r)
    while i >= 0:
        if i < len(sheet['pipes']):
            t = trim(sheet['pipes'][i].get('type')).upper()
            if len(t):
                return t
        i = i - 1
    return ''


# diam_choices -- the PIPE DIAM list for a type, in the project's SIZE unit.
# 0 is first, because a size of 0 still asks for the pipe to be sized.
# An empty list means the diameter is typed: BORE, a blank with nothing
# above it to inherit, or a type the database does not know.  The text
# already in the cell is left as it is; this list does not replace it.
def diam_choices(sheet, type_):
    type_ = trim(type_).upper()
    if type_ == '' or type_ == 'BORE':
        return []
    dn = list(_tools.sizes(type_))
    if not dn:
        return []
    unit = (sheet['settings']['units'].get('SIZE') or 'MM').upper()
    out = ['0']
    if unit == 'IN':
        # Nominal inches, not the millimetre DN.  A DN with no inch name
        # is left off the list: the cell would otherwise write a
        # millimetre figure into a file whose size unit is inches.
        inch = dict((v, k) for k, v in phc.inch_sizes().items())
        for d in dn:
            if d in inch:
                out.append(inch[d])
    else:
        out.extend('%d' % (d + 0) for d in dn)
    return out


def node_columns(sheet):
    u = sheet['settings']['units']
    el = u.get('ELEVATION') or ''
    fl = u.get('FLOW') or ''
    pr = u.get('PRESSURE') or ''
    k = u.get('KFACTOR') or ''
    return [
        _col('node', 'NODE', 12, 'THE NODE NUMBER, TAKEN FROM THE SYSTEM TAB. IT IS NOT TYPED HERE.', ro=1),
        _col('type', 'NODE TYPE', 14, 'BLANK IS A NODE, AND THE WORD IS NOT WRITTEN. CHOOSE SPRINKLER, HYDRANT, HREEL, SUPPLY, OR A PRESSURE DEVICE FROM THE LIST.', kind='type'),
        _col('elev', 'ELEVATION (%s)' % el, 14, "THE NODE'S ELEVATION, IN THE ELEVATION UNIT."),
        _col('fixed_flow', 'FIXED FLOW (%s)' % fl, 16, 'A FLOW THE NODE TAKES WHATEVER THE PRESSURE. BLANK: NONE.'),
        _col('min_flow', 'MIN FLOW (%s)' % fl, 14, "THE LEAST FLOW AN OUTLET MUST GIVE. FOR A NODE THAT IS NOT AN OUTLET, LEAVE IT BLANK."),
        _col('min_p', 'MIN P (%s)' % pr, 12, 'THE LEAST PRESSURE. FOR AN OUTLET THIS IS USED WHEN MIN FLOW IS BLANK. FOR A FIXED FLOW IT IS THE PRESSURE THE FLOW NEEDS.'),
        _col('k', 'K (%s)' % k, 12, 'THE K-FACTOR OF A SPRINKLER, HYDRANT OR HOSE REEL. 0 TURNS THE OUTLET OFF AND LEAVES THE NODE.'),
    ]


def supply_columns(sheet):
    u = sheet['settings']['units']
    fl = u.get('FLOW') or 'LPM'
    pr = u.get('PRESSURE') or 'KPA'
    c = [
        _col('node', 'NODE', 12, "THE SUPPLY NODE. SET THE NODE'S TYPE TO SUPPLY AND THE ROW APPEARS. ELEVATION IS ON THE NODES TAB.", ro=1),
        _col('static', 'STATIC (%s)' % pr, 12, 'THE PRESSURE AT NO FLOW.'),
    ]
    for i in range(1, pair_slots(sheet, 'SUPPLY') + 1):
        c.append(_col('q%d' % i, 'FLOW %d (%s)' % (i, fl), 12, 'A POINT ON THE SUPPLY CURVE: THE FLOW.'))
        c.append(_col('p%d' % i, 'PRESSURE %d (%s)' % (i, pr), 14, 'THE PRESSURE AT THAT FLOW. THE CURVE STARTS AT THE STATIC PRESSURE AT NO FLOW.'))
    return c


# device_columns -- the columns that type needs, and no others.
#   PUMP   name, the node it draws from, the node it delivers to, churn
#          pressure, then flow/pressure points, and the duty it is checked at
#   BP     the pipe the booster sits in, then the same curve and duty
#   BFP    the pipe, then flow/loss points (one pair at flow 0 is a fixed loss)
#   PRV    the same columns as a backflow preventer
#   OPP    the pipe, the drop the plate is sized for, and an optional Cd
#   OFD    the pipe, the bore, and an optional Cd
#   PRA    the pipe, the ratio, the least inlet pressure, and the band
def device_columns(sheet, type_):
    u = sheet['settings']['units']
    fl = u.get('FLOW') or 'LPM'
    pr = u.get('PRESSURE') or 'KPA'
    sz = u.get('SIZE') or 'MM'
    node = _col('node', 'NODE', 12, 'THE NODE WHOSE TYPE IS THIS DEVICE. CHOOSING THE TYPE ADDS THE ROW.', ro=1)
    pipe = _col('pipe', 'PIPE', 12, "THE PIPE THE DEVICE SITS IN. IT IS PLACED AT THAT PIPE'S START.")
    c = [node]
    if type_ == 'PUMP':
        c += [
            _col('name', 'NAME', 12, "THE PUMP'S NAME. A NEW ROW IS NAMED P- AND THE NODE NUMBER."),
            _col('in', 'IN', 12, 'THE NODE THE PUMP DRAWS FROM.'),
            _col('out', 'OUT', 12, "THE NODE THE PUMP DELIVERS TO. A NEW ROW USES THE NODE WHOSE TYPE IS PUMP."),
            _col('churn', 'CHURN (%s)' % pr, 12, 'THE PRESSURE AT NO FLOW.'),
        ]
        for i in range(1, pair_slots(sheet, 'PUMP') + 1):
            c.append(_col('q%d' % i, 'FLOW %d (%s)' % (i, fl), 12, 'A POINT ON THE PUMP CURVE.'))
            c.append(_col('p%d' % i, 'PRESSURE %d (%s)' % (i, pr), 14, 'THE PRESSURE AT THAT FLOW.'))
        c += [
            _col('duty_flow', 'DUTY FLOW (%s)' % fl, 14, 'THE RATED FLOW, IF THE PUMP IS TO BE CHECKED AGAINST ITS CURVE. BLANK: NOT CHECKED.'),
            _col('duty_p', 'DUTY P (%s)' % pr, 12, 'THE RATED PRESSURE AT THAT FLOW.'),
        ]
    elif type_ == 'BP':
        c.append(pipe)
        c.append(_col('churn', 'CHURN (%s)' % pr, 12, 'THE PRESSURE AT NO FLOW.'))
        for i in range(1, pair_slots(sheet, 'BP') + 1):
            c.append(_col('q%d' % i, 'FLOW %d (%s)' % (i, fl), 12, 'A POINT ON THE BOOSTER CURVE.'))
            c.append(_col('p%d' % i, 'PRESSURE %d (%s)' % (i, pr), 14, 'THE PRESSURE AT THAT FLOW.'))
        c += [
            _col('duty_flow', 'DUTY FLOW (%s)' % fl, 14, 'THE RATED FLOW. THE DUTY NAMES THE PIPE. BLANK: NOT CHECKED.'),
            _col('duty_p', 'DUTY P (%s)' % pr, 12, 'THE RATED PRESSURE AT THAT FLOW.'),
        ]
    elif type_ in ('BFP', 'PRV'):
        what = 'BACKFLOW PREVENTER' if type_ == 'BFP' else 'PRESSURE REDUCING VALVE'
        c.append(pipe)
        for i in range(1, pair_slots(sheet, type_) + 1):
            c.append(_col('q%d' % i, 'FLOW %d (%s)' % (i, fl), 12, 'A POINT ON THE %s LOSS CURVE. ONE PAIR AT FLOW 0 IS A LOSS THAT DOES NOT VARY.' % what))
            c.append(_col('l%d' % i, 'LOSS %d (%s)' % (i, pr), 12, 'THE PRESSURE LOSS AT THAT FLOW.'))
    elif type_ == 'OPP':
        c += [
            pipe,
            _col('drop', 'DROP (%s)' % pr, 12, 'THE NET DROP THE PLATE IS SIZED TO GIVE.'),
            _col('cd', 'CD', 8, 'THE DISCHARGE COEFFICIENT. BLANK: 0.596.'),
        ]
    elif type_ == 'OFD':
        c += [
            pipe,
            _col('bore', 'BORE (%s)' % sz, 12, "THE PLATE'S BORE. THE DROP IS CALCULATED."),
            _col('cd', 'CD', 8, 'THE DISCHARGE COEFFICIENT. BLANK: 0.596.'),
        ]
    elif type_ == 'PRA':
        c += [
            pipe,
            _col('ratio', 'RATIO', 10, 'THE PRESSURE RATIO, WRITTEN 3:1 OR 1.5. THE OUTLET IS THE INLET DIVIDED BY THE RATIO.'),
            _col('min_inlet', 'MIN INLET (%s)' % pr, 14, 'THE LEAST INLET PRESSURE THE VALVE IS RATED FOR. BLANK, OR 0: NO MINIMUM.'),
            _col('band', 'BAND (%)', 10, 'HOW FAR EITHER SIDE OF THE RATIO, AS A PERCENTAGE OF THE INLET. BLANK: 5%.'),
        ]
    return c


#==============================================================================
# Reading a .phc file into the grids.
#==============================================================================

# code_and_note -- the line's code, and a // comment if it has one.
def code_and_note(line):
    line = '' if line is None else str(line)
    line = re.sub(r'\r\Z', '', line)
    i = line.find('//')
    if i < 0:
        return line, ''
    note = line[i:]
    code = line[:i]
    code = re.sub(r'\s+\Z', '', code)
    return code, note


# split_min -- an outlet's MINFLOW.  Below zero it is a minimum pressure,
# which the sheet keeps in MIN P so the two columns stay separate.
def split_min(v):
    v = trim(v)
    if not len(v):
        return '', ''
    m = re.match(r'^\-(.+)\Z', v)
    if m:
        return '', m.group(1)
    return v, ''


# read_text -- a .phc text as a sheet.  Settings come out through the same
# split the text editor uses, so the PROJECT tab holds the same fields.
# Copies (PC, NC) are expanded into rows, because a grid has no copy
# command: each pipe and each node is its own row, with the source's
# values.  A CHANGEPIPE is applied to that one row.  The commands are
# then the same network the reader would have built.
def read_text(text):
    text = '' if text is None else text
    doc = editor.split_file(text)
    sheet = new_sheet(doc['settings'])
    by, change, eqv = {}, {}, {}
    nc, fixed, duty = [], [], {}
    use = {'type': '', 'c': '', 'note': ''}

    for raw in doc['network'].split('\n'):
        raw = re.sub(r'\r\Z', '', raw)
        if re.match(r'^\s*$', raw):
            continue
        if re.match(r'^\s*//', raw):
            sheet['notes'].append(raw)
            continue
        note = code_and_note(raw)[1]
        a = phc.analyse(raw)
        if a['status'] != 'ok':
            sheet['extras'].append(raw)
            continue
        spec = phc.command_spec(a['key'])
        if spec and spec['kind'] == 'setting':
            sheet['extras'].append(raw)
            continue
        k = a['key']
        p = list(a['pos'])

        if k == 'USE':
            opt = list(a.get('opt') or [])
            use = {'type': p[0], 'c': opt[0] if len(opt) else '', 'note': note}
        elif k == 'PIPE':
            q = empty_pipe()
            q.update({'pipe': p[0], 'from': p[1], 'to': p[2],
                      'length': p[3], 'diam': p[4]})
            q['type'] = use['type']
            q['c'] = use['c']
            q['use_note'] = use.get('note') or ''
            use['note'] = ''
            q['fittings'] = ' '.join(str(x) for x in (a.get('rest') or []))
            q['note'] = note
            sheet['pipes'].append(q)
            by[trim(q['pipe'])] = q
        elif k == 'PC':
            r = [str(x) for x in (a.get('rest') or [])]
            first = True
            while len(r) >= 3:
                name, s, e = r[0], r[1], r[2]
                r = r[3:]
                q = empty_pipe()
                q.update({'pipe': name, 'from': s, 'to': e})
                q['copy_of'] = p[0]
                if first:
                    q['note'] = note
                first = False
                sheet['pipes'].append(q)
                by[trim(name)] = q
        elif k == 'CHANGEPIPE':
            change[p[0]] = {'length': p[1], 'diam': p[2],
                           'fittings': ' '.join(str(x) for x in (a.get('rest') or [])),
                           'raw': raw}
        elif k == 'EQV':
            eqv[p[0]] = {'eqv': p[1], 'raw': raw}
        elif k == 'NODE':
            n = ensure_node(sheet, p[0])
            n['elev'] = p[1]
            n['defined_in_file'] = 1
            n['note'] = note
        elif k == 'WATER':
            n = ensure_node(sheet, p[0])
            n['type'] = 'SUPPLY'
            n['elev'] = p[1]
            n['static'] = p[2]
            n['pairs'] = [str(x) for x in (a.get('rest') or [])]
            n['defined_in_file'] = 1
            n['note'] = note
        elif _OUTLET.get(k):
            n = ensure_node(sheet, p[0])
            n['type'] = k
            n['elev'] = p[1]
            n['min_flow'], n['min_p'] = split_min(p[2])
            n['k'] = p[3]
            n['defined_in_file'] = 1
            n['note'] = note
        elif k == 'NC':
            nc.append({'source': p[0], 'names': [str(x) for x in (a.get('rest') or [])],
                       'raw': raw, 'note': note})
        elif k == 'FIXEDFLOW':
            opt = list(a.get('opt') or [])
            fixed.append({'name': p[0], 'node': p[1], 'flow': p[2],
                         'minp': opt[0] if len(opt) else '', 'raw': raw})
        elif k == 'PUMP':
            d = empty_device('PUMP')
            d.update({'name': p[0], 'in': p[1], 'out': p[2], 'churn': p[3]})
            d['pairs'] = [str(x) for x in (a.get('rest') or [])]
            d['note'] = note
            sheet['devices'].append(d)
        elif k == 'PUMPDUTY':
            duty[p[0]] = {'q': p[1], 'p': p[2]}
        elif _DEVICE.get(k):
            d = empty_device(k)
            d['pipe'] = p[0]
            d['note'] = note
            opt = [str(x) for x in (a.get('opt') or [])]
            if k == 'BP':
                d['churn'] = p[1]
                d['pairs'] = [str(x) for x in (a.get('rest') or [])]
            elif k in ('BFP', 'PRV'):
                d['pairs'] = [str(x) for x in (a.get('rest') or [])]
            elif k == 'OPP':
                d['drop'] = p[1]
                d['cd'] = opt[0] if len(opt) else ''
            elif k == 'OFD':
                d['bore'] = p[1]
                d['cd'] = opt[0] if len(opt) else ''
            elif k == 'PRA':
                d['ratio'] = p[1]
                d['min_inlet'] = opt[0] if len(opt) else ''
                d['band'] = opt[1] if len(opt) > 1 else ''
            sheet['devices'].append(d)
        else:
            # AREA, SUPPLYGRAPH, and anything the grid has no column for.
            sheet['extras'].append(raw)

    _resolve_pipe_copies(sheet, by)
    for name, ch in change.items():
        q = by.get(trim(name))
        if q is not None:
            q.update({'length': ch['length'], 'diam': ch['diam'],
                      'fittings': ch['fittings']})
        else:
            sheet['extras'].append(ch['raw'])
    for name, e in eqv.items():
        q = by.get(trim(name))
        if q is not None:
            q['eqv'] = e['eqv']
        else:
            sheet['extras'].append(e['raw'])
    _resolve_node_copies(sheet, nc)
    for f in fixed:
        n = sheet['nodes'].get(trim(f['node']))
        if n is not None and not len(trim(n['fixed_flow'])):
            n['fixed_name'] = f['name']
            n['fixed_flow'] = f['flow']
            # An outlet already uses MIN P for its own minimum.  The fixed
            # flow's minimum is kept beside it so neither is thrown away.
            if is_outlet(n['type']):
                n['fixed_min_p'] = f['minp']
            else:
                if not len(trim(n['min_p'])):
                    n['min_p'] = f['minp']
                n['fixed_min_p'] = f['minp']
        else:
            sheet['extras'].append(f['raw'])
    for d in sheet['devices']:
        key = ''
        if d['type'] == 'PUMP':
            key = trim(d.get('name'))
        elif d['type'] == 'BP':
            key = trim(d.get('pipe'))
        if len(key) and key in duty:
            d['duty_flow'] = duty[key]['q']
            d['duty_p'] = duty[key]['p']
            del duty[key]
    # A duty that named nothing is kept, so the file does not lose it.
    for key in sorted(duty):
        sheet['extras'].append('%-9s %s %s %s' %
                               ('PUMPDUTY', key, duty[key]['q'], duty[key]['p']))

    _tie_devices(sheet, by)
    _mark_keepers(sheet)
    reconcile(sheet)
    return sheet


# _resolve_pipe_copies -- a PC row takes its length, type, C, diameter and
# fittings from the source pipe.  A source may itself be a copy.  The
# equivalent length is not copied: EQV belongs to the pipe it names.
def _resolve_pipe_copies(sheet, by):
    for p in sheet['pipes']:
        if not p.get('copy_of'):
            continue
        name, seen = p['copy_of'], {}
        src = None
        while len(str(name or '')) and not seen.get(name):
            seen[name] = 1
            src = by.get(name)
            if src is None:
                break
            if not src.get('copy_of'):
                break
            name = src['copy_of']
        if src is not None and not src.get('copy_of'):
            for f in ('length', 'type', 'c', 'diam', 'fittings'):
                p[f] = src[f]
        del p['copy_of']


# _resolve_node_copies -- an NC name takes the source node's kind,
# elevation and outlet or supply figures.  A fixed flow is not part of
# the node, so it is not copied.  A copy may name another copy, and the
# lines may come in any order, so each pass resolves the ones whose
# source is already known and the rest wait.
def _resolve_node_copies(sheet, nc):
    left = list(nc)
    guard = len(left) + 2
    while left and guard:
        guard = guard - 1
        still = []
        for c in left:
            src = sheet['nodes'].get(trim(c['source']))
            if src is None or not src.get('defined_in_file'):
                still.append(c)
                continue
            first = True
            for id_ in c['names']:
                existing = sheet['nodes'].get(trim(id_))
                if existing is not None and existing.get('defined_in_file'):
                    if first:
                        sheet['extras'].append(c['raw'])
                    first = False
                    continue
                n = ensure_node(sheet, id_)
                seq = n['seq']
                n.clear()
                n.update(src)
                n['pairs'] = list(src.get('pairs') or [])
                n['seq'] = seq
                n['fixed_flow'] = ''
                n['fixed_name'] = ''
                n['fixed_min_p'] = ''
                n['note'] = (c.get('note') or '') if first else ''
                n['defined_in_file'] = 1
                n['keep'] = 0
                first = False
        if len(still) == len(left):
            break
        left = still
    for c in left:
        sheet['extras'].append(c['raw'])


# _tie_devices -- where a file's device can be shown as a node type.
# Only the node the pipe arrives at (the pump's delivery node).  If that
# node is still a plain node, its type becomes the device and the row is
# tied to it.  If it is already an outlet or a supply, the type stays and
# the device remains on its table untied: the file had both, and the
# junction upstream of the device is not relabelled as the device.
def _tie_devices(sheet, by):
    for d in sheet['devices']:
        if d['type'] == 'PUMP':
            id_ = trim(d.get('out'))
        else:
            p = by.get(trim(d.get('pipe') or ''))
            id_ = trim(p.get('to')) if p is not None else ''
        if not len(id_) or id_ not in sheet['nodes']:
            continue
        d['node'] = id_
        if len(normal_type(sheet['nodes'][id_]['type'])):
            continue
        sheet['nodes'][id_]['type'] = d['type']
        d['tied'] = 1


# _mark_keepers -- a node a file defines, which no pipe names, stays on
# the NODES grid.  Without this a supply that only a pump names would
# vanish on save, and the pump would name a node the file no longer
# defines.
def _mark_keepers(sheet):
    end = {}
    for p in sheet['pipes']:
        if pipe_is_blank(p):
            continue
        for f in ('from', 'to'):
            end[trim(p.get(f))] = 1
    for id_, n in sheet['nodes'].items():
        n['keep'] = 1 if (not end.get(id_) and n.get('defined_in_file')) else 0


#==============================================================================
# Writing the grids back to .phc.
#==============================================================================

# cmd -- one command line, in the editor's padding.  Empty fields at the
# end are left off, so a node with no elevation yet is "NODE N1", which
# the reader reports as incomplete rather than as a nought nobody typed.
def cmd(word, *f):
    f = [x if x is not None else '' for x in f]
    while f and not len(trim(f[-1])):
        f.pop()
    return '%-9s %s' % (word, ' '.join(trim(x) for x in f))


# to_text -- the whole .phc file.  The map records, for each network line,
# the cell it came from, so a problem the reader reports can be shown there.
# reconcile runs first: a node type of PRV with no PRV row would save a
# type the file has no command for.
def to_text(sheet):
    reconcile(sheet)
    nodes = node_rows(sheet)
    nrow = dict((v, i) for i, v in enumerate(nodes))
    sup = supply_rows(sheet)
    srow = dict((v, i) for i, v in enumerate(sup))
    out = []
    sheet['map'] = {}
    sheet['at'] = {'node': {}, 'pipe': {}}

    def add(text, loc=None):
        out.append(text)
        if loc:
            sheet['map'][len(out)] = loc

    for note in sheet['notes']:
        add(note)
    if sheet['notes'] and nodes:
        add('')

    for id_ in nodes:
        n = sheet['nodes'][id_]
        t = normal_type(n['type'])
        row = nrow.get(id_)
        loc = {'tab': 'NODES', 'row': row, 'col': 'elev', 'node': id_}
        if t == 'SUPPLY':
            loc = {'tab': 'SUPPLIES', 'row': srow.get(id_), 'col': 'static', 'node': id_}
            pairs = list(n.get('pairs') or [])
            while pairs and not len(trim(pairs[-1])):
                pairs.pop()
            if not len(trim(n['elev'])):
                line = cmd('WATER', id_)
            elif not len(trim(n['static'])):
                line = cmd('WATER', id_, n['elev'])
            else:
                line = cmd('WATER', id_, n['elev'], n['static'], *pairs)
        elif is_outlet(t):
            if len(trim(n['min_flow'])):
                mn = trim(n['min_flow'])
            elif len(trim(n['min_p'])):
                mn = '-' + trim(n['min_p'])
            else:
                mn = ''
            loc['col'] = 'min_flow' if len(trim(n['min_flow'])) \
                else ('min_p' if len(trim(n['min_p'])) else 'k')
            if not len(trim(n['elev'])):
                line = cmd(t, id_)
            elif not len(mn):
                line = cmd(t, id_, n['elev'])
            else:
                line = cmd(t, id_, n['elev'], mn, n['k'])
        else:
            # A plain node, and a node that hosts a device: the device is
            # its own command.  The node still has an elevation.
            line = cmd('NODE', id_, n['elev']) if len(trim(n['elev'])) \
                else cmd('NODE', id_)
        if len(n.get('note') or ''):
            line = line + ' ' + n['note']
        add(line, loc)
        sheet['at']['node'][id_] = len(out)

        if not len(trim(n['fixed_flow'])):
            continue
        fname = trim(n['fixed_name']) if len(trim(n['fixed_name'])) else 'FF-' + id_
        if is_outlet(t):
            mp = n['fixed_min_p']
        else:
            mp = n['min_p'] if len(trim(n['min_p'])) else n['fixed_min_p']
        ff = [fname, id_, trim(n['fixed_flow'])]
        if mp is not None and len(trim(mp)):
            ff.append(trim(mp))
        add(cmd('FIXEDFLOW', *ff),
            {'tab': 'NODES', 'row': row, 'col': 'fixed_flow', 'node': id_})

    prev = None
    for i in range(len(sheet['pipes'])):
        p = sheet['pipes'][i]
        if pipe_is_blank(p):
            continue
        if not len(trim(p['pipe'])):
            continue
        type_ = trim(p['type']).upper()
        c = trim(p['c'])
        key = type_ + '\0' + c
        if len(type_) and prev != key:
            line = cmd('USE', type_, c) if len(c) else cmd('USE', type_)
            if len(p.get('use_note') or ''):
                line = line + ' ' + p['use_note']
            add(line, {'tab': 'SYSTEM', 'row': i,
                       'col': ('c' if len(c) and type_ == trim(p['type']).upper()
                               else 'type'), 'pipe': i})
            prev = key
        fits = [x for x in re.split(r'\s+', trim(p['fittings'])) if len(x)]
        line = cmd('PIPE', trim(p['pipe']), trim(p['from']), trim(p['to']),
                   trim(p['length']), trim(p['diam']), *fits)
        if len(p.get('note') or ''):
            line = line + ' ' + p['note']
        add(line, {'tab': 'SYSTEM', 'row': i, 'col': 'pipe', 'pipe': i})
        sheet['at']['pipe'][i] = len(out)
        if len(trim(p['eqv'])):
            add(cmd('EQV', trim(p['pipe']), trim(p['eqv'])),
                {'tab': 'SYSTEM', 'row': i, 'col': 'eqv', 'pipe': i})

    for type_ in DEVICE_TYPES:
        rows = device_rows(sheet, type_)
        for i, d in enumerate(rows):
            loc = {'tab': 'PRESSURE DEVICES', 'device': type_, 'row': i,
                   'col': 'pipe', 'node': d['node']}
            line = _device_line(d, loc)
            if len(d.get('note') or ''):
                line = line + ' ' + d['note']
            add(line, loc)
            if type_ == 'PUMP':
                duty_name = d['name'] or ('P-' + (d['node'] or ''))
            elif type_ == 'BP':
                duty_name = d['pipe']
            else:
                duty_name = ''
            if len(duty_name) and (len(trim(d['duty_flow'])) or
                                   len(trim(d['duty_p']))):
                l2 = dict(loc)
                l2['col'] = 'duty_flow'
                add(cmd('PUMPDUTY', duty_name, d['duty_flow'], d['duty_p']), l2)

    for extra in sheet['extras']:
        add(extra)
    network = '\n'.join(out)
    if len(network) and not network.endswith('\n'):
        network = network + '\n'
    sheet['network'] = network
    sheet['text'] = editor.join_file(sheet['settings'], network)[0]
    return sheet['text']


# _device_line -- the .phc command for one device, and the cell a missing
# field should point at (loc is updated).
def _device_line(d, loc):
    type_ = d['type']
    pairs = list(d.get('pairs') or [])
    while pairs and not len(trim(pairs[-1])):
        pairs.pop()
    if type_ == 'PUMP':
        name = trim(d['name']) if len(trim(d['name'])) else 'P-' + d['node']
        loc['col'] = 'in' if not len(trim(d['in'])) else \
            ('churn' if not len(trim(d['churn'])) else 'q1')
        return cmd('PUMP', name, d['in'], d['out'], d['churn'], *pairs)
    if type_ == 'BP':
        loc['col'] = 'pipe' if not len(trim(d['pipe'])) else 'churn'
        return cmd('BP', d['pipe'], d['churn'], *pairs)
    if type_ in ('BFP', 'PRV'):
        loc['col'] = 'pipe' if not len(trim(d['pipe'])) else 'q1'
        return cmd(type_, d['pipe'], *pairs)
    if type_ == 'OPP':
        loc['col'] = 'pipe' if not len(trim(d['pipe'])) else 'drop'
        if len(trim(d['cd'])):
            return cmd('OPP', d['pipe'], d['drop'], d['cd'])
        return cmd('OPP', d['pipe'], d['drop'])
    if type_ == 'OFD':
        loc['col'] = 'pipe' if not len(trim(d['pipe'])) else 'bore'
        if len(trim(d['cd'])):
            return cmd('OFD', d['pipe'], d['bore'], d['cd'])
        return cmd('OFD', d['pipe'], d['bore'])
    if type_ == 'PRA':
        loc['col'] = 'pipe' if not len(trim(d['pipe'])) else 'ratio'
        # A band with no minimum is written as minimum 0: the reader
        # treats 0 as "no minimum", and an empty field would slide the
        # band into it.
        f = [d['pipe'], d['ratio']]
        if len(trim(d['band'])):
            f.append(trim(d['min_inlet']) if len(trim(d['min_inlet'])) else '0')
            f.append(trim(d['band']))
        elif len(trim(d['min_inlet'])):
            f.append(trim(d['min_inlet']))
        return cmd('PRA', *f)
    return cmd(type_)


#------------------------------------------------------------------------------
# problems -- what the grids can say that a generated line would only say
# sideways.  An outlet has one minimum in the file, so MIN FLOW and MIN P
# together would keep one and drop the other; that is reported here, on
# the cell, before the file is trusted.  K or MIN FLOW on a plain node has
# nowhere to go, and is reported for the same reason.
#------------------------------------------------------------------------------
def problems(sheet):
    it = []
    ids = node_rows(sheet)
    row = dict((v, i) for i, v in enumerate(ids))
    for id_ in ids:
        n = sheet['nodes'][id_]
        t = normal_type(n['type'])
        loc = {'tab': 'NODES', 'row': row[id_], 'col': 'type', 'node': id_}
        # Before to_text has built the line map there is none: the Perl's
        # look-up autovivifies and gives undef, so None here, not a KeyError.
        line = (sheet['at'].get('node') or {}).get(id_)
        if is_outlet(t) and len(trim(n['min_flow'])) and len(trim(n['min_p'])):
            l2 = dict(loc)
            l2['col'] = 'min_p'
            it.append({
                'what': 'NODE %s: AN OUTLET TAKES MIN FLOW OR MIN P, NOT BOTH' % id_,
                'why': 'THE FILE HAS ONE MINIMUM FOR AN OUTLET: A FLOW, OR, '
                       'WRITTEN AS A NEGATIVE FLOW, A PRESSURE. CLEAR ONE OF '
                       'THE TWO CELLS.',
                'field': 'MIN P', 'line': line, 'loc': l2})
        elif not is_outlet(t) and (len(trim(n['min_flow'])) or len(trim(n['k']))):
            col = 'k' if len(trim(n['k'])) else 'min_flow'
            l2 = dict(loc)
            l2['col'] = col
            it.append({
                'what': 'NODE %s: MIN FLOW AND K BELONG TO A SPRINKLER, '
                        'HYDRANT OR HOSE REEL' % id_,
                'why': "THE NODE'S TYPE IS BLANK, A SUPPLY OR A DEVICE, SO "
                       'THOSE CELLS ARE NOT WRITTEN. SET THE TYPE, OR CLEAR '
                       'THEM.',
                'field': 'NODE TYPE', 'line': line, 'loc': l2})
    return it


# locate -- the cell a validation row points at.  The map knows the line;
# the message names the field when it is not the line's first one.
def locate(sheet, item):
    if item.get('loc'):
        return item['loc']
    if (item.get('tab') or '') == 'PROJECT':
        return {'tab': 'PROJECT', 'field': item.get('field')}
    line = item.get('line')
    if line is None or not sheet['map'].get(line):
        return None
    loc = dict(sheet['map'][line])
    msg = (item.get('what') or '').upper()
    if loc.get('node') and 'ELEVATION' in msg:
        ids = node_rows(sheet)
        row = dict((v, i) for i, v in enumerate(ids))
        if loc['node'] in row:
            l2 = dict(loc)
            l2.update({'tab': 'NODES', 'row': row[loc['node']], 'col': 'elev'})
            return l2
    if 'STATIC' in msg and loc.get('tab') == 'SUPPLIES':
        loc['col'] = 'static'
    elif 'MINFLOW' in msg:
        loc['col'] = 'min_flow'
        if loc.get('node'):
            loc['tab'] = 'NODES'
    elif 'FITTING' in msg:
        loc['col'] = 'fittings'
    elif re.search(r'PIPE TYPE|UNKNOWN PIPE', msg):
        loc['col'] = 'type'
    elif re.search(r'\bLENGTH\b', msg):
        loc['col'] = 'length'
    elif re.search(r'\bSIZE\b|\bBORE\b', msg):
        loc['col'] = 'bore' if (loc.get('tab') == 'PRESSURE DEVICES') else 'diam'
    return loc
