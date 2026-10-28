#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# Editor.pm -- everything the .phc text editor does, without Tk.
#
# phcp_editor.pl is the window: it draws text, takes keys and calls this
# module for every decision.  Keeping the decisions here means each one can be
# tested headless (tools/test_editor.pl) and the window stays thin enough to
# check by reading.  Nothing in this module knows a widget exists.
#
# What it answers:
#
#   check_buffer   every line's status (ok / incomplete / error) and message,
#                  the problems list, and the nodes used but not defined
#   context_at     what is in force at a line: the Use, the Units, the
#                  options, the defined nodes -- what check_line needs
#   proposal       the likely next line after the one just finished
#   choices        the pick list for the cursor's field
#   colour_spans   where on a line the command word and the comment are
#   solve_text     solve the buffer; the report, or the error and its line
#   results_at     the solved figures for the element on a line
#   result_tables  the PIPES, NODES and OUTLETS tables under the editor
#   sort_rows      a table sorted on one column, as the column headings do
#   diagnostics    the ERRORS, WARNINGS and NODES lists beside the editor
#   load_file      read a .phc, or convert a .hcx into a new .phc buffer
#   write_report_file   the report as .pdf or .txt
#
# Every check is made by HardyCross::Phc, the same code that reads a .phc file
# for a solve, so the editor cannot call a line good that the solver refuses,
# or the reverse.

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

#------------------------------------------------------------------------------
# scan -- one pass over the buffer: each line's analysis and what is in force.
#
# Returns {
#   a       => [ per line, HardyCross::Phc::analyse result ],
#   use_at  => [ per line, the Use in force at that line: { type, c } ],
#   units   => { FLOW => 'LPS', ... }      (file-wide, wherever written)
#   options => { FITTING_BASIS => ..., }   (file-wide)
#   nodes   => { id => line of its Node line }
#   ids     => { id => line } for every element and node id
# }
# Settings are file-wide in .phc, so a Units line at the bottom applies to the
# line at the top; that is why this is a whole-buffer pass and not a running
# state.  Use is the exception, and use_at follows it line by line.
#------------------------------------------------------------------------------
sub scan {
    my $text = shift;
    my (undef, @l) = lines($text);
    my %s = (a => [undef], use_at => [undef], units => {}, options => {},
             nodes => {}, ids => {});
    my $use = { type => 'BORE' };
    for my $i (1 .. @l) {
        my $a = HardyCross::Phc::analyse($l[ $i - 1 ]);
        push @{ $s{a} }, $a;
        if ($a->{status} eq 'ok') {
            my $k = $a->{key};
            $use = { type => $a->{pos}[0], c => $a->{opt}{C} } if $k eq 'USE';
            if ($k eq 'UNITS') {
                $s{units}{$_} //= $a->{opt}{$_} for @{ $a->{optorder} };
            }
            $s{options}{ $a->{pos}[0] } //= $a->{pos}[1] if $k eq 'OPTION';
            $s{nodes}{ $a->{pos}[0] } //= $i if $k eq 'NODE';
            my $c = HardyCross::Phc::command_spec($k);
            $s{ids}{ $a->{pos}[0] } //= $i if $c->{kind} eq 'element' || $k eq 'NODE';
        }
        push @{ $s{use_at} }, $use;
    }
    return \%s;
}

#------------------------------------------------------------------------------
# context_at -- the check_line context for line $n of the buffer.
#------------------------------------------------------------------------------
sub context_at {
    my ($text, $n, $scan) = @_;
    $scan ||= scan($text);
    return { use => $scan->{use_at}[$n] || { type => 'BORE' },
             units => $scan->{units}, options => $scan->{options},
             nodes => $scan->{nodes} };
}

