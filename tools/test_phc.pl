#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_phc.pl -- the .phc command language, its converter and its line checker.
#
#   perl tools/test_phc.pl          every check; example 04 compared as parsed
#                                   networks, not solved (it takes minutes)
#   perl tools/test_phc.pl --full   also solve example 04 both ways and compare
#                                   its flows and pressures (several minutes)
#
# What it proves, in order:
#
#   1. CONVERSION.  Every example converted from .hcx gives a report identical
#      to the original's apart from the model file name, and the converted file
#      in examples/ is exactly what the converter writes today.
#   2. EVERY COMMAND.  A valid line reads; a line missing each required field,
#      with a bad number, with an option the command does not take, or setting
#      something twice, is refused -- and every refusal names its line.
#   3. ANY ORDER.  Each example with its lines shuffled solves to the same
#      flows and pressures (iteration counts may differ).
#   4. USE, FITTINGS, UNITS.  Use applies to the pipes after it; the three
#      ways of writing fittings mean the same thing; Units can go anywhere.
#   5. THE LINE CHECKER.  check_line's status, template, pick lists and
#      proposal for each command, headless.
#   6. TRAPS CLOSED.  A node with no Node line, '#' in a line, END as an id,
#      and a parser error reported on the .phc line it came from.
#   7. FIXED-FLOW MINIMUM PRESSURE.  Flow MINP= is read, passed or failed in
#      the report, and governs the demand point when its margin is the least.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use List::Util qw(shuffle);
use Data::Dumper;
use HardyCross;
use HardyCross::Parse;
use HardyCross::Phc;
use HardyCross::Convert;
use HardyCross::Report;
use HardyCross::Demand;

my $FULL = grep { $_ eq '--full' } @ARGV;
my $EX   = "$FindBin::Bin/../examples";
my ($pass, $fail) = (0, 0);

# is -- one named check.  A failure prints what was found, so a red line says
# why without a debugger.
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-66s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}

sub slurp { my $p = shift; open my $f, '<', $p or die "$p: $!\n"; local $/; <$f> }

# read_phc -- (network, undef) or (undef, error message) for .phc text.
sub read_phc {
    my $net = eval { HardyCross::Phc::read_string(shift) };
    return ($net, undef) if $net;
    my $e = $@;
    return (undef, HardyCross::is_model_error($e) ? $e->{msg} : "$e");
}

# refused -- check that .phc text is refused on line $line with a message
# matching $re.
sub refused {
    my ($name, $text, $line, $re) = @_;
    my ($net, $err) = read_phc($text);
    my $ok = !$net && $err =~ /^line \Q$line\E: / && $err =~ $re;
    is($name, $ok, $net ? 'it was accepted' : "got: $err");
}

# The network as plain data, for comparing two reads.  The source texts are
# left out: they are the inputs, which differ by design.
sub canon {
    my $net = shift;
    local $Data::Dumper::Sortkeys = 1;
    local $Data::Dumper::Indent   = 0;
    local $Data::Dumper::Deepcopy = 1;
    my %n = %$net;
    delete @n{qw(source_text phc_text)};
    return Dumper(\%n);
}

