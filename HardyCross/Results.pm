#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# HardyCross/Results.pm -- the results of a solve, kept in the .phc itself.
#
# The model and its last results travel as one file: no JSON beside it to
# lose or to fall out of step.  The results are a block at the end of the
# .phc, every line a comment, so the model reads and solves exactly as it
# did without them:
#
#   //== PHCP RESULTS ... (replaced on every solve; edit the model, not this)
#   //= RESULT  ACCEPTANCE ACCEPTED NUMERICAL PASS PHYSICAL PASS DESIGN PASS
#   //= MODEL   SHA256 <the model's fingerprint, without this block>
#   //= PIPE    P1 FLOW 123.4567 VELOCITY 2.123 LOSS 3.4567
#   ...
#   //== END PHCP RESULTS
#
# Each "//=" line is a record: a word saying what it is, then fields in
# fixed pairs of NAME VALUE, so a program can read it with a split, and a
# person can read it as it stands.  Flows and pressures are in the model's
# own units (the UNITS record says which), as in the report.
#
# A block is written only for the text it was worked out from.  The model
# fingerprint is the SHA-256 of the model WITHOUT the block, so a reader can
# tell whether the results still belong to the model above them: if the
# model has been edited since, the fingerprint no longer matches and the
# results are stale.  PHCP itself drops a stale block rather than keep it
# (the editor saves without one when the last calculation was of other
# text; phcp.pl --save always writes a fresh one).
#==============================================================================
package HardyCross::Results;

use strict;
use warnings;
use HardyCross;
use HardyCross::PipeData;

our $BEGIN = '//== PHCP RESULTS';
our $END   = '//== END PHCP RESULTS';

#------------------------------------------------------------------------------
# strip -- the model text with any results block removed, and the blank
# lines before it.  Everything else is left exactly as it was.
#------------------------------------------------------------------------------
sub strip {
    my $text = shift // '';
    # The model's own last newline stays; the blank line before the block
    # and the block go.
    $text =~ s/(\n)\n*^\Q$BEGIN\E[^\n]*\n.*?^\Q$END\E[^\n]*(?:\n|\z)/$1/ms
        or $text =~ s/\A\Q$BEGIN\E[^\n]*\n.*?^\Q$END\E[^\n]*(?:\n|\z)//ms;
    return $text;
}

# fingerprint -- the SHA-256 of the model without its results block.
sub fingerprint {
    require Digest::SHA;
    return Digest::SHA::sha256_hex(strip(shift));
}