#------------------------------------------------------------------------------
# check_buffer -- every line checked, and the problems listed.
#
#   $text     the buffer
#   $editing  the line the cursor is on (optional): an incomplete line there
#             is still being typed and is not listed as a problem
#
# Returns {
#   lines     => [ per line (from 1): { status, message } ]
#   problems  => [ { line, message } ] in line order
#   undefined => [ { node, line } ]: nodes used but given no Node line,
#                with the first line that uses each
# }
# A line's status is check_line's, except that a setting given twice, or a
# second Node line for a node, is an error on the later line -- the same rule
# and the same words as the reader (HardyCross::Phc::setting_keys).
#------------------------------------------------------------------------------
sub check_buffer {
    my ($text, $editing) = @_;
    my (undef, @l) = lines($text);
    my $scan = scan($text);
    my (%r, %set, %nodeline, %first_use, @used);
    $r{lines} = [undef];
    for my $i (1 .. @l) {
        my $chk = cached_check($l[ $i - 1 ], context_at($text, $i, $scan));
        my ($st, $msg) = ($chk->{status}, $chk->{message});
        my $a = $scan->{a}[$i];
        if ($st eq 'ok' && $a->{key}) {
            for my $k (HardyCross::Phc::setting_keys($a)) {
                if ($set{$k}) { ($st, $msg) = ('error', "$k is already set on line $set{$k}") }
                else          { $set{$k} = $i }
            }
            if ($a->{key} eq 'NODE') {
                my $id = $a->{pos}[0];
                if ($nodeline{$id}) {
                    ($st, $msg) = ('error', "node $id already has a Node line, on line $nodeline{$id}");
                } else {
                    $nodeline{$id} = $i;
                }
            }
            for my $id (HardyCross::Phc::nodes_used($a)) {
                next if $first_use{$id};
                $first_use{$id} = $i;
                push @used, $id;
            }
        }
        push @{ $r{lines} }, { status => $st, message => $msg };
        next if $st eq 'ok';
        next if $st eq 'incomplete' && defined $editing && $editing == $i;
        push @{ $r{problems} }, { line => $i, message => $msg };
    }
    $r{problems} ||= [];
    $r{undefined} = [ map { { node => $_, line => $first_use{$_} } }
                      grep { !$scan->{nodes}{$_} } @used ];
    return \%r;
}

