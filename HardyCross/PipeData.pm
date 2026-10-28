#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# HardyCross/PipeData.pm -- pipe dimensions and fitting allowances.
#
# The DATA comes from data/pipes.dat, the office's pipe and fitting database.
# It is a plain text file the office may edit; the report prints its name and
# SHA-256 so every calculation is tied to the exact data it used.  The RULES --
# which source governs a size, which basis bore it was built on, which
# corrections apply, what counts -- are encoded once here.
#
# THE ONE RULE THAT MATTERS MOST
#   A dash, a blank, an unsupported DN or a missing product size is never
#   converted to zero, never interpolated and never replaced by a neighbouring
#   value.  It comes back as DATA_REQUIRED, naming the component.
#   A resolver that quietly returned 0.0 for a fitting it could not find would
#   under-count friction in exactly the case nobody is looking at.

package HardyCross::PipeData;

use strict;
use warnings;
use utf8;
use FindBin;
use HardyCross::Settings;
use Cwd ();
use File::Spec;
use Digest::SHA ();

my (%PIPETYPE, %PIPE, %FIT, %KPRIME, $DATASET, $ISSUED, $PATH, $SHA256);

# Status codes carried by every fitting record.
use constant {
    APPROVED            => 'APPROVED',
    ASSUMPTION_REQUIRED => 'ASSUMPTION_REQUIRED',
    DATA_REQUIRED       => 'DATA_REQUIRED',
    PROJECT_SPECIFIC    => 'PROJECT_SPECIFIC',
    PROHIBITED          => 'PROHIBITED',
};

# Fittings that are published but not counted: a coupling does
# not turn the flow, and neither does the straight-through run of a tee.
my %NOT_COUNTED = (CPL => 1, TR => 1);