# Solved flows by element id and gauge pressures by node id.
sub results {
    my $net = shift;
    my (%q, %p);
    $q{ $_->{id} } = $_->{q} for @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    for my $n (@{ $net->{nodes} }[1 .. $#{ $net->{nodes} }]) {
        next if $n->{id} eq 'REF';
        $p{ $n->{id} } = $n->{h} - $HardyCross::GAMMA_W * $n->{z};
    }
    return (\%q, \%p);
}

# The worst difference between two id => value maps; huge if the ids differ.
sub worst {
    my ($a, $b) = @_;
    return 1e30 unless join(',', sort keys %$a) eq join(',', sort keys %$b);
    my $w = 0;
    for (keys %$a) { my $d = abs($a->{$_} - $b->{$_}); $w = $d if $d > $w }
    return $w;
}

# The report without its MODEL FILE line, which names the file and so differs.
sub report_body {
    my ($net, $ok, $path) = @_;
    my $r = HardyCross::Report::write_report($net, $ok, $path);
    $r =~ s/^.*MODEL FILE.*\n//mg;
    return $r;
}

#==============================================================================
print "1. CONVERSION - every example, report identical to the .hcx original\n";
#==============================================================================
for my $hcx (sort glob("$EX/*.hcx")) {
    (my $base = $hcx) =~ s{.*/}{};
    (my $phcpath = $hcx) =~ s/\.hcx\z/.phc/;
    my $phc = eval { HardyCross::Convert::hcx_to_phc(slurp($hcx), $base) };
    is("$base converts", defined $phc, $@ && (ref $@ ? $@->{msg} : $@));
    next unless defined $phc;
    is("   examples/ holds exactly what the converter writes",
       -e $phcpath && slurp($phcpath) eq $phc, "re-run phcp.pl --convert for $base");

    my $a = HardyCross::Parse::read_model($hcx);
    my ($b, $err) = read_phc($phc);
    is("   the .phc reads", $b, $err);
    next unless $b;
    is("   same network as the .hcx (every element, node and option)",
       canon($a) eq canon($b));

    if ($base =~ /grid1000/ && !$FULL) {
        print "      (not solved: 1000 nodes takes minutes; --full to solve)\n";
        next;
    }
    my $oka = HardyCross::solve_model($a);
    my $okb = HardyCross::solve_model($b);
    is("   same iterations ($a->{iters})", $a->{iters} == $b->{iters},
       "$a->{iters} against $b->{iters}");
    if ($base =~ /grid1000/) {
        # Its report is not written: the demand point re-solves the whole
        # network dozens of times, hours at 1000 nodes.  The solved flows and
        # pressures, which everything in the report is computed from, are
        # compared instead -- exactly, since the networks are identical.
        my ($qa, $pa) = results($a);
        my ($qb, $pb) = results($b);
        is('   identical solved flows and pressures (report not written: hours)',
           worst($qa, $qb) == 0 && worst($pa, $pb) == 0);
        next;
    }
    is("   report identical apart from the model file name",
       report_body($a, $oka, $hcx) eq report_body($b, $okb, $phcpath));
}

#==============================================================================
print "2. EVERY COMMAND - valid, each field missing, bad number, bad option\n";
#==============================================================================
# A small model the test lines are added to, as line 9.
my $BASE = join "\n", 'Units FLOW=LPM', 'Node A 0', 'Node B 0', 'Node C 1.5',
    'Supply S A STATIC 500', 'Use BORE', 'Pipe P1 A B 10 100', 'Head H B K=80 P=50', '';
my $L = 9;

# Each command: a valid line, the indexes of its numeric fields (counting the
# command word as 0), and the options that are required.
my @CASES = (
    [ 'Title A TEST MODEL',                       [],           [] ],
    [ 'Project JOB HYC-2026-000',                 [],           [] ],
    [ 'Units PRESSURE=KPA LENGTH=M',              [],           [] ],
    [ 'Method HW',                                [],           [] ],
    [ 'Option TOL_FLOW 0.01',                     [2],          [] ],
    [ 'Use ASAM C=110',                           [],           [] ],
    [ 'Node D 2.5',                               [2],          [] ],
    [ 'Pipe P2 B C 5 50 C=100 EQV=1 EPS=0.05 K=0.5', [4, 5],    [] ],
    [ 'Supply S2 C STATIC 600 Z=1',               [4],          [] ],
    [ 'Supply S3 C CURVE 0 600 1000 500 Z=1',     [4, 5, 6, 7], [] ],
    [ 'Pump PU A C 0 300 1000 200',               [4, 5, 6, 7], [] ],
    [ 'Head H2 C K=80 P=50 Z=1',                  [],           [] ],
    [ 'Hydrant HY C Q=600 P=200',                 [],           [] ],
    [ 'HoseReel HR C K=7.5 P=220',                [],           [] ],
    [ 'Flow F1 C Q=100 MINP=150 Z=1',             [],           ['Q'] ],
    [ 'BFP BF A C 0 0 1000 20',                   [4, 5, 6, 7], [] ],
    [ 'PRV PR A C DP=50',                         [],           ['DP'] ],
    [ 'Orifice OR A C DP=20 DN=50 CD=0.6',        [],           ['DP', 'DN'] ],
    [ 'Orifice OD A C BORE=30 PIPEDIA=53',        [],           ['BORE', 'PIPEDIA'] ],
);
for my $case (@CASES) {
    my ($line, $nums, $need) = @$case;
    my ($word) = $line =~ /^(\S+)/;
    my ($net, $err) = read_phc($BASE . $line);
    is("$word: '$line' reads", $net, $err);

    # Each fixed field missing: the line cut after fewer and fewer fields --
    # the command word alone, then with its first field, and so on.
    my $spec = HardyCross::Phc::command_spec($word);
    my @tk = split ' ', $line;
    my $nfix = @{ $spec->{fixed} };
    my @plain = grep { !/=/ } @tk;
    for my $keep (0 .. $nfix - 1) {
        my $cut = join ' ', @plain[0 .. $keep];
        refused("   missing $spec->{fixed}[$keep][0]: '$cut'", $BASE . $cut, $L, qr/needs/);
    }
    # Each required option missing.
    for my $k (@$need) {
        (my $cut = $line) =~ s/\s+$k=\S+//;
        refused("   missing $k=", $BASE . $cut, $L, qr/needs/);
    }
    # Each numeric field given a bad number (the letter O for a zero).
    for my $i (@$nums) {
        my @b = @tk;
        $b[$i] = '1O0';
        refused("   field $i '1O0' is not a number", $BASE . join(' ', @b), $L, qr/not a number/);
    }
    # A bad number in an option.
    if ($line =~ /(\w+)=\d/ && $word ne 'Units') {
        my $k = $1;
        (my $b = $line) =~ s/$k=\S+/$k=1O0/;
        refused("   $k=1O0 is not a number", $BASE . $b, $L, qr/not a number/);
    }
    # An option the command does not take.
    refused("   XX=1 is not an option of $word", "$BASE$line XX=1", $L, qr/not an option/)
        unless $word =~ /^(Title|Project)$/;
}
refused('Option TRACE FULL: an unknown option is an error',
        $BASE . 'Option TRACE FULL', $L, qr/unknown option TRACE/);
refused('Option METHOD: points to the Method command',
        $BASE . 'Option METHOD HW', $L, qr/command of its own/);
refused('Option PROFILE FOO: only EPANET', $BASE . 'Option PROFILE FOO', $L, qr/EPANET/);
refused('Option TOL_FLOW with no value', $BASE . 'Option TOL_FLOW', $L, qr/needs value/);
refused('unknown command', $BASE . 'Sprinkler S9 B K=80 P=50', $L, qr/unknown command/);
refused('Units PRESSURE=XYZ: the parser refuses the unit, on this line',
        $BASE . 'Units PRESSURE=XYZ', $L, qr/unknown unit XYZ/);

print "   a setting given twice names both lines\n";
refused('Units FLOW= twice',    $BASE . 'Units FLOW=LPS',       $L, qr/FLOW= is already set on line 1/);
refused('Method twice',         "Method HW\n$BASE" . 'Method DW', $L + 1, qr/already set on line 1/);
refused('Option twice',         "Option MAXITER 10\n$BASE" . 'Option MAXITER 20',
        $L + 1, qr/Option MAXITER is already set on line 1/);
refused('Title twice',          "Title A\n$BASE" . 'Title B', $L + 1, qr/TITLE is already set/);
refused('Title and Project TITLE', "Title A\n$BASE" . 'Project TITLE B', $L + 1,
        qr/TITLE is already set/);
refused('Project field twice',  "Project JOB 1\n$BASE" . 'Project job 2', $L + 1,
        qr/JOB is already set/);
refused('Node twice',           $BASE . 'Node A 3', $L, qr/node A already has a Node line, on line 2/);
refused('an option twice on one line', $BASE . 'Head H3 C K=80 K=81 P=50', $L, qr/K= is given twice/);

#==============================================================================
print "3. ANY ORDER - shuffled lines solve to the same flows and pressures\n";
#==============================================================================
# The lines are shuffled as units: each setting, Node and element line alone,
# except that a Use line travels with the pipes after it (Use is positional by
# design).  Pipes are shuffled within their Use group.  Tolerances are made
# tight in both runs, so the comparison measures order, not convergence.
srand 20261028;
for my $phcpath (sort glob("$EX/*.phc")) {
    next if $phcpath =~ /grid1000/;
    (my $base = $phcpath) =~ s{.*/}{};
    my @lines = grep { /\S/ && !m{^\s*//} && !/^Option\s+(TOL_FLOW|TOL_LOOP|MAXITER)\b/ }
                split /\n/, slurp($phcpath);
    push @lines, 'Option TOL_FLOW 1E-7', 'Option TOL_LOOP 1E-8', 'Option MAXITER 200000';
    my (@units, $group);
    for (@lines) {
        if (/^Use\b/)       { $group = [$_]; push @units, $group }
        elsif (/^Pipe\b/)   { push @$group, $_ }
        else                { push @units, [$_] }
    }
    my $text = sub { join "\n", map { @$_ } @_ };
    my ($ref) = read_phc($text->(@units));
    HardyCross::solve_model($ref);
    my ($rq, $rp) = results($ref);
    for my $try (1 .. 3) {
        # Shuffle the units, and the pipes inside each Use group.
        my @u = map { $_->[0] =~ /^Use/ ? [ $_->[0], shuffle(@{$_}[1 .. $#$_]) ] : $_ }
                shuffle(@units);
        my ($net, $err) = read_phc($text->(@u));
        unless ($net) { is("$base shuffle $try reads", 0, $err); next }
        HardyCross::solve_model($net);
        my ($q, $p) = results($net);
        my ($wq, $wp) = (worst($rq, $q), worst($rp, $p));
        is(sprintf('%s shuffle %d: worst %.1e L/min, %.1e kPa (%d its against %d)',
                   $base, $try, $wq, $wp, $net->{iters}, $ref->{iters}),
           $wq < 1e-4 && $wp < 1e-4);
    }
}

#==============================================================================
print "4. USE SCOPING, FITTING FORMS, UNITS ANYWHERE\n";
#==============================================================================
{
    my $m = join "\n", 'Node A 0', 'Node B 0', 'Node C 0', 'Node D 0', 'Node E 0',
        'Supply S A STATIC 500', 'Head H E K=80 P=50',
        'Pipe P0 A B 5 100',                  # before any Use: bore, C 120
        'Use ASAM',
        'Pipe P1 B C 5 50',                   # ASAM, the type's own C
        'Pipe P2 C D 5 50 C=100',             # ASAM, C given on the pipe
        'Use S40 C=110',
        'Pipe P3 D E 5 50',                   # S40, the Use line's C
        'Use BORE C=90',
        'Pipe P4 A E 5 52.5',                 # a bore, the Use line's C
        '';
    my ($net, $err) = read_phc($m);
    is('Use model reads', $net, $err);
    my %e = map { $_->{id} => $_ } grep { $_->{id} } @{ $net->{elems} || [] };
    is('before any Use: a bore, C = 120', !$e{P0}{ptype} && $e{P0}{dia} == 100 && $e{P0}{c} == 120);
    is('Use ASAM: type ASAM, bore from the database, its own C',
       $e{P1}{ptype} eq 'ASAM' && $e{P1}{dia} == 53.0 && !$e{P1}{c_given});
    is('a pipe C= overrides', $e{P2}{c} == 100 && $e{P2}{c_given});
    is('Use S40 C=110 applies to the pipe after it', $e{P3}{ptype} eq 'S40' && $e{P3}{c} == 110);
    is('Use BORE C=90: a bore with C 90', !$e{P4}{ptype} && $e{P4}{dia} == 52.5 && $e{P4}{c} == 90);
}
{
    my $m = "Node A 0\nNode B 0\nSupply S A STATIC 500\nHead H B K=80 P=50\nUse ASAM\n";
    my %eqv;
    for my $form ('2E T GV', '2E,1T,1GV', '2E1T1GV', '2e t gv') {
        my ($net, $err) = read_phc($m . "Pipe P1 A B 10 50 $form\n");
        is("fittings '$form' read", $net, $err);
        $eqv{$form} = $net ? $net->{elems}[-1]{eqv} : -1;
    }
    is('all four forms give the same equivalent length (' . $eqv{'2E T GV'} . ' m)',
       1 == keys %{ { reverse %eqv } } && $eqv{'2E T GV'} > 0);
    refused('fittings on a Use BORE pipe', "Node A 0\nNode B 0\nPipe P1 A B 10 50 2E\n", 3,
            qr/fittings need a pipe type/);
    refused('a fitting the database lacks, on its line', $m . "Pipe P1 A B 10 50 2Q\n", 6,
            qr/cannot read fitting code/);
    refused('a DN the type does not make, on its line', $m . "Pipe P1 A B 10 47\n", 6,
            qr/DATA_REQUIRED - DN47/);
    refused('an unknown pipe type, on the Use line', "Use XYZ\nNode A 0\n", 1,
            qr/unknown pipe type XYZ/);
}
{
    my $body = "Node A 0\nNode B 0.5\nSupply S A STATIC 5\nPipe P1 A B 10 100\n"
             . "Head H B K=1.2 P=0.5\nOption TOL_FLOW 0.001\n";
    my ($top) = read_phc("Units FLOW=LPS PRESSURE=BAR\n$body");
    my ($end) = read_phc($body . "Units PRESSURE=BAR\nUnits FLOW=LPS\n");
    is('Units at the end, split and out of order: same network as at the top',
       $top && $end && canon($top) eq canon($end));
    is('   and the values really are in L/s and bar (static 5 bar = 500 kPa)',
       $top && $top->{elems}[1]{pstat} == 500);
}

#==============================================================================
print "5. THE LINE CHECKER - status, template, choices, proposal\n";
#==============================================================================
{
    my $ck = \&HardyCross::Phc::check_line;
    my $ctx = { use => 'ASAM', nodes => [qw(A B C)] };
    for my $case (@CASES) {
        my $line = $case->[0];
        my ($word) = $line =~ /^(\S+)/;
        my $r = $ck->($line, $ctx);
        is("$word: ok, template names the command",
           $r->{status} eq 'ok' && $r->{template}{command} eq $word,
           "$r->{status} $r->{message}");
    }
    my $r = $ck->('Pi', $ctx);
    is("'Pi' while typing: incomplete, not unknown", $r->{status} eq 'incomplete');
    $r = $ck->('Pix', $ctx);
    is("'Pix': error, unknown command", $r->{status} eq 'error' && $r->{message} =~ /unknown command/);
    $r = $ck->('Pipe P1 A', $ctx);
    is("'Pipe P1 A': incomplete, needs n2, cursor in field n1",
       $r->{status} eq 'incomplete' && $r->{message} =~ /needs n2/
       && $r->{template}{fields}[ $r->{template}{current} ] eq 'n1');
    $r = $ck->('Pipe P1 A ', $ctx);
    is("'Pipe P1 A ' (space typed): cursor moves to n2",
       $r->{template}{fields}[ $r->{template}{current} ] eq 'n2');
    $r = $ck->('Pipe P1 A B 3 50 C=1', { %$ctx, cursor => 19 });
    is('cursor in C=: the C= field is current',
       $r->{template}{fields}[ $r->{template}{current} ] eq 'C=');
    is('template text', HardyCross::Phc::template_text('PIPE')
       eq 'Pipe <id> <n1> <n2> <length> <size> <fittings ...> [C=] [EQV=] [EPS=] [K=]',
       HardyCross::Phc::template_text('PIPE'));

    $r = $ck->('Use ', $ctx);
    my %c = map { $_->[0] => $_->[1] } @{ $r->{choices} };
    is('Use type field: choices are the database pipe types and BORE',
       $c{ASAM} && $c{S40} && $c{CPVC} && $c{BORE});
    $r = $ck->('Pipe P1 A B 3 50 ', $ctx);
    %c = map { $_->[0] => $_->[1] } @{ $r->{choices} };
    is('fitting field, ASAM DN50: E T GV CV from AS 2118.1, described',
       $c{E} && $c{T} && $c{GV} && $c{CV} && !$c{EF} && $c{E} =~ /elbow/);
    $r = $ck->('Pipe P1 A B 3 250 ', { %$ctx, use => 'S20' });
    %c = map { $_->[0] => $_->[1] } @{ $r->{choices} };
    is('fitting field, S20 DN250: FM codes including EF', $c{EF} && $c{GV50});
    is('   descriptions are 7-bit ASCII', !grep { /[^\x20-\x7E]/ } values %c);
    $r = $ck->('Pipe P1 A B 3 50 ', { %$ctx, use => 'BORE' });
    is('fitting field under Use BORE: no choices', !@{ $r->{choices} });

    $r = $ck->('Pipe P1 A B 3 47', $ctx);
    is("ASAM DN47: the parser's DATA_REQUIRED, on the line",
       $r->{status} eq 'error' && $r->{message} =~ /DATA_REQUIRED/);
    $r = $ck->('Head H1 B K=80', $ctx);
    is('Head with only K=: incomplete, any two of K Q P',
       $r->{status} eq 'incomplete' && $r->{message} =~ /any two/);
    $r = $ck->('Head H1 B K=0 P=50', $ctx);
    is("Head K=0: the parser's unusable K-factor", $r->{status} eq 'error'
       && $r->{message} =~ /unusable K-factor/);
    $r = $ck->('Supply S1 A STATIC 5', { %$ctx, units => { PRESSURE => 'BAR' } });
    is('units from the context are applied', $r->{status} eq 'ok');
    $r = $ck->('Pipe P1 A Z9 3 50', $ctx);
    is('a node not yet defined is listed, not an error',
       $r->{status} eq 'ok' && "@{ $r->{undefined} }" eq 'Z9');

    is('proposal after a pipe: next id, starts where it ended, no fittings',
       ($ck->('Pipe P7 N3 N4 3.2 50 2E T C=110', $ctx)->{proposal} // '')
       eq 'Pipe P8 N4 N5 3.2 50 C=110');
    is('proposal after a head: id and node stepped, options kept',
       ($ck->('Head S09 N09 K=80 P=50', $ctx)->{proposal} // '') eq 'Head S10 N10 K=80 P=50');
    is('proposal after a node: id stepped, same elevation',
       ($ck->('Node N1 4.5', $ctx)->{proposal} // '') eq 'Node N2 4.5');
    is('no proposal after a setting', !defined $ck->('Method HW', $ctx)->{proposal});
    is('a blank line and a comment are ok',
       $ck->('', $ctx)->{status} eq 'ok' && $ck->('  // note', $ctx)->{status} eq 'ok');
}

#==============================================================================
print "6. TRAPS CLOSED\n";
#==============================================================================
refused('a node with no Node line: named, at the first line using it',
        "Node A 0\nSupply S A STATIC 500\nPipe P1 A B 10 100\nHead H B K=80 P=50\n", 3,
        qr/node B has no Node line/);
refused('several undefined nodes: all named',
        "Node A 0\nPipe P1 A B 10 100\nPipe P2 B C 10 100\n", 2,
        qr/node B has no Node line \(also C on line 3\)/);
refused("'#' in a line is refused, not taken as a comment", $BASE . 'Title JOB #12', $L,
        qr/'#' cannot be used/);
refused("'!' likewise", $BASE . 'Pipe P2 B C 5 ! 50', $L, qr/'!' cannot be used/);
refused('END as an id', $BASE . 'Node END 0', $L, qr/END cannot be used/);
refused('END as a Project field', $BASE . 'Project END x', $L, qr/END cannot be/);
refused('KEY= before the fixed fields', $BASE . 'Pipe P2 B C=100 C 5 50', $L,
        qr/come after the fixed fields/);
refused('Orifice with DP= and BORE=', $BASE . 'Orifice O1 A C DP=20 BORE=30 DN=50', $L,
        qr/not both/);
refused('a parser error comes back on the .phc line (PRV DP=0)', $BASE . 'PRV PR A C DP=0',
        $L, qr/PRV PR needs a positive DP=/);
refused('an unpaired curve value, on its own line after blank and comment lines',
        "Node A 0\n\n// c\nSupply S A CURVE 0 500 100 400\nPump PU A A 0 300 1 200 2\n", 5,
        qr/pressure to pair/);
{
    # The .hcx reader reads text where a number belongs as 0 -- a pipe 1OO m
    # long (letter O) solves as 0 m.  The converter must refuse it, not carry
    # the zero into .phc.
    (my $bad = slurp("$EX/01_single_branch.hcx")) =~ s/100\.0  100\.0  120/1OO  100.0  120/;
    my $phc = eval { HardyCross::Convert::hcx_to_phc($bad, 'bad.hcx') };
    my $err = $@ && (ref $@ ? $@->{msg} : $@);
    is("converter refuses a .hcx length of '1OO', quoting the line",
       !defined $phc && $err =~ /length '1OO' is not a number - in the line 'Pipe\s+P1/, $err);
    my $ex01 = HardyCross::Convert::hcx_to_phc(slurp("$EX/01_single_branch.hcx"), '01.hcx');
    is('converter lists what it drops (TRACE FULL in example 01)',
       $ex01 =~ m{^//\s+line 15: OPTIONS TRACE FULL - not an option}m);
    my $ex02 = HardyCross::Convert::hcx_to_phc(slurp("$EX/02_full_network.hcx"), '02.hcx');
    is('converter keeps MINP= on a fixed flow',
       $ex02 =~ m{^Flow\s+FF1 B Q=300 MINP=200$}m);
    (my $p = slurp("$EX/02_full_network.hcx")) =~ s/Q=300  MINP=200/Q=300 P=210 MINP=200 K=3/;
    my $c = HardyCross::Convert::hcx_to_phc($p, 'p.hcx');
    is('   P= on a fixed flow is its minimum (the parser reads P first); MINP=, K= dropped',
       $c =~ m{^Flow\s+FF1 B Q=300 MINP=210$}m && $c =~ m{not used for a fixed flow: MINP=200 K=3}m);
}
{
    my ($net) = read_phc("Node A 0 // the supply node\nNode B 0\nSupply S A STATIC 500 // tank\n"
                       . "Pipe P1 A B 10 100\nHead H B K=80 P=50\n");
    is('// comments anywhere on a line', $net);
    my $p = "$FindBin::Bin/../examples/01_single_branch.phc";
    my $m = eval { HardyCross::Parse::read_model($p) };
    is('read_model dispatches .phc to the .phc reader', $m && $m->{phc_text});
}

#==============================================================================
print "7. FIXED-FLOW MINIMUM PRESSURE - read, checked, and able to govern\n";
#==============================================================================
{
    # C is 20 m above the supply, so the fixed flow there has far less
    # pressure to spare than the head at B, and governs.
    my $m = join "\n", 'Node A 0', 'Node B 0', 'Node C 20', 'Supply S A STATIC 600',
        'Pipe P1 A B 50 100', 'Pipe P2 B C 30 50', 'Head H B K=80 P=50', '';
    my ($net, $err) = read_phc($m . "Flow F C Q=100 MINP=250\n");
    is('Flow MINP= reads', $net, $err);
    my $ok = HardyCross::solve_model($net);
    my $f = $net->{fixed}[0];
    is('   the fixed flow is kept by id with its minimum (250 kPa)',
       $f && $f->{id} eq 'F' && $f->{preq} == 250 && $f->{qreq} == 100);
    is('   the flow is still exactly the fixed 100 L/min (the solve is unchanged)',
       abs(HardyCross::continuity_error($net)) < 1e-6 && $net->{nodes}[ $f->{n1} ]{demand} == 100);
    my ($gov, $gm) = HardyCross::Demand::governing_outlet($net);
    is('   the fixed flow governs (least margin)', $gov && $gov->{id} eq 'F', $gov && $gov->{id});
    my $dm = HardyCross::Demand::demand_point($net);
    my ($df) = @{ $dm->{net}{fixed} || [] };
    my $pf = $df ? HardyCross::Demand::gauge($dm->{net}, $df->{n1}) : -1;
    is(sprintf('   at the demand point it has exactly its minimum (%.2f kPa)', $pf),
       abs($pf - 250) < 0.05);
    my $rep = HardyCross::Report::write_report($net, $ok, 'm.phc');
    is('   report section 7 lists it, K fixed, PASS',
       $rep =~ /^ F\s+C\s+fixed\s+100\.0\s+100\.0\s+250\.0\s+[\d.]+\s+PASS$/m);
    is('   report section 8 names it as the governing fixed flow',
       $rep =~ /^ Fixed flow F: pressure [\d.]+ kPa, required 250\.0/m);

    my ($bad) = read_phc($m . "Flow F C Q=100 MINP=900\n");
    my $okb = HardyCross::solve_model($bad);
    my $rb = HardyCross::Report::write_report($bad, $okb, 'm.phc');
    is('a minimum above the pressure available FAILS in the report',
       $rb =~ /^ F\s+C\s+fixed.*\*\*\* FAIL$/m && $rb =~ /1 OUTLET\(S\) BELOW REQUIREMENT/);
    my ($none) = read_phc($m . "Flow F C Q=100\n");
    HardyCross::solve_model($none);
    my ($g2) = HardyCross::Demand::governing_outlet($none);
    is('a fixed flow with no minimum cannot govern', $g2 && $g2->{id} eq 'H');
    refused('a negative minimum is refused', $BASE . 'Flow F1 C Q=100 MINP=-5', $L,
            qr/negative minimum pressure/);
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
