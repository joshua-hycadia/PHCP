#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# Editor.pm -- everything the .phc text editor decides, without Tk.
#
# phcp_editor.pl is the window: it draws text and tables, takes keys and calls
# this module for every decision.  Keeping the decisions here means each one
# can be tested headless (tools/test_editor.pl) and the window stays thin
# enough to check by reading.  Nothing in this module knows a widget exists.
#
# What it answers:
#
#   check_buffer   every line's status (ok / incomplete / error) and message
#   diagnostics    the ERRORS, WARNINGS and NODES lists beside the editor
#   context_at     what is in force at a line: USE, UNITS, METHOD, options,
#                  defined nodes -- what HardyCross::Phc::check_line needs
#   proposal       the likely next line after the one just finished
#   choices        the pick list for the cursor's field
#   status_at      the status bar: the field template and the line's message
#   colour_spans   where on a line the command word and the comment are
#   solve_text     solve the buffer; the report, or the error and its line
#   results_at     the solved figures for the element on a line
#   result_tables  the PIPES, NODES and OUTLETS tables under the editor
#   pipe_columns   every pipe column, with which are shown by default
#   sort_rows      a table sorted on one column, as a click on its heading does
#   units_of / set_units   the file's units, read and written as UNITS lines
#   load_file / write_report_file
#
# Every check is made by HardyCross::Phc, the code that reads a .phc file for
# a solve, so the editor cannot call a line good that the solver refuses.

package HardyCross::Editor;

use strict;
use warnings;
use HardyCross;
use HardyCross::Parse;
use HardyCross::Phc;
use HardyCross::Report;

my $GW = $HardyCross::GAMMA_W;

# lines -- the buffer as lines, numbered from 1 ($l[0] is unused).
sub lines {
    my $text = shift // '';
    return (undef, split /\n/, $text, -1);
}

#==============================================================================
# The buffer as a whole.
#==============================================================================

#------------------------------------------------------------------------------
# scan -- one pass over the buffer: each line's analysis and what is in force.
#
# Returns {
#   a       => [ per line, HardyCross::Phc::analyse result ],
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
sub scan {
    my $text = shift;
    my (undef, @l) = lines($text);
    my %s = (a => [undef], use_at => [undef], units => { %HardyCross::Phc::UNIT_DEFAULT },
             options => {}, method => 'HW', nodes => {}, names => {}, used => {});
    my %unit_seen;
    my $use = { type => 'BORE' };
    for my $i (1 .. @l) {
        my $a = HardyCross::Phc::analyse($l[ $i - 1 ]);
        push @{ $s{a} }, $a;
        if ($a->{status} eq 'ok') {
            my ($k, @p) = ($a->{key}, @{ $a->{pos} });
            $use = { type => $p[0], c => $a->{opt}[0] } if $k eq 'USE';
            $s{units}{ $p[0] } = $p[1] if $k eq 'UNITS' && !$unit_seen{ $p[0] }++;
            $s{options}{ $p[0] } //= $p[1] if $k eq 'OPTION';
            $s{method} = $p[0] if $k eq 'METHOD';
            for my $n (HardyCross::Phc::nodes_defined($a)) {
                $s{nodes}{$n} //= $i;
                $s{names}{$n} //= $i;
            }
            $s{names}{$_} //= $i for HardyCross::Phc::names_defined($a);
            $s{used}{$_} //= $i for HardyCross::Phc::nodes_used($a);
        }
        push @{ $s{use_at} }, $use;
    }
    return \%s;
}

# context_at -- the check_line context for line $n.
sub context_at {
    my ($text, $n, $scan) = @_;
    $scan ||= scan($text);
    return { use => $scan->{use_at}[$n] || { type => 'BORE' }, units => $scan->{units},
             options => $scan->{options}, method => $scan->{method}, nodes => $scan->{nodes} };
}