#------------------------------------------------------------------------------
# block -- the results block for a solved network, as text ending in "\n".
#   $net, $ok  the solved network and solve_model's result
#   $text      the model text it was solved from (for the fingerprint)
#------------------------------------------------------------------------------
sub block {
    my ($net, $ok, $text) = @_;
    require HardyCross::Validate;
    require HardyCross::Demand;
    require HardyCross::Report;
    my $as = HardyCross::Validate::assess($net, $ok);
    my $va = $as->{validation};
    my ($uf, $up) = @{$net}{qw(f_flow f_pres)};
    my $GW = $HardyCross::GAMMA_W;
    my @l;
    my $rec = sub { my $w = shift; push @l, sprintf('//= %-8s %s', $w, join ' ', map { defined $_ ? $_ : '-' } @_) };
    my $num = sub { my ($v, $d) = @_; defined $v ? sprintf("%.${d}f", $v) : '-' };
    my $word = sub { my $s = shift // '-'; $s =~ s/\s+/_/g; $s =~ s/[^\x21-\x7E]//g; length $s ? $s : '-' };

    my @t = gmtime;
    push @l, sprintf('%s - PHCP %s, %04d-%02d-%02d %02d:%02d UTC.  Replaced on every solve: edit the model above, '
                   . 'not these lines.', $BEGIN, $HardyCross::VERSION, $t[5] + 1900, $t[4] + 1, @t[3, 2, 1]);
    $rec->('RESULT', ACCEPTANCE => $va->{acceptance}, NUMERICAL => $va->{numerical}{status},
           PHYSICAL => $va->{physical}{status}, DESIGN => $va->{design}{status});
    $rec->('MODEL', SHA256 => fingerprint($text // $net->{source_text} // ''));
    if (HardyCross::PipeData::path()) {
        $rec->('DATABASE', SHA256 => HardyCross::PipeData::sha256());
    }
    $rec->('UNITS', FLOW => $net->{u_flow}, PRESSURE => $net->{u_pres}, LENGTH => 'M', SIZE => 'MM', VELOCITY => 'M/S');
    my $s = $va->{solver};
    $rec->('SOLVER', METHOD => $s->{method}, ITERATIONS => $s->{iterations}, CONVERGED => $s->{hc_converged} ? 'YES' : 'NO',
           SETTLED => $s->{outer_settled} ? 'YES' : 'NO', TOL_FLOW => $s->{tol_flow}, TOL_LOOP => $s->{tol_loop});
    for my $k (qw(continuity balance loop element)) {
        my $r = $va->{residuals}{$k} or next;
        $rec->('RESIDUAL', uc($k), sprintf('%.3e', $r->{value}), TOL => sprintf('%.3e', $r->{tolerance}),
               PASS => $r->{pass} ? 'YES' : 'NO');
    }
    my @el = @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    my $nid = sub { $net->{nodes}[ shift ]{id} };
    for my $e (grep { $_->{kind} eq 'PIPE' } @el) {
        my ($hf) = HardyCross::elem_hf($e, $e->{q}, $net->{opts});
        $rec->('PIPE', $e->{id}, FROM => $nid->($e->{n1}), TO => $nid->($e->{n2}), FLOW => $num->($e->{q} / $uf, 4),
               VELOCITY => $num->(HardyCross::pipe_velocity($e->{q}, $e->{dia}), 3), LOSS => $num->($hf / $up, 4));
    }
    for my $i (1 .. $#{ $net->{nodes} }) {
        my $n = $net->{nodes}[$i];
        next if $n->{id} eq 'REF';
        $rec->('NODE', $n->{id}, ELEVATION => $num->($n->{z}, 3), PRESSURE => $num->(($n->{h} - $GW * $n->{z}) / $up, 4));
    }
    for my $e (grep { $_->{kind} eq 'DISCHARGE' } @el) {
        my $p = HardyCross::outlet_pressure($net, $e);
        my $pass = $e->{q} >= $e->{qreq} - 1e-6 && $p >= $e->{preq} - 1e-6;
        $rec->('OUTLET', $e->{id}, TYPE => $e->{otype}, FLOW => $num->($e->{q} / $uf, 4), REQ_FLOW => $num->($e->{qreq} / $uf, 4),
               PRESSURE => $num->($p / $up, 4), REQ_PRESSURE => $num->($e->{preq} / $up, 4),
               MARGIN => $num->(($p - $e->{preq}) / $up, 4), PASS => $pass ? 'YES' : 'NO');
    }
    for my $f (grep { defined $_->{preq} } @{ $net->{fixed} || [] }) {
        my $p = HardyCross::Demand::gauge($net, $f->{n1});
        $rec->('OUTLET', $f->{id}, TYPE => 'FIXEDFLOW', FLOW => $num->($f->{q} / $uf, 4), REQ_FLOW => $num->($f->{qreq} / $uf, 4),
               PRESSURE => $num->($p / $up, 4), REQ_PRESSURE => $num->($f->{preq} / $up, 4),
               MARGIN => $num->(($p - $f->{preq}) / $up, 4), PASS => $p >= $f->{preq} - 1e-6 ? 'YES' : 'NO');
    }
    for my $e (grep { $_->{kind} =~ /^SUPPLY_/ } @el) {
        $rec->('SUPPLY', $e->{id}, NODE => $nid->($e->{n2}), FLOW => $num->($e->{q} / $uf, 4),
               PRESSURE => $num->(HardyCross::Demand::gauge($net, $e->{n2}) / $up, 4),
               STATUS => $e->{closed} ? 'OUT_OF_SERVICE' : $e->{q} < -$HardyCross::Q_TINY ? 'REVERSE' : 'DELIVERING');
    }
    for my $e (grep { $_->{kind} !~ /^(PIPE|DISCHARGE|SUPPLY_)/ } @el) {
        my ($hf) = $e->{closed} ? (0) : HardyCross::elem_hf($e, $e->{q}, $net->{opts});
        $rec->('DEVICE', $e->{id}, KIND => $e->{kind}, FLOW => $num->($e->{q} / $uf, 4), LOSS => $num->($hf / $up, 4),
               STATE => $e->{closed} ? 'CLOSED' : 'OPEN',
               ($e->{kind} eq 'DPV' ? (MODEL => $word->($e->{db_model} // $e->{model}), BASIS => $e->{loss}) : ()),
               ($e->{kind} eq 'ORIFICE' ? (BORE => $num->($e->{bore}, 2)) : ()));
    }
    my ($go, $gm) = HardyCross::Demand::governing_outlet($net);
    $rec->('GOVERNS', $go->{id}, MARGIN => $num->($gm / $up, 4)) if $go;
    if (my $dm = $as->{demand}) {
        if ($dm->{reason}) { $rec->('DEMAND', NONE => $word->($dm->{reason})) }
        else {
            $rec->('DEMAND', $dm->{supply}{id}, FLOW => $num->($dm->{q_demand} / $uf, 4), PRESSURE => $num->($dm->{p_demand} / $up, 4),
                   AVAILABLE => $num->($dm->{p_avail} / $up, 4), MARGIN => $num->($dm->{margin} / $up, 4),
                   MEETS => $dm->{margin} >= 0 ? 'YES' : 'NO');
        }
    }
    if (my $sp = $as->{supplies}) {
        for my $c (@{ $sp->{conditional} || [] }) {
            $rec->('CONDMIN', $c->{id}, STATUS => $c->{status}, FLOW => $num->(defined $c->{flow} ? $c->{flow} / $uf : undef, 4),
                   PRESSURE => $num->(defined $c->{pressure} ? $c->{pressure} / $up : undef, 4));
        }
        if (my $j = $sp->{joint}) {
            unless ($j->{reason}) {
                $rec->('JOINT', BASIS => $j->{basis}, ($j->{basis} eq 'DERATE' ? (DERATE => $num->($j->{delta} / $up, 4))
                                                                              : (FACTOR => $num->($j->{factor}, 6))),
                       MARGIN => $num->($j->{margin} / $up, 4), GOVERNS => $j->{governing});
                $rec->('JOINT', $_->{id}, FLOW => $num->($_->{flow} / $uf, 4), PRESSURE => $num->($_->{pressure} / $up, 4))
                    for @{ $j->{supplies} };
            }
        }
        for my $sc (@{ $sp->{scenarios} || [] }) {
            $rec->('SCENARIO', $word->($sc->{name}), RESULT => $sc->{acceptance}, REQUIRED => $sc->{required} ? 'YES' : 'NO',
                   MARGIN => $num->(defined $sc->{margin} ? $sc->{margin} / $up : undef, 4));
        }
    }
    for my $f (grep { $_->{severity} ne 'info' } @{ $va->{findings} }) {
        my $m = $f->{message};
        $m =~ s/[^\x20-\x7E]//g;
        push @l, sprintf('//= %-8s %s %s %s %s', 'FINDING', uc $f->{severity}, uc $f->{category}, $f->{code}, $m);
    }
    push @l, $END;
    return join("\n", @l) . "\n";
}

#------------------------------------------------------------------------------
# with_results -- the model text with its results block, fresh, at the end:
# any old block taken out, then one blank line and the new one.
#------------------------------------------------------------------------------
sub with_results {
    my ($text, $net, $ok) = @_;
    my $model = strip($text);
    $model .= "\n" unless $model =~ /\n\z/ || $model eq '';
    return $model . "\n" . block($net, $ok, $model);
}

#------------------------------------------------------------------------------
# read_block -- the records of a results block, for a program that reads a
# .phc for its results: [ [ WORD, field, field, ... ], ... ], or undef with no
# block.  The fingerprint check is the caller's: compare the MODEL SHA256
# with fingerprint() of the same text.
#------------------------------------------------------------------------------
sub read_block {
    my $text = shift // '';
    return undef unless $text =~ /^\Q$BEGIN\E[^\n]*\n(.*?)^\Q$END\E/ms;
    return [ map { [ split ' ', substr($_, 3) ] } grep { /^\/\/= / } split /\n/, $1 ];
}

1;
