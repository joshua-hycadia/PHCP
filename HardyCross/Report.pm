#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# HardyCross/Report.pm -- the calculation report, in monospace ASCII.
#
# WHY PLAIN ASCII
#   The report has to survive being printed, emailed, pasted into a
#   submission, diffed against last week's run and read on whatever a
#   certifier happens to have open.  Box-drawing characters, degree signs and
#   multiplication crosses all turn into question marks somewhere along that
#   chain.  Every character written here is 7-bit printable ASCII, and the
#   last thing the writer does is enforce that.
#
# WHAT IT MUST SAY
#   For each calculation the report states:
#     - each pipe type and the standard it is made to
#     - the C value used
#     - the fitting source and method
#     - the diameter modifier and C multiplier where applicable
#     - any ASSUMPTION_REQUIRED fallback used
#     - any project-specific manufacturer data relied upon
#     - the pipe and fitting database used, by name and SHA-256
#   Sections 2 to 4 below exist to say these things.
#
# THE RULE FOR EVERY NUMBER
#   It must be reproducible by hand from other numbers on the page.  So the
#   fitting table shows the base length, both multipliers and the product; the
#   pipe schedule shows loss per metre, total length and their product; and
#   the two end pressures differ by exactly the loss plus the elevation term.

package HardyCross::Report;

use strict;
use warnings;
use HardyCross;
use HardyCross::PipeData;
use HardyCross::Demand;
use HardyCross::PDF;

# 132 columns: the standard width of a monospace engineering listing, and what
# a 17-column pipe schedule actually needs.  118 was tried first and the pipe
# schedule ran to 136 -- the schedule is the content, so the page grew rather
# than the schedule being split across two tables a checker has to cross-read.
my $W = 132;

#------------------------------------------------------------------------------
# Page furniture.  rule() is the heavy line around a section title, thin() the
# light line under a table's headings, title() a complete section heading with
# an optional clause reference pushed to the right-hand edge.  The PDF writer
# recognises these patterns to decide where pages break, so they are the only
# way section and table boundaries are drawn.
#------------------------------------------------------------------------------
sub rule  { '=' x $W . "\n" }
sub thin  { '-' x $W . "\n" }
sub title {
    my ($t, $ref) = @_;
    my $line = defined $ref ? sprintf(" %-*s%s", $W - 1 - length($ref), $t, $ref) : " $t";
    return "\n" . rule() . "$line\n" . rule();
}
sub sub_t { my $t = shift; "\n $t\n" . thin() }

# Anything the data carries that is not ASCII -- the database's degree signs,
# multiplication crosses and em dashes -- is spelled out rather than dropped.
sub ascii {
    my $t = shift // '';
    $t =~ s/\x{00B0}/ deg/g;          # degree sign
    $t =~ s/\x{00D7}/x/g;             # multiplication sign
    $t =~ s/[\x{2012}-\x{2015}]/-/g;  # dashes
    $t =~ s/[\x{2018}\x{2019}\x{2032}]/'/g;
    $t =~ s/[\x{201C}\x{201D}]/"/g;
    $t =~ s/[^\x20-\x7E\n]/?/g;       # last resort: never emit a non-ASCII byte
    return $t;
}

# A number to a fixed number of places, or '-' when there is none.  A dash is
# an absence; a zero is a measurement.  They must never look alike in a
# schedule a checker is reading.
sub fx { my ($v, $d) = @_; defined $v ? sprintf("%.${d}f", $v) : '-' }

# The model file uses upper-case unit CODES (KPA, LPM).  A certified report
# uses SI SYMBOLS: "KPA" is not a unit, "kPa" is, and the case carries meaning
# (mPa and MPa differ by nine orders of magnitude).
my %SYM = (KPA => 'kPa', BAR => 'bar', MPA => 'MPa', PSI => 'psi', M => 'm',
           MH2O => 'm H2O', MWC => 'm H2O', FTH2O => 'ft H2O', FT => 'ft',
           LPM => 'L/min', 'L/MIN' => 'L/min', LPS => 'L/s', 'L/S' => 'L/s',
           M3H => 'm3/h', 'M3/H' => 'm3/h', GPM => 'US gpm', USGPM => 'US gpm',
           IGPM => 'Imp gpm', MM => 'mm', IN => 'in');
