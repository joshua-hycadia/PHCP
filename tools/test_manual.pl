#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_manual.pl -- docs/PHC_REFERENCE.md checked against the program.
#
#   perl tools/test_manual.pl
#
# The manual is written by hand; this keeps it from falling behind the reader.
#
#   1. EVERYTHING DESCRIBED.  Every command and short form, option, unit and
#      unit spelling, cover-sheet field, pipe type and fitting code the program
#      knows appears in the manual.
#   2. THE EXAMPLES.  Every example line in the manual is a line the reader
#      accepts, and every complete model (a ```phc block) reads, solves and
#      converges.
#   3. PLAIN TEXT.  The manual is 7-bit ASCII.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use HardyCross;
use HardyCross::Phc;
use HardyCross::Editor;
use HardyCross::PipeData;

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-68s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}

my $path = "$FindBin::Bin/../docs/PHC_REFERENCE.md";
my $doc = do { open my $f, '<', $path or die "$path: $!\n"; local $/; <$f> };
# Words the manual marks as code: `WORD`.
my %code = map { $_ => 1 } $doc =~ /`([^`\s]+)`/g;
my $missing = sub { my @m = grep { !$code{$_} } @_; (!@m, @m ? "not in the manual: @m" : undef) };

print "1. EVERYTHING DESCRIBED\n";
is("every command (@{[ scalar @HardyCross::Phc::COMMANDS ]}) has its own section",
   !grep({ $doc !~ /^### \d+\.\d+ (?:\S+, )*\Q$_\E\b/m } @HardyCross::Phc::COMMANDS),
   join ' ', grep { $doc !~ /^### \d+\.\d+ (?:\S+, )*\Q$_\E\b/m } @HardyCross::Phc::COMMANDS);
is('   and a row in the summary', $missing->(@HardyCross::Phc::COMMANDS));
my @alias = grep { my $c = HardyCross::Phc::command_spec($_); $c && $c->{name} ne $_ } qw(P U N W CHP);
is("every short form (@alias)", $missing->(@alias));
is("every option (@{[ scalar @HardyCross::Phc::OPTIONS ]})", $missing->(@HardyCross::Phc::OPTIONS));
is('every units quantity', $missing->(@HardyCross::Phc::UNIT_QUANTITIES));
is('every unit of every quantity', $missing->(map { @$_ } values %HardyCross::Phc::UNIT_CHOICES));
my %spell = map { $_ => HardyCross::Phc::unit_code($_) } qw(L/MIN L/S M3/H USGPM L/MIN/KPA L/MIN/BAR);
is('every other spelling of a unit, and what it is read as',
   ($missing->(keys %spell))[0] && !grep { $doc !~ /`\Q$_\E` \| `\Q$spell{$_}\E`/ } keys %spell);
is('every cover-sheet field', $missing->(@HardyCross::Editor::PROJECT_FIELDS));
HardyCross::PipeData::load();
is('every pipe type in the database', $missing->(HardyCross::PipeData::pipe_types()));
my @fits = do {
    open my $f, '<', HardyCross::PipeData::path() or die;
    my %c;
    while (<$f>) { $c{$1} = 1 if /^(?:FIT\|[^|]*|KPRIME)\|([^|]+)\|/ }
    sort keys %c;
};
is(sprintf('every fitting code in the database (%d)', scalar @fits), $missing->(@fits));
is('every fitting short form', $missing->(keys %HardyCross::Phc::FIT_SHORT, values %HardyCross::Phc::FIT_SHORT));

print "2. THE EXAMPLES\n";
my (@lines, @models);
while ($doc =~ /^```(\w*)\n(.*?)^```/msg) {
    my ($lang, $body) = ($1, $2);
    if ($lang eq 'phc') { push @models, $body; next }
    # A syntax line (<FIELD>) shows the form, not an example.
    push @lines, grep { /\S/ && !/</ } split /\n/, $body;
}
my @bad = grep { HardyCross::Phc::analyse($_)->{status} ne 'ok' && HardyCross::Phc::analyse($_)->{status} ne 'blank' } @lines;
is(sprintf('every example line (%d) is one the reader accepts', scalar @lines), !@bad,
   join ' | ', map { "$_ -> " . HardyCross::Phc::analyse($_)->{msg} } @bad);
is('there is a complete model', scalar @models);
for my $i (0 .. $#models) {
    my $net = eval { HardyCross::Phc::read_string($models[$i]) };
    my $ok = $net && eval { HardyCross::solve_model($net) };
    is("   complete model " . ($i + 1) . ': reads, solves and converges', $ok,
       $net ? 'did not converge' : HardyCross::is_model_error($@) ? $@->{msg} : $@);
}

print "3. PLAIN TEXT\n";
is('the manual is 7-bit ASCII', $doc !~ /[^\x0A\x20-\x7E]/,
   join ' ', map { "line $_" } grep { (split /\n/, $doc)[ $_ - 1 ] =~ /[^\x20-\x7E]/ } 1 .. scalar(split /\n/, $doc));

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
