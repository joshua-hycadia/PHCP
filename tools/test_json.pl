#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_json.pl -- phcp.pl --json, the interface other programs call.
#
#   perl tools/test_json.pl
#
# Runs phcp.pl as a caller would -- a separate process, reading what it
# prints and its exit status -- and checks the JSON against the plain-text
# output of the same solve (the Q and P lines the validation harnesses use),
# so the two outputs of one program cannot disagree.  Then the failures: an
# input error, a .hcx file, a solve that does not converge; and standard
# input, and --report.  (Example 04, the 1000-pipe grid, is left out: its
# demand point re-solves it many times and takes minutes.)
#==============================================================================
use strict;
use warnings;
use FindBin;
use JSON::PP;
use File::Temp qw(tempdir);

my $PHCP = "$FindBin::Bin/../phcp.pl";
my $EX   = "$FindBin::Bin/../examples";
my $TMP  = tempdir(CLEANUP => 1);
my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-66s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
# run -- phcp.pl with arguments (and optional standard input): (exit, stdout).
sub run {
    my ($stdin, @args) = @_;
    my $cmd = join ' ', map { "'$_'" } $^X, $PHCP, @args;
    if (defined $stdin) {
        open my $in, '>', "$TMP/in.phc" or die; print $in $stdin; close $in;
        $cmd .= " < '$TMP/in.phc'";
    }
    my $out = `$cmd 2>/dev/null`;
    return ($? >> 8, $out);
}
sub slurp { my $p = shift; open my $f, '<', $p or die "$p: $!\n"; local $/; <$f> }

