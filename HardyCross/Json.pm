#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# Json.pm -- the results of a solve as JSON, for other programs.
#
# Other programs -- the AutoCAD exporter now, possibly Revit later -- run
# phcp.exe and read what it prints (decided 28 October 2026: a program to call,
# not a DLL).  `phcp.exe --json model.phc` prints one JSON object, described
# below, and the exit status says how it went: 0 converged, 1 solved but did
# not converge, 2 the model could not be read or solved.  The JSON is written
# in every case, so a caller always has something to read -- on an error, the
# message and its .phc line.
#
# The contract is versioned: "interface" is 1.  A field is never renamed or
# given a different meaning under the same number; new fields may be added.
#
#   interface      1
#   program        "PHCP 1.0.0"
#   model          the model file's name, or "-" for standard input
#   status         "converged", "not_converged" or "error"
#   converged      true / false
#   iterations     Hardy Cross iterations taken
#   units          { flow, pressure, length, elevation, size, velocity }: the
#                  units every value below is in -- flow and pressure in the
#                  model's own units, lengths and elevations in m, sizes in
#                  mm, velocity in m/s
#   database       { name, issued, file, sha256 } -- the pipe and fitting data
#                  used, as the report states it
#   pipes          [ { id, from, to, flow, velocity, friction_loss, length,
#                    equivalent_length, bore, nominal } ]  flow is signed: +
#                  from -> to as the model wrote the pipe
#   elements       [ { id, kind, from, to, flow } ] supplies (kind WATER, from
#                  null: a supply feeds its node, "to"), pumps and devices in
#                  pipes (id <pipe>.<command>; it sits at the pipe's start,
#                  between the start node and the node <pipe>~)
#   nodes          [ { id, elevation, pressure } ]  pressure is gauge
#   outlets        [ { id, node, type, k, required_flow, flow,
#                    required_pressure, pressure, margin, pass } ]  fixed flows
#                  included, with type FIXEDFLOW and k null
#   governing      { id, margin } the outlet with least pressure to spare, or null
#   demand         { supply, flow, pressure, available, margin, meets } at the
#                  demand point, or null with demand_reason saying why
#   warnings       [ text ]
#   errors         [ { line, message } ]  line is the .phc line, or null
#   summary        [ text ]  the lines a caller shows a user: the result, the
#                  governing outlet, every failing outlet, the supply; one
#                  string a line, in capitals, ready to print
#
# Numbers are rounded to 0.0001 of their unit (velocity 0.001 m/s); a caller
# needing more should read the report.

package HardyCross::Json;

use strict;
use warnings;
use JSON::PP;
use HardyCross;
use HardyCross::Demand;
use HardyCross::PipeData;
use HardyCross::Report;

our $INTERFACE = 1;
# An element's kind in the language's own words.
my %KIND = (PUMP => 'PUMP', BFP => 'LOSS CURVE', FIXED_DROP => 'FIXED DROP', ORIFICE => 'ORIFICE PLATE',
            ORIFICE_REQUIRED => 'ORIFICE PLATE', RATIO => 'PRA');
my $GW = $HardyCross::GAMMA_W;

sub r4 { my $v = shift; return defined $v ? 0 + sprintf('%.4f', $v) : undef }
sub r3 { my $v = shift; return defined $v ? 0 + sprintf('%.3f', $v) : undef }

# units -- the unit of each quantity, as the report prints it.
sub units {
    my $net = shift;
    return { flow => HardyCross::Report::sym($net->{u_flow}), pressure => HardyCross::Report::sym($net->{u_pres}),
             length => 'm', elevation => 'm', size => 'mm', velocity => 'm/s' };
}

