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
# below, and the exit status says how it went:
#
#   0  ACCEPTED or NONCOMPLIANT: a valid solution, numerically and
#      physically; "acceptance" says whether the design passes
#   1  INDETERMINATE: did not converge, or the device states did not settle
#   2  the model could not be read or solved
#   3  REJECTED: converged, but the network fails a numerical or physical
#      check -- not a valid answer to the model, and not to be used
#
# The JSON is written in every case, so a caller always has something to
# read -- on an error, the message and its .phc line.
#
# The contract is versioned: "interface" is 2.  A field is never renamed or
# given a different meaning under the same number; new fields may be added.
# Interface 2 (introduced after PHCP 1.3.0) changed from 1: outlet "flow" is signed (it was
# the magnitude, which showed a backward discharge as a forward one), "pass"
# needs a forward flow, exit status 3 is new, and a converged solve may now
# exit 1 when its device states did not settle.  Everything else is as in
# interface 1, with the fields marked [2] added.
#
#   interface      2
#   program        "PHCP 1.3.0"
#   model          the model file's name, or "-" for standard input
#   status         "converged", "not_converged" or "error": how the
#                  iteration ended, and nothing more
#   acceptance     [2] "ACCEPTED", "NONCOMPLIANT", "REJECTED",
#                  "INDETERMINATE" or "ERROR" (HardyCross::Validate): whether
#                  the results may be used
#   validation     [2] { numerical, physical, design: { status, errors,
#                  warnings }, residuals: { continuity, balance, loop,
#                  element: { value, tolerance, unit, at, pass } }, solver: {
#                  method, algorithm, hc_converged, outer_settled,
#                  outer_passes, outer_stop, iterations, maxiter, tol_flow,
#                  tol_loop, diagnosis, loops }, findings: [ { code,
#                  category, severity, item, value, limit, unit, message } ] }
#   validation_errors [2] [ "CODE: message" ] every error finding
#   supplies       [2] with more than one supply: { operating, supply_sum,
#                  net_demand, balance, governing, conditional, joint,
#                  scenarios } (HardyCross::Supplies); absent with one
#   dry_pipe_valves [2] [ { id, pipe, from, to, nominal_size, model,
#                  trip_method, trip_ratio, trip_pressure, accelerator,
#                  loss_basis, equivalent_length, flow, loss, state,
#                  initial_air_pressure, delivery_time (null: not
#                  calculated), delivery_time_calculated (false),
#                  validation, findings } ]
#   traceability   [2] { program, version, model_sha256, database { name,
#                  sha256 }, method, algorithm, tolerances, assumptions,
#                  scenarios }
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
#   velocity_pressure  true / false: OPTION VELOCITY_PRESSURE.  true, in-line
#                  sprinklers discharge on normal pressure (AS 2118.1 Cl 14.15);
#                  false, every outlet on total pressure
#   outlets        [ { id, node, type, k, required_flow, flow,
#                    required_pressure, pressure, velocity_pressure,
#                    discharge_pressure, margin, pass } ]  pressure is the
#                  gauge (total) pressure; velocity_pressure the Pv taken off
#                  it (0 unless applied); discharge_pressure = pressure -
#                  velocity_pressure, what flow = k sqrt(P) is worked on, and
#                  what margin and pass are measured on.  Fixed flows
#                  included, with type FIXEDFLOW and k null
#                  flow is signed [2]: negative for an outlet discharging
#                  backwards, which never passes
#   governing      { id, margin } the outlet with least pressure to spare, or null
#   demand         { supply, flow, pressure, available, margin, meets } at the
#                  demand point, or null with demand_reason saying why
#   design_area    the design area (AREA) these results are for, or null
#   areas          [ { name, outlets, governing, margin, demand_flow,
#                    demand_pressure, supply_margin, converged, governs } ]
#                  every design area solved (HardyCross::Areas), or null
#   sized          [ { line, pipes, type, dn, size, velocity } ] the pipes
#                  auto sizing sized (size 0 in the model), or null
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

