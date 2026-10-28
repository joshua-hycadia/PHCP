#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# check_lisp.pl -- structural checks on the AutoCAD exporter, without AutoCAD.
#
#   perl tools/check_lisp.pl [autocad/phcp_export.lsp]
#
# No AutoLISP interpreter runs here, so the exporter cannot be executed until
# it is loaded in AutoCAD.  What can be checked is checked: the file is read
# as the Lisp reader reads it -- strings ("..." with \ escapes) and comments
# (; to the end of the line) skipped -- and
#   - every bracket is matched, and no top-level form is left open;
#   - every phcp:... function called is defined (a typo in a helper's name is
#     otherwise found only when that line runs in AutoCAD);
#   - every command c:... named in the load message exists.
#==============================================================================
use strict;
use warnings;
use FindBin;

my $file = shift // "$FindBin::Bin/../autocad/phcp_export.lsp";
open my $fh, '<', $file or die "$file: $!\n";
my $src = do { local $/; <$fh> };
close $fh;

# The code with strings and comments blanked out, so brackets and names are
# seen as the reader sees them.  Line breaks are kept for the line numbers.
my $code = '';
my @strings;
my ($i, $n) = (0, length $src);
while ($i < $n) {
    my $c = substr $src, $i, 1;
    if ($c eq ';') { my $e = index $src, "\n", $i; $e = $n if $e < 0; $i = $e; next }
    if ($c eq '"') {
        my $j = $i + 1;
        $j += substr($src, $j, 1) eq '\\' ? 2 : 1 while $j < $n && substr($src, $j, 1) ne '"';
        push @strings, substr($src, $i + 1, $j - $i - 1);
        $code .= '""';
        $code .= "\n" x (() = substr($src, $i, $j - $i + 1) =~ /\n/g);
        $i = $j + 1;
        next;
    }
    $code .= $c;
    $i++;
}

my ($pass, $fail) = (0, 0);
sub is { my ($name, $ok, $why) = @_; printf "  %-66s %s\n", $name, $ok ? 'ok' : '*** FAIL';
         print "      $why\n" if !$ok && defined $why; $ok ? $pass++ : $fail++ }

# Brackets.
my ($depth, $line, $bad) = (0, 1, '');
for my $ch (split //, $code) {
    $line++ if $ch eq "\n";
    if ($ch eq '(') { $depth++ }
    elsif ($ch eq ')') { $depth--; $bad ||= "a ) with nothing open, line $line" if $depth < 0 }
}
is('every bracket matched', !$bad && $depth == 0, $bad || "$depth left open at the end");

# Functions.
my %def = map { lc($_) => 1 } $code =~ /\(defun\s+([^\s()]+)/gi;
my %called;
$called{ lc $1 }++ while $code =~ /\(\s*(phcp:[A-Za-z0-9\-]+)/g;
# 'phcp:x quoted as a function argument, as in (mapcar 'phcp:x ...)
$called{ lc $1 }++ while $code =~ /'(phcp:[A-Za-z0-9\-]+)/g;
my @undef = grep { !$def{$_} } sort keys %called;
is(sprintf('every phcp: function called is defined (%d called)', scalar keys %called), !@undef, "@undef");
my @unused = grep { !$called{$_} && !/^c:/ } sort keys %def;
is('every phcp: function defined is used', !@unused, "@unused");

# Commands named in the load message.
my ($msg) = grep { /Commands:/ } @strings;
my @cmds = $msg ? ($msg =~ /\b(PHCP[A-Z]+)\b/g) : ();
my @missing = grep { !$def{ lc "c:$_" } } @cmds;
is(sprintf('the %d commands in the load message all exist', scalar @cmds), @cmds && !@missing, "@missing");

# The model it writes is .phc: no .hcx section words remain.
my @hcx = grep { /^(NODES|PIPES|SUPPLIES|DISCHARGES|END|OPTIONS)$/ || /TYPE=|FIT=|\bK=/ } @strings;
is('it writes .phc, not .hcx (no .hcx block words or KEY= fields)', !@hcx, join ' | ', @hcx);

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