#------------------------------------------------------------------------------
# check_buffer -- every line checked.
#
#   $editing  the line the cursor is on (optional): an incomplete line there
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
sub check_buffer {
    my ($text, $editing) = @_;
    my (undef, @l) = lines($text);
    my $scan = scan($text);
    my (%set, %node, %name, %r);
    $r{lines} = [undef];
    for my $i (1 .. @l) {
        my $chk = cached_check($l[ $i - 1 ], context_at($text, $i, $scan));
        my ($st, $msg) = ($chk->{status}, $chk->{message});
        my $a = $scan->{a}[$i];
        if ($st eq 'ok' && $a->{key}) {
            for my $k (HardyCross::Phc::setting_keys($a)) {
                if ($set{$k}) { ($st, $msg) = ('error', "$k IS ALREADY SET ON LINE $set{$k}") }
                else          { $set{$k} = $i }
            }
            for my $n (HardyCross::Phc::nodes_defined($a)) {
                if ($node{$n}) { ($st, $msg) = ('error', "NODE $n IS ALREADY DEFINED ON LINE $node{$n}") }
                else           { $node{$n} = $i }
            }
            for my $n (HardyCross::Phc::names_defined($a)) {
                if ($name{$n}) { ($st, $msg) = ('error', "THE NAME $n IS ALREADY USED ON LINE $name{$n}") }
                else           { $name{$n} = $i }
            }
        }
        push @{ $r{lines} }, { status => $st, message => $msg };
        next if $st eq 'ok';
        next if $st eq 'incomplete' && defined $editing && $editing == $i;
        push @{ $r{problems} }, { line => $i, message => $msg };
    }
    $r{problems} ||= [];
    my $u = $scan->{used};
    $r{undefined} = [ map { { node => $_, line => $u->{$_} } }
                      sort { $u->{$a} <=> $u->{$b} } grep { !$scan->{nodes}{$_} } keys %$u ];
    my $d = $scan->{nodes};
    $r{unused} = [ map { { node => $_, line => $d->{$_} } }
                   sort { $d->{$a} <=> $d->{$b} } grep { !$u->{$_} } keys %$d ];
    return \%r;
}

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
my %CHECK_CACHE;
my $CACHE_LIMIT = 50_000;
sub cached_check {
    my ($line, $ctx) = @_;
    my $u = $ctx->{use} || {};
    my $key = join "\x00", $line, $u->{type} // '', $u->{c} // '', $ctx->{method} // '',
        (map { "$_=$ctx->{units}{$_}" } sort keys %{ $ctx->{units} || {} }),
        (map { "$_=$ctx->{options}{$_}" } sort keys %{ $ctx->{options} || {} });
    %CHECK_CACHE = () if keys %CHECK_CACHE > $CACHE_LIMIT;
    return $CHECK_CACHE{$key} //= do {
        my %c = %$ctx;
        delete $c{nodes};
        my $r = HardyCross::Phc::check_line($line, \%c);
        { status => $r->{status}, message => $r->{message} };
    };
}

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
# $net is the last solve, or undef; warnings need one.  Each entry carries the
# .phc line it belongs to, so a click can go there.
#------------------------------------------------------------------------------
sub diagnostics {
    my ($text, $net, $editing) = @_;
    my $chk  = check_buffer($text, $editing);
    my $scan = scan($text);
    my %d = (errors => $chk->{problems}, warnings => [], nodes => []);
    push @{ $d{nodes} }, { line => $_->{line}, message => "$_->{node} - USED, BUT NOT DEFINED" }
        for @{ $chk->{undefined} };
    push @{ $d{nodes} }, { line => $_->{line}, message => "$_->{node} - DEFINED, BUT NOTHING CONNECTS TO IT" }
        for @{ $chk->{unused} };
    return \%d unless $net;

    # A device's id is "<pipe>.<kind>" and its node "<pipe>~": either leads
    # back to the pipe's line.
    my $line = sub { my $id = shift; $id =~ s/[.~].*//; $scan->{names}{$id} };
    push @{ $d{warnings} }, { line => undef,
        message => 'THE SOLVE DID NOT CONVERGE: THE RESULTS MUST NOT BE USED' } unless $net->{converged};
    my $vl = $net->{opts}{vel_limit} // 6;
    for my $e (grep { $_->{kind} eq 'PIPE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        my $v = abs HardyCross::pipe_velocity($e->{q}, $e->{dia});
        push @{ $d{warnings} }, { line => $line->($e->{id}),
            message => sprintf('%s - VELOCITY %.2f M/S IS OVER THE LIMIT OF %g M/S', $e->{id}, $v, $vl) }
            if $v > $vl;
    }
    my $t = result_tables($net);
    for my $r (@{ $t->{outlets}{rows} }) {
        next unless $r->{keys}[-1] eq 'FAIL';
        push @{ $d{warnings} }, { line => $line->($r->{keys}[0]),
            message => sprintf('%s - BELOW ITS REQUIREMENT: %s AGAINST %s REQUIRED',
                               $r->{keys}[0], $r->{cells}[7], $r->{cells}[6]) };
    }
    push @{ $d{warnings} }, map { { line => undef, message => uc $_ } } @{ $net->{warnings} || [] };
    return \%d;
}

#==============================================================================
# The cursor's line.
#==============================================================================

#------------------------------------------------------------------------------
# proposal -- the line to offer after line $n, or undef.
#
# HardyCross::Phc::propose steps the names (P7 -> P8; a pipe starts where the
# last ended).  Here the name is stepped again, as often as needed, past any
# name the buffer already uses, so accepting a proposal never makes a
# duplicate.
#------------------------------------------------------------------------------
sub proposal {
    my ($text, $n) = @_;
    my (undef, @l) = lines($text);
    return undef unless $n >= 1 && $n <= @l;
    my $p = HardyCross::Phc::propose($l[ $n - 1 ]) // return undef;
    my $scan = scan($text);
    my ($word, $id, @rest) = split ' ', $p;
    for (1 .. 1000) {
        last unless $scan->{names}{$id};
        $id = HardyCross::Phc::step_id($id);
    }
    return join ' ', $word, $id, @rest;
}

# choices -- the pick list at column $col of line $n: [ [code, description] ].
sub choices {
    my ($text, $n, $col) = @_;
    my (undef, @l) = lines($text);
    return [] unless $n >= 1 && $n <= @l;
    my $ctx = context_at($text, $n);
    $ctx->{cursor} = $col;
    return HardyCross::Phc::check_line($l[ $n - 1 ], $ctx)->{choices} || [];
}

# status_at -- the status bar for the cursor at line $n, column $col:
# { template => { command, text, fields, current }, status, message }.
sub status_at {
    my ($text, $n, $col) = @_;
    my (undef, @l) = lines($text);
    return { status => 'ok', message => '', template => undef } unless $n >= 1 && $n <= @l;
    my $ctx = context_at($text, $n);
    $ctx->{cursor} = $col;
    my $r = HardyCross::Phc::check_line($l[ $n - 1 ], $ctx);
    return { status => $r->{status}, message => $r->{message}, template => $r->{template} };
}

#------------------------------------------------------------------------------
# colour_spans -- where the command word and the comment are on a line:
# ( [start, end, 'command'], [start, end, 'comment'] ), columns, end exclusive.
# The command word is coloured only when it IS a command.
#------------------------------------------------------------------------------
sub colour_spans {
    my $line = shift // '';
    my @s;
    my $cpos = index $line, '//';
    my $code = $cpos >= 0 ? substr($line, 0, $cpos) : $line;
    if ($code =~ /^(\s*)(\S+)/ && HardyCross::Phc::command_spec($2)) {
        push @s, [ length $1, length($1) + length($2), 'command' ];
    }
    push @s, [ $cpos, length $line, 'comment' ] if $cpos >= 0;
    return @s;
}

#==============================================================================
# Solving and results.
#==============================================================================

#------------------------------------------------------------------------------
# solve_text -- read and solve the buffer.
#
# Returns { ok, converged, net, report, error, line }: ok when it was read and
# solved (converged or not); error and its .phc line when it was not.
#------------------------------------------------------------------------------
sub solve_text {
    my ($text, $path) = @_;
    my $net = eval { HardyCross::Phc::read_string($text) };
    return error_result($@) unless $net;
    my $conv = eval { HardyCross::solve_model($net) };
    return error_result($@) unless defined $conv;
    $net->{converged} = $conv;
    return { ok => 1, converged => $conv, net => $net,
             report => HardyCross::Report::write_report($net, $conv, $path // 'UNTITLED.PHC') };
}

# error_result -- a model error as { error, line }; anything else is a bug and
# is passed on, so it is seen rather than shown as a model problem.
sub error_result {
    my $e = shift;
    die $e unless HardyCross::is_model_error($e);
    my $r = { ok => 0, error => uc $e->{msg} };
    $r->{line} = $1 if $e->{msg} =~ /^line (\d+): /;
    return $r;
}

#------------------------------------------------------------------------------
# display_units -- how figures are shown: flows and pressures in the file's
# units, lengths in its LENGTH unit, elevations in its ELEVATION unit,
# velocity in m/s.  The network holds metres, L/min and kPa internally.
#------------------------------------------------------------------------------
my %TO_METRE = (MM => 0.001, CM => 0.01, M => 1, IN => 0.0254, FT => 0.3048);
my %LABEL = (LPM => 'L/MIN', LPS => 'L/S', M3H => 'M3/H', GPM => 'GPM',
             KPA => 'KPA', BAR => 'BAR', MPA => 'MPA', PSI => 'PSI', M => 'M HEAD');
sub display_units {
    my $net = shift;
    my $u = $net->{phc_units} || { LENGTH => uc $net->{u_len}, ELEVATION => uc $net->{u_len} };
    return {
        qf => $net->{f_flow}, pf => $net->{f_pres},
        q  => $LABEL{ uc $net->{u_flow} } // uc $net->{u_flow},
        p  => $LABEL{ uc $net->{u_pres} } // uc $net->{u_pres},
        lf => $TO_METRE{ $u->{LENGTH} } // 1,    l => $u->{LENGTH},
        ef => $TO_METRE{ $u->{ELEVATION} } // 1, e => $u->{ELEVATION},
        qdp => $net->{f_flow} > 1.5 ? 3 : 1, pdp => $net->{f_pres} > 1.5 ? 3 : 1,
    };
}

#------------------------------------------------------------------------------
# results_at -- the solved figures for the element or node on a line, as one
# line of text in the model's units, or undef when the line names nothing in
# the solved network (a setting, a blank, an element added since the solve).
#------------------------------------------------------------------------------
sub results_at {
    my ($net, $line) = @_;
    return undef unless $net;
    my $a = HardyCross::Phc::analyse($line // '');
    return undef unless $a->{status} eq 'ok' && $a->{key};
    my $u = display_units($net);
    my ($k, $id) = ($a->{key}, $a->{pos}[0]);
    my %el = map { $_->{id} => $_ } grep { $_->{id} } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    my %ni = map { $net->{nodes}[$_]{id} => $_ } 1 .. $#{ $net->{nodes} };
    my $p  = sub { my $i = shift; ($net->{nodes}[$i]{h} - $GW * $net->{nodes}[$i]{z}) / $u->{pf} };
    my $nm = sub { $net->{nodes}[ shift ]{id} };
    my $qs = sub { sprintf '%.*f %s', $u->{qdp}, $_[0] / $u->{qf}, $u->{q} };
    my $ps = sub { sprintf '%.*f %s', $u->{pdp}, $_[0], $u->{p} };

    if ($k eq 'PIPE' || $k eq 'CHANGEPIPE' || $k eq 'EQV') {
        my $e = $el{$id} or return undef;
        my $v = abs HardyCross::pipe_velocity($e->{q}, $e->{dia});
        my ($b, $t) = $e->{q} >= 0 ? ($e->{n1}, $e->{n2}) : ($e->{n2}, $e->{n1});
        return sprintf '%s  Q %s  V %.2f M/S  %s %s -> %s %s', $id, $qs->(abs $e->{q}), $v,
            $nm->($b), $ps->($p->($b)), $nm->($t), $ps->($p->($t));
    }
    if ($k eq 'FIXEDFLOW') {
        my ($f) = grep { $_->{id} eq $id } @{ $net->{fixed} || [] } or return undef;
        return sprintf '%s  FIXED %s AT %s%s', $id, $qs->($f->{q}), $ps->($p->($f->{n1})),
            defined $f->{preq} ? sprintf(' (REQUIRED %.*f)', $u->{pdp}, $f->{preq} / $u->{pf}) : '';
    }
    if ($k =~ /^(SPRINKLER|HYDRANT|HREEL)\z/ && $el{$id}) {
        my $e = $el{$id};
        return sprintf '%s  DISCHARGE %s AT %s (REQUIRED %.*f)', $id, $qs->(abs $e->{q}),
            $ps->($p->($e->{n1})), $u->{pdp}, $e->{preq} / $u->{pf};
    }
    if ($k eq 'WATER' && $el{$id}) {
        return sprintf '%s  SUPPLIES %s AT %s', $id, $qs->(abs $el{$id}{q}), $ps->($p->($el{$id}{n2}));
    }
    if (HardyCross::Phc::command_spec($k)->{kind} eq 'device' || $k eq 'PUMP') {
        my $e = $el{ $k eq 'PUMP' ? $id : "$id.$k" } or return undef;
        return sprintf '%s  Q %s  %s %s -> %s %s', $e->{id}, $qs->($e->{q}),
            $nm->($e->{n1}), $ps->($p->($e->{n1})), $nm->($e->{n2}), $ps->($p->($e->{n2}));
    }
    if (defined $ni{$id}) {
        my $z = $net->{nodes}[ $ni{$id} ]{z} / $u->{ef};
        return sprintf '%s  PRESSURE %s, ELEVATION %.3f %s', $id, $ps->($p->($ni{$id})), $z, $u->{e};
    }
    return undef;
}

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
sub pipe_columns {
    my $u = shift;
    my ($q, $p, $l) = ($u->{q}, $u->{p}, $u->{l});
    my $col = sub { my ($key, $head, $desc, $unit, $align, $show) = @_;
        { key => $key, head => $head, desc => $desc, unit => $unit, align => $align, show => $show } };
    return (
        { %{ $col->('NAME', 'NAME', 'PIPE NAME', '', 'w', 1) }, fixed => 1 },
        $col->('SNODE',   'SNODE',   'START NODE',                         '',      'w', 1),
        $col->('ENODE',   'ENODE',   'END NODE',                           '',      'w', 1),
        $col->('NOM',     'NOM',     'NOMINAL SIZE',                       'MM',    'e', 1),
        $col->('ID',      'I.D.',    'ID - INTERNAL DIAMETER',             'MM',    'e', 1),
        $col->('MAT',     'MAT',     'MAT - PIPE MATERIAL',                '',      'w', 1),
        $col->('C',       'C',       'C - C FACTOR OR ABSOLUTE ROUGHNESS', '',      'e', 1),
        $col->('L',       'L',       'L - PIPE LENGTH',                    $l,      'e', 1),
        $col->('F',       'F',       'F - FITTING EQV LENGTH',             $l,      'e', 1),
        $col->('T',       'T',       'T - TOTAL LENGTH',                   $l,      'e', 1),
        $col->('K',       'FIT K',   'K - FITTING LOSS CONSTANT',          '',      'e', 1),
        $col->('Q',       'Q',       'Q - FLOW',                           $q,      'e', 1),
        $col->('PF',      'PF',      'PF - FRICTION LOSS',                 $p,      'e', 1),
        $col->('PFX',     'PF/M',    'PF/X - FRICTION LOSS/DISTANCE',      "$p/M",  'e', 0),
        $col->('PE',      'PE',      'PE - ELEVATION LOSS',                $p,      'e', 0),
        $col->('PS',      'PS',      'PS - DEVICE PRESSURE LOSS',          $p,      'e', 1),
        $col->('PV',      'PV',      'PV - VELOCITY PRESSURE',             $p,      'e', 0),
        $col->('VEL',     'VEL',     'VEL - VELOCITY',                     'M/S',   'e', 1),
        $col->('RE',      'RE',      'RE - REYNOLDS NUMBER',               '',      'e', 0),
        $col->('FD',      'F',       'F - DARCY FRICTION FACTOR',          '',      'e', 0),
        $col->('FORMULA', 'FORMULA', 'FRICTION FORMULA',                   '',      'w', 0),
    );
}

sub result_tables {
    my $net = shift or return {};
    my $u = display_units($net);
    my $o = $net->{opts};
    my $dw = ($o->{method} // 'HW') eq 'DW';
    my $node = sub { $net->{nodes}[ shift ] };
    my $gauge = sub { my $n = $node->(shift); ($n->{h} - $GW * $n->{z}) / $u->{pf} };
    my $num = sub { my ($v, $dp) = @_; [ sprintf('%.*f', $dp, $v), $v ] };
    my $txt = sub { my $t = uc(shift // ''); [ $t, $t ] };
    my $none = [ '-', -1e300 ];
    my $row = sub { my ($cells, $act) = @_;
        { cells => [ map { $_->[0] } @$cells ], keys => [ map { $_->[1] } @$cells ], active => $act } };
    my %el = map { $_->{id} => $_ } grep { $_->{id} } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    my %t;

    #------------------------------------------------------------ PIPES
    # Written in the direction of flow, as the report's pipe schedule is:
    # SNODE upstream, Q positive, PE the pressure lost climbing to ENODE.  PF
    # is friction alone (a K-factor loss is shown through FIT K); PS is the
    # loss across a device placed in the pipe -- a BFP, PRV, plate or ratio
    # valve, or a pump's gain, which is negative.
    $t{pipes}{columns} = [ pipe_columns($u) ];
    for my $e (grep { $_->{kind} eq 'PIPE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        my $fwd = $e->{q} >= 0;
        my ($b, $f) = $fwd ? ($e->{n1}, $e->{n2}) : ($e->{n2}, $e->{n1});
        my ($hf) = HardyCross::elem_hf($e, $e->{q}, $o);
        my $v   = abs HardyCross::pipe_velocity($e->{q}, $e->{dia});
        my $pv  = 0.5 * $v ** 2;                              # rho v^2 / 2, kPa
        my $pk  = ($e->{kfit} // 0) * $pv;                   # the K-factor part
        my $pf  = (abs($hf) - $pk) / $u->{pf};
        my $lt  = $e->{len} + $e->{eqv};                     # metres
        my $pe  = $GW * ($node->($f)->{z} - $node->($b)->{z}) / $u->{pf};
        my $re  = $v * $e->{dia} / 1000 / ($o->{nu} // 1.004e-6);
        my $fd  = $dw ? HardyCross::dw_friction($re, $e->{eps}, $e->{dia}) : undef;
        my ($dev) = grep { index($_, "$e->{id}.") == 0 } keys %el;
        my $ps;
        if ($dev) {
            my $d = $el{$dev};
            ($ps) = $d->{closed} ? (0) : HardyCross::elem_hf($d, $d->{q}, $o);
            $ps /= $u->{pf};
        }
        push @{ $t{pipes}{rows} }, $row->([
            $txt->($e->{id}), $txt->($node->($b)->{id}), $txt->($node->($f)->{id}),
            (defined $e->{dn} ? $num->($e->{dn}, 0) : $none), $num->($e->{dia}, 1),
            $txt->($e->{ptype} // 'BORE'),
            ($dw ? $num->($e->{eps}, 3) : $num->($e->{c}, 0)),
            $num->($e->{len} / $u->{lf}, 2), $num->($e->{eqv} / $u->{lf}, 2), $num->($lt / $u->{lf}, 2),
            $num->($e->{kfit} // 0, 2), $num->(abs($e->{q}) / $u->{qf}, $u->{qdp}),
            $num->($pf, $u->{pdp} + 1), ($lt > 0 ? $num->($pf / $lt, $u->{pdp} + 3) : $none),
            $num->($pe, $u->{pdp} + 1), (defined $ps ? $num->($ps, $u->{pdp} + 1) : $none),
            $num->($pv / $u->{pf}, $u->{pdp} + 1), $num->($v, 2), $num->($re, 0),
            (defined $fd ? $num->($fd, 5) : $none), $txt->($dw ? 'DW' : 'HW'),
        ], abs($e->{q}) > 1e-6);
    }

    #------------------------------------------------------------ NODES
    $t{nodes}{columns} = [
        { head => 'NAME', unit => '', align => 'w' }, { head => 'TYPE', unit => '', align => 'w' },
        { head => 'ELEV', unit => $u->{e}, align => 'e' }, { head => 'PRESSURE', unit => $u->{p}, align => 'e' },
        { head => 'DISCHARGE', unit => $u->{q}, align => 'e' }, { head => 'REQUIRED', unit => $u->{p}, align => 'e' },
        { head => 'MARGIN', unit => $u->{p}, align => 'e' } ];
    my (%type, %out, %req);
    for my $e (values %el) {
        if ($e->{kind} eq 'DISCHARGE') {
            $type{ $e->{n1} } = $e->{otype} eq 'HOSEREEL' ? 'HREEL' : $e->{otype};
            $out{ $e->{n1} } += abs $e->{q};
            $req{ $e->{n1} } = $e->{preq} if $e->{preq} > ($req{ $e->{n1} } // -1);
        }
        $type{ $e->{n2} } = 'WATER' if $e->{kind} =~ /^SUPPLY_/;
    }
    for my $f (@{ $net->{fixed} || [] }) {
        $type{ $f->{n1} } //= 'FIXEDFLOW';
        $req{ $f->{n1} } = $f->{preq} if defined $f->{preq} && $f->{preq} > ($req{ $f->{n1} } // -1);
    }
    for my $i (1 .. $#{ $net->{nodes} }) {
        my $n = $node->($i);
        next if $n->{id} eq 'REF';
        my $d = ($out{$i} // 0) + ($n->{demand} // 0);
        my $pg = $gauge->($i);
        push @{ $t{nodes}{rows} }, $row->([
            $txt->($n->{id}), $txt->($type{$i} // ($n->{id} =~ /~\z/ ? 'DEVICE' : 'NODE')),
            $num->($n->{z} / $u->{ef}, 3), $num->($pg, $u->{pdp}), $num->($d / $u->{qf}, $u->{qdp}),
            (defined $req{$i} ? $num->($req{$i} / $u->{pf}, $u->{pdp}) : $none),
            (defined $req{$i} ? $num->($pg - $req{$i} / $u->{pf}, $u->{pdp}) : $none),
        ], HardyCross::Report::node_throughput($net, $i) > 1e-6 || $d > 0);
    }

    #------------------------------------------------------------ OUTLETS
    # Required and achieved flow and pressure, the margin, PASS or FAIL: the
    # report's outlet compliance, sortable -- sort on MARGIN to see what
    # governs.  K is in the file's KFACTOR unit.  Fixed flows have K "FIXED".
    $t{outlets}{columns} = [
        { head => 'NAME', unit => '', align => 'w' }, { head => 'NODE', unit => '', align => 'w' },
        { head => 'TYPE', unit => '', align => 'w' }, { head => 'K', unit => '', align => 'e' },
        { head => 'REQ Q', unit => $u->{q}, align => 'e' }, { head => 'ACT Q', unit => $u->{q}, align => 'e' },
        { head => 'REQ P', unit => $u->{p}, align => 'e' }, { head => 'ACT P', unit => $u->{p}, align => 'e' },
        { head => 'MARGIN', unit => $u->{p}, align => 'e' }, { head => 'RESULT', unit => '', align => 'w' } ];
    # K held internally in L/min per kPa^0.5; one K unit of the file in those.
    my $kunit = $net->{phc_units} ? HardyCross::Phc::k_factor_to_model(1, $net->{phc_units})
                                    * $u->{qf} / sqrt($u->{pf}) : 1;
    for my $e (grep { $_->{kind} eq 'DISCHARGE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        my $p = ($node->($e->{n1})->{h} - $GW * $e->{z}) / $u->{pf};
        my $pass = abs($e->{q}) >= $e->{qreq} - 1e-6 && $p >= $e->{preq} / $u->{pf} - 1e-6;
        push @{ $t{outlets}{rows} }, $row->([
            $txt->($e->{id}), $txt->($node->($e->{n1})->{id}),
            $txt->($e->{otype} eq 'HOSEREEL' ? 'HREEL' : $e->{otype}), $num->($e->{k} / $kunit, 3),
            $num->($e->{qreq} / $u->{qf}, $u->{qdp}), $num->(abs($e->{q}) / $u->{qf}, $u->{qdp}),
            $num->($e->{preq} / $u->{pf}, $u->{pdp}), $num->($p, $u->{pdp}),
            $num->($p - $e->{preq} / $u->{pf}, $u->{pdp}), $txt->($pass ? 'PASS' : 'FAIL'),
        ], 1);
    }
    for my $f (grep { defined $_->{preq} } @{ $net->{fixed} || [] }) {
        my $p = ($node->($f->{n1})->{h} - $GW * $f->{z}) / $u->{pf};
        push @{ $t{outlets}{rows} }, $row->([
            $txt->($f->{id}), $txt->($node->($f->{n1})->{id}), $txt->('FIXEDFLOW'), [ 'FIXED', -1 ],
            $num->($f->{qreq} / $u->{qf}, $u->{qdp}), $num->($f->{q} / $u->{qf}, $u->{qdp}),
            $num->($f->{preq} / $u->{pf}, $u->{pdp}), $num->($p, $u->{pdp}),
            $num->($p - $f->{preq} / $u->{pf}, $u->{pdp}),
            $txt->($p >= $f->{preq} / $u->{pf} - 1e-6 ? 'PASS' : 'FAIL'),
        ], 1);
    }
    $t{$_}{rows} ||= [] for keys %t;
    return \%t;
}

#------------------------------------------------------------------------------
# sort_rows -- a table's rows sorted on column $col, descending if $desc.
#
# Numbers sort as numbers and text as text; ties keep their order, so sorting
# on one column and then another groups as expected.  "-" sorts first.
#------------------------------------------------------------------------------
sub sort_rows {
    my ($rows, $col, $desc) = @_;
    my $numeric = !grep { $_->{keys}[$col] !~ /^-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\z/ } @$rows;
    my @i = 0 .. $#$rows;
    my @s = $numeric
        ? sort { $rows->[$a]{keys}[$col] <=> $rows->[$b]{keys}[$col] || $a <=> $b } @i
        : sort { $rows->[$a]{keys}[$col] cmp $rows->[$b]{keys}[$col] || $a <=> $b } @i;
    @s = reverse @s if $desc;
    return [ @{$rows}[@s] ];
}

#==============================================================================
# Units and files.
#==============================================================================

# units_of -- the file's units, defaults filled in: { LENGTH => 'MM', ... }.
sub units_of { return { %{ scan(shift)->{units} } } }

#------------------------------------------------------------------------------
# set_units -- the buffer with its UNITS lines set to %$units.
#
# Each quantity's UNITS line is rewritten where it stands; a quantity with no
# line gets one at the top (after any leading comments), unless it is the
# default, which needs no line.  The rest of the text is untouched.
#------------------------------------------------------------------------------
sub set_units {
    my ($text, $units) = @_;
    my (undef, @l) = lines($text);
    my %done;
    for my $i (0 .. $#l) {
        my $a = HardyCross::Phc::analyse($l[$i]);
        next unless $a->{status} eq 'ok' && $a->{key} eq 'UNITS';
        my $q = $a->{pos}[0];
        next unless $units->{$q};
        $l[$i] = "UNITS     $q $units->{$q}";
        $done{$q} = 1;
    }
    my @new = map { "UNITS     $_ $units->{$_}" }
              grep { $units->{$_} && !$done{$_} && $units->{$_} ne $HardyCross::Phc::UNIT_DEFAULT{$_} }
              @HardyCross::Phc::UNIT_QUANTITIES;
    my $at = 0;
    $at++ while $at < @l && $l[$at] =~ m{^\s*(//|$)};
    splice @l, $at, 0, @new if @new;
    return join "\n", @l;
}

#------------------------------------------------------------------------------
# load_file -- { text, path } for a .phc file.  The editor works in .phc only;
# a .hcx is refused with the reason.
#------------------------------------------------------------------------------
sub load_file {
    my $path = shift;
    HardyCross::fail('THE EDITOR WORKS IN .PHC FILES; %s IS NOT ONE', $path) unless $path =~ /\.phc\z/i;
    open my $fh, '<', $path or HardyCross::fail('CANNOT OPEN %s: %s', $path, uc $!);
    my $text = do { local $/; <$fh> };
    close $fh;
    $text =~ s/\r\n/\n/g;
    return { text => $text, path => $path };
}

# write_report_file -- the report of a solved network to a .pdf or .txt file.
sub write_report_file {
    my ($net, $ok, $model_path, $out) = @_;
    if ($out =~ /\.pdf\z/i) {
        HardyCross::Report::write_pdf_report($net, $ok, $model_path, $out);
    } else {
        open my $fh, '>', $out or HardyCross::fail('CANNOT WRITE %s: %s', $out, uc $!);
        print $fh HardyCross::Report::write_report($net, $ok, $model_path);
        close $fh;
    }
    return 1;
}

1;