#------------------------------------------------------------------------------
# results -- the JSON object (a hash) for a solved network.
#   $ok     solve_model's result: converged or not
#   $model  the model's name for the output
#   %o      demand => 0 to leave out the demand point (it re-solves the
#           network many times; a large model may not want it every time)
#------------------------------------------------------------------------------
sub results {
    my ($net, $ok, $model, %o) = @_;
    my ($uf, $up) = @{$net}{qw(f_flow f_pres)};
    my $node = sub { $net->{nodes}[ shift ] };
    my $gauge = sub { HardyCross::Demand::gauge($net, shift) / $up };
    my @el = @{ $net->{elems} }[1 .. $#{ $net->{elems} }];

    my (@pipes, @elems, @nodes, @outlets);
    for my $e (@el) {
        if ($e->{kind} eq 'PIPE') {
            my ($hf) = HardyCross::elem_hf($e, $e->{q}, $net->{opts});
            push @pipes, { id => $e->{id}, from => $node->($e->{n1})->{id}, to => $node->($e->{n2})->{id},
                flow => r4($e->{q} / $uf), velocity => r3(HardyCross::pipe_velocity($e->{q}, $e->{dia})),
                friction_loss => r4($hf / $up), length => r4($e->{len}), equivalent_length => r4($e->{eqv}),
                bore => r4($e->{dia}), nominal => $e->{dn} };
        } elsif ($e->{kind} =~ /^SUPPLY_/) {
            # A supply joins its node to the solver's datum (REF), which is
            # nothing to a caller: it is reported by its node alone.
            push @elems, { id => $e->{id}, kind => 'WATER', from => undef,
                           to => $node->($e->{n2})->{id}, flow => r4($e->{q} / $uf) };
        } elsif ($e->{kind} ne 'DISCHARGE') {
            # A device in a pipe is "<pipe>.<command>": its kind is the
            # command the user wrote (PRV, BFP, OPP, OFD, PRA, BP).
            push @elems, { id => $e->{id}, kind => $e->{id} =~ /\.([A-Z]+)\z/ ? $1 : $KIND{ $e->{kind} } // $e->{kind},
                           from => $node->($e->{n1})->{id}, to => $node->($e->{n2})->{id},
                           flow => r4($e->{q} / $uf) };
        }
    }
    for my $i (1 .. $#{ $net->{nodes} }) {
        my $n = $node->($i);
        next if $n->{id} eq 'REF';
        push @nodes, { id => $n->{id}, elevation => r4($n->{z}), pressure => r4($gauge->($i)) };
    }
    my @fail;
    for my $e (grep { $_->{kind} eq 'DISCHARGE' } @el) {
        my $p = ($node->($e->{n1})->{h} - $GW * $e->{z}) / $up;
        my $pass = abs($e->{q}) >= $e->{qreq} - 1e-6 && $p >= $e->{preq} / $up - 1e-6;
        push @outlets, { id => $e->{id}, node => $node->($e->{n1})->{id},
            type => $e->{otype} eq 'HOSEREEL' ? 'HREEL' : $e->{otype}, k => r4($e->{k}),
            required_flow => r4($e->{qreq} / $uf), flow => r4(abs($e->{q}) / $uf),
            required_pressure => r4($e->{preq} / $up), pressure => r4($p),
            margin => r4($p - $e->{preq} / $up), pass => $pass ? JSON::PP::true : JSON::PP::false };
        push @fail, $outlets[-1] unless $pass;
    }
    for my $f (grep { defined $_->{preq} } @{ $net->{fixed} || [] }) {
        my $p = ($node->($f->{n1})->{h} - $GW * $f->{z}) / $up;
        my $pass = $p >= $f->{preq} / $up - 1e-6;
        push @outlets, { id => $f->{id}, node => $node->($f->{n1})->{id}, type => 'FIXEDFLOW', k => undef,
            required_flow => r4($f->{qreq} / $uf), flow => r4($f->{q} / $uf),
            required_pressure => r4($f->{preq} / $up), pressure => r4($p),
            margin => r4($p - $f->{preq} / $up), pass => $pass ? JSON::PP::true : JSON::PP::false };
        push @fail, $outlets[-1] unless $pass;
    }

    my ($go, $gm) = HardyCross::Demand::governing_outlet($net);
    my %j = (
        interface => $INTERFACE, program => "PHCP $HardyCross::VERSION", model => $model,
        status => $ok ? 'converged' : 'not_converged', converged => $ok ? JSON::PP::true : JSON::PP::false,
        iterations => $net->{iters} // 0, units => units($net),
        database => HardyCross::PipeData::path()
            ? { name => HardyCross::PipeData::dataset(), issued => HardyCross::PipeData::issued(),
                file => HardyCross::PipeData::path(), sha256 => HardyCross::PipeData::sha256() } : undef,
        pipes => \@pipes, elements => \@elems, nodes => \@nodes, outlets => \@outlets,
        governing => $go ? { id => $go->{id}, margin => r4($gm / $up) } : undef,
        warnings => [ @{ $net->{warnings} || [] } ], errors => [],
    );

    my $u = $j{units};
    if (($o{demand} // 1) && $ok) {
        my $dm = HardyCross::Demand::demand_point($net);
        if ($dm->{reason}) {
            ($j{demand}, $j{demand_reason}) = (undef, $dm->{reason});
        } else {
            $j{demand} = { supply => $dm->{supply}{id}, flow => r4($dm->{q_demand} / $uf),
                pressure => r4($dm->{p_demand} / $up), available => r4($dm->{p_avail} / $up),
                margin => r4($dm->{margin} / $up),
                meets => $dm->{margin} >= 0 ? JSON::PP::true : JSON::PP::false };
        }
    } else {
        ($j{demand}, $j{demand_reason}) = (undef, $ok ? 'not asked for' : 'the solve did not converge');
    }

    # The summary: what a caller shows a user in a few lines.
    my @s;
    push @s, $ok ? "CONVERGED IN $j{iterations} ITERATIONS"
                 : 'DID NOT CONVERGE - THE RESULTS MUST NOT BE USED';
    if ($go) {
        my ($g) = grep { $_->{id} eq $go->{id} } @outlets;
        push @s, sprintf('GOVERNING OUTLET %s: %.1f %s AGAINST %.1f REQUIRED, MARGIN %.1f %s', $go->{id},
            $g->{pressure}, uc $u->{pressure}, $g->{required_pressure}, $g->{margin}, uc $u->{pressure}) if $g;
    }
    push @s, sprintf('FAIL: %s AT %s %.1f %s AGAINST %.1f REQUIRED', $_->{type}, $_->{id}, $_->{pressure},
                     uc $u->{pressure}, $_->{required_pressure}) for @fail;
    push @s, @fail ? scalar(@fail) . ' OUTLET' . (@fail == 1 ? '' : 'S') . ' FAIL' : 'EVERY OUTLET PASSES'
        if @outlets;
    if (my $d = $j{demand}) {
        push @s, sprintf('SUPPLY %s %s THE DEMAND: %.1f %s AVAILABLE AT %.1f %s, %.1f NEEDED',
            $d->{supply}, $d->{meets} ? 'MEETS' : 'DOES NOT MEET', $d->{available}, uc $u->{pressure},
            $d->{flow}, uc $u->{flow}, $d->{pressure});
    }
    my $nw = @{ $j{warnings} };
    my $nv = grep { abs($_->{velocity}) > ($net->{opts}{vel_limit} // 6) } @pipes;
    push @s, "$nv PIPE" . ($nv == 1 ? '' : 'S') . ' OVER THE VELOCITY LIMIT' if $nv;
    push @s, "$nw WARNING" . ($nw == 1 ? '' : 'S') . ' - SEE THE REPORT' if $nw;
    $j{summary} = \@s;
    return \%j;
}

#------------------------------------------------------------------------------
# error_result -- the JSON object when the model could not be read or solved:
# status "error", the message, and its .phc line when it has one.
#------------------------------------------------------------------------------
sub error_result {
    my ($e, $model) = @_;
    my $msg = HardyCross::is_model_error($e) ? $e->{msg} : "$e";
    $msg =~ s/\s+\z//;
    my $line;
    $line = 0 + $1 if $msg =~ s/^line (\d+): //i;
    return { interface => $INTERFACE, program => "PHCP $HardyCross::VERSION", model => $model,
             status => 'error', converged => JSON::PP::false, errors => [ { line => $line, message => uc $msg } ],
             summary => [ 'NOT SOLVED: ' . uc($msg) . (defined $line ? " (LINE $line)" : '') ] };
}

# encode -- the object as JSON text: keys in a fixed order, indented, one
# value a line -- so a caller with no JSON reader (AutoLISP) can still find
# the summary lines by reading line by line.
sub encode { return JSON::PP->new->canonical->pretty->ascii->encode(shift) }

1;
