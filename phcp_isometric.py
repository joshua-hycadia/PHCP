#!/usr/bin/env python3
# phcp_isometric.py -- the network drawn, rather than typed: a port of
# phcp_isometric.pl.  PHCP - the Perl Hydraulic Calculation Program (the
# Python port keeps the name; the window is hardycross.window, this
# file the one that opens it).
#
# Usage:  phcp_isometric [model.phc]
#
# A fork of phcp_editor.py.  That file is not modified: hardycross.win is
# loaded for the PROJECT tab, the results, the database and the file
# commands, and the window built here has no NETWORK tab.  The model
# still lives in the editor's buffer, because the calculation is the
# .phc text.  The drawing writes that text.

import sys

import hardycross.window.isometric      # noqa: F401 -- the fork's patches
from hardycross import win


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    win.main(argv[0] if argv else None)


if __name__ == '__main__':
    main()
