#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# HardyCross/Sizing.pm -- auto pipe sizing: a pipe given size 0 is sized.
#
# WHAT IS ASKED
#   A PIPE (or CHANGEPIPE) line with SIZE 0, under a USE <pipetype>, asks PHCP
#   to choose the size from the sizes the database has for that pipe type.
#   Two settings say how:
#
#     OPTION SIZING_GOAL   SMALLEST   the smallest pipes that will do (the
#                                     default)
#                          VOLUME     the least water held in the sized pipes
#                                     (what matters for a dry or preaction
#                                     system's trip time)
#     OPTION SIZING_MARGIN 10%        the system must need at least 10 % less
#                                     than the supply gives at the demand flow
#                          50         ...or 50 (in the PRESSURE unit) less
#                                     (blank: 0, no margin)
#     OPTION SIZING_TRIALS 5          how many trials the search makes (1 to
#                                     50; blank: 5)
#
# WHAT "WILL DO" MEANS
#   With the sized pipes, every outlet gets at least its requirement from a
#   supply reduced by the margin, and no sized pipe runs faster than the
#   velocity limit (OPTION VEL_LIMIT, 6 m/s unless set) at the operating
#   point - the supply as it is, the most water the pipes carry, and the
#   condition the report's velocity warnings are for.  With one supply that
#   is the same as: the demand point lies the margin below the supply curve,
#   and that is checked at the end with the demand point itself.  With design
#   areas (AREA) every area must pass.  Pipes not given size 0 are never
#   changed.
#
# HOW THE SIZES ARE FOUND
#   Several trials, each from a different start; the best that passes wins.
#   "Best" is the least sum of length x bore over the sized pipes (SMALLEST),
#   or the least water they hold (VOLUME).
#
#     trial 1      from the smallest sizes
#     trial 2      from the largest sizes
#     trial 3 ...  from the best so far, with about a third of the pipes
#                  moved a size or two up and a third a size down - by a
#                  fixed sequence, so the same model always gives the same
#                  sizes
#
#   Each trial:
#   1. UP.  While the network does not pass, the one pipe whose next size up
#      closes the most of the shortfall for its cost is made one size larger.
#      The cost of a step is one size (SMALLEST), or the water it adds
#      (VOLUME).  The shortfall is the governing outlet's pressure short of
#      its requirement, plus any velocity over the limit, weighted.
#   2. DOWN.  Each pipe is tried one size smaller, the biggest saving first,
#      and kept smaller if the network still passes, until none can be.
#   3. SWAP.  One pipe a size up and another a size down, kept when it still
#      passes and costs less - what a step at a time cannot find (skipped for
#      more than $SWAP_MAX pipes).
#   A search, not a proof: it finds a good answer, not always the very best
#   one, and the report lists each trial and which one won.
#
#   A PIPE line sizes its pipe and every copy of it (PC) not changed since:
#   copies are the same pipe by definition.  A CHANGEPIPE line sizes the one
#   pipe it changes.
#
# THE ANSWER
#   The sizes are put into the model text, which is then solved and reported
#   like any other.  annotate() writes each size back into the user's own
#   text as a comment after the line, //AS - 25, leaving SIZE 0 so the pipe is
#   sized again next time.
#==============================================================================
package HardyCross::Sizing;

use strict;
use warnings;
use HardyCross;
use HardyCross::PipeData;

our $VEL_WEIGHT = 50;      # kPa of shortfall counted per m/s over the limit
our $MAX_STEPS  = 2000;    # a ceiling on the search, never reached in practice
our $SWAP_MAX   = 40;      # the swap pass is skipped for more pipes than this
our $TRIALS     = 5;       # trials unless OPTION SIZING_TRIALS says otherwise

my $PI = 4 * atan2(1, 1);

