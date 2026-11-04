#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_sheet.pl -- the spreadsheet model, HardyCross::Sheet, without Tk.
#
#   perl tools/test_sheet.pl
#
# The sheet is the other window's network: pipes, the nodes taken from them,
# supplies, and a table for each pressure device.  It has no Tk.  What is
# checked here is that the grids follow the rules, and that a .phc file read
# into the grids and written out again solves to the same pipe flows and node
# pressures.  The text editor is not loaded.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use HardyCross;
use HardyCross::Phc;
use HardyCross::Sheet;

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-66s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub slurp { my $p = shift; open my $f, '<', $p or die "$p: $!\n"; local $/; <$f> }
my $EX = "$FindBin::Bin/../examples";

# Solved pipe flows by id, and gauge pressures by node id.  The same
# comparison the .phc tests use.
sub results {
    my $net = shift;
    my (%q, %p);
    $q{ $_->{id} } = $_->{q} for grep { $_->{kind} eq 'PIPE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    $p{ $_->{id} } = $_->{h} - $HardyCross::GAMMA_W * $_->{z}
        for grep { $_->{id} ne 'REF' } @{ $net->{nodes} }[1 .. $#{ $net->{nodes} }];
    return (\%q, \%p);
}
sub worst {
    my ($a, $b) = @_;
    my $w = 0;
    for (keys %$a) {
        return 1e30 unless exists $b->{$_};
        my $d = abs($a->{$_} - $b->{$_});
        $w = $d if $d > $w;
    }
    return $w;
}
sub read_net {
    my $text = shift;
    my $net = eval { HardyCross::Phc::read_string($text) };
    return ($net, $@);
}
sub ids {
    my $net = shift;
    my @p = map { $_->{id} } grep { $_->{kind} eq 'PIPE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    my @n = map { $_->{id} } grep { $_->{id} ne 'REF' } @{ $net->{nodes} }[1 .. $#{ $net->{nodes} }];
    return (join(' ', sort @p), join(' ', sort @n));
}

#==============================================================================
print "1. NODES COME FROM THE PIPES, AND A BLANK TYPE IS A NODE\n";
#==============================================================================
{
    my $s = HardyCross::Sheet::new_sheet();
    push @{ $s->{pipes} }, { %{ HardyCross::Sheet::empty_pipe() },
        pipe => 'P1', from => 'A', to => 'B', length => '10', type => 'BORE', diam => '100' };
    push @{ $s->{pipes} }, { %{ HardyCross::Sheet::empty_pipe() },
        pipe => 'P2', from => 'B', to => 'C', length => '4', type => 'BORE', diam => '50' };
    my @n = HardyCross::Sheet::node_rows($s);
    is('nodes in the order the pipes introduce them', join(' ', @n) eq 'A B C', "@n");
    is('a new node\'s type is blank: a node, not the word',
       !grep { length HardyCross::Sheet::normal_type($s->{nodes}{$_}{type}) } @n);
    is('NODE, A NODE and ANODE are that same blank',
       HardyCross::Sheet::normal_type('anode') eq '' && HardyCross::Sheet::normal_type('A NODE') eq ''
       && HardyCross::Sheet::normal_type('NODE') eq '');

    $s->{nodes}{C}{elev} = '4.5';
    $s->{nodes}{C}{type} = 'SPRINKLER';
    $s->{nodes}{C}{min_p} = '50';
    $s->{nodes}{C}{k} = '80';
    # C drops out of the system.  Its values stay, and come back with it.
    @{ $s->{pipes} } = ($s->{pipes}[0]);
    @n = HardyCross::Sheet::node_rows($s);
    is('a node no pipe names leaves the grid', !grep { $_ eq 'C' } @n, "@n");
    push @{ $s->{pipes} }, { %{ HardyCross::Sheet::empty_pipe() },
        pipe => 'P2', from => 'B', to => 'C', length => '4', type => 'BORE', diam => '50' };
    @n = HardyCross::Sheet::node_rows($s);
    is('typing the node again brings its elevation and type back',
       (grep { $_ eq 'C' } @n) && $s->{nodes}{C}{elev} eq '4.5' && $s->{nodes}{C}{type} eq 'SPRINKLER');

    my $text = HardyCross::Sheet::to_text($s);
    is('a blank type is written as NODE, a sprinkler as SPRINKLER',
       $text =~ /^NODE\s+A\s/m && $text =~ /^NODE\s+B\s/m && $text =~ /^SPRINKLER\s+C\s+\S+\s+-50\s+80/m,
       $text);
    is('the negative minimum is the MIN P column, not a negative flow stored as such',
       $s->{nodes}{C}{min_flow} eq '' && $s->{nodes}{C}{min_p} eq '50');
}

#==============================================================================
print "2. A DEVICE TYPE ADDS THAT DEVICE'S ROW, AND ONLY THAT TABLE\n";
#==============================================================================
{
    my $s = HardyCross::Sheet::new_sheet();
    push @{ $s->{pipes} }, { %{ HardyCross::Sheet::empty_pipe() },
        pipe => '1', from => '2', to => '101', length => '20', type => 'S20', c => '120', diam => '100', fittings => '2E T GV' };
    HardyCross::Sheet::node_rows($s);
    $s->{nodes}{'101'}{type} = 'PRV';
    $s->{nodes}{'101'}{elev} = '3';
    HardyCross::Sheet::reconcile($s);
    my @prv = HardyCross::Sheet::device_rows($s, 'PRV');
    my @bfp = HardyCross::Sheet::device_rows($s, 'BFP');
    is('choosing PRV adds one PRV row and no other device', @prv == 1 && !@bfp);
    is('the row is tied to that node, on the pipe that arrives there',
       $prv[0]{node} eq '101' && $prv[0]{tied} && $prv[0]{pipe} eq '1');
    my @heads = map { $_->{head} } HardyCross::Sheet::device_columns($s, 'PRV');
    is('a PRV table has the columns a PRV needs',
       join(' ', @heads) =~ /NODE/ && join(' ', @heads) =~ /PIPE/ && join(' ', @heads) =~ /FLOW 1/ && join(' ', @heads) =~ /LOSS 1/);
    my @opp = map { $_->{key} } HardyCross::Sheet::device_columns($s, 'OPP');
    is('an orifice plate sized for a drop has DROP and CD, not a loss curve',
       (grep { $_ eq 'drop' } @opp) && (grep { $_ eq 'cd' } @opp) && !(grep { $_ eq 'q1' } @opp));

    $prv[0]{pairs} = [ '0', '35' ];
    my $text = HardyCross::Sheet::to_text($s);
    is('the PRV is written on its pipe, and the node stays a node',
       $text =~ /^NODE\s+101\s+3/m && $text =~ /^PRV\s+1\s+0\s+35/m, $text);

    $s->{nodes}{'101'}{type} = '';
    HardyCross::Sheet::reconcile($s);
    is('clearing the type takes the PRV off its table', !HardyCross::Sheet::device_rows($s, 'PRV'));
    $s->{nodes}{'101'}{type} = 'PRV';
    HardyCross::Sheet::reconcile($s);
    my ($back) = HardyCross::Sheet::device_rows($s, 'PRV');
    is('choosing it again brings the loss back', $back && join(' ', @{ $back->{pairs} }) eq '0 35');

    $s->{nodes}{'2'}{type} = 'SUPPLY';
    $s->{nodes}{'2'}{elev} = '0';
    $s->{nodes}{'2'}{static} = '900';
    my @sup = HardyCross::Sheet::supply_rows($s);
    is('SUPPLY puts the node on the supplies grid', @sup == 1 && $sup[0] eq '2');
    $text = HardyCross::Sheet::to_text($s);
    is('and writes it as WATER, with the elevation from the nodes grid',
       $text =~ /^WATER\s+2\s+0\s+900/m, $text);
}

#==============================================================================
print "3. A FITTING STRING, A FIXED FLOW, AND BOTH MINIMUMS\n";
#==============================================================================
{
    my $s = HardyCross::Sheet::new_sheet();
    push @{ $s->{pipes} }, { %{ HardyCross::Sheet::empty_pipe() },
        pipe => 'P1', from => 'S', to => 'H', length => '12', type => 'ASAM', diam => '100',
        fittings => '1T 2E 1GV', eqv => '2.5' };
    HardyCross::Sheet::node_rows($s);
    $s->{nodes}{S}{type} = 'SUPPLY';
    $s->{nodes}{S}{elev} = '0';
    $s->{nodes}{S}{static} = '700';
    $s->{nodes}{H}{type} = 'HYDRANT';
    $s->{nodes}{H}{elev} = '1';
    $s->{nodes}{H}{min_flow} = '600';
    $s->{nodes}{H}{min_p} = '200';
    $s->{nodes}{H}{k} = '80';
    $s->{nodes}{H}{fixed_flow} = '100';
    my @bad = HardyCross::Sheet::problems($s);
    # problems() looks at the line map to_text builds.
    HardyCross::Sheet::to_text($s);
    @bad = HardyCross::Sheet::problems($s);
    is('an outlet with MIN FLOW and MIN P both filled is refused',
       @bad == 1 && $bad[0]{what} =~ /NOT BOTH/ && $bad[0]{loc}{col} eq 'min_p');
    $s->{nodes}{H}{min_p} = '';
    my $text = HardyCross::Sheet::to_text($s);
    is('fittings and the equivalent length are written on the pipe',
       $text =~ /^PIPE\s+P1\s+S\s+H\s+12\s+100\s+1T\s+2E\s+1GV/m && $text =~ /^EQV\s+P1\s+2\.5/m, $text);
    is('the fixed flow is written, and the hydrant keeps its minimum flow',
       $text =~ /^HYDRANT\s+H\s+1\s+600\s+80/m && $text =~ /^FIXEDFLOW\s+\S+\s+H\s+100/m);
    is('with the pressure cleared, that outlet has no sheet problem', !HardyCross::Sheet::problems($s));
}

#==============================================================================
print "4. EVERY EXAMPLE SURVIVES THE GRIDS\n";
#==============================================================================
# Example 04 is a thousand nodes: it is read and written, not solved.
# The others are solved both ways and compared.
my %SOLVE = map { $_ => 1 } qw(01_single_branch 02_full_network 03_dw_altunits 05_crosscheck
    06_orifice 07_pipe_database_demo 08_autocad_export_format 09_parallel_pumps
    11_design_areas 12_auto_sizing);
for my $path (sort glob("$EX/*.phc")) {
    my ($base) = $path =~ m{([^/]+)\.phc\z};
    my $text = slurp($path);
    my $sheet = eval { HardyCross::Sheet::read_text($text) };
    is("$base reads into the grids", $sheet, $@);
    next unless $sheet;
    my $out = eval { HardyCross::Sheet::to_text($sheet) };
    is("   writes .phc", $out, $@);
    next unless $out;
    my ($a, $ea) = read_net($text);
    my ($b, $eb) = read_net($out);
    is('   the written file reads', $b, $eb || $ea);
    next unless $a && $b;
    my ($ap, $an) = ids($a);
    my ($bp, $bn) = ids($b);
    is('   the same pipes and nodes', $ap eq $bp && $an eq $bn,
       $ap eq $bp ? "nodes differ" : "pipes differ");
    my @sys = HardyCross::Sheet::system_columns($sheet);
    is('   the system columns are the pipe, its ends, length, type, diameter and fittings',
       (grep { $_->{key} eq 'pipe' } @sys) && (grep { $_->{key} eq 'from' } @sys)
       && (grep { $_->{key} eq 'fittings' } @sys) && (grep { $_->{key} eq 'diam' } @sys));
    next unless $SOLVE{$base};
    my $oka = HardyCross::solve_model($a);
    my $okb = HardyCross::solve_model($b);
    my ($qa, $pa) = results($a);
    my ($qb, $pb) = results($b);
    my ($wq, $wp) = (worst($qa, $qb), worst($pa, $pb));
    is(sprintf('   same result (%.2g L/min, %.2g kPa), both %s', $wq, $wp, ($oka && $okb) ? 'solved' : 'unsolved'),
       $oka && $okb && $wq < 0.2 && $wp < 0.2);
}

#==============================================================================
print "5. WHAT EXAMPLE 02 PUTS ON EACH GRID\n";
#==============================================================================
{
    my $s = HardyCross::Sheet::read_text(slurp("$EX/02_full_network.phc"));
    my @n = HardyCross::Sheet::node_rows($s);
    is('every pipe end is a node, and the tank the pump draws from is kept',
       (grep { $_ eq 'T1' } @n) && (grep { $_ eq 'J2' } @n) && (grep { $_ eq 'A' } @n));
    is('the tank is a supply, and its type is not the word NODE', $s->{nodes}{T1}{type} eq 'SUPPLY');
    is('the hose reel keeps a minimum pressure in MIN P',
       $s->{nodes}{A}{type} eq 'HREEL' && $s->{nodes}{A}{min_p} eq '220' && $s->{nodes}{A}{min_flow} eq '');
    is('the fixed flow is on its node', $s->{nodes}{B}{fixed_flow} eq '300' && $s->{nodes}{B}{min_p} eq '200');
    my ($pmp) = HardyCross::Sheet::device_rows($s, 'PUMP');
    my ($bfp) = HardyCross::Sheet::device_rows($s, 'BFP');
    my ($prv) = HardyCross::Sheet::device_rows($s, 'PRV');
    my ($opp) = HardyCross::Sheet::device_rows($s, 'OPP');
    my ($ofd) = HardyCross::Sheet::device_rows($s, 'OFD');
    is('the pump, the backflow preventer, the reducing valve and both plates are listed',
       $pmp && $bfp && $prv && $opp && $ofd);
    is('the pump is the delivery node\'s type', $pmp->{tied} && $s->{nodes}{ $pmp->{node} }{type} eq 'PUMP');
    is('a plate upstream of a sprinkler stays a plate, and the sprinkler stays a sprinkler',
       !$opp->{tied} && $s->{nodes}{X2}{type} eq 'SPRINKLER');
    my ($m1) = grep { $_->{pipe} eq 'M1' } @{ $s->{pipes} };
    is('the fitting string is empty there and the equivalent length is kept',
       $m1 && $m1->{fittings} eq '' && $m1->{eqv} eq '8.0');
    my @areas = grep { /^AREA\b/ } @{ $s->{extras} };
    is('example 02 has no design areas to keep', !@areas);
}
{
    my $s = HardyCross::Sheet::read_text(slurp("$EX/11_design_areas.phc"));
    my @areas = grep { /^AREA\b/ } @{ $s->{extras} };
    is('design areas are kept and written back', @areas == 4);
    my $out = HardyCross::Sheet::to_text($s);
    is('all four AREA lines are in the file', scalar(() = $out =~ /^AREA\s/mg) == 4);
}
{
    my $s = HardyCross::Sheet::read_text(slurp("$EX/12_auto_sizing.phc"));
    is('a copied sprinkler is a sprinkler of its own, with the source\'s K',
       $s->{nodes}{A4}{type} eq 'SPRINKLER' && $s->{nodes}{A4}{k} eq '80' && $s->{nodes}{B1}{min_p} eq '100');
    my ($sized) = grep { $_->{pipe} eq 'H2' } @{ $s->{pipes} };
    is('a size of 0 stays 0, so the pipe is still one to be sized', $sized && $sized->{diam} eq '0');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
