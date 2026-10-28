#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# Parse.pm -- the network builder.
#
# HardyCross::Phc turns each .phc line into a row -- a section word (UNITS,
# OPTIONS, NODES, PIPES, PUMPS, SUPPLIES, DISCHARGES, DEVICES) and its tokens --
# and parse_row below adds that row to the network.  All numeric values are in
# the units set by the UNITS rows, which come first; everything is converted to
# internal units (L/min, kPa, m, mm) on the way in.

package HardyCross::Parse;

use strict;
use warnings;
use HardyCross;
use HardyCross::PipeData;

# The pipe and fitting database is loaded once, on first use, from
# data/pipes.dat.  A model that never names a pipe type never
# touches it, so older models and the validation suite are unaffected.
my $db_loaded = 0;
sub ensure_db {
    return if $db_loaded;
    HardyCross::PipeData::load();
    $db_loaded = 1;
}

# INTENDED as AS 1074 medium, but NOT transcribed from a controlled copy of
# the standard -- the same caveat every other implementation carries.
my %PIPE_ID = (15 => 16.1, 20 => 21.7, 25 => 27.3, 32 => 36.0, 40 => 41.9,
               50 => 53.1, 65 => 68.9, 80 => 80.9, 100 => 105.3,
               150 => 155.1, 200 => 207.3);

# The roughness a pipe takes, in mm, when the model gives none and the
# database publishes none for its type: commercial steel, new.
our $EPS_DEFAULT = 0.045;