#------------------------------------------------------------------------------
# choices -- the sizes a pipe of $type with fittings @$fits may be: every DN
# the database has for the type at which each fitting has a value, smallest
# first, as [ dn, token, bore_mm ].  token is the size as the SIZE unit writes
# it: the DN, or with SIZE IN the nominal inch size (a DN with no inch size is
# left out).
#------------------------------------------------------------------------------
sub choices {
    my ($type, $fits, $unit) = @_;
    HardyCross::Parse::ensure_db();
    require HardyCross::Phc;
    my %inch = reverse HardyCross::Phc::inch_sizes();
    my $spec = join ',', map { HardyCross::Phc::fitting_code($_) } @{ $fits || [] };
    my @out;
    for my $dn (1 .. 1200) {
        next unless HardyCross::PipeData::pipe_row($type, $dn);
        my $bore = HardyCross::PipeData::bore($type, $dn) or next;
        if (length $spec) {
            my $r = HardyCross::PipeData::resolve(type => $type, dn => $dn, spec => $spec);
            next unless defined $r->{total};
        }
        my $tok = ($unit // 'MM') eq 'IN' ? $inch{$dn} : $dn;
        push @out, [ $dn, $tok, $bore ] if defined $tok;
    }
    return \@out;
}

#------------------------------------------------------------------------------
# margin_of -- the SIZING_MARGIN setting as { kind => 'PERCENT', f } or
# { kind => 'FIXED', p } (p in kPa), with the text the report prints.
#------------------------------------------------------------------------------
sub margin_of {
    my ($v, $net) = @_;
    return { kind => 'FIXED', p => 0, text => 'none (SIZING_MARGIN not set)' } unless defined $v && length $v;
    return { kind => 'PERCENT', f => $1 / 100, text => "$1% of the supply pressure" } if $v =~ /^([\d.]+)%\z/;
    require HardyCross::Report;
    return { kind => 'FIXED', p => $v * $net->{f_pres},
             text => sprintf('%s %s below the supply', $v, HardyCross::Report::sym($net->{u_pres})) };
}

# reduce -- every supply in a network lowered by the margin (plus $extra
# kPa): what the sized network must still satisfy.  A curve is moved along
# the flow axis by the hose allowance too, since the hose flow is drawn from
# the supply as well.
sub reduce {
    my ($net, $m, $extra) = @_;
    my @sup = grep { $_->{kind} =~ /^SUPPLY_/ } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    my $hose = @sup == 1 ? ($net->{opts}{hose} // 0) : 0;
    my $g = sub {
        my $p = shift;
        $p = $m->{kind} eq 'PERCENT' ? $p * (1 - $m->{f}) : $p - $m->{p};
        return $p - $extra;
    };
    for my $s (@sup) {
        if ($s->{kind} eq 'SUPPLY_STATIC') { $s->{pstat} = $g->($s->{pstat}); next }
        my $c = $s->{curve};
        my @q = (0, grep { $_ > 1e-9 } map { $_ - $hose } @{ $c->{q} });
        push @q, $q[-1] + ($c->{qhi} || 1) if @q < 2;
        my %seen;
        @q = grep { !$seen{ sprintf '%.9g', $_ }++ } @q;
        $s->{curve} = HardyCross::fit_curve({ q => \@q, p => [ map { $g->(HardyCross::curve_eval($c, $_ + $hose)) } @q ] }, 0);
    }
}

#------------------------------------------------------------------------------
# size -- ($net, $ok) of the model with its size-0 pipes sized; a model with
# none is returned as it is.  The network returned is read from the sized
# text (so every later re-read - the demand point, design areas - sees the
# sizes) and carries sizing: { units => [ { line, kind, pipes, type, dn,
# token, velocity } ], goal, margin (text), passes, demand_margin, required,
# solves }.
#------------------------------------------------------------------------------
sub size {
    my ($net, $ok, %arg) = @_;
    my $units = $net->{auto_sizing} or return ($net, $ok);
    require HardyCross::Phc;
    require HardyCross::Demand;
    my $text = $net->{source_text};
    my @lines = split /\n/, $text, -1;
    my $o = $net->{sizing_opts} || {};
    my $goal = $o->{SIZING_GOAL} // 'SMALLEST';
    my $ntrials = $o->{SIZING_TRIALS} // $TRIALS;
    # progress -- called as the search goes, with a line saying where it is,
    # so a window can show that it is working, not stuck.
    my $progress = $arg{progress};
    my $trial = 0;
    my $m = margin_of($o->{SIZING_MARGIN}, $net);
    my $vlim = $net->{opts}{vel_limit} // 6;
    my %len = map { $_->{id} => $_->{len} } grep { $_->{kind} eq 'PIPE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    for my $u (@$units) {
        $u->{length} = 0;
        $u->{length} += $len{$_} // 0 for @{ $u->{pipes} };
    }
    my @cases = $net->{areas} && !defined $net->{design_area} ? map { $_->{name} } @{ $net->{areas} } : (undef);
    my $dir = $net->{model_dir};
    my $solves = 0;

    # The model text with each unit at the size chosen by @$idx.
    my $sized = sub {
        my $idx = shift;
        my @l = @lines;
        for my $i (0 .. $#$units) {
            my $u = $units->[$i];
            $l[ $u->{line} - 1 ] = set_field($l[ $u->{line} - 1 ], $u->{field}, $u->{choices}[ $idx->[$i] ][1]);
        }
        return join "\n", @l;
    };
    # How far the network is from passing with the supplies reduced: 0 when
    # it passes; the solve's velocities of each unit for the search.
    my $extra = 0;
    my $assess = sub {
        my $idx = shift;
        my $t = $sized->($idx);
        $t .= "\n" unless $t =~ /\n\z/;
        $progress->(sprintf('AUTO SIZING %d PIPE%s - TRIAL %d OF %d - %d SOLVES', scalar @$units,
                            @$units == 1 ? '' : 'S', $trial || 1, $ntrials, $solves)) if $progress;
        my ($short, @vel) = (0);
        for my $case (@cases) {
            my $case_text = $t . (defined $case ? "OPTION DESIGN_AREA $case\n" : '');
            # The outlets: with every supply reduced by the margin.
            my $n = eval { HardyCross::Phc::read_string($case_text, $dir) } or return { short => 1e12 };
            reduce($n, $m, $extra);
            $solves++;
            my $c = eval { HardyCross::solve_model($n) };
            return { short => 1e9 } unless $c;
            my (undef, $mg) = HardyCross::Demand::governing_outlet($n);
            $short += -$mg if defined $mg && $mg < 0;
            # The velocities: at the operating point, with the supply as it
            # is - the most water the pipes carry, and what the report flags.
            my $f = eval { HardyCross::Phc::read_string($case_text, $dir) } or return { short => 1e12 };
            $solves++;
            eval { HardyCross::solve_model($f) } or return { short => 1e9 };
            my %e = map { ($_->{id} // '') => $_ } @{ $f->{elems} }[1 .. $#{ $f->{elems} }];
            for my $i (0 .. $#$units) {
                for my $p (@{ $units->[$i]{pipes} }) {
                    my $e = $e{$p} or next;
                    my $v = abs HardyCross::pipe_velocity($e->{q}, $e->{dia});
                    $vel[$i] = $v if !defined $vel[$i] || $v > $vel[$i];
                    $short += $VEL_WEIGHT * ($v - $vlim) if $v > $vlim + 1e-9;
                }
            }
        }
        return { short => $short, vel => \@vel };
    };
    my $volume = sub { my ($u, $k) = @_; $u->{length} * $PI / 4 * ($u->{choices}[$k][2] / 1000) ** 2 };
    my $cost = sub {
        my ($i, $from, $to) = @_;
        return $goal eq 'VOLUME' ? abs($volume->($units->[$i], $to) - $volume->($units->[$i], $from)) || 1e-12 : 1;
    };

    # What is made least: the pipes' size, length-weighted (SMALLEST), or
    # the water they hold (VOLUME).
    my $objective = sub {
        my $idx = shift;
        my $sum = 0;
        for my $i (0 .. $#$units) {
            my $d = $units->[$i]{choices}[ $idx->[$i] ][2] / 1000;
            $sum += $units->[$i]{length} * ($goal eq 'VOLUME' ? $PI / 4 * $d * $d : $d);
        }
        return $sum;
    };
    my $passes_at = sub { $assess->(shift)->{short} <= 1e-6 };
    my $top = sub { $#{ $units->[ $_[0] ]{choices} } };

    # up -- one size at a time, the step doing most good for its cost,
    # until the network passes.  False if even the largest sizes do not.
    my $up = sub {
        my $idx = shift;
        my $now = $assess->($idx);
        my $steps = 0;
        while ($now->{short} > 1e-6 && $steps++ < $MAX_STEPS) {
            my ($best, $bscore, $bres);
            for my $i (0 .. $#$units) {
                next if $idx->[$i] >= $top->($i);
                my @t = @$idx;
                $t[$i]++;
                my $r = $assess->(\@t);
                my $score = ($now->{short} - $r->{short}) / $cost->($i, $idx->[$i], $t[$i]);
                ($best, $bscore, $bres) = ($i, $score, $r) if !defined $bscore || $score > $bscore;
            }
            last unless defined $best;
            # No step helps (the network does not solve yet, say): enlarge
            # the fastest pipe.
            if ($bscore <= 0) {
                my @open = grep { $idx->[$_] < $top->($_) } 0 .. $#$units;
                ($best) = sort { ($now->{vel}[$b] // 0) <=> ($now->{vel}[$a] // 0) } @open;
                my @t = @$idx; $t[$best]++;
                $bres = $assess->(\@t);
            }
            $idx->[$best]++;
            $now = $bres;
        }
        return $now->{short} <= 1e-6;
    };
    # down -- each pipe one size smaller, the biggest saving first, kept
    # while the network still passes, until none can be.
    my $down = sub {
        my $idx = shift;
        my $changed = 1;
        while ($changed) {
            $changed = 0;
            my @order = sort { $cost->($b, $idx->[$b], $idx->[$b] - 1) <=> $cost->($a, $idx->[$a], $idx->[$a] - 1)
                               || $units->[$b]{choices}[ $idx->[$b] ][0] <=> $units->[$a]{choices}[ $idx->[$a] ][0] }
                        grep { $idx->[$_] > 0 } 0 .. $#$units;
            for my $i (@order) {
                my @t = @$idx; $t[$i]--;
                if ($passes_at->(\@t)) { @$idx = @t; $changed = 1 }
            }
        }
    };
    # swap -- one pipe a size up and another a size down, kept when it
    # still passes and costs less: what a step at a time cannot find.
    my $swap = sub {
        my $idx = shift;
        return if @$units > $SWAP_MAX;
        my $better = 1;
        while ($better) {
            $better = 0;
            PAIR: for my $i (0 .. $#$units) {
                next if $idx->[$i] >= $top->($i);
                for my $j (grep { $_ != $i && $idx->[$_] > 0 } 0 .. $#$units) {
                    my @t = @$idx;
                    $t[$i]++; $t[$j]--;
                    next unless $objective->(\@t) < $objective->($idx) - 1e-12;
                    if ($passes_at->(\@t)) { @$idx = @t; $better = 1; last PAIR }
                }
            }
        }
    };
    # A fixed sequence of "random" numbers, so the same model always gives
    # the same sizes.
    my $seed = 20261101;
    my $rand = sub { $seed = ($seed * 1103515245 + 12345) % 2147483648; $seed / 2147483648 };

    my (@idx, @trials, $passes, $dmargin, $required);
    for my $round (1 .. 6) {
        @trials = ();
        my ($best, $bobj);
        for my $k (1 .. $ntrials) {
            $trial = $k;
            my $before = $solves;
            my @t;
            my $from;
            if ($k == 1)    { @t = (0) x @$units; $from = 'the smallest sizes' }
            elsif ($k == 2) { @t = map { $top->($_) } 0 .. $#$units; $from = 'the largest sizes' }
            else {
                # From the best so far, with about a third of the pipes moved
                # a size or two up and a third a size down.
                last unless $best;
                @t = @$best;
                for my $i (0 .. $#t) {
                    my $r = $rand->();
                    $t[$i] += 1 + int($rand->() * 2) if $r < 1 / 3;
                    $t[$i] -= 1 if $r > 2 / 3;
                    $t[$i] = 0 if $t[$i] < 0;
                    $t[$i] = $top->($i) if $t[$i] > $top->($i);
                }
                $from = 'the best so far, varied';
            }
            my $ok = $up->(\@t);
            if ($ok) { $down->(\@t); $swap->(\@t) }
            my $obj = $objective->(\@t);
            push @trials, { trial => $k, from => $from, passes => $ok ? 1 : 0, objective => $obj,
                            solves => $solves - $before, sizes => [ map { $units->[$_]{choices}[ $t[$_] ][0] } 0 .. $#t ] };
            ($best, $bobj) = ([@t], $obj) if $ok && (!defined $bobj || $obj < $bobj - 1e-12);
            # The largest sizes do not pass: no trial can.
            last if $k == 2 && !$ok && !$best;
        }
        unless ($best) {                       # nothing passes: the largest sizes
            @idx = map { $top->($_) } 0 .. $#$units;
            $passes = 0;
            last;
        }
        @idx = @$best;
        # The first trial to reach the best is the one chosen; any other
        # reaching it too is marked SAME.
        my $marked;
        for (@trials) {
            next unless $_->{passes} && abs($_->{objective} - $bobj) < 1e-12;
            $_->{$marked ? 'same' : 'best'} = 1;
            $marked = 1;
        }

        # The check that counts: with one supply, the demand point itself.
        ($passes, $dmargin, $required) = (1, undef, undef);
        my $t = $sized->(\@idx);
        for my $case (@cases) {
            my $n = HardyCross::Phc::read_string($t . ($t =~ /\n\z/ ? '' : "\n")
                                                 . (defined $case ? "OPTION DESIGN_AREA $case\n" : ''), $dir);
            HardyCross::solve_model($n) or do { $passes = 0; next };
            my $d = HardyCross::Demand::demand_point($n);
            next unless defined $d->{margin};
            my $need = $m->{kind} eq 'PERCENT' ? $m->{f} * $d->{p_avail} : $m->{p};
            my $gap = $d->{margin} - $need;
            ($dmargin, $required) = ($d->{margin}, $need) if !defined $dmargin || $gap < $dmargin - $required;
            $passes = 0 if $gap < -0.01;
        }
        last if $passes;
        # Short at the demand point (the reduced curve is drawn through
        # fewer points): ask for that much more and search again.
        $extra += ($required - $dmargin) + 0.5;
    }
    $passes = 0 unless defined $passes;

    # The answer, solved and reported as any model.
    my $t = $sized->(\@idx);
    my $out = HardyCross::Phc::read_string($t, $dir);
    my $c = HardyCross::solve_model($out);
    my %e = map { ($_->{id} // '') => $_ } @{ $out->{elems} }[1 .. $#{ $out->{elems} }];
    my @res;
    for my $i (0 .. $#$units) {
        my $u = $units->[$i];
        my ($v) = sort { $b <=> $a } map { abs HardyCross::pipe_velocity($_->{q}, $_->{dia}) } grep { $_ } @e{ @{ $u->{pipes} } };
        push @res, { line => $u->{line}, kind => $u->{kind}, pipes => [ @{ $u->{pipes} } ], type => $u->{type},
                     lines => [ sort { $a <=> $b } keys %{ $u->{lines} } ],
                     dn => $u->{choices}[ $idx[$i] ][0], token => $u->{choices}[ $idx[$i] ][1], velocity => $v };
    }
    $out->{sizing} = { units => \@res, goal => $goal, margin => $m->{text}, passes => $passes,
                       trials => \@trials, ntrials => $ntrials,
                       demand_margin => $dmargin, required => $required, solves => $solves,
                       vel_limit => $vlim, text => $text };
    push @{ $out->{warnings} }, 'auto sizing: even the largest sizes in the database do not meet the demand with '
        . "the margin asked for ($m->{text}); the pipes are left at those sizes" unless $passes;
    $out->{converged} = $c;
    return ($out, $c);
}

#------------------------------------------------------------------------------
# set_field -- a .phc line with its $n-th field (0 = the command) replaced,
# spacing and comment kept.
#------------------------------------------------------------------------------
sub set_field {
    my ($line, $n, $value) = @_;
    my ($code, $rest) = $line =~ m{^(.*?)((?://.*)?)\z}s;
    my $i = -1;
    $code =~ s/(\S+)/++$i == $n ? $value : $1/ge;
    return $code . $rest;
}

#------------------------------------------------------------------------------
# annotate -- the user's own .phc text with each sized pipe's size written as
# a comment after its line: //AS - 25.  SIZE 0 is left as it is, so the pipe
# is sized again next time; an earlier //AS comment is replaced.  A line with
# a comment of its own keeps it, after the size.  $offset is subtracted from
# each line number (the editor shows the network without its settings).
#------------------------------------------------------------------------------
sub annotate {
    my ($text, $sizing, $offset) = @_;
    my @l = split /\n/, $text, -1;
    my %tok;
    for my $u (@{ $sizing->{units} || [] }) {
        $tok{ $_ - ($offset // 0) } = $u->{token} for @{ $u->{lines} };
    }
    for my $n (keys %tok) {
        next if $n < 1 || $n > @l;
        $l[ $n - 1 ] = mark($l[ $n - 1 ], $tok{$n});
    }
    return join "\n", @l;
}

# mark -- one line with //AS - <size> after its fields.
sub mark {
    my ($line, $tok) = @_;
    my ($code, $comment) = $line =~ m{^(.*?)\s*((?://.*)?)\z}s;
    $comment =~ s{^//AS - \S+\s*}{};
    return "$code  //AS - $tok" . (length $comment ? " $comment" : '');
}

# clear -- the //AS comments taken off again (a pipe no longer sized).
sub clear {
    my $text = shift;
    $text =~ s{[ \t]*//AS - \S+[ \t]*(//)}{ $1}mg;
    $text =~ s{[ \t]*//AS - \S+[ \t]*$}{}mg;
    return $text;
}

1;