sub sym { my $u = shift // ''; $SYM{ uc $u } // $u }

# Decimal places per unit, chosen so every printed value resolves 0.1 kPa and
# 0.1 L/min or better.  A fixed two decimals was fine in kPa and quietly
# useless in bar: 0.01 bar is 1 kPa, and the stress test found the same model
# reported 0.5 kPa apart in kPa and in bar purely from print rounding.
my %PDP = (KPA => 1, BAR => 3, MPA => 4, PSI => 2, M => 2, MH2O => 2, MWC => 2,
           FTH2O => 2, FT => 2);
my %QDP = (LPM => 1, 'L/MIN' => 1, LPS => 3, 'L/S' => 3, M3H => 3, 'M3/H' => 3,
           GPM => 2, USGPM => 2, IGPM => 2);
# How many decimal places a pressure or a flow needs in the model's own unit.
# 0.1 kPa is enough; 0.1 bar is ten times coarser and would lose the figures
# a hand-check depends on, so each unit carries its own precision.
sub pdp { $PDP{ uc(shift // '') } // 2 }
sub qdp { $QDP{ uc(shift // '') } // 2 }

#------------------------------------------------------------------------------
#==============================================================================
# write_report -- the whole calculation as 132-column ASCII text.
#
#   $net    a network that has been read AND solved
#   $ok     whether it converged; a report of an unconverged model says so on
#           the cover and again in the notes, in capitals
#   $path   the model file, printed on the cover for traceability
#
# The report is assembled top to bottom: cover sheet, then numbered sections.
# Each section is written so that every figure can be reproduced by hand from
# others on the same page, and says which check to make.  The same text feeds
# the PDF writer, so the two formats can never disagree.
#==============================================================================
sub write_report {
    my ($net, $ok, $path) = @_;
    my ($uf, $up, $ul) = @{$net}{qw(f_flow f_pres f_len)};
    my $pj = $net->{project} || {};
    my $o  = $net->{opts};
    my $GW = $HardyCross::GAMMA_W;
    my $out = '';

    # Whether any pipe takes its data from the pipe database; Sections 2
    # and 4 word their provenance statements on it.
    my $uses_db = grep { $_->{ptype} } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];

    #----------------------------------------------------------- cover sheet
    $out .= cover_sheet($net, $ok, $path);

    #------------------------------------------------------------ 1. basis
    # Method, friction equation, units, tolerances and the result: what a
    # reviewer needs before any number in the report means anything.
    $out .= title('1. BASIS OF CALCULATION');
    my $dw = ($o->{method} // 'HW') eq 'DW';
    $out .= sprintf " %-26s %s\n", 'Friction method',
        $dw ? 'Darcy-Weisbach, Colebrook-White friction factor'
            : 'Hazen-Williams, AS 2118.1:2017 Clause 14.10';
    $out .= sprintf " %-26s P = %.4g x Q^%.3f / (C^%.3f x d^%.3f)   kPa/m, Q L/min, d mm\n",
        'Friction equation', $o->{hwk}, $o->{hwq}, $o->{hwq}, $o->{hwd}
        unless $dw;
    if ($dw) {
        # Where each pipe's roughness came from; an assumed one is never
        # passed off as data.
        my %src;
        $src{ $_->{eps_src} // 'GIVEN' }++ for grep { $_->{kind} eq 'PIPE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
        my @parts = ((map { "$src{$_} " . { GIVEN => 'as given in the model', DATABASE => 'from the database for the pipe type' }->{$_} }
                      grep { $src{$_} } qw(GIVEN DATABASE)),
                     ($src{DEFAULT} ? "$src{DEFAULT} ASSUMED 0.045 mm, the program default - see Warnings" : ()));
        $out .= wrap(sprintf(' %-26s ', 'Pipe roughness'), 'Pipes: ' . join('; ', @parts) . '.');
    }
    $out .= sprintf " %-26s flow %s, pressure %s, length %s, diameter %s\n", 'Units',
        map { sym($_) } @{$net}{qw(u_flow u_pres u_len u_dia)};
    $out .= sprintf " %-26s flow %.2g %s, loop %.2g %s, %d iterations maximum\n",
        'Convergence tolerance', $o->{tol_flow} / $uf, sym($net->{u_flow}),
        $o->{tol_loop} / $up, sym($net->{u_pres}), $o->{maxiter};
    # Printed whether or not it was set, and says which: a default the
    # designer never chose must not read as a requirement of the Standard.
    $out .= sprintf " %-26s %g m/s  (%s)\n", 'Velocity limit', $o->{vel_limit} // 6,
        $o->{vel_limit_set} ? 'set in the model OPTIONS'
                            : 'program default - not set in the model, not from a standard';
    $out .= sprintf " %-26s %s\n", 'Result',
        $ok ? sprintf('CONVERGED in %d iterations, %d loops', $net->{iters},
                      scalar @{ $net->{loops} })
            : '*** NOT CONVERGED - NOTHING IN THIS REPORT IS USABLE ***';
    $out .= "\n Node head is total head referred to datum: H = p + 9.80665 z  (kPa, m).\n";
    $out .= " Loops are fundamental loops of a spanning tree; supplies and outlets are\n";
    $out .= " edges to a reference node at datum, so pseudo-loops tie fixed-grade points.\n";

    #-------------------------------------------------------- 2. pipe data
    # Which pipe types were used, the standard each is made to, the C factors
    # in force, and the database the dimensions came from.
    $out .= title('2. PIPE DATA');
    my %used;
    for my $e (@{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        next unless $e->{kind} eq 'PIPE';
        my $k = $e->{ptype} // '(untyped)';
        $used{$k}{c}{ $e->{c} } = 1;
        $used{$k}{n}++;
    }
    $out .= sprintf " %-10s %-40s %-14s %-10s %6s\n",
        'CODE', 'PIPE TYPE', 'STANDARD', 'C', 'PIPES';
    $out .= thin();
    for my $k (sort keys %used) {
        my $info = $k eq '(untyped)' ? undef : HardyCross::PipeData::pipe_type($k);
        $out .= sprintf " %-10s %-40s %-14s %-10s %6d\n", $k,
            $info ? ascii($info->{name}) : 'bore entered directly',
            $info ? ascii($info->{std}) : '-',
            join('/', sort { $a <=> $b } keys %{ $used{$k}{c} }), $used{$k}{n};
    }

    #--------------------------------------------------- 3. fitting allowances
    # Every fitting on every pipe, with its source, base length, both
    # multipliers and the product, so each allowance can be recomputed from
    # the page.
    $out .= title('3. FITTING ALLOWANCES');
    my @fitted = grep { $_->{kind} eq 'PIPE' && $_->{fitres} && @{ $_->{fitres}{records} } }
                 @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    if (!@fitted) {
        $out .= " No fitting strings in this model.  Any fitting allowance was entered directly\n";
        $out .= " as an equivalent length and carries no database provenance.\n";
    } else {
        $out .= sprintf " %-7s %-4s %3s %-5s %-36s %-4s %6s %8s %6s %6s %7s %7s  %s\n",
            'PIPE', 'DN', 'QTY', 'CODE', 'FITTING', 'SRC', 'BASE m', 'BASIS mm',
            'C MUL', 'D MUL', 'EACH m', 'TOTAL m', 'STATUS';
        $out .= thin();
        my %assump;
        for my $e (@fitted) {
            for my $r (@{ $e->{fitres}{records} }) {
                my $src = $r->{method} eq 'NOT_COUNTED' ? 'n/c'
                        : $r->{method} eq 'LE_OVER_D'   ? 'PPI'
                        : $r->{doc} =~ /14\.11\.1/       ? 'AS'
                        : $r->{doc} =~ /Table 12/        ? 'FM'
                        : $r->{doc} =~ /BlazeMaster/     ? 'CPVC' : '?';
                # 36 characters for the label: the longest status,
                # ASSUMPTION_REQUIRED, otherwise ran the row to 138 columns.
                $out .= sprintf " %-7s %-4s %3d %-5s %-36s %-4s %6s %8s %6s %6s %7s %7s  %s\n",
                    $e->{id}, $e->{dn}, $r->{count}, $r->{code},
                    substr(ascii($r->{label} // ''), 0, 36), $src,
                    fx($r->{base}, 2), fx($r->{basis_bore}, 2),
                    fx($r->{cmult}, 3), fx($r->{dmult}, 3),
                    fx($r->{each}, 3), fx($r->{total}, 3), $r->{status};
                $assump{ $r->{status} }++;
            }
            (my $fs = $e->{fitspec}) =~ tr/+/,/;
            $out .= sprintf " %-7s %-100s %7s\n", '', 'allowance for ' . $e->{id}
                . ' (' . ascii($fs) . ')', fx($e->{fitres}{total}, 3);
        }
        $out .= thin();
        $out .= " SOURCE  AS   AS 2118.1:2017 Table 14.11.1, DN20-DN150, C = 120, AS 1074 Medium basis\n";
        $out .= "         FM   FM Global DS 3-0 (March 2010) Table 12(a), DN200-DN600, C = 120, Sch 40 basis\n";
        $out .= "         CPVC TYCO/BlazeMaster IH-1900 Table F2 - no corrections applied\n";
        $out .= "         PPI  PPI Handbook of PE Pipe Ch.6, Le = K'd, actual bore - no corrections\n";
        $out .= "         n/c  published but not counted - does not turn the flow\n";
        $out .= " C MUL   (C / 120)^1.85\n";
        $out .= " D MUL   (d installed / d basis)^4.87\n";
        $out .= " EACH  = BASE x C MUL x D MUL.   TOTAL = QTY x EACH.\n";
    }

    #--------------------------------------------- 4. assumptions and elections
    # Anything the calculation assumed rather than read from a governing
    # document, stated so it can be challenged.
    $out .= title('4. ASSUMPTIONS AND ELECTIONS');
    my @notes;
    if ($uses_db) {
        # The database is user editable, so name the exact file and its
        # fingerprint: a later edit to the data cannot pass for this one.
        # The program's own database is named by its file name alone; one in
        # a team folder or beside the program by its full path and where it
        # came from, so a reader can tell the shared data from a local copy.
        my $db = HardyCross::PipeData::path();
        my $from = HardyCross::PipeData::origin($db);
        if ($from eq 'BUILT-IN') { $db =~ s{.*[\\/]}{} }
        else                     { $db .= ' (' . lc($from) . ')' }
        my $iss = HardyCross::PipeData::issued();
        push @notes, 'Pipe dimensions and fitting allowances are taken from the database: '
            . HardyCross::PipeData::dataset() . ($iss ne '' ? " ($iss)" : '')
            . ", file $db, SHA-256 " . HardyCross::PipeData::sha256() . '.';
    }
    if (grep { ($_->{doc} // '') =~ /14\.11\.1/ && $_->{dmult} != 1 }
        map { @{ $_->{fitres}{records} } } @fitted) {
        push @notes, 'AS 2118.1 does not state a basis bore for Table 14.11.1. AS 1074 Medium '
            . 'is adopted as that basis (an office assumption); AS 2118.1 values on '
            . 'other pipe are corrected against it.';
    }
    my @fallback = grep { $_->{status} eq 'ASSUMPTION_REQUIRED' }
                   map { @{ $_->{fitres}{records} } } @fitted;
    if (@fallback) {
        my %p = map { ($_->{type} . ' DN' . $_->{dn}) => 1 } @fallback;
        push @notes, 'ASSUMPTION_REQUIRED: generic equivalent-length fallback used for '
            . join(', ', sort keys %p) . '. No product-specific hydraulic data are held for '
            . 'these fittings.';
    }
    push @notes, 'ELECTION: calculated to the published Standard alone. AS 2118.1 Table '
        . '14.11.1 is applied unmodified and the diameter modifier was NOT applied.'
        if ($o->{fitting_basis} // '') eq 'STANDARD';
    for my $e (grep { $_->{kind} eq 'PIPE' && $_->{ptype} && $_->{c_given} }
               @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        my $tc = HardyCross::PipeData::pipe_type($e->{ptype})->{c};
        push @notes, "Pipe $e->{id}: C = $e->{c} used in place of $e->{ptype}'s C = $tc."
            if $e->{c} != $tc;
    }
    my @untyped = grep { $_->{kind} eq 'PIPE' && !$_->{ptype} }
                  @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    push @notes, scalar(@untyped) . ' pipe(s) have a bore entered directly rather than a '
        . 'pipe type, and so carry no database provenance: '
        . join(', ', map { $_->{id} } @untyped[0 .. ($#untyped < 7 ? $#untyped : 7)])
        . (@untyped > 8 ? ' ...' : '') . '.' if @untyped;
    if (!$dw && grep { $_->{kind} eq 'PIPE' && ($_->{kfit} // 0) > 0 }
                @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        push @notes, 'Minor-loss K values are present on a Hazen-Williams calculation. Under '
            . 'AS 2118.1 fitting allowances are equivalent lengths; K belongs with '
            . 'Darcy-Weisbach. The K terms have been applied as entered.';
    }
    # How a curve is drawn between the points entered changes the answer, so
    # it is stated whenever the model has one.
    my @curved = grep { $_->{curve} } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    push @notes, 'Supply, pump and loss-device curves (' . join(', ', map { $_->{id} } @curved[0 .. ($#curved < 7 ? $#curved : 7)])
        . (@curved > 8 ? ' ...' : '') . ') pass through every point entered, with pressure '
        . 'linear in Q^1.85 between points and continued linearly beyond the last.' if @curved;
    push @notes, 'No project-specific manufacturer data are relied upon.';
    for my $i (0 .. $#notes) { $out .= wrap(sprintf(' %2d  ', $i + 1), $notes[$i]) }

    #----------------------------------------------------- 5. node schedule
    # Every node's elevation, pressure and total head, and the outlet at it.
    $out .= title('5. NODE SCHEDULE');
    $out .= sprintf " %-10s %10s %12s %12s %12s %12s %11s  %s\n",
        'NODE', 'ELEV ' . sym($net->{u_len}), 'ELEV HEAD', 'PRESSURE', 'TOTAL HEAD', 'DISCHARGE', 'REQUIRED P', 'OUTLET';
    $out .= sprintf " %-10s %10s %12s %12s %12s %12s %11s\n", '', '', sym($net->{u_pres}),
        sym($net->{u_pres}), sym($net->{u_pres}), sym($net->{u_flow}), sym($net->{u_pres});
    $out .= thin();
    for my $i (1 .. $#{ $net->{nodes} }) {
        my $n = $net->{nodes}[$i];
        next if $n->{id} eq 'REF';
        my ($q, $preq, $tag) = ($n->{demand}, 0, '');
        for my $e (@{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
            next unless $e->{kind} eq 'DISCHARGE' && $e->{n1} == $i;
            $q += abs $e->{q}; $preq = $e->{preq}; $tag = $e->{id};
        }
        # A fixed flow's minimum pressure is a requirement at its node too.
        # Its flow is already in the node's demand above.
        for my $f (grep { $_->{n1} == $i } @{ $net->{fixed} || [] }) {
            $preq = $f->{preq} if defined $f->{preq} && $f->{preq} > $preq;
            $tag = $tag ? "$tag $f->{id}" : $f->{id};
        }
        my ($pd, $qd) = (pdp($net->{u_pres}) + 1, qdp($net->{u_flow}));
        $out .= sprintf " %-10s %10.3f %12.*f %12.*f %12.*f %12.*f %11s  %s\n",
            $n->{id}, $n->{z} / $ul, $pd, $GW * $n->{z} / $up,
            $pd, ($n->{h} - $GW * $n->{z}) / $up, $pd, $n->{h} / $up, $qd, $q / $uf,
            $preq ? fx($preq / $up, $pd) : '-', $tag;
    }
    $out .= thin();
    $out .= " Check: PRESSURE + ELEV HEAD = TOTAL HEAD on every row.\n";

    #----------------------------------------------------- 6. pipe schedule
    #
    # NFPA worksheet layout: four lines per pipe, laid out the way a checker
    # works a pipe by hand, and the form fire authorities are used to reading.
    #
    #   line 1  BEG node, elevation, q and K of an outlet there, L, and Pt
    #   line 2  pipe, Q in the pipe, fitting string, F, C, Pe and Pv
    #   line 3  pipe type, velocity, bore, TL, friction per length, Pf, Pn
    #   line 4  DN, END node, elevation, q and K of an outlet there, Pt
    #
    # Each pipe is written in the direction its water flows, so BEG is the
    # upstream end, Q is positive and Pt falls along the pipe by Pe + Pf -- the
    # sum a checker does first.  A pipe drawn against the flow is turned round
    # for the schedule only; the model is not changed.
    $out .= title('6. PIPE SCHEDULE');
    {
        my ($pd, $qd) = (pdp($net->{u_pres}), qdp($net->{u_flow}));
        my ($pu, $qu, $lu) = (sym($net->{u_pres}), sym($net->{u_flow}), sym($net->{u_len}));
        # Headings are placed at measured column positions, taken from the data
        # lines below, rather than by a second format string -- two format
        # strings kept in step by eye drifted a column apart on the first try.
        #   PIPE 1  BEG 10  ELEV ends 26  q= 30  K= 43  L= 62  C 75  Pt 89
        my $place = sub {
            my $line = ' ' x 120;
            while (my ($col, $txt, $right) = splice @_, 0, 3) {
                $col = $col - length($txt) + 1 if $right;
                substr($line, $col, length $txt) = $txt;
            }
            $line =~ s/\s+$//;
            return "$line\n";
        };
        $out .= $place->(1, 'PIPE', 0, 10, 'BEG', 0, 26, 'ELEV', 1, 30, 'FLOW', 0,
                         43, 'K-FACTOR', 0, 62, 'LENGTH', 0, 75, 'C-FACTOR', 0, 89, 'PRESSURE', 0);
        $out .= $place->(1, 'NO.', 0, 26, "($lu)", 1, 30, $qu, 0,
                         43, 'FITTINGS', 0, 62, "FTG $lu", 0, 75, 'FRI-LOSS', 0, 89, "($pu)", 0);
        $out .= $place->(1, 'TYPE', 0, 10, 'END', 0, 26, 'ELEV', 1,
                         43, 'DIAMETER mm', 0, 62, "TOTAL $lu", 0, 75, "($pu/$lu)", 0);
        $out .= thin();

        # Outlets and fixed demands by node, so q and K can be printed beside
        # the node they belong to.
        my %at;
        for my $e (@{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
            next unless $e->{kind} eq 'DISCHARGE';
            $at{ $e->{n1} } = { q => abs($e->{q}), k => $e->{k} * sqrt($up) / $uf };
        }
        for my $i (1 .. $#{ $net->{nodes} }) {
            my $d = $net->{nodes}[$i]{demand} or next;
            $at{$i} //= { q => $d, k => undef };
        }
        # Each outlet's q is printed exactly once, on the first pipe listed that
        # touches its node.  Printing it on every pipe from a node would invite
        # someone to add the same discharge up two or three times.
        my %shown;
        my $qk = sub {
            my $node = shift;
            my $o = $at{$node};
            return ('-', '-') unless $o && !$shown{$node}++;
            return (sprintf('%.*f', $qd, $o->{q} / $uf),
                    defined $o->{k} ? sprintf('%.3f', $o->{k}) : 'fixed');
        };

        my @pipes = grep { $_->{kind} eq 'PIPE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
        for my $n (0 .. $#pipes) {
            my $e = $pipes[$n];
            my ($hf_raw) = HardyCross::elem_hf($e, $e->{q}, $o);
            my $fwd = $e->{q} >= 0;
            my ($ib, $ie) = $fwd ? ($e->{n1}, $e->{n2}) : ($e->{n2}, $e->{n1});
            my ($nb, $ne) = ($net->{nodes}[$ib], $net->{nodes}[$ie]);
            my $q    = abs $e->{q};
            my $pf   = $fwd ? $hf_raw : -$hf_raw;              # loss in the flow direction
            my $pe   = $GW * ($ne->{z} - $nb->{z});           # rise costs pressure
            my $ptb  = $nb->{h} - $GW * $nb->{z};
            my $pte  = $ne->{h} - $GW * $ne->{z};
            my $v    = abs HardyCross::pipe_velocity($q, $e->{dia});
            my $pv   = 0.5 * $v ** 2;                          # rho v^2 / 2, kPa
            my $lt   = $e->{len} + $e->{eqv};
            my ($qb, $kb) = $qk->($ib);
            my ($qe, $ke) = $qk->($ie);
            (my $fit = $e->{fitspec} // '') =~ tr/+/,/;
            $fit = $e->{eqv} > 0 ? 'EQV' : '-' unless length $fit;

            $out .= sprintf " %-8s %-8s %8.3f   q=%9s  K= %-14s  L= %8.2f  %-12s  Pt %8.*f  Pt %8.*f\n",
                '', $nb->{id}, $nb->{z} / $ul, $qb, $kb, $e->{len} / $ul, '',
                $pd, $ptb / $up, $pd, $ptb / $up;
            $out .= sprintf " %-8s %-8s %8s   Q=%9.*f  F= %-14s  F= %8.2f  %-12s  Pe %8.*f  Pv %8.*f\n",
                $e->{id}, '', '', $qd, $q / $uf, substr($fit, 0, 14), $e->{eqv} / $ul,
                sprintf('C= %.0f', $e->{c}), $pd + 1, $pe / $up, $pd + 1, $pv / $up;
            $out .= sprintf " %-8s %-8s %8s Vel=%9.2f  D= %-14s TL= %8.2f  %-12s  Pf %8.*f  Pn %8.*f\n",
                $e->{ptype} // '', '', '', $v, sprintf('%.2f', $e->{dia}), $lt / $ul,
                ($lt > 0 ? sprintf('%.*f', $pd + 3, abs($pf) / $lt / $up * $ul) : '-'),
                $pd + 1, $pf / $up, $pd, ($ptb - $pv) / $up;
            # The END line names q and K only when it has an outlet to report.
            # Dashes on every END line are noise the NFPA form does not carry.
            my $qkseg = $qe eq '-' ? ' ' x 30
                                   : sprintf('q=%9s  K= %-14s', $qe, $ke);
            $out .= sprintf " %-8s %-8s %8.3f   %s  %-11s  %-12s  Pt %8.*f\n",
                (defined $e->{dn} ? "DN$e->{dn}" : ''), $ne->{id}, $ne->{z} / $ul, $qkseg, '', '',
                $pd, $pte / $up;
            $out .= '      ' . '-' x ($W - 6) . "\n" if $n < $#pipes;
        }
        $out .= thin();
        $out .= wrap(' ', "Each pipe is written in the direction of flow: BEG is upstream, and Pt falls "
            . "along the pipe by Pe + Pf.  q and K are the outlet at that node, printed once, on the "
            . "first pipe that reaches it; '-' means no outlet, or one already shown.");
        $out .= wrap(' ', 'Check: TL = L + F.   Pf = FRI-LOSS x TL.   Pt END = Pt BEG - Pe - Pf.   '
            . 'Pn = Pt BEG - Pv.');
        $out .= wrap(' ', 'Pv, the velocity pressure (rho v^2 / 2), and Pn, the normal pressure, are '
            . 'shown in the NFPA manner for reference only.  This calculation works in TOTAL pressure '
            . 'throughout, as FM Global DS 3-0 does: every outlet discharge is q = K x sqrt(Pt), not '
            . 'K x sqrt(Pn).  Fittings are equivalent lengths from the pipe and fitting database; '
            . 'see Section 3.');
    }

    #-------------------------------------------------- 7. outlet compliance
    # Each outlet's required and achieved flow and pressure, PASS or FAIL.
    # Fixed flows with a minimum pressure are listed after the outlets: their
    # flow is set, so only the pressure can fail, and K is shown as "fixed".
    my @dis = grep { $_->{kind} eq 'DISCHARGE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    my @fix = grep { defined $_->{preq} } @{ $net->{fixed} || [] };
    if (@dis || @fix) {
        $out .= title('7. OUTLET COMPLIANCE');
        $out .= sprintf " %-12s %-8s %9s %11s %11s %11s %11s   %s\n",
            'OUTLET', 'NODE', 'K', 'REQ Q', 'ACT Q', 'REQ P', 'ACT P', 'RESULT';
        $out .= thin();
        my $fails = 0;
        for my $e (@dis) {
            my $q = abs $e->{q};
            my $p = $net->{nodes}[ $e->{n1} ]{h} - $GW * $e->{z};
            my $pass = $q >= $e->{qreq} - 1e-6 && $p >= $e->{preq} - 1e-6;
            $fails++ unless $pass;
            my ($pd, $qd) = (pdp($net->{u_pres}), qdp($net->{u_flow}));
            $out .= sprintf " %-12s %-8s %9.3f %11.*f %11.*f %11.*f %11.*f   %s\n",
                $e->{id}, $net->{nodes}[ $e->{n1} ]{id},
                $e->{k} * sqrt($up) / $uf, $qd, $e->{qreq} / $uf, $qd, $q / $uf,
                $pd, $e->{preq} / $up, $pd, $p / $up, $pass ? 'PASS' : '*** FAIL';
        }
        for my $f (@fix) {
            my $p = $net->{nodes}[ $f->{n1} ]{h} - $GW * $f->{z};
            my $pass = $p >= $f->{preq} - 1e-6;
            $fails++ unless $pass;
            my ($pd, $qd) = (pdp($net->{u_pres}), qdp($net->{u_flow}));
            $out .= sprintf " %-12s %-8s %9s %11.*f %11.*f %11.*f %11.*f   %s\n",
                $f->{id}, $net->{nodes}[ $f->{n1} ]{id}, 'fixed',
                $qd, $f->{qreq} / $uf, $qd, $f->{q} / $uf,
                $pd, $f->{preq} / $up, $pd, $p / $up, $pass ? 'PASS' : '*** FAIL';
        }
        $out .= thin();
        $out .= " Check: ACT Q = K x sqrt(ACT P) on every row (AS 2118.1 Appendix B, eqn B1).\n"
            if @dis && !@fix;
        $out .= " Check: ACT Q = K x sqrt(ACT P) on every row with a K (AS 2118.1 Appendix B,\n"
              . " eqn B1).  A fixed flow's Q is set by the model; only its pressure is checked.\n"
            if @fix;
        $out .= $fails ? " *** $fails OUTLET(S) BELOW REQUIREMENT ***\n" : " All outlets meet their requirement.\n";
    }

    #------------------------------------------------- 8. flow path worksheet
    my ($gov, $gmargin) = HardyCross::Demand::governing_outlet($net);
    if ($gov) {
        $out .= title('8. FLOW PATH TO THE GOVERNING OUTLET');
        $out .= wrap('    ', sprintf('Governing outlet: %s at node %s - the outlet with the least '
            . 'pressure to spare over its requirement (%.2f %s), and so the first to fail as the '
            . 'supply weakens.  It is not necessarily the one furthest away on the drawing.',
            $gov->{id}, $net->{nodes}[ $gov->{n1} ]{id}, $gmargin / $up, sym($net->{u_pres})));
        my ($steps, $perr) = HardyCross::Demand::flow_path($net, $gov);
        if (!$steps) {
            $out .= " Path could not be traced: $perr\n";
        } else {
            $out .= "\n";
            my $pf = " %3s %-8s %-7s %-6s %-6s %4s %6s %9s %7s %8s %8s %8s %8s %9s %9s %7s\n";
            $out .= sprintf $pf, 'STEP', 'ELEMENT', 'TYPE', 'FROM', 'TO', 'DN', 'T', 'PF/M',
                'Q', 'PF', 'PE', 'P FROM', 'P TO', 'P SOLVED', 'DIFF', '';
            $out .= sprintf $pf, '', '', '', '', '', '', sym($net->{u_len}),
                sym($net->{u_pres}) . '/' . sym($net->{u_len}), sym($net->{u_flow}),
                (map { sym($net->{u_pres}) } 1 .. 6), '';
            $out .= thin();
            my %nm = (PIPE => 'PIPE', PUMP => 'PUMP', SUPPLY_STATIC => 'SUPPLY',
                      SUPPLY_CURVE => 'SUPPLY', FIXED_DROP => 'PRV', ORIFICE => 'ORIFICE',
                      ORIFICE_REQUIRED => 'ORIF_P', BFP => 'BFP', RATIO => 'PRA');
            my $p;              # running pressure, carried forward by hand
            my $worst = 0;
            my $k = 0;
            for my $st (@$steps) {
                my $e = $st->{elem};
                if ($e->{kind} =~ /^SUPPLY_/) {
                    # The path starts at the supply connection, at its solved pressure.
                    $p = HardyCross::Demand::gauge($net, $st->{to});
                    $out .= sprintf " %3s %-8s %-7s %-6s %-6s %4s %6s %9s %7.1f %8s %8s %8s %8.1f %9.1f %9s\n",
                        '', $e->{id}, 'SUPPLY', '-', $net->{nodes}[ $st->{to} ]{id}, '-', '-', '-',
                        $st->{q} / $uf, '-', '-', '-', $p / $up, $p / $up, 'start';
                    next;
                }
                $k++;
                my ($hf) = HardyCross::elem_hf($e, $e->{q}, $o);
                # Loss in the direction walked.  The path follows the flow, so for
                # a pipe it is positive; a pump shows as a negative loss -- a gain.
                my $loss = $e->{n1} == $st->{from} ? $hf : -$hf;
                my ($a, $b) = ($net->{nodes}[ $st->{from} ], $net->{nodes}[ $st->{to} ]);
                my $pe = $GW * ($b->{z} - $a->{z});
                my $pfrom = $p;
                $p = $p - $loss - $pe;
                my $solved = HardyCross::Demand::gauge($net, $st->{to});
                my $diff = $p - $solved;
                $worst = abs $diff if abs $diff > $worst;
                my $pipe = $e->{kind} eq 'PIPE';
                my $lt = $pipe ? $e->{len} + $e->{eqv} : 0;
                $out .= sprintf " %3d %-8s %-7s %-6s %-6s %4s %6s %9s %7.1f %8.2f %8.2f %8.1f %8.1f %9.1f %9.2e\n",
                    $k, $e->{id}, $nm{ $e->{kind} } // $e->{kind}, $a->{id}, $b->{id},
                    $pipe ? ($e->{dn} // '-') : '-',
                    $pipe ? sprintf('%.2f', $lt / $ul) : '-',
                    ($pipe && $lt > 0)
                        ? sprintf('%.*f', pdp($net->{u_pres}) + 3, $loss / $lt / $up * $ul) : '-',
                    $st->{q} / $uf, $loss / $up, $pe / $up, $pfrom / $up, $p / $up,
                    $solved / $up, $diff / $up;
            }
            $out .= thin();
            my $pgo = HardyCross::Demand::gauge($net, $gov->{n1});
            if ($gov->{kind} eq 'FIXEDFLOW') {
                # A fixed flow has no K: its discharge is set by the model.
                $out .= sprintf " Fixed flow %s: pressure %.1f %s, required %.1f, margin %.1f.   "
                    . "Discharge %.1f %s, fixed.\n",
                    $gov->{id}, $pgo / $up, sym($net->{u_pres}), $gov->{preq} / $up,
                    ($pgo - $gov->{preq}) / $up, $gov->{q} / $uf, sym($net->{u_flow});
            } else {
                $out .= sprintf " Outlet %s: pressure %.1f %s, required %.1f, margin %.1f.   "
                    . "Discharge %.1f %s = K %.3f x sqrt(%.1f).\n",
                    $gov->{id}, $pgo / $up, sym($net->{u_pres}), $gov->{preq} / $up,
                    ($pgo - $gov->{preq}) / $up, abs($gov->{q}) / $uf, sym($net->{u_flow}),
                    $gov->{k} * sqrt($up) / $uf, $pgo / $up;
            }
            $out .= " Check: P TO = P FROM - PF - PE on every row.  PF = PF/M x T.\n";
            $out .= sprintf " Check: P TO worked by hand agrees with P SOLVED at every node, "
                . "worst difference %.1e %s.\n", $worst / $up, sym($net->{u_pres});
            $out .= wrap(' ', 'On a looped network water reaches an outlet by more than one '
                . 'route.  This path follows the element bringing the most water into each node, '
                . 'traced back from the outlet.  Pressure at a node is the same by any route, '
                . 'which is why the hand-worked P TO must land on the solved value.');
        }
    }

    #--------------------------------------------------- 9. supply and demand
    $out .= title('9. SUPPLY AND DEMAND');
    my $dm = HardyCross::Demand::demand_point($net);
    if ($dm->{reason}) {
        $out .= wrap(' ', 'A demand point is not reported: ' . $dm->{reason} . '.');
        my @sup = grep { $_->{kind} =~ /^SUPPLY_/ } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
        for my $s (@sup) {
            $out .= sprintf " %-12s operating at %9.1f %s and %8.1f %s\n", $s->{id},
                abs($s->{q}) / $uf, sym($net->{u_flow}),
                HardyCross::Demand::gauge($net, $s->{n2}) / $up, sym($net->{u_pres});
        }
        # With more than one supply: what each must give, on one common
        # pressure; a graph of each; then all of them combined.
        my $cd = @sup > 1 && $net->{source_text} ? HardyCross::Demand::combined_demand($net) : undef;
        if ($cd && $cd->{reason}) {
            $out .= wrap(' ', 'The supplies are not graphed: ' . $cd->{reason} . '.');
        } elsif ($cd) {
            my ($qu, $pu) = (sym($net->{u_flow}), sym($net->{u_pres}));
            $out .= "\n" . wrap(' ', 'Each supply is graphed below with the other supplies connected as '
                . 'modelled.  Its system curve is the whole network re-solved with this supply held at '
                . 'a range of pressures, the others unchanged, and its flow read from each solve; only '
                . 'solves that converge with water leaving this supply are plotted.  The operating '
                . 'point O is where that curve meets the supply.');
            my $q_all = 0;
            $q_all += abs $_->{q} for @sup;
            for my $s (@sup) {
                $out .= supply_graph($net, { supply => $s, shared => 1, q_oper => abs $s->{q},
                                             p_oper => HardyCross::Demand::gauge($net, $s->{n2}),
                                             q_all => $q_all });
            }
            # Then all of them together: the curves added in flow at equal
            # pressure, and the required flows added at the common pressure.
            $out .= "\n" . wrap(' ', sprintf('ALL SUPPLIES COMBINED.  The supply curves are added in flow '
                . 'at equal pressure - at each pressure, the flows the supplies give are summed; pressures '
                . 'are not adjusted.  The COMBINED DUTY is found on the same basis, as for pumps on one '
                . 'header: every supply held at one common pressure, raised until the governing outlet, %s, '
                . 'receives exactly its minimum; the flows of all the supplies then, added, at that '
                . 'pressure.  Where the supplies connect at different points the modelled network runs '
                . 'each at its own pressure, as listed above, so the combined figures describe the '
                . 'supplies taken together and each supply is also shown on its own graph.',
                $cd->{governing}{id})
                . ($cd->{one_pressure}
                    ? '  The supplies operate at one pressure in the modelled network, so their operating '
                      . 'flows, added, are the combined operating point O.'
                    : ''));
            $out .= sprintf "   %-30s %10.1f %-7s at %9.1f %s\n", 'COMBINED DUTY',
                $cd->{q_demand} / $uf, $qu, $cd->{p_demand} / $up, $pu;
            $out .= sprintf "   %-30s %10s %-7s    %9.1f %s\n", 'COMBINED SUPPLY at that flow', '', '',
                $cd->{p_avail} / $up, $pu;
            $out .= sprintf "   %-30s %10s %-7s    %9.1f %s\n",
                $cd->{margin} >= 0 ? 'MARGIN' : 'SHORTFALL', '', '', abs($cd->{margin}) / $up, $pu;
            $out .= sprintf "   %-30s %10.1f %-7s at %9.1f %s\n", 'COMBINED OPERATING POINT',
                $cd->{q_oper} / $uf, $qu, $cd->{p_oper} / $up, $pu if $cd->{one_pressure};
            $out .= $cd->{margin} >= 0
                ? " The supplies combined MEET the combined duty.\n"
                : " *** THE SUPPLIES COMBINED DO NOT MEET THE COMBINED DUTY ***\n";
            $out .= supply_graph($net, $cd);
        }
    } else {
        my $s = $dm->{supply};
        my ($qu, $pu) = (sym($net->{u_flow}), sym($net->{u_pres}));
        $out .= sprintf " Supply %s at node %s, %s\n\n", $s->{id},
            $net->{nodes}[ $s->{n2} ]{id},
            $s->{kind} eq 'SUPPLY_STATIC' ? 'static pressure' : 'flow/pressure curve';
        $out .= sprintf "   %-30s %10.1f %-7s at %9.1f %s\n", 'DEMAND', $dm->{q_demand} / $uf, $qu,
            $dm->{p_demand} / $up, $pu;
        $out .= sprintf "   %-30s %10s %-7s    %9.1f %s\n", 'AVAILABLE at the demand flow', '', '',
            $dm->{p_avail} / $up, $pu;
        $out .= sprintf "   %-30s %10s %-7s    %9.1f %s   (%.1f %% of available)\n",
            'MARGIN', '', '', $dm->{margin} / $up, $pu,
            $dm->{p_avail} > 0 ? 100 * $dm->{margin} / $dm->{p_avail} : 0;
        $out .= sprintf "   %-30s %10.1f %-7s at %9.1f %s\n\n", 'OPERATING POINT', $dm->{q_oper} / $uf,
            $qu, $dm->{p_oper} / $up, $pu;
        $out .= wrap(' ', sprintf('DEMAND is the pressure the system needs at the supply connection '
            . 'for the governing outlet, %s, to receive exactly its minimum - found by re-solving '
            . 'the whole network at trial supply pressures until its margin is zero.  The '
            . 'OPERATING POINT is what actually happens with this supply: every outlet receives more '
            . 'than its minimum, and the supply meets the system exactly.  The difference between '
            . 'available and demand is the margin.', $dm->{governing}{id}));
        $out .= $dm->{margin} >= 0
            ? " The supply MEETS the demand.\n"
            : " *** THE SUPPLY DOES NOT MEET THE DEMAND ***\n";
        $out .= supply_graph($net, $dm);
    }

    #---------------------------------------------- 8. supplies and devices
    my @sup = grep { $_->{kind} =~ /^(SUPPLY_|PUMP|FIXED_DROP|ORIFICE|BFP|RATIO)/ }
              @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    if (@sup) {
        $out .= title('10. SUPPLIES, PUMPS AND PRESSURE DEVICES');
        $out .= sprintf " %-12s %-11s %-8s %-8s %11s %11s   %s\n",
            'ELEMENT', 'TYPE', 'FROM', 'TO', 'FLOW', 'HEAD/LOSS', 'NOTE';
        $out .= thin();
        my %nm = (SUPPLY_STATIC => 'STATIC', SUPPLY_CURVE => 'CURVE', PUMP => 'PUMP',
                  FIXED_DROP => 'PRV', ORIFICE => 'ORIFICE', ORIFICE_REQUIRED => 'ORIFICE_P',
                  BFP => 'BFP', RATIO => 'PRA');
        for my $e (@sup) {
            my ($hf) = $e->{closed} ? (0) : HardyCross::elem_hf($e, $e->{q}, $o);
            my $note = $e->{closed} ? 'CHECK VALVE CLOSED - would run backwards'
                     : $e->{kind} eq 'ORIFICE' && $e->{bore}
                        ? sprintf('bore %.2f mm in %.2f mm pipe, beta %.3f',
                                  $e->{bore}, $e->{pipedia}, $e->{bore} / $e->{pipedia})
                     : $e->{kind} eq 'RATIO'
                        # Outlet = inlet x (1/ratio - band), so the reader
                        # can check it: the bottom of the valve's band.
                        ? sprintf('ratio %g:1 +/-%g%%, inlet %.1f, outlet %.1f (band %.1f to %.1f)',
                                  $e->{ratio}, 100 * ($e->{band} // 0.05), ($e->{pin} // 0) / $up,
                                  (($e->{pin} // 0) - $e->{dp}) / $up,
                                  ($e->{pin} // 0) * (1 / $e->{ratio} - ($e->{band} // 0.05)) / $up,
                                  ($e->{pin} // 0) * (1 / $e->{ratio} + ($e->{band} // 0.05)) / $up)
                     : '';
            $out .= sprintf " %-12s %-11s %-8s %-8s %11.*f %11.*f   %s\n",
                $e->{id}, $nm{ $e->{kind} } // $e->{kind},
                $net->{nodes}[ $e->{n1} ]{id}, $net->{nodes}[ $e->{n2} ]{id},
                qdp($net->{u_flow}), $e->{q} / $uf, pdp($net->{u_pres}) + 1, $hf / $up, $note;
        }
        $out .= ratio_band_note($net) if grep { $_->{kind} eq 'RATIO' } @sup;
    }

    #------------------------------------------------------- 9. verification
    # Loop closure and continuity, worked from the final flows: the two
    # conditions a Hardy Cross solution has to satisfy.
    $out .= title('11. VERIFICATION');
    my $worst = 0;
    for my $lp (@{ $net->{loops} }) {
        my $s = 0;
        for my $st (@$lp) {
            my ($hf) = HardyCross::elem_hf($net->{elems}[ $st->[0] ],
                                           $net->{elems}[ $st->[0] ]{q}, $o);
            $s += $st->[1] * $hf;
        }
        $worst = abs $s if abs $s > $worst;
    }
    $out .= sprintf " %-44s %12.3e %s\n", 'Worst loop closure, sum of signed losses',
        $worst / $up, sym($net->{u_pres});
    $out .= sprintf " %-44s %12.3e %s\n", 'Worst nodal continuity error',
        HardyCross::continuity_error($net) / $uf, sym($net->{u_flow});
    $out .= "\n Continuity is exact by construction: every correction circulates around a\n";
    $out .= " closed loop, so only rounding appears above.\n";

    #--------------------------------------------------------- 10. warnings
    $out .= title('12. NOTES AND WARNINGS');
    my @w;
    push @w, 'THE SOLUTION DID NOT CONVERGE. Every figure in this report is provisional.'
        unless $ok;
    # One finding, not one per pipe.  Five identical sentences bury whatever
    # else is on the list; the pipes and their velocities are the information.
    my $vl = $o->{vel_limit} // 6;
    my @fast = map { sprintf '%s %.2f', $_->[0], $_->[1] }
               sort { $b->[1] <=> $a->[1] }
               grep { $_->[1] > $vl }
               map  { [ $_->{id}, abs HardyCross::pipe_velocity($_->{q}, $_->{dia}) ] }
               grep { $_->{kind} eq 'PIPE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    push @w, sprintf('%d pipe(s) exceed the velocity limit of %g m/s, fastest first (m/s): %s.',
        scalar @fast, $vl, join(', ', @fast)) if @fast;
    push @w, @{ $net->{warnings} || [] };
    push @w, 'No warnings.' unless @w;
    for my $i (0 .. $#w) { $out .= wrap(sprintf(' %2d  ', $i + 1), $w[$i]) }

    $out .= "\n" . rule() . " END OF CALCULATION\n" . rule();

    # The guarantee: nothing but printable ASCII leaves this module.
    $out = ascii($out);
    return $out;
}

#------------------------------------------------------------------------------
# COVER SHEET
#
# Modelled on the NFPA-style submittal cover, adapted for Australia: design data
# in AS 2118.1 terms (hazard class, design density in mm/min, area of operation
# in m2), and NO hose stream allowance, which Australian practice does not add
# to a sprinkler calculation.
#
# PHCP solves with the supply connected, so its schedules show the OPERATING
# point, where every head receives more than its minimum.  A submittal cover is
# normally read at the DEMAND point, where the governing head receives exactly
# its minimum.  The flow and density figures are given at BOTH, side by side and
# labelled, rather than one quietly standing in for the other.
#------------------------------------------------------------------------------
sub flow_stats {
    my $n = shift or return;
    my %s = (spk => 0, other => 0, nspk => 0, supply => 0);
    for my $e (@{ $n->{elems} }[1 .. $#{ $n->{elems} }]) {
        if ($e->{kind} eq 'DISCHARGE') {
            my $q = abs $e->{q};
            if (uc($e->{otype} // 'SPRINKLER') eq 'SPRINKLER') {
                $s{spk} += $q;
                $s{nspk}++;
                ($s{low}, $s{low_id}) = ($q, $e->{id}) if !defined $s{low} || $q < $s{low};
            } else { $s{other} += $q }
        }
        $s{supply} += abs $e->{q} if $e->{kind} =~ /^SUPPLY_/;
    }
    # Fixed-flow demands are water the system needs too.
    $s{other} += $n->{nodes}[$_]{demand} for 1 .. $#{ $n->{nodes} };
    return \%s;
}

# Flow through a node: the sum of everything arriving at it.
sub node_throughput {
    my ($n, $i) = @_;
    my $in = 0;
    for my $e (@{ $n->{elems} }[1 .. $#{ $n->{elems} }]) {
        next if $e->{closed};
        $in += $e->{q}  if $e->{n2} == $i && $e->{q} > 0;
        $in += -$e->{q} if $e->{n1} == $i && $e->{q} < 0;
    }
    return $in;
}

sub node_index_by_id {
    my ($n, $id) = @_;
    return unless defined $id && length $id;
    for my $i (1 .. $#{ $n->{nodes} }) { return $i if $n->{nodes}[$i]{id} eq $id }
    return;
}

sub num_or_undef { my $v = shift; defined $v && $v =~ /^\s*([\d.]+)/ ? $1 + 0 : undef }

sub cover_sheet {
    my ($net, $ok, $path) = @_;
    my $pj = $net->{project} || {};
    my ($uf, $up) = @{$net}{qw(f_flow f_pres)};
    my ($qu, $pu) = (sym($net->{u_flow}), sym($net->{u_pres}));
    my $qd = qdp($net->{u_flow});
    my $pd = pdp($net->{u_pres});
    my $ns = sub { my $v = shift; defined $v && length $v ? $v : 'not stated' };
    my $out = '';

    $out .= rule();
    $out .= sprintf " %-*s%s\n", $W - 1 - length('PHCP'), 'HYDRAULIC CALCULATION', 'PHCP';
    $out .= rule() . "\n";

    # --- the design data, from the PROJECT block and the solved network
    my $dm   = HardyCross::Demand::demand_point($net);
    my $sd   = $dm->{net} ? flow_stats($dm->{net}) : undef;
    my $so   = flow_stats($net);
    my $dens = num_or_undef($pj->{DENSITY});             # mm/min
    my $aps  = num_or_undef($pj->{AREA_PER_SPRINKLER});  # m2
    my $aoo  = num_or_undef($pj->{AREA_OF_OPERATION});   # m2
    my $aoo_txt = defined $aoo ? sprintf('%.1f m2', $aoo)
                : (defined $aps && $so->{nspk})
                    ? sprintf('%.1f m2  (%d sprinklers x %.1f m2)', $so->{nspk} * $aps, $so->{nspk}, $aps)
                    : 'not stated';
    my $uses_db = grep { $_->{ptype} } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];

    my @left = (
        [ 'COMPANY',     $ns->($pj->{COMPANY}) ],
        [ 'ADDRESS',     $ns->($pj->{ADDRESS}) ],
        [ 'LICENCE',     $ns->($pj->{LICENCE}) ],
        [ 'DESIGNER',    $ns->($pj->{DESIGNER}) ],
        [ 'CHECKER',     $ns->($pj->{CHECKER}) ],
        [ 'DATE',        $ns->($pj->{DATE}) ],
        [ 'REVISION',    $ns->($pj->{REVISION}) ],
        [ '', '' ],
        [ 'JOB NAME',    $ns->($pj->{TITLE}) ],
        [ 'PROJECT',     $ns->($pj->{PROJECT}) ],
        [ 'JOB NUMBER',  $ns->($pj->{JOB}) ],
        [ 'LOCATION',    $ns->($pj->{LOCATION}) ],
        [ 'MODEL FILE',  $path ],
    );
    my @right = (
        [ 'DESIGN DATA', undef ],
        [ 'Standard',            $ns->($pj->{STANDARD}) ],
        [ 'Hazard class',        $ns->($pj->{HAZARD}) ],
        [ 'Design density',      defined $dens ? sprintf('%.2f mm/min', $dens) : 'not stated' ],
        [ 'Area per sprinkler',  defined $aps ? sprintf('%.1f m2', $aps) : 'not stated' ],
        [ 'Area of operation',   $aoo_txt ],
        [ 'Sprinklers flowing',  $so->{nspk} ],
        [ 'Pipe data',           $uses_db ? HardyCross::PipeData::dataset() : ($pj->{DATA_SOURCE} // 'not stated') ],
        [ 'Program',             "PHCP $HardyCross::VERSION" ],
    );
    # A long value WRAPS within its column rather than being cut off: an
    # address or a licence number truncated on a certified cover sheet is
    # worse than a longer cover.  Continuation lines hang under the value.
    my @lcol;
    for my $f (@left) {
        if ($f->[0] eq '') { push @lcol, ''; next }
        my @w = split /\s+/, $f->[1];
        my $line = sprintf '%-11s : ', $f->[0];
        my $indent = ' ' x length $line;
        my $cur = $line;
        for my $word (@w) {
            if (length($cur) + length($word) > 64 && $cur ne $line) {
                push @lcol, $cur;
                $cur = $indent;
            }
            $cur .= ($cur eq $line || $cur eq $indent ? '' : ' ') . $word;
        }
        push @lcol, $cur;
    }
    my @rcol = map { !defined $_->[1] ? $_->[0] : sprintf('  %-19s : %s', @$_) } @right;
    for my $i (0 .. ($#lcol > $#rcol ? $#lcol : $#rcol)) {
        (my $line = sprintf " %-64s %s", $lcol[$i] // '', $rcol[$i] // '') =~ s/\s+$//;
        $out .= "$line\n";
    }

    # --- flow data, at the demand point and at the operating point
    my $col = sub {          # one figure, or a dash when that column has none
        my ($v, $d) = @_;
        return defined $v ? sprintf('%.*f', $d, $v) : '-';
    };
    my $ri = node_index_by_id($net, $pj->{BASE_OF_RISER});
    my $rid = $ri && $dm->{net} ? node_index_by_id($dm->{net}, $pj->{BASE_OF_RISER}) : undef;
    my $gauge = sub { my ($n, $i) = @_; $n->{nodes}[$i]{h} - $HardyCross::GAMMA_W * $n->{nodes}[$i]{z} };

    $out .= "\n";
    my $tf = " %-44s %-8s %16s %18s\n";
    $out .= sprintf $tf, 'FLOW DATA', '', 'DEMAND POINT', 'OPERATING POINT';
    $out .= sprintf $tf, '  Total sprinkler flow', $qu,
        $col->($sd ? $sd->{spk} / $uf : undef, $qd), $col->($so->{spk} / $uf, $qd);
    $out .= sprintf $tf, '  Hydrant, hose reel and fixed flow', $qu,
        $col->($sd ? $sd->{other} / $uf : undef, $qd), $col->($so->{other} / $uf, $qd)
        if $so->{other} > 1e-9;
    $out .= sprintf $tf, '  Total water required at the supply', $qu,
        $col->($sd ? $sd->{supply} / $uf : undef, $qd), $col->($so->{supply} / $uf, $qd);
    if ($ri) {
        $out .= sprintf $tf, "  Base of riser, node $pj->{BASE_OF_RISER} - flow", $qu,
            $col->($rid ? node_throughput($dm->{net}, $rid) / $uf : undef, $qd),
            $col->(node_throughput($net, $ri) / $uf, $qd);
        $out .= sprintf $tf, '                              pressure', $pu,
            $col->($rid ? $gauge->($dm->{net}, $rid) / $up : undef, $pd),
            $col->($gauge->($net, $ri) / $up, $pd);
    } elsif (defined $pj->{BASE_OF_RISER} && length $pj->{BASE_OF_RISER}) {
        $out .= "  Base of riser: node $pj->{BASE_OF_RISER} is not in the model\n";
    }
    $out .= sprintf $tf, '  Pressure at the supply connection', $pu,
        $col->($dm->{p_demand} ? $dm->{p_demand} / $up : undef, $pd),
        $col->($dm->{p_oper} ? $dm->{p_oper} / $up : undef, $pd);

    # --- density check.  Every sprinkler must deliver at least the design
    # density over the area it protects: q >= density x area per sprinkler.
    $out .= "\n";
    $out .= sprintf $tf, 'DENSITY CHECK', '', 'DEMAND POINT', 'OPERATING POINT';
    if (defined $dens && defined $aps && $aps > 0 && $so->{nspk}) {
        my $qmin = $dens * $aps;                            # L/min
        my $dd = $sd && defined $sd->{low} ? $sd->{low} / $aps : undef;
        my $do = defined $so->{low} ? $so->{low} / $aps : undef;
        $out .= sprintf $tf, '  Min. flow per sprinkler, density x area', 'L/min',
            sprintf('%.1f', $qmin), sprintf('%.1f', $qmin);
        $out .= sprintf $tf, '  Lowest sprinkler flow', 'L/min',
            $sd ? sprintf('%.1f (%s)', $sd->{low}, $sd->{low_id}) : '-',
            sprintf('%.1f (%s)', $so->{low}, $so->{low_id});
        $out .= sprintf $tf, '  Computed density (lowest flow / area)', 'mm/min',
            $col->($dd, 2), $col->($do, 2);
        $out .= sprintf $tf, '  Result against the design density', '',
            defined $dd ? ($dd >= $dens - 1e-9 ? 'MEETS' : '*** FAILS') : '-',
            defined $do ? ($do >= $dens - 1e-9 ? 'MEETS' : '*** FAILS') : '-';
    } else {
        $out .= "  Not checked: the design density and area per sprinkler must both be entered.\n";
    }

    # --- supply
    $out .= "\n SUPPLY\n";
    if ($dm->{reason}) {
        $out .= wrap('   ', 'Not reported: ' . $dm->{reason} . '.  See Section 9.');
    } else {
        $out .= sprintf "   %-44s %10.*f %s\n", 'Supply pressure available at the demand flow',
            $pd, $dm->{p_avail} / $up, $pu;
        $out .= sprintf "   %-44s %10.*f %s\n", 'Demand pressure required', $pd, $dm->{p_demand} / $up, $pu;
        $out .= sprintf "   %-44s %10.*f %s   (%.1f %% of available)%s\n", 'Pressure cushion',
            $pd, $dm->{margin} / $up, $pu,
            $dm->{p_avail} > 0 ? 100 * $dm->{margin} / $dm->{p_avail} : 0,
            $dm->{margin} >= 0 ? '' : '   *** SUPPLY INSUFFICIENT';
    }
    my ($vmax, $vid) = (0, '');
    for my $e (grep { $_->{kind} eq 'PIPE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        my $v = abs HardyCross::pipe_velocity($e->{q}, $e->{dia});
        ($vmax, $vid) = ($v, $e->{id}) if $v > $vmax;
    }
    $out .= sprintf "   %-44s %10.2f m/s in pipe %s (operating point)\n", 'Maximum velocity', $vmax, $vid;
    $out .= sprintf "   %-44s %10s\n", 'Result',
        $ok ? 'CONVERGED' : '*** NOT CONVERGED - NOTHING IN THIS REPORT IS USABLE ***';

    $out .= "\n";
    $out .= sprintf " %-30s : %-40s  PHONE : %s\n", 'AUTHORITY HAVING JURISDICTION',
        $ns->($pj->{AUTHORITY}), $ns->($pj->{AUTHORITY_PHONE});
    $out .= "\n";
    $out .= wrap(' ', 'DEMAND POINT: the governing outlet receives exactly its minimum - the design '
        . 'condition.  OPERATING POINT: this supply connected, every outlet at or above its '
        . 'minimum; the schedules in this report are at the operating point.  No hose stream '
        . 'allowance is included.');
    return $out;
}

#------------------------------------------------------------------------------
# The report as a PDF: the same text, paginated.  Made from the same call to
# write_report, so the PDF and the text file cannot say different things.  The
# supply graph's numbers, worked out by that call, are passed on so the PDF can
# draw the graph with lines where the text report draws it in characters.
#------------------------------------------------------------------------------
sub write_pdf_report {
    my ($net, $ok, $model_path, $pdf_path) = @_;
    delete $net->{supply_graphs};
    my $text = write_report($net, $ok, $model_path);
    my $pj = $net->{project} || {};
    (my $model = $model_path // '') =~ s{.*[/\\]}{};
    return HardyCross::PDF::write_pdf($text, $pdf_path,
        title    => $pj->{TITLE}    // 'Hydraulic calculation',
        job      => $pj->{JOB}      // '',
        revision => $pj->{REVISION} // '',
        date     => $pj->{DATE}     // '',
        designer => $pj->{DESIGNER} // '',
        model    => $model,
        program  => "PHCP $HardyCross::VERSION - Perl Hydraulic Calculation Program",
        graphs   => $net->{supply_graphs} || []);
}

#------------------------------------------------------------------------------
# Supply graph on an N^1.85 flow axis.
#
# Water-supply curves are drawn with flow to the power 1.85 along the bottom
# because a Hazen-Williams system curve then comes out close to a straight line
# -- which is what lets an engineer read margin off it by eye.  The system curve
# is not sketched: each dot is a full solve of the network at a different supply
# pressure.  The operating point is where it crosses the supply.
#
# The graph is worked out once, by supply_graph_data, and drawn twice from the
# same numbers: in characters here for the text report (which is 7-bit ASCII),
# and as lines and text by HardyCross::PDF for the PDF.  So the two cannot
# disagree, and the ten extra solves run once.
#------------------------------------------------------------------------------

#------------------------------------------------------------------------------
# supply_graph_data -- everything either drawing needs, in the network's
# internal units (L/min, kPa); the display factors and unit names come with it.
#
# $dm is the demand point (HardyCross::Demand::demand_point) for a single
# supply.  With several supplies there is none, and $dm is instead one supply
# with shared => 1, its q_oper and p_oper, and q_all, the flow of all the
# supplies together: the graph then has no demand point, and its system curve
# is the network re-solved with this supply alone held at each pressure.
#
#   qmax, pmax    the axes' extents: 0 .. qmax flow, 0 .. pmax pressure
#   avail         a sub: the supply's pressure at a flow
#   supply        [ [q, p] ... ] the supply curve sampled evenly in q^1.85,
#                 fine enough to draw as a smooth line
#   tests         [ [q, p] ... ] the points the supply curve was entered as
#                 (none for a static supply)
#   sys           [ [q, p] ... ] the system curve, each a full solve, by flow
#   demand, oper  [ q, p ] the demand and operating points (no demand when
#                 shared)
#   p_avail, margin   at the demand flow (none when shared)
#   shared        1 when other supplies share the load
#   xticks, yticks    round values for the gridlines, in internal units
#   uf, up, qu, pu    display factors and unit names
#   kind, id, node    the supply
#------------------------------------------------------------------------------
sub supply_graph_data {
    my ($net, $dm) = @_;
    my ($uf, $up) = @{$net}{qw(f_flow f_pres)};
    my $s = $dm->{supply};
    # A supply's pressure at a flow, from its curve or its static pressure.
    my $curve_of = sub {
        my $e = shift;
        return sub { $e->{kind} eq 'SUPPLY_STATIC' ? $e->{pstat} : HardyCross::curve_eval($e->{curve}, shift) };
    };
    my $combined = $dm->{combined} ? 1 : 0;
    my $avail = $combined ? $dm->{avail} : $curve_of->($s);

    my $shared = $dm->{shared} ? 1 : 0;

    # The system curve, one full solve per point.
    my @sys;
    if ($shared) {
        # From half the operating pressure to a tenth above the supply's
        # highest.  Near no flow, with the other supplies pushing back, the
        # network may not settle; such solves, and any with water running
        # back into this supply, are left off.
        my $a0 = $avail->(0);
        my ($plo, $phi) = ($dm->{p_oper} * 0.5, ($a0 > $dm->{p_oper} ? $a0 : $dm->{p_oper}) * 1.1);
        for my $i (0 .. 11) {
            my $p = $plo + ($phi - $plo) * $i / 11;
            my ($ok, $n) = HardyCross::Demand::solve_at($net->{source_text}, $s->{id}, $p);
            next unless $ok;
            my ($x) = grep { ($_->{id} // '') eq $s->{id} } @{ $n->{elems} }[1 .. $#{ $n->{elems} }];
            push @sys, [ $x->{q}, $p ] if $x && !$x->{closed} && $x->{q} > 0;
        }
    } elsif (!$combined) {
        my $ptop = $dm->{p_oper} > $dm->{p_demand} ? $dm->{p_oper} : $dm->{p_demand};
        for my $i (0 .. 9) {
            my $p = $dm->{p_demand} * 0.5 + ($ptop * 1.05 - $dm->{p_demand} * 0.5) * $i / 9;
            my (undef, $n) = HardyCross::Demand::margin_at($net->{source_text}, $s->{id}, $p);
            next unless $n;
            my ($x) = grep { ($_->{id} // '') eq $s->{id} } @{ $n->{elems} }[1 .. $#{ $n->{elems} }];
            push @sys, [ abs $x->{q}, $p ] if $x;
        }
    }
    @sys = sort { $a->[0] <=> $b->[0] } @sys;

    # Flows to fit: the demand (or required) point, and the operating point
    # where there is one.
    my @fit = grep { defined } $dm->{q_demand}, ($combined && !$dm->{one_pressure} ? () : $dm->{q_oper});
    my ($qmax) = sort { $b <=> $a } @fit;
    $qmax = $_->[0] for grep { $_->[0] > $qmax } @sys;
    $qmax *= 1.2;
    my $pmax = $avail->(0);
    for my $v ((grep { defined } $dm->{p_oper}, $dm->{p_demand}), (map { $_->[1] } @sys),
               (map { $curve_of->($_)->(0) } @{ $dm->{parts} || [] })) {
        $pmax = $v if $v > $pmax;
    }
    $pmax *= 1.1;
    return undef unless $qmax > 0 && $pmax > 0;

    # The supply, sampled evenly along the q^1.85 axis: within the entered
    # points it is straight on this paper; beyond them the curve continues
    # linearly in q, which on this paper bends, so it is sampled throughout.
    my @supply;
    for my $k (0 .. 200) {
        my $q = $qmax * ($k / 200) ** (1 / 1.85);
        push @supply, [ $q, $avail->($q) ];
    }
    my @tests = $s->{kind} ne 'SUPPLY_CURVE' ? ()
              : map { [ $s->{curve}{q}[$_], $s->{curve}{p}[$_] ] } 0 .. $#{ $s->{curve}{q} };
    # For the combined graph, each supply's own curve, on the same samples,
    # to draw lightly under the combined one.
    my @parts = map {
        my ($e, $c) = ($_, $curve_of->($_));
        [ $e->{id}, [ map { [ $_->[0], $c->($_->[0]) ] } @supply ] ]
    } @{ $dm->{parts} || [] };

    my ($qu, $pu) = (sym($net->{u_flow}), sym($net->{u_pres}));
    my $at = sub { sprintf '%.1f %s', $_[0] / $_[1], $_[2] };
    return {
        qmax => $qmax, pmax => $pmax, avail => $avail, supply => \@supply,
        tests => [ grep { $_->[0] <= $qmax } @tests ], sys => \@sys, shared => $shared,
        combined => $combined, parts => \@parts,
        demand => defined $dm->{q_demand} ? [ $dm->{q_demand}, $dm->{p_demand} ] : undef,
        oper => $combined && !$dm->{one_pressure} ? undef : [ $dm->{q_oper}, $dm->{p_oper} ],
        p_avail => $dm->{p_avail}, margin => $dm->{margin},
        xticks => [ map { $_ * $uf } nice_ticks($qmax / $uf, 10) ],
        yticks => [ map { $_ * $up } nice_ticks($pmax / $up, 8) ],
        uf => $uf, up => $up, qu => $qu, pu => $pu,
        kind => $s->{kind}, id => $s->{id}, node => $combined ? '' : $net->{nodes}[ $s->{n2} ]{id},
        # The key figures as Section 9 prints them, for the key beside the
        # drawn graph: [ label, flow or '', pressure ].
        figures => $combined ? [
            [ 'COMBINED DUTY', $at->($dm->{q_demand}, $uf, $qu), $at->($dm->{p_demand}, $up, $pu) ],
            [ 'COMBINED SUPPLY', '', $at->($dm->{p_avail}, $up, $pu) ],
            [ $dm->{margin} >= 0 ? 'MARGIN' : 'SHORTFALL', '', $at->(abs($dm->{margin}), $up, $pu) ],
            ($dm->{one_pressure}
                ? [ 'OPERATING', $at->($dm->{q_oper}, $uf, $qu), $at->($dm->{p_oper}, $up, $pu) ] : ()),
        ] : $shared ? [
            [ 'OPERATING', $at->($dm->{q_oper}, $uf, $qu), $at->($dm->{p_oper}, $up, $pu) ],
            [ 'SHARE OF ALL SUPPLIES', '',
              sprintf('%.1f %%', $dm->{q_all} > 0 ? 100 * $dm->{q_oper} / $dm->{q_all} : 0) ],
        ] : [
            [ 'DEMAND',    $at->($dm->{q_demand}, $uf, $qu), $at->($dm->{p_demand}, $up, $pu) ],
            [ 'AVAILABLE', '', $at->($dm->{p_avail}, $up, $pu) ],
            [ $dm->{margin} >= 0 ? 'MARGIN' : 'SHORTFALL', '', $at->(abs($dm->{margin}), $up, $pu) ],
            [ 'OPERATING', $at->($dm->{q_oper}, $uf, $qu), $at->($dm->{p_oper}, $up, $pu) ],
        ],
    };
}

#------------------------------------------------------------------------------
# nice_ticks -- round gridline values from 0 to $max: a step of 1, 2, 2.5 or 5
# times a power of ten, giving about $n divisions or fewer.
#------------------------------------------------------------------------------
sub nice_ticks {
    my ($max, $n) = @_;
    return (0) unless $max > 0;
    my $raw = $max / $n;
    my $mag = 10 ** int(log($raw) / log(10) - ($raw < 1 ? 1 : 0));
    my ($step) = grep { $_ * $mag >= $raw } 1, 2, 2.5, 5, 10;
    $step *= $mag;
    my @t;
    for (my $v = 0; $v <= $max * (1 + 1e-9); $v += $step) { push @t, 0 + sprintf('%.10g', $v) }
    return @t;
}

#------------------------------------------------------------------------------
# supply_graph -- the graph in characters, for the text report.  The PDF draws
# the same data with lines instead (HardyCross::PDF::draw_graph).
#------------------------------------------------------------------------------
sub supply_graph {
    my ($net, $dm) = @_;
    my $d = supply_graph_data($net, $dm) or return '';
    push @{ $net->{supply_graphs} }, $d;    # for the PDF, drawn from the same numbers
    my ($qmax, $pmax, $uf, $up) = @{$d}{qw(qmax pmax uf up)};
    my ($W, $H) = (64, 16);

    my @g = map { [ (' ') x $W ] } 1 .. $H;
    my $col = sub { my $x = ($_[0] / $qmax) ** 1.85; int($x * ($W - 1) + 0.5) };
    my $row = sub { my $r = int((1 - $_[0] / $pmax) * ($H - 1) + 0.5);
                    $r < 0 ? 0 : $r > $H - 1 ? $H - 1 : $r };
    my $put = sub { my ($q, $pp, $ch) = @_;
                    my ($c, $r) = ($col->($q), $row->($pp));
                    $g[$r][$c] = $ch if $c >= 0 && $c < $W };

    # Combined: each supply's own curve first, numbered, under the combined one.
    my @parts = @{ $d->{parts} || [] };
    for my $i (0 .. $#parts) {
        $put->(@$_, $i + 1 > 9 ? '+' : $i + 1) for grep { $_->[1] >= 0 && $_->[1] <= $pmax } @{ $parts[$i][1] };
    }
    for my $c (0 .. $W - 1) {                         # the supply, a continuous line
        my $q = $qmax * ($c / ($W - 1)) ** (1 / 1.85);
        my $pa = $d->{avail}->($q);
        $put->($q, $pa, '*') if $pa >= 0;
    }
    $put->(@$_, '.') for @{ $d->{sys} };              # the system, solved point by point
    $put->(@{ $d->{demand} }, 'D') if $d->{demand};
    $put->(@{ $d->{oper} },   'O') if $d->{oper};

    my ($pu, $qu) = @{$d}{qw(pu qu)};
    my $out = $d->{combined}
        ? "\n SUPPLY GRAPH - ALL SUPPLIES COMBINED, FLOWS ADDED AT EQUAL PRESSURE - pressure against flow^1.85\n\n"
        : $d->{shared}
        ? "\n SUPPLY GRAPH - $d->{id} AT NODE $d->{node}, THE OTHER SUPPLIES CONNECTED - pressure against flow^1.85\n\n"
        : "\n SUPPLY GRAPH - pressure against flow^1.85\n\n";
    for my $r (0 .. $H - 1) {
        my $label = ($r == 0 || $r == int(($H - 1) / 2) || $r == $H - 1)
            ? sprintf('%8.0f', $pmax * (1 - $r / ($H - 1)) / $up) : ' ' x 8;
        $out .= sprintf " %s |%s\n", $label, join '', @{ $g[$r] };
    }
    $out .= ' ' x 10 . '+' . '-' x $W . "\n";
    my @at = (0, int(($W - 1) / 3), int(2 * ($W - 1) / 3), $W - 1);
    my $line = ' ' x ($W + 12);
    for my $c (@at) {
        my $q = $qmax * ($c / ($W - 1)) ** (1 / 1.85);
        my $t = sprintf '%.0f', $q / $uf;
        substr($line, 11 + $c - int(length($t) / 2), length $t) = $t;
    }
    $out .= "$line\n";
    $out .= sprintf " %8s   flow, %s, on a flow^1.85 scale\n\n", $pu, $qu;
    if ($d->{combined}) {
        $out .= "   *  the supplies combined     " . join('  ', map { ($_ + 1 > 9 ? '+' : $_ + 1) . " $parts[$_][0]" } 0 .. $#parts) . "\n";
        $out .= sprintf("   O  combined operating point: %s at %s\n", @{ $d->{figures}[3] }[1, 2])
            if $d->{oper};
        $out .= sprintf("   D  combined duty: %s at %s; combined supply there %s; %s %s\n",
                        $d->{figures}[0][1], $d->{figures}[0][2], $d->{figures}[1][2],
                        lc $d->{figures}[2][0], $d->{figures}[2][2]);
        return $out;
    }
    $out .= "   *  supply available          .  system curve, each point a full solve\n";
    $out .= $d->{shared}
        ? sprintf("   O  operating point: %s at %s, %s of the flow of all the supplies\n",
                  $d->{figures}[-2][1], $d->{figures}[-2][2], $d->{figures}[-1][2])
        : "   D  demand point              O  operating point\n";
    return $out;
}

#------------------------------------------------------------------------------
# ratio_band_note -- what the report says under Section 10 about pressure
# ratio valves and their band.
#
# The calculation uses the bottom of each valve's band (HardyCross::
# ratio_valves): every outlet is checked against the least pressure the valve
# can be relied on to give.  The top of the band is what pipe, fitting and
# head ratings downstream must stand, so the network is solved once more with
# every valve at the top of its band, and the highest pressure that solve
# gives at a node the valves raise is stated -- with each valve's outlet.
#------------------------------------------------------------------------------
sub ratio_band_note {
    my $net = shift;
    my $up = $net->{f_pres};
    my $pu = sym($net->{u_pres});
    my $out = "\n" . wrap(' ', 'Each pressure ratio valve holds its outlet at inlet / ratio to within a '
        . 'band: +/-5% of the inlet pressure, from the manufacturer\'s data, unless the model gives another.  '
        . 'The calculation uses the BOTTOM of each band, outlet = inlet x (1/ratio - band), so every outlet '
        . 'is checked against the least pressure the valve can be relied on to give.');
    my $high = eval {
        require HardyCross::Phc;
        my $h = HardyCross::Phc::read_string($net->{source_text});
        $h->{opts}{pra_side} = 'HIGH';
        HardyCross::solve_model($h) ? $h : undef;
    };
    unless ($high) {
        return $out . wrap(' ', 'The network was not solved with the valves at the top of their bands, '
            . 'so the highest pressures downstream are not stated: check the pressure ratings by hand.');
    }
    # The highest pressure at a node the valves raise: one whose pressure is
    # higher with the valves at the top of their bands than at the bottom.
    my %low = map { $net->{nodes}[$_]{id} => HardyCross::Demand::gauge($net, $_) } 1 .. $#{ $net->{nodes} };
    my ($top, $at);
    for my $i (1 .. $#{ $high->{nodes} }) {
        my $id = $high->{nodes}[$i]{id};
        next if $id eq 'REF' || !defined $low{$id};
        my $g = HardyCross::Demand::gauge($high, $i);
        next unless $g > $low{$id} + 0.01;
        ($top, $at) = ($g, $id) if !defined $top || $g > $top;
    }
    my @v = map { my $e = $_; sprintf('%s outlet %.1f %s', $e->{id},
                  HardyCross::Demand::gauge($high, $e->{n2}) / $up, $pu) }
            grep { $_->{kind} eq 'RATIO' } @{ $high->{elems} }[1 .. $#{ $high->{elems} }];
    return $out . wrap(' ', 'With every valve at the TOP of its band (' . join(', ', @v) . ')'
        . (defined $top ? sprintf(', the highest pressure downstream is %.1f %s at node %s', $top / $up, $pu, $at)
                        : '') . ': the pipes, fittings and heads downstream must be rated for it.');
}

# Hang-indented paragraph wrap, so a long note reads as one item.
#------------------------------------------------------------------------------
# wrap -- a paragraph, word-wrapped to the page width, with a hanging indent.
# $lead is printed on the first line and its width in spaces on the rest, so a
# numbered note reads as one item however many lines it takes.
#------------------------------------------------------------------------------
sub wrap {
    my ($lead, $text) = @_;
    my $w = $W - length $lead;
    my @lines;
    my $cur = '';
    for my $word (split /\s+/, ascii($text)) {
        if (length($cur) + length($word) + 1 > $w && length $cur) {
            push @lines, $cur; $cur = $word;
        } else { $cur = length $cur ? "$cur $word" : $word }
    }
    push @lines, $cur if length $cur;
    my $pad = ' ' x length $lead;
    return $lead . join("\n$pad", @lines) . "\n";
}

1;