# The data file sits beside this module, in ../data.  It is located from the
# module's OWN path rather than from $FindBin::Bin: FindBin is the directory of
# whatever script happened to start Perl, which is a different place for the
# command line, the GUI and the test harness.
sub default_path {
    # A folder chosen for the database (HardyCross::Settings: a team's shared
    # folder on a network drive) is used whenever one is set, and nothing
    # else is: if it cannot be read, loading fails and says where, rather
    # than quietly calculating with different data.
    if (defined(my $dir = HardyCross::Settings::database_dir())) {
        return File::Spec->catfile($dir, 'pipes.dat');
    }
    # Otherwise, in order:
    #   1. beside the program itself, in ./data -- the office's own copy.  The
    #      editor's DATABASE tab saves here, and a copy here wins over the one
    #      built into a packaged .exe, so the office can correct or add data
    #      without a rebuild (decided 28 October 2026).  Running from the
    #      source folder this is the same file as 2.
    #   2. beside this module, in ../data  -- running from the source folder
    #   3. inside a packaged .exe, which unpacks to PAR_TEMP/inc/lib/data
    # The first that exists wins.  If none does, the source copy is returned
    # so the error message names a real, expected location.  The report
    # prints the path and the SHA-256 of whichever was read.
    my ($vol, $dir) = File::Spec->splitpath(File::Spec->rel2abs(__FILE__));
    my $name = 'pipes.dat';
    my @try = (user_path());
    push @try, File::Spec->catfile($vol . $dir, File::Spec->updir, 'data', $name);
    push @try, File::Spec->catfile($ENV{PAR_TEMP}, 'inc', 'lib', 'data', $name) if $ENV{PAR_TEMP};
    # A found file is named plainly (no "HardyCross/../"), as the report
    # prints it.
    for (@try) { return Cwd::abs_path($_) // $_ if -r $_ }
    return $try[1];
}

# origin -- where the database in use comes from, in words for the window:
# TEAM FOLDER (the folder set in the settings), BUILT-IN (the program's own:
# the source folder's, or the copy packed into an .exe), or BESIDE THE
# PROGRAM (an office copy in data/ next to the .exe).
sub origin {
    my $p = File::Spec->rel2abs(shift // $PATH // default_path());
    my $dir = HardyCross::Settings::database_dir();
    return 'TEAM FOLDER' if defined $dir && $p eq File::Spec->rel2abs(File::Spec->catfile($dir, 'pipes.dat'));
    my ($vol, $mdir) = File::Spec->splitpath(File::Spec->rel2abs(__FILE__));
    my $src = File::Spec->rel2abs(File::Spec->catfile($vol . $mdir, File::Spec->updir, 'data', 'pipes.dat'));
    return 'BUILT-IN' if $p eq $src || ($ENV{PAR_TEMP} && index($p, $ENV{PAR_TEMP}) == 0);
    my ($a, $b) = map { my $x = $_; 1 while $x =~ s{[^/\\]+[/\\]\.\.[/\\]}{}; $x } $p, $src;
    return 'BUILT-IN' if $a eq $b;
    return 'BESIDE THE PROGRAM';
}

# user_path -- the office's own copy: data/pipes.dat beside the program.  A
# packaged .exe names itself in PAR_PROGNAME; otherwise it is the script.
sub user_path {
    my ($pv, $pd) = File::Spec->splitpath(File::Spec->rel2abs($ENV{PAR_PROGNAME} || $0));
    return File::Spec->catfile($pv . $pd, 'data', 'pipes.dat');
}

sub load {
    my $path = shift // default_path();
    # Fingerprint the exact bytes read, so the report can say which data was
    # used.  The database is user editable; the hash is what makes that safe.
    open my $raw, '<:raw', $path
        or die "cannot open the pipe and fitting database $path: $!"
             . (defined HardyCross::Settings::database_dir()
                ? ' (the database folder set in the PHCP settings, ' . HardyCross::Settings::file() . ')' : '')
             . "\n";
    my $bytes = do { local $/; <$raw> };
    close $raw;
    # Start clean: the editor reloads after saving an edit, and a row deleted
    # there must not survive from the last load.
    %PIPETYPE = %PIPE = %FIT = %KPRIME = ();
    ($DATASET, $ISSUED) = (undef, undef);
    $SHA256 = Digest::SHA::sha256_hex($bytes);
    $PATH   = $path;
    open my $fh, '<:encoding(UTF-8)', \$bytes
        or die "cannot read the pipe and fitting database $path: $!\n";
    # Defensive: never trust the caller's record separator.  This is the bug
    # that made the first integration load an empty database.
    local $/ = "\n";
    while (my $l = <$fh>) {
        chomp $l;
        next if $l =~ /^\s*(#|$)/;
        my @f = split /\|/, $l;
        my $kind = shift @f;
        if    ($kind eq 'DATASET')  { ($DATASET, $ISSUED) = @f }
        elsif ($kind eq 'PIPETYPE') {
            # The roughness (mm, for Darcy-Weisbach) is the last field; a
            # database written before it was added has none, and DASH is none
            # published -- either way undef, and the caller's default applies.
            my ($code, $name, $std, $range, $c, $eps) = @f;
            $eps = undef if defined $eps && ($eps eq 'DASH' || $eps !~ /^\s*(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\s*\z/);
            $PIPETYPE{$code} = { name => $name, std => $std, range => $range,
                                 c => $c, eps => $eps };
        }
        elsif ($kind eq 'PIPE') {
            my ($code, $dn, $od, $bore, $k) = @f;
            $PIPE{$code}{$dn} = { od => $od, bore => $bore, k => $k };
        }
        elsif ($kind eq 'FIT') {
            my ($src, $code, $label, $dn, $le) = @f;
            $FIT{$src}{$code}{$dn} = { label => $label, le => $le };
            $FIT{$src}{$code}{_label} = $label;
        }
        elsif ($kind eq 'KPRIME') {
            my ($code, $label, $kp, $use) = @f;
            $KPRIME{$code} = { label => $label, kp => $kp, use => $use };
        }
    }
    close $fh;
    die "database $path has no DATASET line -- add one naming this data and its date\n"
        unless $DATASET;
    return 1;
}

sub dataset   { $DATASET // '' }
sub issued    { $ISSUED  // '' }
sub path      { $PATH    // '' }
sub sha256    { $SHA256  // '' }
sub pipe_type { $PIPETYPE{ $_[0] } }
sub pipe_types { sort keys %PIPETYPE }

# The actual bore for a pipe type and nominal size, from its PIPE records.
# Undef where the size is not in the database.
sub bore {
    my ($type, $dn) = @_;
    my $r = $PIPE{$type} && $PIPE{$type}{$dn} or return undef;
    return $r->{bore} eq 'DASH' ? undef : $r->{bore};
}

sub pipe_row { my ($type, $dn) = @_; $PIPE{$type} && $PIPE{$type}{$dn} }

#------------------------------------------------------------------------------
# Which source governs a fitting on a given pipe at a given size.  The source
# codes are the first field of the FIT records in the database.
#
#   CPVC            CPVC  BlazeMaster, at every size
#   PE11, PE9       PPI   Le = K'd
#   PVCM16          AS / FM as a controlled FALLBACK
#   steel DN<=150   AS    AS 2118.1 Table 14.11.1
#   steel DN>=200   FM    FM Global DS 3-0 Table 12(a)
#
# The DN150/DN200 boundary is deliberately clean: every size has exactly ONE
# source.  AS 2118.1 also publishes DN200 to DN300 columns, and they are not
# used.
#------------------------------------------------------------------------------
sub governing_source {
    my ($type, $dn) = @_;
    return { method => 'EQUIVALENT_LENGTH', class => 'A3', table => 'CPVC',
             doc => 'TYCO/BlazeMaster IH-1900 rev. 04/2019 Table F2',
             corrections => 0, status => APPROVED } if $type eq 'CPVC';
    return { method => 'LE_OVER_D', class => 'B', table => 'PPI',
             doc => 'PPI Handbook of PE Pipe 2nd ed. Ch. 6 Eq. 2-9, Table 2-2',
             corrections => 0, status => APPROVED } if $type =~ /^PE/;

    my $fallback = $type eq 'PVCM16';
    my $tno  = $dn <= 150 ? 'AS' : 'FM';
    my $base = $tno eq 'AS'
        ? { basis => 'ASAM', doc => 'AS 2118.1:2017 Table 14.11.1', class => 'A1' }
        : { basis => 'S40',  doc => 'FM Global DS 3-0 (March 2010) Table 12(a)',
            class => 'A2' };
    return {
        method      => $fallback ? 'EQUIVALENT_LENGTH_FALLBACK' : 'EQUIVALENT_LENGTH',
        class       => $fallback ? 'C' : $base->{class},
        table       => $tno,
        doc         => $base->{doc},
        basis_type  => $base->{basis},
        corrections => 1,
        # A PVC-M fitting has no governing value of its own: the generic
        # allowance is a controlled fallback, and the assumption must be
        # stated in the report.
        status      => $fallback ? ASSUMPTION_REQUIRED : APPROVED,
    };
}

#------------------------------------------------------------------------------
# Parse a fitting string.
#
# Both the office form "2E,1T" and the compact form "1E1T" are accepted, so
# a string copied off an existing calculation sheet works unchanged.  A count
# with no code, or a code the database does not know, is an error -- it is not
# skipped, because a skipped fitting is an uncounted fitting.
#------------------------------------------------------------------------------
# The largest count of one fitting accepted on a single pipe.  An office
# convention, not a figure from any standard; raise it if a real pipe needs it.
our $MAX_COUNT = 99;

sub parse_fittings {
    my $spec = shift // '';
    $spec =~ s/\s+//g;
    return ([], undef) unless length $spec;
    my @items;
    my $rest = uc $spec;
    while (length $rest) {
        $rest =~ s/^[,+]+//;          # ',' as typed, '+' after tokenising
        last unless length $rest;
        # the longest codes first, so E45M2 is not read as E45 then M2
        if ($rest =~ s/^(\d*)(E45M[12]|E60M[12]|E30M[12]|E15M1|EM[123]|GV(?:75|50|25)?|CV[MB]?|E45|E15|EL|EF|GLV|CPL|TR|BV|AV|E|T)//) {
            my ($n, $code) = ($1 eq '' ? 1 : $1, $2);
            # A count of zero is not a fitting: it is almost always a digit
            # lost from "10E" or a stray 0, and accepting it counts nothing
            # without saying so.  Found by the stress test, which also found
            # "1000000E" accepted as 1.5 km of elbows.  No single pipe carries
            # a hundred of one fitting; a count that large is a typing error,
            # and solving it produces a plausible-looking wrong answer.
            return (undef, "fitting count of zero in '$code' - a count of zero "
                         . "is not a fitting; check the string") if $n == 0;
            return (undef, "fitting count of $n for '$code' is not plausible for "
                         . "one pipe (limit $MAX_COUNT); check the string")
                if $n > $MAX_COUNT;
            push @items, [ $n, $code ];
        } else {
            return (undef, "cannot read fitting code at '$rest'");
        }
    }
    return (\@items, undef);
}

#------------------------------------------------------------------------------
# Resolve one fitting string for one pipe.
#
# Returns a hash:
#   total    final equivalent length in metres (undef if anything is missing)
#   records  one per fitting, carrying everything the report must state
#   errors   human-readable DATA_REQUIRED / unknown-code messages
#
# Options:
#   standard_only => 1   the "published Standard alone" election: AS 2118.1
#                        values unmodified, diameter modifier not applied.
#                        Legitimate, but the report must state it.
#------------------------------------------------------------------------------
sub resolve {
    my (%a) = @_;
    my ($type, $dn, $c, $spec) = @a{qw(type dn c spec)};
    my %out = (total => 0, records => [], errors => []);

    my ($items, $err) = parse_fittings($spec);
    if ($err) { push @{ $out{errors} }, $err; $out{total} = undef; return \%out }
    return \%out unless @$items;

    unless ($PIPETYPE{$type}) {
        push @{ $out{errors} }, "unknown pipe type '$type'";
        $out{total} = undef;
        return \%out;
    }
    my $bore = bore($type, $dn);
    unless (defined $bore) {
        push @{ $out{errors} },
            "DATA_REQUIRED: DN$dn is not in the database for pipe type $type";
        $out{total} = undef;
        return \%out;
    }
    $c //= $PIPETYPE{$type}{c};
    my $src = governing_source($type, $dn);

    for my $it (@$items) {
        my ($n, $code) = @$it;
        my %r = (count => $n, code => $code, type => $type, dn => $dn,
                 bore => $bore, c => $c, class => $src->{class},
                 doc => $src->{doc}, method => $src->{method},
                 status => $src->{status}, dataset => $DATASET);

        # Published but not counted.
        if ($NOT_COUNTED{$code}) {
            @r{qw(label base cmult dmult each total method note)} =
                (($src->{table} eq 'PPI' ? ($KPRIME{$code} || {})->{label}
                                      : $FIT{ $src->{table} }{$code}{_label}) // $code,
                 0, 1, 1, 0, 0, 'NOT_COUNTED',
                 'does not turn the flow - not counted');
            push @{ $out{records} }, \%r;
            next;
        }

        if ($src->{method} eq 'LE_OVER_D') {
            # PE: Le = K' d, with d the ACTUAL bore in metres.  No C or
            # diameter correction is applied to a PPI value.
            my $kp = $KPRIME{$code};
            unless ($kp) {
                push @{ $out{errors} },
                    "DATA_REQUIRED: no PPI K' for fitting $code on $type DN$dn";
                $out{total} = undef;
                $r{status} = DATA_REQUIRED;
                push @{ $out{records} }, \%r;
                next;
            }
            my $each = $kp->{kp} * $bore / 1000;
            @r{qw(label base cmult dmult each total note)} =
                ($kp->{label}, $kp->{kp}, 1, 1, $each, $n * $each,
                 "Le = K'd = $kp->{kp} x " . sprintf('%.4f', $bore / 1000) . ' m');
            $out{total} += $n * $each if defined $out{total};
            push @{ $out{records} }, \%r;
            next;
        }

        my $row = $FIT{ $src->{table} }{$code};
        my $cell = $row && $row->{$dn};
        if (!$row || !$cell || $cell->{le} eq 'DASH') {
            # The single most important branch in this module.
            my $why = !$row  ? "$src->{doc} has no '$code' fitting"
                    : !$cell ? "$src->{doc} has no DN$dn value"
                    :          "$src->{doc} publishes no value (dash) at DN$dn";
            # E is the SCREWED elbow (office decision): FM stops publishing it
            # at DN300 because screwed fittings are not made larger.  Say what
            # to use instead rather than leave the designer to work it out.
            my $hint = ($code eq 'E' && $src->{table} eq 'FM')
                     ? ' - E is the screwed elbow; use EF for a flanged, grooved or'
                     . ' medium-sweep elbow' : '';
            push @{ $out{errors} },
                "DATA_REQUIRED: $code on $type DN$dn - $why; not zero, not interpolated$hint";
            $out{total} = undef;
            $r{status} = DATA_REQUIRED;
            $r{label}  = $row ? $row->{_label} : $code;
            push @{ $out{records} }, \%r;
            next;
        }

        my ($cm, $dm, $basis_bore) = (1, 1, undef);
        if ($src->{corrections}) {
            # C multiplier: Le = Le,tab x (C/120)^1.85
            $cm = ($c / 120) ** 1.85;
            # Diameter modifier: Le = Le,tab x (d/d,tab)^4.87, against the bore
            # the table was built on -- AS 1074 Medium for AS 2118.1 (an office
            # assumption), Schedule 40 for FM DS 3-0.
            $basis_bore = bore($src->{basis_type}, $dn);
            if (!defined $basis_bore) {
                push @{ $out{errors} },
                    "DATA_REQUIRED: no $src->{basis_type} basis bore at DN$dn "
                  . "for the diameter modifier";
                $out{total} = undef;
                $r{status} = DATA_REQUIRED;
                push @{ $out{records} }, \%r;
                next;
            }
            $dm = $a{standard_only} ? 1 : ($bore / $basis_bore) ** 4.87;
        }
        my $each = $cell->{le} * $cm * $dm;
        @r{qw(label base basis_type basis_bore basis_c cmult dmult each total)} =
            ($cell->{label}, $cell->{le}, $src->{basis_type}, $basis_bore, 120,
             $cm, $dm, $each, $n * $each);
        $r{note} = 'diameter modifier NOT applied - Standard-alone election'
            if $src->{corrections} && $a{standard_only};
        $out{total} += $n * $each if defined $out{total};
        push @{ $out{records} }, \%r;
    }
    return \%out;
}

1;