#------------------------------------------------------------------------------
# cached_check -- check_line for check_buffer, remembered between calls.
#
# The window re-checks the whole buffer after each pause in typing, and on a
# 3000-line model that took a second -- every line parsed again although only
# one had changed.  A line's verdict depends only on its text, the Use in
# force, the Units and the options, so that is the key; the defined nodes are
# left out (check_buffer works out undefined nodes itself).  The cache is
# simply emptied when it grows past a limit.
#------------------------------------------------------------------------------
my %CHECK_CACHE;
my $CACHE_LIMIT = 50_000;
sub cached_check {
    my ($line, $ctx) = @_;
    my $u = $ctx->{use} || {};
    my $key = join "\x00", $line, $u->{type} // '', $u->{c} // '',
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
# proposal -- the line to offer after line $n, or undef.
#
# HardyCross::Phc::propose steps the ids (P7 -> P8; a pipe starts where the
# last ended).  Here the id is stepped again, as often as needed, past any id
# the buffer already uses, so accepting a proposal never creates a duplicate.
#------------------------------------------------------------------------------
sub proposal {
    my ($text, $n) = @_;
    my (undef, @l) = lines($text);
    return undef unless $n >= 1 && $n <= @l;
    my $p = HardyCross::Phc::propose($l[ $n - 1 ]) // return undef;
    my $scan = scan($text);
    my ($word, $id, @rest) = split ' ', $p;
    for (1 .. 1000) {
        last unless $scan->{ids}{$id};
        $id = HardyCross::Phc::step_id($id);
    }
    return join ' ', $word, $id, @rest;
}

#------------------------------------------------------------------------------
# choices -- the pick list at column $col of line $n: [ [code, description] ].
#------------------------------------------------------------------------------
sub choices {
    my ($text, $n, $col) = @_;
    my (undef, @l) = lines($text);
    return [] unless $n >= 1 && $n <= @l;
    my $ctx = context_at($text, $n);
    $ctx->{cursor} = $col;
    return HardyCross::Phc::check_line($l[ $n - 1 ], $ctx)->{choices} || [];
}

#------------------------------------------------------------------------------
# status_at -- the status bar for the cursor at line $n, column $col.
#
# Returns { template => { text, fields, current }, status, message }.  The
# window draws the fields with the current one highlighted.
#------------------------------------------------------------------------------
sub status_at {
    my ($text, $n, $col) = @_;
    my (undef, @l) = lines($text);
    return { status => 'ok', message => '', template => undef }
        unless $n >= 1 && $n <= @l;
    my $ctx = context_at($text, $n);
    $ctx->{cursor} = $col;
    my $r = HardyCross::Phc::check_line($l[ $n - 1 ], $ctx);
    return { status => $r->{status}, message => $r->{message}, template => $r->{template} };
}

#------------------------------------------------------------------------------
# colour_spans -- where the command word and the comment are on a line.
#
# Returns ( [start, end, 'command'], [start, end, 'comment'] ) as character
# columns, end exclusive.  The command word is coloured only when it IS a
# command; an unknown word is left plain and the line shows as an error.
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

#------------------------------------------------------------------------------
# solve_text -- read and solve the buffer.
#
# Returns {
#   ok        1 if it was read and solved (converged or not)
#   converged whether the solve converged
#   net       the solved network
#   report    the full ASCII report
#   error     the message, when it could not be read or solved
#   line      the .phc line of the error, when it has one
# }
#------------------------------------------------------------------------------
sub solve_text {
    my ($text, $path) = @_;
    my $net = eval { HardyCross::Phc::read_string($text) };
    return error_result($@) unless $net;
    my $conv = eval { HardyCross::solve_model($net) };
    return error_result($@) unless defined $conv;
    return { ok => 1, converged => $conv, net => $net,
             report => HardyCross::Report::write_report($net, $conv, $path // 'untitled.phc') };
}

# error_result -- a model error as { error, line }; anything else is a bug and
# is passed on, so it is seen rather than shown as a model problem.
sub error_result {
    my $e = shift;
    die $e unless HardyCross::is_model_error($e);
    my $r = { ok => 0, error => $e->{msg} };
    $r->{line} = $1 if $e->{msg} =~ /^line (\d+): /;
    return $r;
}

#------------------------------------------------------------------------------
# results_at -- the solved figures for the element or node on a line.
#
# Returns a short line of text in the model's own units, or undef when the
# line names nothing in the solved network (a setting, a blank, an element
# added since the solve):
#
#   Pipe    Q 1234.5 L/min  V 2.34 m/s  N1 650.0 kPa -> N2 612.3 kPa
#   Head    q 95.2 L/min at 52.1 kPa (required 50.0)
#   Node    pressure 612.3 kPa, elevation 4.500 m
#------------------------------------------------------------------------------
sub results_at {
    my ($net, $line) = @_;
    return undef unless $net;
    my $a = HardyCross::Phc::analyse($line // '');
    return undef unless $a->{status} eq 'ok' && $a->{key};
    # Settings and Use lines name nothing in the network.
    my $kind = HardyCross::Phc::command_spec($a->{key})->{kind};
    return undef unless $kind eq 'element' || $kind eq 'node';
    my ($uf, $up, $ul) = ($net->{f_flow}, $net->{f_pres}, $net->{f_len});
    my ($qu, $pu, $lu) = map { lc } ($net->{u_flow}, $net->{u_pres}, $net->{u_len});
    $qu = 'L/min' if $qu eq 'lpm';
    $qu = 'L/s'   if $qu eq 'lps';
    $pu = 'kPa'   if $pu eq 'kpa';
    my $id = $a->{pos}[0];
    my $p  = sub { my $i = shift; ($net->{nodes}[$i]{h} - $GW * $net->{nodes}[$i]{z}) / $up };
    my $nid = sub { $net->{nodes}[ shift ]{id} };

    if ($a->{key} eq 'NODE') {
        my ($i) = grep { $net->{nodes}[$_]{id} eq $id } 1 .. $#{ $net->{nodes} };
        return undef unless $i;
        return sprintf '%s  pressure %.1f %s, elevation %.3f %s', $id, $p->($i), $pu,
                       $net->{nodes}[$i]{z} / $ul, $lu;
    }
    if ($a->{key} eq 'FLOW') {
        my ($f) = grep { $_->{id} eq $id } @{ $net->{fixed} || [] };
        return undef unless $f;
        return sprintf '%s  fixed %.1f %s at %.1f %s%s', $id, $f->{q} / $uf, $qu, $p->($f->{n1}), $pu,
            defined $f->{preq} ? sprintf(' (required %.1f)', $f->{preq} / $up) : '';
    }
    my ($e) = grep { ($_->{id} // '') eq $id } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    return undef unless $e;
    if ($e->{kind} eq 'PIPE') {
        # The engine's own velocity, as the report prints it.
        my $v = abs HardyCross::pipe_velocity($e->{q}, $e->{dia});
        my ($b, $t) = $e->{q} >= 0 ? ($e->{n1}, $e->{n2}) : ($e->{n2}, $e->{n1});
        return sprintf '%s  Q %.1f %s  V %.2f m/s  %s %.1f %s -> %s %.1f %s', $id,
            abs($e->{q}) / $uf, $qu, $v, $nid->($b), $p->($b), $pu, $nid->($t), $p->($t), $pu;
    }
    if ($e->{kind} eq 'DISCHARGE') {
        return sprintf '%s  q %.1f %s at %.1f %s (required %.1f)', $id, abs($e->{q}) / $uf, $qu,
            $p->($e->{n1}), $pu, $e->{preq} / $up;
    }
    if ($e->{kind} =~ /^SUPPLY_/) {
        return sprintf '%s  supplies %.1f %s at %.1f %s', $id, abs($e->{q}) / $uf, $qu,
            $p->($e->{n2}), $pu;
    }
    # Pumps and devices: flow, and the pressure each side.
    return sprintf '%s  Q %.1f %s  %s %.1f %s -> %s %.1f %s', $id, $e->{q} / $uf, $qu,
        $nid->($e->{n1}), $p->($e->{n1}), $pu, $nid->($e->{n2}), $p->($e->{n2}), $pu;
}

#==============================================================================
# The results tables, shown under the editor after a solve.
#
# Each table is { columns => [ [heading, unit, align], ... ],
#                 rows    => [ { cells => [text, ...], keys => [sort value, ...],
#                               active => 0|1 }, ... ] }
# cells are what is shown, already formatted; keys are what the column sorts
# on (numbers as numbers), so sorting 9.5 before 10.2 does not depend on the
# text.  active is false for a pipe carrying no flow or a node no water passes
# through, which the HIDE boxes leave out.  Units in the headings are the
# model's own.
#==============================================================================
sub result_tables {
    my $net = shift or return {};
    my ($uf, $up, $ul) = ($net->{f_flow}, $net->{f_pres}, $net->{f_len});
    my ($qu, $pu, $lu) = (unit_label($net->{u_flow}), unit_label($net->{u_pres}),
                          lc $net->{u_len});
    my $o = $net->{opts};
    my $node = sub { $net->{nodes}[ shift ] };
    my $gauge = sub { my $n = $node->(shift); ($n->{h} - $GW * $n->{z}) / $up };
    my $row = sub { my ($fmt, $act) = (shift, shift); { cells => [ map { $_->[0] } @$fmt ],
                    keys => [ map { $_->[1] } @$fmt ], active => $act } };
    my $num = sub { my ($v, $dp) = @_; [ sprintf('%.*f', $dp, $v), $v ] };
    my $txt = sub { my $t = shift // ''; [ $t, $t ] };
    my %t;

    #------------------------------------------------------------ PIPES
    # Written in the direction of flow, as the report's pipe schedule is: SNODE
    # upstream, Q positive, PE the pressure lost to the rise from SNODE to ENODE.
    $t{pipes}{columns} = [ [ 'NAME', '', 'w' ], [ 'SNODE', '', 'w' ], [ 'ENODE', '', 'w' ],
        [ 'NOM', 'mm', 'e' ], [ 'I.D.', 'mm', 'e' ], [ 'MAT', '', 'w' ], [ 'C', '', 'e' ],
        [ 'L', $lu, 'e' ], [ 'F', $lu, 'e' ], [ 'T', $lu, 'e' ], [ 'FIT K', '', 'e' ],
        [ 'Q', $qu, 'e' ], [ 'PF', $pu, 'e' ], [ 'VEL', 'm/s', 'e' ],
        [ 'PF/L', "$pu/$lu", 'e' ], [ 'PE', $pu, 'e' ] ];
    for my $e (grep { $_->{kind} eq 'PIPE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        my $fwd = $e->{q} >= 0;
        my ($b, $f) = $fwd ? ($e->{n1}, $e->{n2}) : ($e->{n2}, $e->{n1});
        my ($hf) = HardyCross::elem_hf($e, $e->{q}, $o);
        my $pf = abs($hf) / $up;
        my $lt = ($e->{len} + $e->{eqv}) / $ul;
        my $pe = $GW * ($node->($f)->{z} - $node->($b)->{z}) / $up;
        push @{ $t{pipes}{rows} }, $row->([
            $txt->($e->{id}), $txt->($node->($b)->{id}), $txt->($node->($f)->{id}),
            (defined $e->{dn} ? $num->($e->{dn}, 0) : [ '-', -1 ]), $num->($e->{dia}, 1),
            $txt->($e->{ptype} // 'BORE'), $num->($e->{c}, 0),
            $num->($e->{len} / $ul, 2), $num->($e->{eqv} / $ul, 2), $num->($lt, 2),
            $num->($e->{kfit}, 2), $num->(abs($e->{q}) / $uf, qdp($net)),
            $num->($pf, pdp($net)), $num->(abs HardyCross::pipe_velocity($e->{q}, $e->{dia}), 2),
            ($lt > 0 ? $num->($pf / $lt, pdp($net) + 3) : [ '-', 0 ]), $num->($pe, pdp($net)),
        ], abs($e->{q}) > 1e-6);
    }

    #------------------------------------------------------------ NODES
    # Discharge is everything leaving the network at the node: outlets and
    # fixed flows.  REQUIRED is the highest pressure an outlet or fixed flow
    # there needs.
    $t{nodes}{columns} = [ [ 'NAME', '', 'w' ], [ 'ELEV', $lu, 'e' ], [ 'PRESSURE', $pu, 'e' ],
        [ 'TOTAL HEAD', $pu, 'e' ], [ 'DISCHARGE', $qu, 'e' ], [ 'REQUIRED', $pu, 'e' ],
        [ 'OUTLET', '', 'w' ] ];
    my (%out, %req, %tag);
    for my $e (grep { $_->{kind} eq 'DISCHARGE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        $out{ $e->{n1} } += abs $e->{q};
        $req{ $e->{n1} } = $e->{preq} if $e->{preq} > ($req{ $e->{n1} } // -1);
        push @{ $tag{ $e->{n1} } }, $e->{id};
    }
    for my $f (@{ $net->{fixed} || [] }) {
        $req{ $f->{n1} } = $f->{preq} if defined $f->{preq} && $f->{preq} > ($req{ $f->{n1} } // -1);
        push @{ $tag{ $f->{n1} } }, $f->{id};
    }
    for my $i (1 .. $#{ $net->{nodes} }) {
        my $n = $node->($i);
        next if $n->{id} eq 'REF';
        my $d = ($out{$i} // 0) + ($n->{demand} // 0);
        push @{ $t{nodes}{rows} }, $row->([
            $txt->($n->{id}), $num->($n->{z} / $ul, 3), $num->($gauge->($i), pdp($net)),
            $num->($n->{h} / $up, pdp($net)), $num->($d / $uf, qdp($net)),
            (defined $req{$i} ? $num->($req{$i} / $up, pdp($net)) : [ '-', -1 ]),
            $txt->(join ' ', @{ $tag{$i} || [] }),
        ], HardyCross::Report::node_throughput($net, $i) > 1e-6 || $d > 0);
    }

    #------------------------------------------------------------ OUTLETS
    # Required and achieved flow and pressure, the margin, PASS or FAIL: the
    # report's outlet compliance, sortable -- sort on MARGIN to see what
    # governs.  Fixed flows are listed with K "fixed".
    $t{outlets}{columns} = [ [ 'NAME', '', 'w' ], [ 'NODE', '', 'w' ], [ 'TYPE', '', 'w' ],
        [ 'K', '', 'e' ], [ 'REQ Q', $qu, 'e' ], [ 'ACT Q', $qu, 'e' ], [ 'REQ P', $pu, 'e' ],
        [ 'ACT P', $pu, 'e' ], [ 'MARGIN', $pu, 'e' ], [ 'RESULT', '', 'w' ] ];
    for my $e (grep { $_->{kind} eq 'DISCHARGE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        my $p = ($node->($e->{n1})->{h} - $GW * $e->{z}) / $up;
        my $pass = abs($e->{q}) >= $e->{qreq} - 1e-6 && $p >= $e->{preq} / $up - 1e-6;
        push @{ $t{outlets}{rows} }, $row->([
            $txt->($e->{id}), $txt->($node->($e->{n1})->{id}), $txt->($e->{otype}),
            $num->($e->{k} * sqrt($up) / $uf, 3), $num->($e->{qreq} / $uf, qdp($net)),
            $num->(abs($e->{q}) / $uf, qdp($net)), $num->($e->{preq} / $up, pdp($net)),
            $num->($p, pdp($net)), $num->($p - $e->{preq} / $up, pdp($net)),
            $txt->($pass ? 'PASS' : 'FAIL'),
        ], 1);
    }
    for my $f (grep { defined $_->{preq} } @{ $net->{fixed} || [] }) {
        my $p = ($node->($f->{n1})->{h} - $GW * $f->{z}) / $up;
        push @{ $t{outlets}{rows} }, $row->([
            $txt->($f->{id}), $txt->($node->($f->{n1})->{id}), $txt->('FIXEDFLOW'),
            [ 'fixed', -1 ], $num->($f->{qreq} / $uf, qdp($net)), $num->($f->{q} / $uf, qdp($net)),
            $num->($f->{preq} / $up, pdp($net)), $num->($p, pdp($net)),
            $num->($p - $f->{preq} / $up, pdp($net)),
            $txt->($p >= $f->{preq} / $up - 1e-6 ? 'PASS' : 'FAIL'),
        ], 1);
    }
    $t{$_}{rows} ||= [] for keys %t;
    return \%t;
}

# Decimal places for a flow and a pressure in the model's units: fewer in
# L/min and kPa, more in L/s and bar, where the figures are small.
sub qdp { my $n = shift; $n->{f_flow} > 1.5 ? 3 : 1 }
sub pdp { my $n = shift; $n->{f_pres} > 1.5 ? 3 : 1 }

# unit_label -- a model unit code as it reads in a heading: LPM is L/min.
sub unit_label {
    my $u = uc(shift // '');
    my %l = (LPM => 'L/min', 'L/MIN' => 'L/min', LPS => 'L/s', 'L/S' => 'L/s',
             KPA => 'kPa', BAR => 'bar', MPA => 'MPa', PSI => 'psi', M3H => 'm3/h',
             GPM => 'gpm', USGPM => 'gpm', IGPM => 'igpm');
    return $l{$u} // lc $u;
}

#------------------------------------------------------------------------------
# sort_rows -- a table's rows sorted on column $col, descending if $desc.
#
# Numbers sort as numbers and text as text (case-insensitively); ties keep
# their order, so sorting on one column and then another groups as expected.
#------------------------------------------------------------------------------
sub sort_rows {
    my ($rows, $col, $desc) = @_;
    my $numeric = !grep { $_->{keys}[$col] !~ /^-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\z/ } @$rows;
    my @i = 0 .. $#$rows;
    my @s = $numeric
        ? sort { $rows->[$a]{keys}[$col] <=> $rows->[$b]{keys}[$col] || $a <=> $b } @i
        : sort { lc $rows->[$a]{keys}[$col] cmp lc $rows->[$b]{keys}[$col] || $a <=> $b } @i;
    @s = reverse @s if $desc;
    return [ @{$rows}[@s] ];
}

#------------------------------------------------------------------------------
# diagnostics -- the three lists beside the editor.
#
# Returns {
#   errors   => [ { line, message } ]  lines the reader refuses (check_buffer)
#   warnings => [ { line, message } ]  what a solve found: no convergence, a
#                                      pipe over the velocity limit, an outlet
#                                      or fixed flow below its requirement, and
#                                      the engine's own warnings
#   nodes    => [ { line, message } ]  nodes used but never defined (an error
#                                      when solving), and nodes defined but
#                                      used by nothing (the solve refuses an
#                                      unconnected node)
# }
# $net is the last solve, or undef; warnings need one.  Each entry carries the
# .phc line it belongs to, so a click can go there.
#------------------------------------------------------------------------------
sub diagnostics {
    my ($text, $net, $editing) = @_;
    my $chk  = check_buffer($text, $editing);
    my $scan = scan($text);
    my %d = (errors => $chk->{problems}, warnings => [], nodes => []);

    push @{ $d{nodes} }, { line => $_->{line}, message => "$_->{node} - used, but has no Node line" }
        for @{ $chk->{undefined} };
    my %used;
    for my $a (grep { $_ && $_->{status} eq 'ok' } @{ $scan->{a} }) {
        $used{$_} = 1 for HardyCross::Phc::nodes_used($a);
    }
    for my $id (sort { $scan->{nodes}{$a} <=> $scan->{nodes}{$b} } keys %{ $scan->{nodes} }) {
        push @{ $d{nodes} }, { line => $scan->{nodes}{$id}, message => "$id - defined, but nothing uses it" }
            unless $used{$id};
    }

    if ($net) {
        my $line = sub { $scan->{ids}{ shift() } };
        push @{ $d{warnings} }, { line => undef, message => 'the solve did NOT converge: the results must not be used' }
            if defined $net->{iters} && $net->{iters} >= ($net->{opts}{maxiter} // 0) && !$net->{converged_flag};
        my $t = result_tables($net);
        my $vl = $net->{opts}{vel_limit} // 6;
        for my $r (@{ $t->{pipes}{rows} }) {
            my $v = $r->{keys}[13];
            push @{ $d{warnings} }, { line => $line->($r->{keys}[0]),
                message => sprintf('%s - velocity %.2f m/s is over the limit of %g m/s', $r->{keys}[0], $v, $vl) }
                if $v > $vl;
        }
        for my $r (@{ $t->{outlets}{rows} }) {
            next unless $r->{keys}[9] eq 'FAIL';
            push @{ $d{warnings} }, { line => $line->($r->{keys}[0]),
                message => sprintf('%s - below its requirement: %s %s against %s required',
                                   $r->{keys}[0], $r->{cells}[7], 'P', $r->{cells}[6]) };
        }
        push @{ $d{warnings} }, map { { line => undef, message => $_ } } @{ $net->{warnings} || [] };
    }
    return \%d;
}

#------------------------------------------------------------------------------
# load_file -- the text to put in the editor for a file.
#
# Returns { text, path, converted, note }.  A .phc is read as it is.  A .hcx
# is converted into a NEW, unsaved .phc buffer: path is undef (so SAVE asks
# for a name, suggested as the .hcx name with .phc), and note says so -- the
# .hcx on disk is never overwritten with .phc text.
#------------------------------------------------------------------------------
sub load_file {
    my $path = shift;
    open my $fh, '<', $path or HardyCross::fail("cannot open %s: %s", $path, $!);
    my $text = do { local $/; <$fh> };
    close $fh;
    $text =~ s/\r\n/\n/g;
    return { text => $text, path => $path, converted => 0, note => '' }
        unless $path =~ /\.hcx\z/i;
    require HardyCross::Convert;
    (my $name = $path) =~ s{.*[/\\]}{};
    (my $suggest = $path) =~ s/\.hcx\z/.phc/i;
    return { text => HardyCross::Convert::hcx_to_phc($text, $name), path => undef,
             converted => 1, suggest => $suggest,
             note => "converted from $name into a new .phc - not yet saved" };
}

#------------------------------------------------------------------------------
# write_report_file -- the report of a solved network to a .pdf or .txt file.
#------------------------------------------------------------------------------
sub write_report_file {
    my ($net, $ok, $model_path, $out) = @_;
    if ($out =~ /\.pdf\z/i) {
        HardyCross::Report::write_pdf_report($net, $ok, $model_path, $out);
    } else {
        open my $fh, '>', $out or HardyCross::fail("cannot write %s: %s", $out, $!);
        print $fh HardyCross::Report::write_report($net, $ok, $model_path);
        close $fh;
    }
    return 1;
}

1;