#------------------------------------------------------------------------------
# roughness_defaulted -- the pipes whose roughness is the program default,
# 0.045 mm, because the model gave none and the database publishes none for
# their type.  Only under Darcy-Weisbach, the one method that uses it.
#------------------------------------------------------------------------------
sub roughness_defaulted {
    my $net = shift;
    return () unless ($net->{opts}{method} // 'HW') eq 'DW';
    return map { $_->{id} } grep { $_->{kind} eq 'PIPE' && ($_->{eps_src} // '') eq 'DEFAULT' }
                            @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
}

# roughness_warning -- the warning for those pipes, or nothing.
sub roughness_warning {
    my @ids = roughness_defaulted(shift);
    return () unless @ids;
    my @shown = @ids > 12 ? (@ids[0 .. 11], sprintf('and %d more', @ids - 12)) : @ids;
    return sprintf('roughness ASSUMED: %d pipe(s) take 0.045 mm, the program default, because no roughness '
        . 'is given for them in the model or in the database: %s.  Give it on the USE line (USE BORE <mm>, '
        . 'USE <type> <mm>), or for the pipe type in the database.', scalar @ids, join(', ', @shown));
}

sub tokenize {
    my $line = shift;
    # Strip the line ending FIRST.  The separator class does not include \n,
    # so without this every last token on a line keeps a trailing newline --
    # and because Perl's $ anchor matches before a final newline, the section
    # headers still matched while the data quietly did not.
    $line =~ s/\r?\n\z//;
    $line =~ s/[!#].*$//;
    # Control bytes and anything outside printable ASCII are SEPARATORS, not
    # data.  Splitting on whitespace alone let a corrupted byte become part of
    # a node name, from where it travelled into every report that named the
    # node.  A damaged file can now produce an unknown keyword -- which is
    # reported -- but can never smuggle a non-printable byte into the output.
    # The fuzz tests found 60 cases of this.
    $line =~ s/[^\x20-\x7E]+/ /g;
    # Commas separate tokens in this format -- so "FIT=2E,1T,1GV" was being cut
    # to "FIT=2E" with the rest left as stray tokens and silently ignored.  A
    # pipe with five fittings solved with one, and nothing said so.  Inside a
    # FIT= value the commas are fitting separators, not token separators, so
    # they are protected before the split.
    $line =~ s{(FIT=\S*)}{ (my $f = $1) =~ tr/,/+/; $f }gie;
    return grep { length } split /[ \t,;]+/, $line;
}

#------------------------------------------------------------------------------
# num -- a token as a number, or 0.
#
# Deliberately strict: a plain decimal or scientific number is accepted and
# anything else is 0.  The callers that must NOT accept a silent zero -- a pipe
# diameter, a device drop -- check the result against zero themselves and fail
# with a message, so a typing error is reported rather than calculated.
# "nan" and "inf" are refused outright: one non-finite value would flow into
# every sum in the network and make every later check meaningless.
#------------------------------------------------------------------------------
sub num {
    my $t = shift // 0;
    return is_num($t) ? $t + 0 : 0;
}

#------------------------------------------------------------------------------
# is_num -- true when num() would read the token as a number rather than as 0.
#
# The .phc reader (HardyCross::Phc) must refuse "1O0" for a length instead of
# solving it as 0, and to do that it has to know what num() accepts.  Asking
# here keeps ONE definition of a number for both input formats.
#------------------------------------------------------------------------------
sub is_num {
    my $t = shift;
    return 0 unless defined $t;
    # nan and inf are rejected outright: accepting one puts a non-finite value
    # into the network and every later check becomes meaningless.
    return 0 if $t =~ /^[-+]?(nan|inf)/i;
    return $t =~ /^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$/ ? 1 : 0;
}

#------------------------------------------------------------------------------
# kv -- the value of a KEY=value token on the line, as a number, or undef.
#
# Keys are case-insensitive (C=120 and c=120 are the same).  undef, not 0,
# when the key is absent, so a caller can tell "not given" from "given as 0" --
# a PRV with DP=0 is an error, a PRV with no DP is a different error.
#------------------------------------------------------------------------------
sub kv {
    my ($tk, $key) = @_;
    for my $t (@$tk) {
        my ($k, $v) = split /=/, $t, 2;
        return num($v) if defined $v && uc($k) eq uc($key);
    }
    return undef;
}

#------------------------------------------------------------------------------
# node_index -- the index of a node by name, creating it on first mention.
#
# A node does not have to be declared in NODES before a pipe uses it; it is
# created here at elevation 0.  That is convenient and occasionally dangerous
# (a mistyped node name makes a new, unconnected node), which is why the
# topology check afterwards refuses a network with an unconnected node.
# Index 0 is unused and index 1 is always the reference node, REF.
#------------------------------------------------------------------------------
sub node_index {
    my ($net, $id) = @_;
    for my $i (1 .. $#{ $net->{nodes} }) {
        return $i if $net->{nodes}[$i]{id} eq $id;
    }
    push @{ $net->{nodes} },
        { id => $id, z => 0, demand => 0, h => 0,
          pelem => 0, pnode => 0, depth => 0, visited => 0 };
    return $#{ $net->{nodes} };
}

#------------------------------------------------------------------------------
# read_curve -- flow/pressure pairs from a line, converted and fitted.
#
# The pairs start at token $from and stop at the first KEY=value token.  Each
# pair is converted to internal units (L/min, kPa) on the way in, then fitted
# by HardyCross::fit_curve.  $rising is true for a LOSS curve (a backflow
# preventer's loss rises with flow) and false for a SUPPLY or PUMP curve
# (the pressure available falls with flow); the fit guards its end slopes in
# the direction that keeps the loop correction well posed.
#------------------------------------------------------------------------------
sub read_curve {
    my ($net, $tk, $from, $rising) = @_;
    my @v = map { num($_) } grep { !/=/ } @$tk[$from .. $#$tk];
    HardyCross::fail("curve needs at least two flow/pressure pairs")
        if @v < 4 || @v % 2;
    my $c = { q => [], p => [] };
    while (@v >= 2) {
        push @{ $c->{q} }, shift(@v) * $net->{f_flow};
        push @{ $c->{p} }, shift(@v) * $net->{f_pres};
    }
    return HardyCross::fit_curve($c, $rising);
}

# read_model reads a model file: a .phc command file, the one file type PHCP
# reads.  HardyCross::Phc translates its lines into rows and hands each to
# parse_row below, so every check, default and unit conversion lives in one
# place.  Any other file is refused, with the reason.
sub read_model {
    my $path = shift;
    HardyCross::fail('%s IS NOT A .PHC MODEL. PHCP READS .PHC FILES ONLY', $path)
        unless $path =~ /\.phc\z/i;
    # Loaded here, not at the top, because Phc.pm itself uses this module.
    require HardyCross::Phc;
    return HardyCross::Phc::read_model($path);
}

#------------------------------------------------------------------------------
# new_net -- an empty network with the program defaults.
#
# Every default a model starts from is set here and nowhere else.  The .phc
# reader starts from it, and so does the .phc line checker, which parses one row at a
# time into a scratch network to find out whether the parser would accept it.
#------------------------------------------------------------------------------
sub new_net {
    return {
        nodes => [ {}, { id => 'REF', z => 0, demand => 0, h => 0,
                         pelem => 0, pnode => 0, depth => 0, visited => 0 } ],
        elems => [ {} ],
        loops => [], iref => 1,
        f_flow => 1, f_pres => 1, f_len => 1, f_dia => 1,
        u_flow => 'LPM', u_pres => 'KPA', u_len => 'M', u_dia => 'MM',
        opts => { method => 'HW', hwk => $HardyCross::HWK_DEF,
                  hwq => 1.85, hwd => 4.87, nu => 1.004e-6,
                  maxiter => 50000, tol_flow => 0.05, tol_loop => 0.01,
                  orif_step => 0.5,
                  # The velocity above which a pipe is flagged, in m/s.  It is
                  # a SETTING: no clause of AS 2118.1 is cited for it here, and
                  # the value in force is printed in every report so nobody
                  # mistakes it for a requirement of the Standard.
                  vel_limit => 6.0, vel_limit_set => 0 },
    };
}

sub parse_row {
    my ($net, $section, $tk) = @_;

    #--------------------------------------------------------------- UNITS
    # One quantity per line: FLOW LPM, PRESSURE KPA, LENGTH M, DIAMETER MM.
    # The factor is stored on the network and applied to every later value, so
    # UNITS must come before the data it describes -- as every example does.
    if ($section eq 'UNITS') {
        HardyCross::set_unit($net, uc $tk->[0], uc($tk->[1] // ''));
        return;
    }
    #------------------------------------------------------------- OPTIONS
    # Solver settings.  Tolerances are given in the model's own units and
    # converted, so TOL_FLOW 0.05 means 0.05 of whatever FLOW unit is in force.
    # An option this parser does not recognise is ignored; every one that
    # changes a result is listed here.
    if ($section eq 'OPTIONS') {
        my ($k, $v) = (uc $tk->[0], $tk->[1] // '');
        my $o = $net->{opts};
        if    ($k eq 'METHOD') {
            $o->{method} = uc($v) =~ /^(HW|HAZEN|HAZEN-WILLIAMS)$/ ? 'HW'
                         : uc($v) =~ /^(DW|DARCY|DARCY-WEISBACH)$/ ? 'DW'
                         : HardyCross::fail("METHOD must be HW or DW, not %s", $v);
        }
        elsif ($k eq 'HW_CONST') { $o->{hwk} = num($v) }
        elsif ($k eq 'NU') {
            $o->{nu} = num($v);
            HardyCross::fail("NU must be greater than zero") if $o->{nu} <= 0;
        }
        elsif ($k eq 'TOL_FLOW') { $o->{tol_flow} = num($v) * $net->{f_flow} }
        elsif ($k eq 'TOL_LOOP') { $o->{tol_loop} = num($v) * $net->{f_pres} }
        elsif ($k eq 'MAXITER')  {
            $o->{maxiter} = int num($v);
            # Zero is a legitimate request -- no iterations, report the seed --
            # but a negative count is nonsense.
            $o->{maxiter} = 0 if $o->{maxiter} < 0;
        }
        elsif ($k eq 'RELAX') {
            # Outside (0, 2] the correction either does nothing or is unstable
            # by construction.  It used to be silently ignored altogether,
            # which accepted RELAX 100 and ran as if it had not been given.
            my $r = num($v);
            HardyCross::fail("RELAX must be greater than 0 and at most 2")
                if $r <= 0 || $r > 2;
            $o->{relax} = $r;
        }
        elsif ($k eq 'VEL_LIMIT') {
            my $vl = num($v);
            HardyCross::fail("VEL_LIMIT must be greater than zero, in m/s") if $vl <= 0;
            $o->{vel_limit} = $vl;
            $o->{vel_limit_set} = 1;
        }
        elsif ($k eq 'FITTING_BASIS') {
            # CORRECTED (the default): fitting lengths corrected for C and for
            # the installed bore.  STANDARD: AS 2118.1 values unmodified, the
            # "published Standard alone" election.  It is legitimate, and the
            # report states it.
            my $v2 = uc $v;
            HardyCross::fail("FITTING_BASIS must be CORRECTED or STANDARD")
                unless $v2 eq 'CORRECTED' || $v2 eq 'STANDARD';
            $o->{fitting_basis} = $v2;
        }
        elsif ($k eq 'ORIF_STEP'){ $o->{orif_step} = num($v) * $net->{f_dia} }
        return;
    }
    #--------------------------------------------------------------- NODES
    # "id elevation".  Elevation in the model's LENGTH unit, above an
    # arbitrary but consistent datum.
    if ($section eq 'NODES') {
        my $i = node_index($net, $tk->[0]);
        $net->{nodes}[$i]{z} = num($tk->[1]) * $net->{f_len} if defined $tk->[1];
        return;
    }
    #--------------------------------------------------------------- PIPES
    # "id n1 n2 length diameter [C] [KEY=value ...]".
    #
    # Two forms.  With TYPE= the diameter is a NOMINAL size, the bore comes
    # from the pipe database, and FIT= is resolved to an equivalent length by
    # HardyCross::PipeData -- this is the form a design should use.  Without TYPE= the
    # diameter is the bore itself and fittings are an EQV= length; this form
    # exists for models written before the database and for validation cases.
    if ($section eq 'PIPES') {
        HardyCross::fail("PIPE needs: id n1 n2 length diameter") if @$tk < 5;

        # TYPE= names a pipe type from the database.  When it is present the
        # diameter field is the NOMINAL size and the bore comes from that
        # type's PIPE records -- which is how a
        # calculation sheet is written, and means nobody types a bore.
        my ($ptype) = map { /^TYPE=(.*)$/i ? uc $1 : () } @$tk;
        my ($fitspec) = map { /^FIT=(.*)$/i ? $1 : () } @$tk;
        if (defined $ptype) {
            ensure_db();
            my $info = HardyCross::PipeData::pipe_type($ptype)
                or HardyCross::fail("pipe %s: unknown pipe type %s (the pipe database lists %s)",
                                    $tk->[0], $ptype,
                                    join(', ', HardyCross::PipeData::pipe_types()));
            my $dn = int(num($tk->[4]) + 0.5);
            my $bore = HardyCross::PipeData::bore($ptype, $dn);
            HardyCross::fail("pipe %s: DATA_REQUIRED - DN%d is not in the database "
                           . "for %s; the bore is not guessed", $tk->[0], $dn, $ptype)
                unless defined $bore;
            my $c = kv($tk, 'C');
            $c = (defined $tk->[5] && $tk->[5] !~ /=/) ? num($tk->[5]) : undef
                unless defined $c;
            # A C different from the type's own is allowed -- a lined main, an
            # old unlined one -- but it must be deliberate, so it is recorded.
            my $c_given = defined $c;
            $c //= $info->{c};

            my $eqv = (kv($tk, 'EQV') // 0) * $net->{f_len};
            my $res;
            if (defined $fitspec && $fitspec =~ /\S/) {
                $res = HardyCross::PipeData::resolve(
                    type => $ptype, dn => $dn, c => $c, spec => $fitspec,
                    standard_only => ($net->{opts}{fitting_basis} // '') eq 'STANDARD');
                # Missing data stops the solve and names the component.
                # Solving on regardless would under-count exactly the fittings
                # nobody is checking.
                HardyCross::fail("pipe %s: %s", $tk->[0], join('; ', @{ $res->{errors} }))
                    if @{ $res->{errors} };
                $eqv += $res->{total};
            }
            # The roughness (Darcy-Weisbach): as given in the model; else the
            # database's for the pipe type; else the program default, 0.045
            # mm -- recorded, so that an assumed value is flagged, never
            # passed off as data (roughness_defaulted below).
            my $eps = kv($tk, 'EPS');
            my $eps_src = defined $eps ? 'GIVEN' : defined $info->{eps} ? 'DATABASE' : 'DEFAULT';
            $eps = defined $eps ? $eps * $net->{f_dia} : $info->{eps} // $EPS_DEFAULT;
            my $e = {
                id => $tk->[0], kind => 'PIPE',
                n1 => node_index($net, $tk->[1]), n2 => node_index($net, $tk->[2]),
                len => num($tk->[3]) * $net->{f_len},
                dia => $bore, c => $c, eqv => $eqv,
                eps => $eps, eps_src => $eps_src,
                kfit => (kv($tk, 'K') // 0),
                q => 0, in_tree => 0,
                # provenance, for the report
                ptype => $ptype, dn => $dn, c_given => $c_given,
                fitspec => $fitspec, fitres => $res,
            };
            HardyCross::fail("pipe %s has a negative length", $e->{id}) if $e->{len} < 0;
            push @{ $net->{elems} }, $e;
            return;
        }
        HardyCross::fail("pipe %s: a fitting string needs TYPE= so its table and "
                       . "basis bore are known", $tk->[0])
            if defined $fitspec && $fitspec =~ /\S/;
        my $c = kv($tk, 'C');
        $c = (defined $tk->[5] && $tk->[5] !~ /=/) ? num($tk->[5]) : 120 unless defined $c;
        my $e = {
            id => $tk->[0], kind => 'PIPE',
            n1 => node_index($net, $tk->[1]), n2 => node_index($net, $tk->[2]),
            len => num($tk->[3]) * $net->{f_len},
            dia => num($tk->[4]) * $net->{f_dia},
            c   => $c,
            eqv => (kv($tk, 'EQV') // 0) * $net->{f_len},
            # As given, else the program default -- flagged (roughness_defaulted).
            eps => defined kv($tk, 'EPS') ? kv($tk, 'EPS') * $net->{f_dia} : $EPS_DEFAULT,
            eps_src => defined kv($tk, 'EPS') ? 'GIVEN' : 'DEFAULT',
            # Minor loss coefficient.  Dimensionless, so no unit factor.
            kfit => (kv($tk, 'K') // 0),
            q => 0, in_tree => 0,
        };
        HardyCross::fail("pipe %s has a non-positive diameter", $e->{id}) if $e->{dia} <= 0;
        HardyCross::fail("pipe %s has a negative length", $e->{id})       if $e->{len} < 0;
        HardyCross::fail("pipe %s has a non-positive C factor", $e->{id}) if $e->{c} <= 0;
        push @{ $net->{elems} }, $e;
        return;
    }
    #--------------------------------------------------------------- PUMPS
    # "id n1 n2 Q1 P1 Q2 P2 ...": a booster from n1 to n2 on a curve of flow
    # against pressure RISE.  Its check valve is handled by the solver's outer
    # loop, not here.
    if ($section eq 'PUMPS') {
        push @{ $net->{elems} }, {
            id => $tk->[0], kind => 'PUMP',
            n1 => node_index($net, $tk->[1]), n2 => node_index($net, $tk->[2]),
            curve => read_curve($net, $tk, 3, 0), q => 0, in_tree => 0,
        };
        return;
    }
    #------------------------------------------------------------ SUPPLIES
    # "id node STATIC p" or "id node CURVE Q1 P1 Q2 P2 ...".  A supply is an
    # edge from the reference node into the network; a pressure is measured at
    # the node's own elevation unless Z= gives another.
    if ($section eq 'SUPPLIES') {
        my $n = node_index($net, $tk->[1]);
        my $z = defined kv($tk, 'Z') ? kv($tk, 'Z') * $net->{f_len}
                                     : $net->{nodes}[$n]{z};
        if (uc($tk->[2]) eq 'STATIC') {
            push @{ $net->{elems} }, {
                id => $tk->[0], kind => 'SUPPLY_STATIC',
                n1 => $net->{iref}, n2 => $n,
                pstat => num($tk->[3]) * $net->{f_pres}, z => $z,
                q => 0, in_tree => 0,
            };
        } else {
            push @{ $net->{elems} }, {
                id => $tk->[0], kind => 'SUPPLY_CURVE',
                n1 => $net->{iref}, n2 => $n,
                curve => read_curve($net, $tk, 3, 0), z => $z,
                q => 0, in_tree => 0,
            };
        }
        return;
    }
    #---------------------------------------------------------- DISCHARGES
    # "id node TYPE [K=] [Q=] [P=]": an outlet -- sprinkler, hydrant, hose reel
    # -- as an edge from its node back to the reference node.  Any two of K,
    # Q and P fix the third through Q = K sqrt(P).  FIXEDFLOW is different: a
    # set demand with no K, added to the node and never corrected.  Its MINP=
    # (or P=) is the pressure it needs at that flow: it does not change the
    # solve, but it is checked -- see the fixed-flow note below.
    if ($section eq 'DISCHARGES') {
        my $n  = node_index($net, $tk->[1]);
        my $ty = uc $tk->[2];
        my $z  = defined kv($tk, 'Z') ? kv($tk, 'Z') * $net->{f_len}
                                      : $net->{nodes}[$n]{z};
        my ($uf, $up) = ($net->{f_flow}, $net->{f_pres});
        my $kk = kv($tk, 'K');  $kk = $kk * $uf / sqrt($up) if defined $kk;
        my $qq = kv($tk, 'Q') // kv($tk, 'MINQ');
        $qq = $qq * $uf if defined $qq;
        my $pp = kv($tk, 'P') // kv($tk, 'MINP');
        $pp = $pp * $up if defined $pp;

        if ($ty eq 'FIXEDFLOW' || $ty eq 'FIXED') {
            HardyCross::fail("FIXEDFLOW needs Q=") unless defined $qq;
            HardyCross::fail("FIXEDFLOW %s has a negative minimum pressure", $tk->[0])
                if defined $pp && $pp < 0;
            # A fixed-flow outlet is a nodal demand: it sits outside every loop
            # and is never corrected, which is what "fixed" has to mean.
            $net->{nodes}[$n]{demand} += $qq;
            # Kept as well, by id, so its minimum pressure can be CHECKED: the
            # outlet compliance table passes or fails it, and the governing
            # outlet and demand point count it like any other outlet.  The
            # minimum used to be read and then thrown away, so a fixed flow at
            # a node far below its required pressure was reported as if all
            # were well.  The flow itself stays fixed whatever the pressure --
            # that is what the designer asked for -- so the solve is unchanged.
            push @{ $net->{fixed} }, {
                id => $tk->[0], kind => 'FIXEDFLOW', n1 => $n,
                qreq => $qq, q => $qq, preq => $pp, z => $z,
            };
            return;
        }
        my $given = grep { defined } ($kk, $qq, $pp);
        HardyCross::fail("discharge %s needs any TWO of K, Q, P", $tk->[0]) if $given < 2;
        $kk //= ($pp > $HardyCross::D_TINY ? $qq / sqrt($pp) : 0);
        $qq //= $kk * sqrt($pp > 0 ? $pp : 0);
        $pp //= ($kk > $HardyCross::D_TINY ? ($qq / $kk) ** 2 : 0);
        HardyCross::fail("discharge %s resolves to an unusable K-factor", $tk->[0])
            if $kk <= $HardyCross::D_TINY;
        push @{ $net->{elems} }, {
            id => $tk->[0], kind => 'DISCHARGE',
            # SPRINKLER, HYDRANT, HOSEREEL: the cover sheet counts sprinklers
            # and reports hydrant and hose reel flow separately.
            otype => $ty,
            n1 => $n, n2 => $net->{iref},
            k => $kk, qreq => $qq, preq => $pp, z => $z,
            q => 0, in_tree => 0,
        };
        return;
    }
    #------------------------------------------------------------- DEVICES
    # "id n1 n2 TYPE ...": PRV (a fixed drop), BFP (a loss curve), ORIFICE_D
    # (a plate of known bore) or ORIFICE_P (a plate whose drop is required and
    # whose bore the outer loop sizes).  Each value is checked for being
    # physically possible here, because a device that adds pressure or a plate
    # wider than its pipe would otherwise be solved without complaint.
    if ($section eq 'DEVICES') {
        my $n1 = node_index($net, $tk->[1]);
        my $n2 = node_index($net, $tk->[2]);
        my $ty = uc $tk->[3];
        my $dn = int(kv($tk, 'DN') // 0);
        my $pd = defined kv($tk, 'PIPEDIA') ? kv($tk, 'PIPEDIA') * $net->{f_dia}
                                            : ($PIPE_ID{$dn} // 0);
        my $cd = kv($tk, 'CD') // 0.596;

        # A device that removes no pressure, or adds it, is not a device; a
        # plate with no bore, or one wider than its pipe, is not a plate.  These
        # were accepted and solved, producing an answer to a model that cannot
        # exist.
        my $dp   = (kv($tk, 'DP')   // 0) * $net->{f_pres};
        my $bore = (kv($tk, 'BORE') // 0) * $net->{f_dia};
        HardyCross::fail("PRV %s needs a positive DP=", $tk->[0])
            if $ty eq 'PRV' && $dp <= 0;
        HardyCross::fail("ORIFICE_P %s needs a positive DP=", $tk->[0])
            if $ty eq 'ORIFICE_P' && $dp <= 0;
        HardyCross::fail("ORIFICE_D %s needs a positive BORE=", $tk->[0])
            if $ty eq 'ORIFICE_D' && $bore <= 0;
        HardyCross::fail("orifice %s bore is not smaller than the pipe bore", $tk->[0])
            if $ty eq 'ORIFICE_D' && $pd > 0 && $bore >= $pd;

        if ($ty eq 'PRV') {
            push @{ $net->{elems} }, {
                id => $tk->[0], kind => 'FIXED_DROP', n1 => $n1, n2 => $n2,
                dp => (kv($tk, 'DP') // 0) * $net->{f_pres}, q => 0, in_tree => 0,
            };
        } elsif ($ty eq 'ORIFICE_P') {
            HardyCross::fail("orifice %s needs DN= or PIPEDIA= for the pipe bore",
                             $tk->[0]) if $pd <= 0;
            # An ORIFICE_P states the drop it must PRODUCE; the bore is an
            # output.  Until the outer loop sizes it, it behaves as a fixed drop.
            push @{ $net->{elems} }, {
                id => $tk->[0], kind => 'ORIFICE_REQUIRED', n1 => $n1, n2 => $n2,
                dp => (kv($tk, 'DP') // 0) * $net->{f_pres},
                dn => $dn, pipedia => $pd, cd => $cd, bore => 0,
                q => 0, in_tree => 0,
            };
        } elsif ($ty eq 'ORIFICE_D') {
            push @{ $net->{elems} }, {
                id => $tk->[0], kind => 'ORIFICE', n1 => $n1, n2 => $n2,
                bore => (kv($tk, 'BORE') // 0) * $net->{f_dia},
                pipedia => $pd, cd => $cd, q => 0, in_tree => 0,
            };
        } elsif ($ty eq 'PRA') {
            # A pressure ratio valve: outlet pressure = inlet / RATIO.  Its
            # drop is set from the solved inlet pressure by the solver's outer
            # loop (HardyCross::ratio_valves); it starts at zero.
            my $r = kv($tk, 'RATIO') // 0;
            HardyCross::fail("PRA %s needs RATIO= more than 1", $tk->[0]) if $r <= 1;
            my $mi = kv($tk, 'MININLET');
            # BAND= the valve's tolerance, as a percentage of its inlet
            # pressure (the manufacturer's +/- 5 % unless given); the solve
            # designs to the bottom of it (HardyCross::ratio_valves).
            my $band = kv($tk, 'BAND') // 5;
            HardyCross::fail("PRA %s: BAND= cannot be negative", $tk->[0]) if $band < 0;
            HardyCross::fail("PRA %s: a band of %g%% of the inlet pressure is more than the %g%% "
                             . "a %g:1 valve passes - the bottom of the band would be no pressure at all",
                             $tk->[0], $band, 100 / $r, $r) if $band / 100 >= 1 / $r;
            push @{ $net->{elems} }, {
                id => $tk->[0], kind => 'RATIO', n1 => $n1, n2 => $n2,
                ratio => $r, band => $band / 100, dp => 0, q => 0, in_tree => 0,
                (defined $mi && $mi > 0 ? (mininlet => $mi * $net->{f_pres}) : ()),
            };
        } elsif ($ty eq 'BFP') {
            push @{ $net->{elems} }, {
                id => $tk->[0], kind => 'BFP', n1 => $n1, n2 => $n2,
                curve => read_curve($net, $tk, 4, 1), q => 0, in_tree => 0,
            };
        } else {
            HardyCross::fail("device type %s is not known", $ty);
        }
        return;
    }
}

1;
