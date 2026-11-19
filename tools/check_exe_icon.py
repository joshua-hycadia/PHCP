#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# check_exe_icon.py -- does a built .exe carry the PHCP icon?
#
#   python3 tools/check_exe_icon.py <program.exe> [icon.ico]   (icon: data/phcp.ico)
#
# WHY THIS EXISTS
#   The v1.0.0 build log said the icon had been set, yet both programs showed
#   the packager's stock icon in Explorer: the tool that wrote the icon had
#   written a resource table that still pointed at the old pictures.  So the
#   finished .exe itself is read here, the way Explorer reads it, and its
#   icon compared byte for byte with the .ico file.
#
#   Explorer shows a program's FIRST icon group: named groups sort before
#   numbered ones, names alphabetically, numbers in order.  That group lists
#   its pictures by number; each picture is an RT_ICON resource holding the
#   same bytes as the matching image in a .ico file.  So the check is:
#     - the first group lists as many pictures as the .ico holds, of the same
#       sizes, in the same order
#     - each picture's bytes are the .ico image's bytes
#
#   Pure Python, so it runs anywhere, on any .exe, without Windows.  Exits 0
#   if the icon matches, 1 with the reason if not.  build_windows.py runs it
#   on every .exe it builds, and CI runs it on the built programs.
#==============================================================================

import struct
import sys


class Bad(Exception):
    pass


def size(p):
    # "32x32" for a picture; a width or height of 0 in the tables means 256.
    return '%dx%d' % (p['w'] or 256, p['h'] or 256)


def slurp(f):
    try:
        with open(f, 'rb') as fh:
            return fh.read()
    except OSError as e:
        raise Bad('check_exe_icon: cannot read %s: %s' % (f, e.strerror))


def ico_images(b, ico):
    # The pictures in a .ico file, in file order.
    #   header: reserved 0, type 1, count; then 16 bytes per picture:
    #   width, height, colours, reserved, planes, bits, bytes, offset.
    zero, typ, n = struct.unpack_from('<HHH', b, 0)
    if not (zero == 0 and typ == 1 and n):
        raise Bad('check_exe_icon: %s is not an icon file' % ico)
    out = []
    for i in range(n):
        w, h, _, _, _, _, ln, off = struct.unpack_from('<BBBBHHII', b, 6 + 16 * i)
        out.append({'w': w, 'h': h, 'data': b[off:off + ln]})
    return out


def exe_icon(b, exe):
    # The name of a program's first icon group, then its pictures.
    if b[:2] != b'MZ':
        raise Bad('check_exe_icon: %s is not a Windows program' % exe)
    pe = struct.unpack_from('<I', b, 0x3C)[0]
    if b[pe:pe + 4] != b'PE\0\0':
        raise Bad('check_exe_icon: %s has no PE header' % exe)
    nsec = struct.unpack_from('<H', b, pe + 6)[0]
    optsz = struct.unpack_from('<H', b, pe + 20)[0]
    # The data directories follow the optional header's fixed part, which is
    # 96 bytes for a 32-bit program and 112 for a 64-bit one; the resource
    # table is the third directory.
    magic = struct.unpack_from('<H', b, pe + 24)[0]
    dirs = pe + 24 + (112 if magic == 0x20b else 96)
    rva = struct.unpack_from('<I', b, dirs + 2 * 8)[0]
    if not rva:
        raise Bad('check_exe_icon: %s has no resources' % exe)

    # Section table: to turn an address in memory (RVA) into a file offset.
    sec = []
    for i in range(nsec):
        vsize, va, rsize, ptr = struct.unpack_from('<IIII', b, pe + 24 + optsz + 40 * i + 8)
        sec.append((va, max(vsize, rsize), ptr))

    def at(r):
        for va, ln, ptr in sec:
            if va <= r < va + ln:
                return ptr + r - va
        raise Bad('check_exe_icon: address %d is in no section' % r)

    root = at(rva)

    def level(d):
        # One level of the resource tree: (key, sort key, offset) per entry,
        # sorted as Windows looks them up.  Offsets are from the tree's root;
        # the high bit marks a name (instead of a number) or a sub-directory.
        named, ids = struct.unpack_from('<HH', b, root + d + 12)
        e = []
        for i in range(named + ids):
            id_, off = struct.unpack_from('<II', b, root + d + 16 + 8 * i)
            if id_ & 0x80000000:
                p = root + (id_ & 0x7fffffff)
                ln = struct.unpack_from('<H', b, p)[0]
                name = ''.join(chr(c) for c in struct.unpack_from('<%dH' % ln, b, p + 2))
                e.append((name, '0' + name, off))
            else:
                e.append(('#%d' % id_, '1%010d' % id_, off))
        return sorted(e, key=lambda x: x[1])

    def data(off):
        # The bytes of the first language of a named resource.
        if off & 0x80000000:
            off = level(off & 0x7fffffff)[0][2]
        drva, ln = struct.unpack_from('<II', b, root + off)
        p = at(drva)
        return b[p:p + ln]

    typ = {k: off for k, _, off in level(0)}
    if not (typ.get('#14') and typ.get('#3')):
        raise Bad('check_exe_icon: %s has no icon group' % exe)
    first = level(typ['#14'] & 0x7fffffff)[0]
    pic = {k: off for k, _, off in level(typ['#3'] & 0x7fffffff)}

    # The group: reserved, type, count; then 14 bytes per picture:
    # width, height, colours, reserved, planes, bits, bytes, picture number.
    g = data(first[2])
    n = struct.unpack_from('<H', g, 4)[0]
    pics = []
    for i in range(n):
        w, h, _, _, _, _, _, id_ = struct.unpack_from('<BBBBHHIH', g, 6 + 14 * i)
        if not pic.get('#%d' % id_):
            raise Bad('check_exe_icon: picture #%d of the icon group is missing' % id_)
        pics.append({'w': w, 'h': h, 'data': data(pic['#%d' % id_])})
    return first[0], pics


def check(exe, ico='data/phcp.ico'):
    """0 and a line saying so when exe carries ico, else 1 and the reasons."""
    want = ico_images(slurp(ico), ico)
    group, got = exe_icon(slurp(exe), exe)
    bad = []
    if len(got) != len(want):
        bad.append('%d pictures in the first icon group (%s), %d in %s'
                   % (len(got), group, len(want), ico))
    for i in range(min(len(got), len(want))):
        g, w = got[i], want[i]
        if g['data'] != w['data']:
            bad.append('picture %d is %s, %d bytes; %s has %s, %d bytes'
                       % (i + 1, size(g), len(g['data']), ico, size(w), len(w['data'])))
    if bad:
        return 1, ['check_exe_icon: %s does NOT carry %s' % (exe, ico)] + ['  ' + x for x in bad]
    return 0, ['check_exe_icon: %s carries %s - icon group %s, %d pictures (%s), bytes identical'
               % (exe, ico, group, len(got), ' '.join(size(p) for p in got))]


def main():
    args = sys.argv[1:]
    if not args:
        sys.stderr.write('usage: check_exe_icon.py program.exe [icon.ico]\n')
        sys.exit(255)
    exe = args[0]
    ico = args[1] if len(args) > 1 else 'data/phcp.ico'
    try:
        rc, lines = check(exe, ico)
    except (Bad, struct.error) as e:
        sys.stderr.write('%s\n' % e)
        sys.exit(255)
    for line in lines:
        print(line)
    sys.exit(rc)


if __name__ == '__main__':
    main()