#==============================================================================
print "1. EVERY EXAMPLE - the JSON agrees with the plain output of the same solve\n";
#==============================================================================
for my $m (grep { !/grid1000/ } sort glob("$EX/*.phc")) {
    (my $name = $m) =~ s{.*/}{};
    my ($code, $out) = run(undef, '--json', $m);
    my $j = eval { decode_json($out) };
    is("$name: valid JSON, interface 1, converged, exit 0",
       $j && $j->{interface} == 1 && $j->{status} eq 'converged' && $j->{converged} && $code == 0, $@ || "exit $code");
    next unless $j;
    my ($c2, $plain) = run(undef, $m);
    my %q = $plain =~ /^Q (\S+) (\S+)$/mg;
    my %p = $plain =~ /^P (\S+) (\S+)$/mg;
    my $bad = 0;
    for (@{ $j->{pipes} }, @{ $j->{elements} }) { $bad++ unless abs($_->{flow} - $q{ $_->{id} }) < 1e-3 }
    for (@{ $j->{nodes} }) { $bad++ unless abs($_->{pressure} - $p{ $_->{id} }) < 1e-3 }
    is("   every flow and pressure as the plain output (" . (@{ $j->{pipes} } + @{ $j->{nodes} }) . ' values)', !$bad);
    is('   units named, as the model declared', $j->{units}{flow} && $j->{units}{pressure}
       && $plain =~ /^# units flow (\S+) pressure (\S+)$/m);
    my %pipe = map { $_->{id} => $_ } @{ $j->{pipes} };
    my ($v) = grep { $_->{flow} != 0 && $_->{bore} > 0 } @{ $j->{pipes} };
    # Velocity by hand: Q / A, Q in m3/s.  The flow unit factor is the
    # ratio of the plain output's flow to... the JSON's own: both in model
    # units, so it is recomputed from L/min when the model is in L/min only.
    if ($v && $j->{units}{flow} eq 'L/min') {
        my $vh = abs($v->{flow}) / 60000 / (3.14159265358979 * ($v->{bore} / 1000) ** 2 / 4);
        is(sprintf('   velocity of %s by hand: %.3f m/s', $v->{id}, $vh), abs($vh - abs $v->{velocity}) < 0.002);
    }
    my $nfix = () = slurp($m) =~ /^FIXEDFLOW\s+\S+\s+\S+\s+\S+\s+\S+/mg;
    my $nout = () = slurp($m) =~ /^(SPRINKLER|HYDRANT|HREEL)\b/mg;
    is("   every outlet listed ($nout outlets, $nfix fixed flows with a minimum)",
       @{ $j->{outlets} } == $nout + $nfix);
    if (@{ $j->{outlets} }) {
        my ($low) = sort { $a->{margin} <=> $b->{margin} } @{ $j->{outlets} };
        is('   the governing outlet is the one with least margin', $j->{governing}{id} eq $low->{id});
        is('   the summary names it', grep { /^GOVERNING OUTLET \Q$low->{id}\E:/ } @{ $j->{summary} });
    }
    my $uses_db = slurp($m) =~ /^USE\s+(?!BORE\b)\S+/m;
    is('   ' . ($uses_db ? 'the database used, with its fingerprint' : 'no pipe type used: no database'),
       $uses_db ? ($j->{database} && $j->{database}{sha256} =~ /^[0-9a-f]{64}\z/) : !$j->{database});
    is('   a demand point, or the reason there is none', $j->{demand} || $j->{demand_reason});
}

#==============================================================================
print "2. FAILURES - the JSON is written whatever happens\n";
#==============================================================================
{
    my $bad = "WATER S 0 500\nNODE A 0\nPIPE P1 S A 10 100\nPIPX P2\nSPRINKLER H 0 -50 80\nPIPE P3 A H 3 50\n";
    my ($code, $out) = run($bad, '--json', '-');
    my $j = eval { decode_json($out) };
    is('an input error: exit 2, status error', $j && $code == 2 && $j->{status} eq 'error', "exit $code");
    is('   the error has its .phc line (4) and message', $j && $j->{errors}[0]{line} == 4
       && $j->{errors}[0]{message} =~ /UNKNOWN COMMAND PIPX/, $out);
    is('   and a summary line saying so', $j && $j->{summary}[0] =~ /^NOT SOLVED: .*\(LINE 4\)$/);
    open my $old, '>', "$TMP/old.hcx" or die "$TMP/old.hcx: $!\n";
    print $old "NODES\n  N1 0\nEND\n";
    close $old;
    ($code, $out) = run(undef, '--json', "$TMP/old.hcx");
    $j = eval { decode_json($out) };
    is('a .hcx file: exit 2, the reason in the JSON', $j && $code == 2
       && $j->{errors}[0]{message} =~ /IS NOT A \.PHC MODEL/);
    (my $slow = slurp("$EX/02_full_network.phc")) =~ s/^OPTION\s+MAXITER.*$//mg;
    $slow .= "OPTION MAXITER 1\n";
    ($code, $out) = run($slow, '--json', '-');
    $j = eval { decode_json($out) };
    is('a solve that does not converge: exit 1, status not_converged',
       $j && $code == 1 && $j->{status} eq 'not_converged' && !$j->{converged}, "exit $code");
    is('   and the summary says not to use the results', $j && $j->{summary}[0] =~ /MUST NOT BE USED/);
}

#==============================================================================
print "3. STANDARD INPUT AND --report\n";
#==============================================================================
{
    my $m = "$EX/07_pipe_database_demo.phc";
    my ($c1, $a) = run(undef, '--json', $m);
    my ($c2, $b) = run(slurp($m), '--json', '-');
    my ($ja, $jb) = map { decode_json($_) } $a, $b;
    $_->{model} = '' for $ja, $jb;
    is('the model from standard input gives the same results', $c2 == 0
       && JSON::PP->new->canonical->encode($ja) eq JSON::PP->new->canonical->encode($jb));
    my ($c3, $c) = run(undef, '--json', $m, '--report', "$TMP/r.pdf");
    is('--report writes the PDF as well as the JSON', $c3 == 0 && -s "$TMP/r.pdf"
       && slurp("$TMP/r.pdf") =~ /^%PDF-/ && decode_json($c)->{status} eq 'converged');
    # PHCPSOLVE in AutoCAD has no JSON reader: it finds the summary by
    # reading the output line by line (phcp:summary in phcp_export.lsp).
    # The same reading, here, must give exactly the summary.
    my ($in, @lines);
    for my $l (split /\n/, $a) {
        $l =~ s/^[ \t]+|[ \t]+$//g;
        if ($l =~ /^"summary".*\[$/)              { $in = 1 }
        elsif ($in && substr($l, 0, 1) eq ']')    { $in = 0 }
        elsif ($in) { $l =~ s/,+$//; $l =~ s/^"+|"+$//g; push @lines, $l }
    }
    is('the summary can be read line by line, as AutoCAD reads it',
       @lines && join("\n", @lines) eq join("\n", @{ $ja->{summary} }), join(' | ', @lines));
    my ($c4, $plain) = run(undef, $m, "$TMP/r.txt");
    is('without --json, the plain output and report as before', $c4 == 0 && $plain =~ /^# converged yes/m
       && -s "$TMP/r.txt");
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