our $INTERFACE = 2;

# exit_code -- the exit status for a solve, from its acceptance (see the head
# of this module).  phcp.pl uses it with and without --json, so the two agree.
sub exit_code {
    my $acc = shift // 'INDETERMINATE';
    return { ACCEPTED => 0, NONCOMPLIANT => 0, INDETERMINATE => 1, ERROR => 2, REJECTED => 3 }->{$acc} // 1;
}
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
        # pressure is the gauge (total) pressure at the outlet, as it always
        # was; discharge_pressure is what q = K sqrt(P) is worked on -- the
        # normal pressure of an in-line sprinkler with velocity pressure ON,
        # the same as pressure otherwise.  margin and pass are on the latter.
        # flow is SIGNED (interface 2): an outlet discharging backwards has a
        # negative flow and never passes.  Interface 1 printed |q|, which
        # showed water entering the network through a sprinkler as a
        # positive discharge.
        my $p  = ($node->($e->{n1})->{h} - $GW * $e->{z}) / $up;
        my $pd = HardyCross::outlet_pressure($net, $e) / $up;
        my $pass = $e->{q} >= $e->{qreq} - 1e-6 && $pd >= $e->{preq} / $up - 1e-6;
        push @outlets, { id => $e->{id}, node => $node->($e->{n1})->{id},
            type => $e->{otype} eq 'HOSEREEL' ? 'HREEL' : $e->{otype}, k => r4($e->{k}),
            required_flow => r4($e->{qreq} / $uf), flow => r4($e->{q} / $uf),
            required_pressure => r4($e->{preq} / $up), pressure => r4($p),
            velocity_pressure => r4(($e->{pv} // 0) / $up), discharge_pressure => r4($pd),
            margin => r4($pd - $e->{preq} / $up), pass => $pass ? JSON::PP::true : JSON::PP::false };
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
        velocity_pressure => $net->{opts}{vel_press} ? JSON::PP::true : JSON::PP::false,
        database => HardyCross::PipeData::path()
            ? { name => HardyCross::PipeData::dataset(), issued => HardyCross::PipeData::issued(),
                file => HardyCross::PipeData::path(), sha256 => HardyCross::PipeData::sha256() } : undef,
        pipes => \@pipes, elements => \@elems, nodes => \@nodes, outlets => \@outlets,
        governing => $go ? { id => $go->{id}, margin => r4($gm / $up) } : undef,
        warnings => [ @{ $net->{warnings} || [] } ], errors => [],
        design_area => $net->{design_area},
        sized => $net->{sizing} ? [ map { { line => $_->{line}, pipes => $_->{pipes}, type => $_->{type},
            dn => $_->{dn}, size => $_->{token}, velocity => defined $_->{velocity} ? 0 + sprintf('%.3f', $_->{velocity}) : undef } }
            @{ $net->{sizing}{units} } ] : undef,
        areas => $net->{area_results} ? [ map { my $d = $_->{demand}; {
            name => $_->{name}, outlets => $_->{outlets}, governing => $_->{governing},
            margin => defined $_->{margin} ? r4($_->{margin} / $up) : undef,
            demand_flow => $d ? r4($d->{q} / $uf) : undef, demand_pressure => $d ? r4($d->{p} / $up) : undef,
            supply_margin => $d ? r4($d->{margin} / $up) : undef,
            converged => $_->{ok} ? JSON::PP::true : JSON::PP::false,
            governs => $_->{governs} ? JSON::PP::true : JSON::PP::false } } @{ $net->{area_results} } ] : undef,
    );

    my $u = $j{units};

    # The validation (HardyCross::Validate::assess): the same result the
    # report prints.  acceptance decides whether the results may be used;
    # status and converged say only how the iteration ended.
    require HardyCross::Validate;
    my $as = HardyCross::Validate::assess($net, $ok, demand => $o{demand} // 1);
    my $va = $as->{validation};
    $j{acceptance} = $va->{acceptance};
    $j{validation} = {
        numerical => $va->{numerical}, physical => $va->{physical}, design => $va->{design},
        residuals => { map { my $r = $va->{residuals}{$_};
                             $_ => { value => 0 + sprintf('%.6e', $r->{value}), tolerance => 0 + sprintf('%.6e', $r->{tolerance}),
                                     unit => HardyCross::Report::sym($r->{unit}), at => $r->{at},
                                     pass => $r->{pass} ? JSON::PP::true : JSON::PP::false } }
                       grep { $va->{residuals}{$_} } keys %{ $va->{residuals} || {} } },
        solver => { %{ $va->{solver} }, map { $_ => $va->{solver}{$_} ? JSON::PP::true : JSON::PP::false }
                                          qw(hc_converged outer_settled) },
        findings => [ map { my $f = $_; +{ map { $_ => $f->{$_} } grep { defined $f->{$_} }
                          qw(code category severity item value limit unit message outlet_type) } }
                      @{ $va->{findings} } ],
    };
    # Errors and warnings as data, from the validation: a caller can act on
    # the code without reading the sentence.  The plain warnings above stay.
    $j{validation_errors}   = [ map { "$_->{code}: $_->{message}" } grep { $_->{severity} eq 'error' } @{ $va->{findings} } ];
    $j{supplies}        = supplies_json($net, $as->{supplies}) if $as->{supplies};
    $j{dry_pipe_valves} = dpv_json($net, $va);
    $j{traceability}    = traceability($net, $va);

    if (($o{demand} // 1) && $ok) {
        my $dm = $as->{demand};
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
    push @s, 'CALCULATION ' . uc HardyCross::Validate::acceptance_text($va->{acceptance});
    push @s, $ok ? "CONVERGED IN $j{iterations} ITERATIONS"
                 : 'DID NOT CONVERGE - THE RESULTS MUST NOT BE USED';
    push @s, map { uc "MANDATORY: $_->{code} - $_->{message}" }
             grep { $_->{severity} eq 'error' && $_->{category} ne 'design' } @{ $va->{findings} };
    push @s, $j{areas} ? sprintf('DESIGN AREA %s GOVERNS, OF %d AREAS SOLVED', $j{design_area}, scalar @{ $j{areas} })
           : defined $j{design_area} ? "DESIGN AREA $j{design_area}, CHOSEN BY OPTION DESIGN_AREA" : ();
    # Said only when it is ON, so a total-pressure summary reads as it always has.
    push @s, 'VELOCITY PRESSURE INCLUDED: IN-LINE SPRINKLERS DISCHARGE ON NORMAL PRESSURE (AS 2118.1 CL 14.15)'
        if $net->{opts}{vel_press};
    if ($go) {
        my ($g) = grep { $_->{id} eq $go->{id} } @outlets;
        push @s, sprintf('GOVERNING OUTLET %s: %.1f %s AGAINST %.1f REQUIRED, MARGIN %.1f %s', $go->{id},
            $g->{discharge_pressure} // $g->{pressure}, uc $u->{pressure}, $g->{required_pressure}, $g->{margin},
            uc $u->{pressure}) if $g;
    }
    push @s, sprintf('FAIL: %s AT %s %.1f %s AGAINST %.1f REQUIRED', $_->{type}, $_->{id},
                     $_->{discharge_pressure} // $_->{pressure},
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
# supplies_json -- the multiple-supply schedule (HardyCross::Supplies), in the
# model's units.
#------------------------------------------------------------------------------
sub supplies_json {
    my ($net, $s) = @_;
    my ($uf, $up) = @{$net}{qw(f_flow f_pres)};
    my ($Q, $P) = (sub { r4(defined $_[0] ? $_[0] / $uf : undef) }, sub { r4(defined $_[0] ? $_[0] / $up : undef) });
    my $j = {
        operating => [ map { { id => $_->{id}, node => $_->{node}, elevation => r4($_->{z}), type => $_->{kind},
                               flow => $Q->($_->{flow}), pressure => $P->($_->{pressure}),
                               supply_pressure => $P->($_->{supply_pressure}), share_percent => r4($_->{share}),
                               status => $_->{status},
                               extrapolated => $_->{extrapolated} ? JSON::PP::true : JSON::PP::false } }
                       @{ $s->{operating} } ],
        supply_sum => $Q->($s->{supply_sum}), net_demand => $Q->($s->{net_demand}),
        balance => 0 + sprintf('%.6e', $s->{balance} / $uf), governing => $s->{governing},
    };
    $j->{conditional} = [ map { { id => $_->{id}, status => $_->{status}, reason => $_->{reason},
                                  basis => 'the other supplies as modelled',
                                  required_flow => $Q->($_->{flow}), required_pressure => $P->($_->{pressure}),
                                  available_pressure => $P->($_->{available}), margin => $P->($_->{margin}),
                                  governing => $_->{governing}, acceptance => $_->{acceptance},
                                  others_reverse => $_->{others_reverse} } } @{ $s->{conditional} } ]
        if $s->{conditional};
    if (my $jd = $s->{joint}) {
        $j->{joint} = $jd->{reason} ? { reason => $jd->{reason} } : {
            basis => $jd->{basis}, assumption => $jd->{assumption},
            ($jd->{basis} eq 'DERATE' ? (derating => $P->($jd->{delta})) : (factor => r4($jd->{factor}))),
            margin => $P->($jd->{margin}), governing => $jd->{governing}, acceptance => $jd->{acceptance},
            total_flow => $Q->($jd->{q_total}),
            supplies => [ map { { id => $_->{id}, flow => $Q->($_->{flow}), pressure => $P->($_->{pressure}),
                                  available_pressure => $P->($_->{available}), margin => $P->($_->{margin}),
                                  share_percent => r4($_->{share}), status => $_->{status} } } @{ $jd->{supplies} } ],
        };
    }
    $j->{scenarios} = [ map { my $sc = $_; {
        name => $sc->{name}, description => $sc->{description},
        required => $sc->{required} ? JSON::PP::true : JSON::PP::false, line => $sc->{line},
        definition => { map { $_ => 0 + $sc->{shares}{$_} } keys %{ $sc->{shares} } },
        acceptance => $sc->{acceptance}, governing => $sc->{governing}, margin => $P->($sc->{margin}),
        findings => $sc->{findings} || [], error => $sc->{error},
        supplies => [ map { { id => $_->{id}, percent => 0 + $_->{percent}, flow => $Q->($_->{flow}),
                              pressure => $P->($_->{pressure}), status => $_->{status} } } @{ $sc->{supplies} } ],
    } } @{ $s->{scenarios} } ] if $s->{scenarios};
    return $j;
}

#------------------------------------------------------------------------------
# dpv_json -- each dry pipe valve: its configuration, its steady-state
# hydraulics, and its validation.  delivery_time is always null: it is not
# calculated.
#------------------------------------------------------------------------------
sub dpv_json {
    my ($net, $va) = @_;
    my ($uf, $up) = @{$net}{qw(f_flow f_pres)};
    my @out;
    for my $e (grep { $_->{kind} eq 'DPV' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        my ($hf) = HardyCross::elem_hf($e, $e->{q}, $net->{opts});
        my @err = map { $_->{code} } grep { ($_->{item} // '') eq $e->{id} && $_->{severity} eq 'error' } @{ $va->{findings} };
        push @out, {
            id => $e->{id}, pipe => $e->{host_id}, from => $net->{nodes}[ $e->{n1} ]{id},
            to => $net->{nodes}[ $e->{n2} ]{id}, nominal_size => $e->{size}, model => $e->{model},
            trip_method => $e->{trip_mode}, trip_ratio => r4($e->{trip_ratio}),
            trip_pressure => defined $e->{trip_pressure} ? r4($e->{trip_pressure} / $up) : undef,
            accelerator => $e->{accelerator},
            loss_basis => $e->{loss}, equivalent_length => r4($e->{eql}),
            database_valve => $e->{db} ? { maker => $e->{db}{maker}, model => $e->{db}{model}, dn => 0 + $e->{db}{dn},
                                           reference_bore => r4($e->{ref_bore}),
                                           reference_c => defined $e->{ref_c} ? 0 + $e->{ref_c} : undef,
                                           cv => defined $e->{cv} ? 0 + $e->{cv} : undef,
                                           published_trip => $e->{db}{trip}, rated_pressure => $e->{db}{pmax},
                                           status => $e->{db}{status}, source => $e->{db}{source} } : undef,
            flow => r4($e->{q} / $uf), loss => r4($hf / $up),
            state => 'TRIPPED_OPEN',
            initial_air_pressure => defined $e->{transient}{air_initial} ? r4($e->{transient}{air_initial} / $up) : undef,
            delivery_time => undef, delivery_time_calculated => JSON::PP::false,
            validation => @err ? 'FAIL' : 'PASS', findings => \@err,
        };
    }
    return \@out;
}

#------------------------------------------------------------------------------
# traceability -- what produced these results: the program and its version,
# the model's fingerprint, the database's, the method, the tolerances, and
# the assumptions applied.
#------------------------------------------------------------------------------
sub traceability {
    my ($net, $va) = @_;
    require Digest::SHA;
    my $text = $net->{source_text};
    my @assume;
    push @assume, 'every dry pipe valve tripped and fully open (steady state); no delivery time calculated'
        if grep { $_->{kind} eq 'DPV' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    push @assume, 'joint demand of the supplies on the ' . (($net->{opts}{joint_basis} // 'DERATE') eq 'DERATE'
        ? 'uniform pressure derating' : 'uniform pressure scaling') . ' basis'
        if HardyCross::Demand::supplies($net) > 1;
    push @assume, 'pressure ratio valves at the bottom of their band' if grep { $_->{kind} eq 'RATIO' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    push @assume, 'velocity pressure included at in-line sprinklers (AS 2118.1 Cl 14.15)' if $net->{opts}{vel_press};
    push @assume, 'supply, pump and loss curves extrapolated linearly beyond their last point'
        if grep { $_->{code} eq 'CURVE_EXTRAPOLATED' } @{ $va->{findings} };
    return {
        program => "PHCP $HardyCross::VERSION", version => $HardyCross::VERSION,
        # The model without any results block saved in it (HardyCross::Results).
        model_sha256 => defined $text ? do { require HardyCross::Results; HardyCross::Results::fingerprint($text) } : undef,
        database => HardyCross::PipeData::path()
            ? { name => HardyCross::PipeData::dataset(), sha256 => HardyCross::PipeData::sha256() } : undef,
        method => $va->{solver}{method} eq 'DW' ? 'Darcy-Weisbach' : 'Hazen-Williams',
        algorithm => $va->{solver}{algorithm},
        tolerances => { flow => $va->{solver}{tol_flow}, loop => $va->{solver}{tol_loop},
                        maxiter => $va->{solver}{maxiter} },
        assumptions => \@assume,
        scenarios => [ map { { name => $_->{name}, line => $_->{line},
                               shares => { map { $_->[0] => 0 + $_->[1] } @{ $_->{shares} } } } }
                       @{ $net->{scenarios} || [] } ],
    };
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
             status => 'error', acceptance => 'ERROR', converged => JSON::PP::false,
             errors => [ { line => $line, message => uc $msg } ],
             summary => [ 'NOT SOLVED: ' . uc($msg) . (defined $line ? " (LINE $line)" : '') ] };
}

# encode -- the object as JSON text: keys in a fixed order, indented, one
# value a line -- so a caller with no JSON reader (AutoLISP) can still find
# the summary lines by reading line by line.
sub encode { return JSON::PP->new->canonical->pretty->ascii->encode(shift) }

1;
