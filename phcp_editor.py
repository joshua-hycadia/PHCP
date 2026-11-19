#!/usr/bin/env python3
# phcp_editor.py -- the PHCP editor window: the whole of the former
# Perl program, ported.  PHCP - the Python Hydraulic Calculation Program
# (the name is historical; the window is hardycross.window, this file
# the one that opens it).
#
# Usage:  phcp_editor [file.phc ...]
#         -v, --version      print the version and exit
#         -h, --help         print the usage and exit
#
# One instance per command line: the window is a singleton, as in Perl
# (a second call of the program opens a second process and a second
# window).

import sys

import hardycross.win


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    hardycross.win.main(argv)


if __name__ == '__main__':
    main()
