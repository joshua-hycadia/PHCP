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
# clear_cache -- forget every remembered verdict: after the pipe and fitting
# database changes, a line that was good may not be, and the other way about.
sub clear_cache { %CHECK_CACHE = () }
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
my %KEYWORD_TYPE = map { $_ => 1 } qw(pipetype quantity unit method option field);
sub colour_spans {
    my $line = shift // '';
    my @s;
    my $cpos = index $line, '//';
    my $code = $cpos >= 0 ? substr($line, 0, $cpos) : $line;
    my @tok;
    push @tok, [ $-[0], $+[0], $1 ] while $code =~ /(\S+)/g;
    my $c = @tok ? HardyCross::Phc::command_spec($tok[0][2]) : undef;
    if ($c) {
        push @s, [ $tok[0][0], $tok[0][1], 'command' ];
        unless ($c->{name} eq 'TITLE' || $c->{name} eq 'PROJECT') {
            my @types = map { $_->[1] } @{ $c->{fixed} }, @{ $c->{opt} || [] };
            my $rest = $c->{rest} // '';
            for my $i (1 .. $#tok) {
                my ($a, $b, $t) = @{ $tok[$i] };
                my $type = $types[ $i - 1 ];
                my $j = $i - 1 - @types;                     # index into the rest
                my $kind =
                      defined $type ? ($type eq 'new' ? 'name'
                                     : $type eq 'node' || $type eq 'pipe' ? 'ref'
                                     : $KEYWORD_TYPE{$type} ? 'keyword'
                                     : $t =~ /^[-+.]?\d/ ? 'number' : undef)
                    : $rest eq 'fittings' ? 'keyword'
                    : $rest eq 'pairs'    ? 'number'
                    : $rest eq 'copies'   ? ($j % 3 ? 'ref' : 'name')
                    : $rest eq 'names'    ? 'name' : undef;
                push @s, [ $a, $b, $kind ] if $kind;
            }
        }
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

#==============================================================================
# The document: settings kept apart from the network.
#
# The window shows only the network in its editor.  The title, the project
# details, the units, the method and the options are set in the PROJECT tab.
# The .phc file still holds them all, as lines at its head, so a file is
# complete on its own and phcp.pl reads it unchanged.
#
# A document is { settings => {...}, network => text }.  The functions below
# build the whole .phc text from it (join_file) and run the checks of this
# module on that, then number what they find by NETWORK line - the line the
# user sees in the editor - or, for a setting, by its PROJECT tab field.
#==============================================================================

# The PROJECT tab's fields, in the order shown: the report's cover sheet.
our @PROJECT_FIELDS = qw(PROJECT JOB COMPANY ADDRESS LICENCE LOCATION DESIGNER CHECKER
                         REVISION DATE STANDARD HAZARD DENSITY AREA_PER_SPRINKLER
                         AREA_OF_OPERATION BASE_OF_RISER AUTHORITY AUTHORITY_PHONE DATA_SOURCE);
our %PROJECT_LABEL = (DENSITY => 'DENSITY (MM/MIN)', AREA_PER_SPRINKLER => 'AREA PER SPRINKLER (M2)',
                      AREA_OF_OPERATION => 'AREA OF OPERATION (M2)', BASE_OF_RISER => 'BASE OF RISER (NODE)',
                      AUTHORITY_PHONE => 'AUTHORITY PHONE', DATA_SOURCE => 'PIPE DATA SOURCE');
sub project_label { my $f = shift; return $PROJECT_LABEL{$f} // ($f =~ tr/_/ /r) }

#------------------------------------------------------------------------------
# The PROJECT tab's UNITS and CALCULATION fields in plain words.  Each option
# keeps its .phc name (written in the file, and shown small beside the label
# for anyone reading a file by hand), and gets a label and one line saying what
# it does and what it is when left blank.  The defaults quoted are the
# reader's own (HardyCross::Parse::new_net).  Options a user rarely needs come
# last, under SOLVER - ADVANCED.
#------------------------------------------------------------------------------
our %UNIT_LABEL = (LENGTH => 'PIPE LENGTH', ELEVATION => 'ELEVATION', SIZE => 'PIPE SIZE AND BORE',
                   PRESSURE => 'PRESSURE', FLOW => 'FLOW', KFACTOR => 'K-FACTOR');
our @OPTION_FORM = (
    [ 'VEL_LIMIT', 'VELOCITY WARNING LIMIT',
      'PIPES FASTER THAN THIS, IN M/S, ARE LISTED AS WARNINGS. BLANK: 6 M/S.' ],
    [ 'FITTING_BASIS', 'FITTING LENGTHS',
      'CORRECTED: ADJUSTED FOR THE C-FACTOR AND THE INSTALLED BORE. STANDARD: AS PUBLISHED IN AS 2118.1. '
      . 'BLANK: CORRECTED.', [ '', 'CORRECTED', 'STANDARD' ] ],
    [ 'ORIF_STEP', 'ORIFICE PLATE BORE STEP',
      'A BORE SIZED FOR AN OPP PLATE IS ROUNDED TO THIS STEP, IN THE PIPE SIZE UNIT. BLANK: 0.5 MM.' ],
    [ 'HOSE_ALLOWANCE', 'HOSE STREAM ALLOWANCE',
      'A FLOW, IN THE FLOW UNIT, ADDED AT THE SUPPLY FOR HOSE STREAMS: THE DEMAND IS CHECKED AT THE SYSTEM\'S FLOW '
      . 'PLUS THIS. BLANK: NONE.' ],
    'SOLVER - ADVANCED',
    [ 'TOL_FLOW', 'FLOW TOLERANCE',
      'THE SOLVE ENDS WHEN EVERY LOOP\'S FLOW CORRECTION IS SMALLER THAN THIS, IN THE FLOW UNIT. BLANK: 0.05 L/MIN.' ],
    [ 'TOL_LOOP', 'PRESSURE TOLERANCE',
      'AND EVERY LOOP BALANCES TO WITHIN THIS, IN THE PRESSURE UNIT. BLANK: 0.01 KPA.' ],
    [ 'MAXITER', 'MAXIMUM ITERATIONS',
      'THE SOLVE STOPS AFTER THIS MANY ROUNDS AND REPORTS THAT IT DID NOT CONVERGE. BLANK: 50000.' ],
    [ 'HW_CONST', 'HAZEN-WILLIAMS CONSTANT',
      'THE CONSTANT OF THE HAZEN-WILLIAMS FORMULA, FOR KPA PER METRE. BLANK: 6.05E7, AS IN AS 2118.1.' ],
    [ 'NU', 'KINEMATIC VISCOSITY',
      'OF THE WATER, IN M2/S, FOR DARCY-WEISBACH ONLY. BLANK: 1.004E-6, WATER AT 20 C.' ],
    [ 'RELAX', 'RELAXATION',
      'NOT USED BY THE SOLVER. ACCEPTED SO THAT OLDER FILES STILL READ.' ],
);

# new_settings -- an empty document's settings: the office defaults.
sub new_settings {
    return { title => '', project => {}, extra => [], units => { %HardyCross::Phc::UNIT_DEFAULT },
             method => 'HW', options => {} };
}

#------------------------------------------------------------------------------
# split_file -- a .phc text as { settings, network }.
#
# Every TITLE, PROJECT, UNITS, METHOD and OPTION line that reads cleanly goes
# into the settings and out of the network.  A setting line in error, or one
# repeating a setting already taken, stays in the network, where the checks
# mark it, so nothing in the file is lost without the user seeing it.  Blank
# lines left at the head and foot of the network are trimmed.
#------------------------------------------------------------------------------
sub split_file {
    my $text = shift // '';
    my $s = new_settings();
    my (@net, %seen);
    for my $line (split /\n/, $text, -1) {
        my $a = HardyCross::Phc::analyse($line);
        my $c = $a->{status} eq 'ok' && $a->{key} ? HardyCross::Phc::command_spec($a->{key}) : undef;
        if ($c && $c->{kind} eq 'setting' && !grep { $seen{$_}++ } HardyCross::Phc::setting_keys($a)) {
            my ($k, @p) = ($a->{key}, @{ $a->{pos} });
            if    ($k eq 'TITLE')   { $s->{title} = uc $a->{text} }
            elsif ($k eq 'PROJECT') { $s->{project}{ $p[0] } = uc $a->{text};
                                      push @{ $s->{extra} }, $p[0] unless grep { $_ eq $p[0] } @PROJECT_FIELDS }
            elsif ($k eq 'UNITS')   { $s->{units}{ $p[0] } = $p[1] }
            elsif ($k eq 'METHOD')  { $s->{method} = $p[0] }
            elsif ($k eq 'OPTION')  { $s->{options}{ $p[0] } = uc $p[1] }
            next;
        }
        push @net, $line;
    }
    shift @net while @net && $net[0] =~ /^\s*$/;
    pop @net   while @net && $net[-1] =~ /^\s*$/;
    return { settings => $s, network => join("\n", @net) . (@net ? "\n" : '') };
}

#------------------------------------------------------------------------------
# header_lines -- the settings as .phc lines, each with the PROJECT tab field
# it came from: ( [ line, field ] ... ).  Every unit is written, defaults
# included, so a file says its units plainly.  Values are in capitals.
#------------------------------------------------------------------------------
sub header_lines {
    my $s = shift;
    my $row = sub { [ sprintf('%-9s %s', $_[0], $_[1]), $_[2] ] };
    my @h;
    push @h, $row->('TITLE', uc $s->{title}, 'TITLE') if length($s->{title} // '');
    for my $f (@PROJECT_FIELDS, @{ $s->{extra} || [] }) {
        my $v = $s->{project}{$f} // '';
        push @h, $row->('PROJECT', "$f " . uc $v, $f) if length $v;
    }
    push @h, $row->('UNITS', "$_ $s->{units}{$_}", $_) for @HardyCross::Phc::UNIT_QUANTITIES;
    push @h, $row->('METHOD', $s->{method} // 'HW', 'METHOD');
    for my $o (@HardyCross::Phc::OPTIONS) {
        my $v = $s->{options}{$o} // '';
        push @h, $row->('OPTION', "$o " . uc $v, $o) if length $v;
    }
    return @h;
}

#------------------------------------------------------------------------------
# join_file -- the document as one .phc text.  Returns (text, H): H is the
# number of lines before the network (the settings and one blank line), so
# network line n is line n + H of the text.
#------------------------------------------------------------------------------
sub join_file {
    my ($s, $network) = @_;
    my @h = map { $_->[0] } header_lines($s);
    my $text = join("\n", @h, '', '') . ($network // '');
    return ($text, @h + 1);
}

# doc_text -- join_file for a document.
sub doc_text { my $d = shift; return join_file($d->{settings}, $d->{network}) }

# shift_lines -- "ON LINE n" in a message, renumbered from file to network line.
sub shift_lines { my ($msg, $h) = @_; $msg =~ s/\bON LINE (\d+)/'ON LINE ' . ($1 - $h)/ge; return $msg }

#------------------------------------------------------------------------------
# doc_check -- check_buffer for a document, by network line.
#
# Returns check_buffer's result for the network lines, plus settings_problems
# [ { field, message } ] for any setting the reader refuses.  A setting command
# typed into the network is an error there: settings belong in the PROJECT tab.
#------------------------------------------------------------------------------
sub doc_check {
    my ($d, $editing) = @_;
    my ($full, $h) = doc_text($d);
    my $r = check_buffer($full, defined $editing ? $editing + $h : undef);
    my @hdr = header_lines($d->{settings});
    my (undef, @nl) = lines($d->{network});
    pop @nl if @nl && $nl[-1] eq '' && $d->{network} =~ /\n\z/;
    my %o = (lines => [undef], problems => [], settings_problems => []);
    for my $i (1 .. @nl) {
        my $l = $r->{lines}[ $i + $h ] || { status => 'ok', message => '' };
        my $a = HardyCross::Phc::analyse($nl[ $i - 1 ]);
        my $c = $a->{key} ? HardyCross::Phc::command_spec($a->{key}) : undef;
        $l = { status => 'error', message => "$c->{name} IS SET IN THE PROJECT TAB, NOT IN THE NETWORK" }
            if $c && $c->{kind} eq 'setting';
        $l = { status => $l->{status}, message => shift_lines($l->{message}, $h) };
        push @{ $o{lines} }, $l;
        next if $l->{status} eq 'ok';
        next if $l->{status} eq 'incomplete' && defined $editing && $editing == $i;
        push @{ $o{problems} }, { line => $i, message => $l->{message} };
    }
    for my $p (@{ $r->{problems} }) {
        next if $p->{line} > $h || $p->{line} > @hdr;
        push @{ $o{settings_problems} }, { field => $hdr[ $p->{line} - 1 ][1], message => $p->{message} };
    }
    for my $k (qw(undefined unused)) {
        $o{$k} = [ map { { node => $_->{node}, line => $_->{line} - $h } } grep { $_->{line} > $h } @{ $r->{$k} } ];
    }
    return \%o;
}

#------------------------------------------------------------------------------
# doc_diagnostics -- the ERRORS, WARNINGS and NODES lists, by network line.
# A setting the reader refuses is listed in ERRORS with no line, naming its
# PROJECT tab field.
#------------------------------------------------------------------------------
sub doc_diagnostics {
    my ($d, $net, $editing) = @_;
    my ($full, $h) = doc_text($d);
    my $chk = doc_check($d, $editing);
    my $dg = diagnostics($full, $net, $editing);
    my $mv = sub { my $l = shift; defined $l && $l > $h ? $l - $h : undef };
    return {
        errors   => [ (map { { line => undef, field => $_->{field},
                                   message => "PROJECT TAB, $_->{field}: $_->{message}" } }
                       @{ $chk->{settings_problems} }), @{ $chk->{problems} } ],
        warnings => [ map { { line => $mv->($_->{line}), message => $_->{message} } } @{ $dg->{warnings} } ],
        nodes    => [ map { { line => $mv->($_->{line}), message => $_->{message} } } @{ $dg->{nodes} } ],
    };
}

# doc_choices / doc_status -- choices and status_at for network line $n, with
# the settings in force (the fittings offered depend on the SIZE unit).
sub doc_choices { my ($d, $n, $col) = @_; my ($t, $h) = doc_text($d); return choices($t, $n + $h, $col) }
sub doc_status  { my ($d, $n, $col) = @_; my ($t, $h) = doc_text($d); return status_at($t, $n + $h, $col) }

# doc_solve -- solve_text for a document; an error's line is a network line,
# or undef with the error in a setting.
sub doc_solve {
    my ($d, $path) = @_;
    my ($t, $h) = doc_text($d);
    my $r = solve_text($t, $path);
    return $r if $r->{ok};
    if (defined $r->{line}) {
        my $n = $r->{line} - $h;
        $r->{error} =~ s/^LINE \d+: /$n > 0 ? "LINE $n: " : 'PROJECT TAB: '/e;
        $r->{error} = shift_lines($r->{error}, $h);
        $r->{line} = $n > 0 ? $n : undef;
    }
    return $r;
}

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
#   tab               'PROJECT' for a setting, otherwise undef
#
# In order: the settings; every network line (an incomplete line is an error
# here, wherever the cursor is); nodes used but not defined; nodes nothing
# connects to; then, when every line is good, the network read whole and its
# structure checked as the solver will - one supply or outlet anchoring it,
# every node connected.  ok is true only when nothing is found, and only then
# may the window calculate.
#------------------------------------------------------------------------------
sub validate {
    my $d = shift;
    my ($full, $h) = doc_text($d);
    my $chk = doc_check($d);
    my (undef, @nl) = lines($d->{network});
    my $u = $d->{settings}{units};
    my @it;
    for my $p (@{ $chk->{settings_problems} }) {
        push @it, { what => $p->{message}, tab => 'PROJECT', field => $p->{field},
                    why => why($p->{message}, undef, $u) };
    }
    for my $p (@{ $chk->{problems} }) {
        my $line = $nl[ $p->{line} - 1 ];
        my ($a, $b, $field, $key) = fault_span($line, $p->{message});
        push @it, { what => $p->{message}, line => $p->{line}, start => $a, end => $b,
                    field => $field, why => why($p->{message}, $key, $u) };
    }
    for my $n (@{ $chk->{undefined} }) {
        my ($a, $b) = word_span($nl[ $n->{line} - 1 ], $n->{node});
        push @it, { what => "NODE $n->{node} IS USED, BUT NOT DEFINED", line => $n->{line},
                    start => $a, end => $b, field => 'NODE', why => why('NOT DEFINED', undef, $u) };
    }
    for my $n (@{ $chk->{unused} }) {
        my ($a, $b) = word_span($nl[ $n->{line} - 1 ], $n->{node});
        push @it, { what => "NOTHING CONNECTS TO NODE $n->{node}", line => $n->{line},
                    start => $a, end => $b, field => 'NAME', why => why('NOTHING CONNECTS', undef, $u) };
    }
    unless (@it) {
        my $scan = scan($full);
        my $ok = eval { HardyCross::build_tree(HardyCross::Phc::read_string($full)); 1 };
        unless ($ok) {
            my $e = $@;
            die $e unless HardyCross::is_model_error($e);
            my $msg = uc $e->{msg};
            my $line;
            if ($msg =~ s/^LINE (\d+): //) { $line = $1 - $h }
            elsif ($msg =~ /^NODE (\S+) IS NOT CONNECTED/) { $line = ($scan->{nodes}{$1} // 0) - $h }
            $msg = shift_lines($msg, $h);
            $line = undef unless defined $line && $line > 0;
            my $node = $msg =~ /^NODE (\S+)/ ? $1 : undef;
            my ($a, $b) = defined $line ? word_span($nl[ $line - 1 ], $node) : ();
            push @it, { what => $msg, line => $line, start => $a, end => $b,
                        field => defined $node ? 'NAME' : undef, why => why($msg, undef, $u) };
        }
    }
    @it = sort { ($a->{tab} ? 0 : 1) <=> ($b->{tab} ? 0 : 1) || ($a->{line} // 0) <=> ($b->{line} // 0) } @it;
    return { ok => !@it, items => \@it };
}

# words -- the words of a line's code part: ( [start, end, text] ... ).
sub words {
    my $line = shift // '';
    my $cpos = index $line, '//';
    my $code = $cpos >= 0 ? substr($line, 0, $cpos) : $line;
    my @w;
    push @w, [ $-[0], $+[0], $1 ] while $code =~ /(\S+)/g;
    return @w;
}

# word_span -- the columns of a word on a line (the whole line if not found).
sub word_span {
    my ($line, $word) = @_;
    my @w = words($line);
    if (defined $word) {
        my ($m) = grep { uc $_->[2] eq uc $word } @w[1 .. $#w];
        return ($m->[0], $m->[1]) if $m;
    }
    return (@w ? $w[0][0] : 0, @w ? $w[-1][1] : length($line // ''));
}

#------------------------------------------------------------------------------
# fault_span -- where on a line its problem is: (start, end, field, command).
#
# An unknown command is its first word.  A line that stops short points just
# past its end, at the field it needs.  A value quoted in the message ('X')
# is that word.  Otherwise the reader accepted as many fields as it put in
# pos and opt, so the next one is at fault.  Failing all of those, the whole
# line.
#------------------------------------------------------------------------------
sub fault_span {
    my ($line, $msg) = @_;
    my @w = words($line);
    my $a = HardyCross::Phc::analyse($line);
    my $c = $a->{key} ? HardyCross::Phc::command_spec($a->{key}) : undef;
    my @fields = $c ? HardyCross::Phc::template_fields($c) : ();
    my $fname = sub { my $i = shift; $i >= 1 && @fields ? $fields[ $i - 1 > $#fields ? $#fields : $i - 1 ] : undef };
    return ($w[0][0], $w[0][1], 'COMMAND', undef) if @w && !$c;
    my $key = $c ? $c->{name} : undef;
    return ($w[0][0], $w[0][1], 'COMMAND', $key) if $c && $c->{kind} eq 'setting';
    if ($a->{status} eq 'incomplete') {
        my $e = @w ? $w[-1][1] : 0;
        return ($e, $e + 1, $a->{msg}, $key);
    }
    if ($msg =~ /^(?:NODE|THE NAME) (\S+) IS ALREADY/) {
        my ($x, $y) = word_span($line, $1);
        return ($x, $y, 'NAME', $key);
    }
    if ($msg =~ /'([^']+)'/) {
        my $q = $1;
        for my $i (1 .. $#w) {
            return ($w[$i][0], $w[$i][1], $fname->($i), $key) if uc $w[$i][2] eq uc $q;
        }
    }
    if ($a->{status} eq 'error') {
        my $i = 1 + @{ $a->{pos} } + @{ $a->{opt} };
        return ($w[$i][0], $w[$i][1], $fname->($i), $key) if $i <= $#w;
    }
    if ($key && $key eq 'PIPE' && $msg =~ /DATA_REQUIRED|NOT IN THE DATABASE/ && $#w >= 5) {
        return ($w[5][0], $w[5][1], 'SIZE', $key);
    }
    return (@w ? $w[0][0] : 0, @w ? $w[-1][1] : length $line, undef, $key);
}

#------------------------------------------------------------------------------
# why -- the reason behind a problem, in plain words: what the program needs
# and why, so the user can put it right without the manual.  Matched on the
# message; a message not listed gets the command's field template, which says
# what the line should hold.
#------------------------------------------------------------------------------
my @NETWORK_COMMANDS = map { @$_ } @HardyCross::Phc::COMMAND_GROUPS[1 .. $#HardyCross::Phc::COMMAND_GROUPS];
sub why {
    my ($msg, $key, $u) = @_;
    $u ||= \%HardyCross::Phc::UNIT_DEFAULT;
    my $tpl = sub { my $k = shift; $k ? "$k IS WRITTEN: " . HardyCross::Phc::template_text($k) . '.' : '' };
    my @why = (
        [ qr/^UNKNOWN COMMAND/,
          'EVERY LINE STARTS WITH A COMMAND. THE NETWORK COMMANDS ARE: ' . join(' ', @NETWORK_COMMANDS) . '.' ],
        [ qr/IS SET IN THE PROJECT TAB/,
          'THE TITLE, PROJECT DETAILS, UNITS, METHOD AND OPTIONS ARE KEPT IN THE PROJECT TAB SO THE EDITOR HOLDS '
          . 'ONLY THE NETWORK. SET IT THERE AND DELETE THIS LINE.' ],
        [ qr/^(\S+) NEEDS (.+)/,
          sub { "THE LINE ENDS BEFORE ITS $2. " . $tpl->($1) } ],
        [ qr/^NODE \S+ IS ALREADY DEFINED/,
          'A NODE IS DEFINED ONCE: A SECOND DEFINITION WOULD GIVE IT TWO ELEVATIONS. RENAME ONE OR DELETE THE REPEAT.' ],
        [ qr/^THE NAME \S+ IS ALREADY USED/,
          'PIPES, NODES AND ELEMENTS SHARE ONE SET OF NAMES, SO EVERY RESULT AND MESSAGE POINTS TO ONE THING. '
          . 'GIVE THIS ONE A NAME OF ITS OWN.' ],
        [ qr/IS ALREADY SET ON LINE/,
          'A SETTING IS GIVEN ONCE; A SECOND WOULD SILENTLY REPLACE THE FIRST.' ],
        [ qr/IS NOT A LENGTH/,
          sub { "A LENGTH IS A NUMBER IN THE LENGTH UNIT ($u->{LENGTH}), OR CARRIES ITS OWN UNIT: 3.2M, 3200MM, 10'6\"." } ],
        [ qr/RATIO .* IS NOT A RATIO|RATIO MUST BE/,
          'A PRESSURE RATIO VALVE DIVIDES ITS INLET PRESSURE BY THE RATIO, SO IT IS WRITTEN 3:1 OR 3, AND IS MORE THAN 1.' ],
        [ qr/IS NOT A NUMBER/,
          'THIS FIELD TAKES A NUMBER, IN THE UNIT SET IN THE PROJECT TAB.' ],
        [ qr/CANNOT BE NEGATIVE/,
          'A NEGATIVE VALUE HAS NO MEANING HERE. (AN OUTLET\'S MINIMUM FLOW IS THE ONE FIELD THAT TAKES A '
          . 'NEGATIVE NUMBER: -50 MEANS A MINIMUM PRESSURE OF 50.)' ],
        [ qr/FIELDS GO BY POSITION/,
          'EACH FIELD IS KNOWN BY ITS PLACE ON THE LINE, AS THE STATUS BAR SHOWS: WRITE THE VALUE ALONE, WITHOUT KEY=.' ],
        [ qr/IS NOT A FITTING|CANNOT READ FITTING/,
          'AFTER ITS SIZE A PIPE TAKES FITTING CODES, EACH WITH AN OPTIONAL COUNT (2E IS TWO ELBOWS). '
          . 'CTRL+SPACE LISTS THE CODES FOR THE PIPE TYPE AND SIZE.' ],
        [ qr/FITTINGS NEED A PIPE TYPE/,
          'FITTING LOSSES COME FROM THE DATABASE FOR A PIPE TYPE; A PLAIN BORE HAS NONE TO LOOK UP. '
          . 'PUT A USE LINE ABOVE, OR GIVE THE ALLOWANCE AS A LENGTH WITH EQV.' ],
        [ qr/DATA_REQUIRED|NOT IN THE DATABASE/,
          'THE PIPE TYPE IN FORCE (THE USE LINE ABOVE) HAS NO PIPE OF THIS SIZE IN THE DATABASE, AND A BORE IS '
          . 'NEVER GUESSED. CHECK THE SIZE, OR THE USE LINE.' ],
        [ qr/UNEXPECTED FIELD/,
          sub { 'THE LINE HAS MORE FIELDS THAN ITS COMMAND TAKES. ' . $tpl->($key) } ],
        [ qr/CANNOT BE USED IN A .PHC LINE/,
          'THE CHARACTER IS RESERVED. A COMMENT STARTS WITH //.' ],
        [ qr/NOT DEFINED/,
          'A PIPE OR ELEMENT JOINS NODES THAT ARE DEFINED BY NODE, NC, WATER, SPRINKLER, HYDRANT OR HREEL. '
          . 'DEFINE THE NODE, OR CORRECT THE NAME.' ],
        [ qr/NOTHING CONNECTS|NOT CONNECTED/,
          'EVERY NODE MUST BE JOINED TO THE REST OF THE NETWORK, OR ITS FLOWS CANNOT BE BALANCED. '
          . 'CONNECT IT WITH A PIPE, OR DELETE IT.' ],
        [ qr/NO SUPPLY AND NO DISCHARGE/,
          'PRESSURES ARE WORKED OUT FROM A KNOWN PRESSURE. ADD A WATER SUPPLY, OR AN OUTLET.' ],
        [ qr/UNKNOWN OPTION|VALUE .* IS NOT A NUMBER|FITTING_BASIS/,
          'CHECK THE OPTION IN THE PROJECT TAB: LEAVE A FIELD BLANK FOR THE DEFAULT.' ],
    );
    for my $w (@why) {
        next unless $msg =~ $w->[0];
        return ref $w->[1] ? $w->[1]->() : $w->[1];
    }
    return $tpl->($key) || 'THE SOLVER CANNOT READ THIS AS WRITTEN.';
}

1;
