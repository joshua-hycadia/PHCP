#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# Phc.pm -- the .phc command language.
#
# A .phc file is the model typed as short command lines, one element per line,
# in any order:
#
#     Units  FLOW=LPM PRESSURE=KPA
#     Node   N1 0.0
#     Node   N2 0.0
#     Use    ASAM
#     Pipe   P1 N1 N2 12.0 100 2E T GV
#     Supply SUP1 N1 STATIC 900
#     Head   S1 N2 K=80 P=50
#
# THIS MODULE TRANSLATES; IT DOES NOT RE-IMPLEMENT.  Every command becomes the
# .hcx row that means the same thing, the rows are assembled into .hcx text,
# and that text is read by HardyCross::Parse::read_string -- the same code that
# reads a .hcx file.  Every hydraulic check, default and unit conversion
# therefore lives in one place, and a .phc model cannot quietly mean something
# different from its .hcx equivalent.  What is checked HERE is only what
# belongs to the language itself: the command words, the field count, which
# KEY= options a command takes, that a number is a number, that every node has
# a Node line, and that no setting is given twice.
#
# Every error carries the .phc line number it came from.  The .hcx parser
# numbers its own errors by .hcx line; read_string below maps those back.
#
# check_line() is the same analysis applied to one line, without Tk, for the
# editor: is the line complete, which field is the cursor in, what may be
# typed there, and what line is likely to come next.

package HardyCross::Phc;

use strict;
use warnings;
use HardyCross;
use HardyCross::Parse;
use HardyCross::PipeData;

#------------------------------------------------------------------------------
# The vocabulary.
#------------------------------------------------------------------------------

# Every OPTIONS name the .hcx parser acts on, except METHOD, which has a
# command of its own.  The .hcx parser silently ignores any other name -- which
# is how example 01 came to carry "TRACE FULL", a setting that does nothing.  In
# .phc an unknown option is an error, so a setting that does nothing cannot
# look as if it does something.
our @OPTIONS = qw(PROFILE HW_CONST NU TOL_FLOW TOL_LOOP MAXITER RELAX
                  VEL_LIMIT FITTING_BASIS ORIF_STEP);
my %OPTION = map { $_ => 1 } @OPTIONS;
# The options whose value is a number.  num() reads anything else as 0, so a
# typing error in a tolerance would otherwise become a tolerance of zero.
my %NUM_OPTION = map { $_ => 1 } qw(HW_CONST NU TOL_FLOW TOL_LOOP MAXITER
                                    RELAX VEL_LIMIT ORIF_STEP);

# The four unit quantities.  The .hcx UNITS block also takes the short names
# PRES, LEN and DIA; in .phc only the full names are keys, so that a duplicate
# such as "FLOW=LPM ... FLOW=LPS" is always seen as one.
our @UNIT_KEYS = qw(FLOW PRESSURE LENGTH DIAMETER);

# The command table.  For each command:
#   name   the spelling used in messages, templates and the converter
#   kind   setting (file-wide), use (positional), node, or element
#   block  the .hcx block an element's row is filed under
#   fixed  the positional fields, each [label, type]; types are
#            text      the rest of the line, raw (Title, Project)
#            word      one word (a PROJECT field name, a METHOD)
#            id        an element or node id -- case-sensitive, as in .hcx
#            node      a node id referred to
#            num       a number, as HardyCross::Parse::num reads one
#            option    an OPTION name
#            value     an OPTION value
#            pipetype  a pipe type in the database, or BORE
#            mode      STATIC or CURVE
#   rest   what may follow the fixed fields: fittings, curve, supply, or none
#   keys   the KEY=value options the command takes
#   need   options that must be present
my %CMD = (
    TITLE    => { name => 'Title', kind => 'setting',
                  fixed => [ [ 'text', 'text' ] ] },
    PROJECT  => { name => 'Project', kind => 'setting',
                  fixed => [ [ 'field', 'word' ], [ 'text', 'text' ] ] },
    UNITS    => { name => 'Units', kind => 'setting', fixed => [],
                  keys => [@UNIT_KEYS] },
    METHOD   => { name => 'Method', kind => 'setting',
                  fixed => [ [ 'HW|DW', 'word' ] ] },
    OPTION   => { name => 'Option', kind => 'setting',
                  fixed => [ [ 'name', 'option' ], [ 'value', 'value' ] ] },
    USE      => { name => 'Use', kind => 'use',
                  fixed => [ [ 'pipetype|BORE', 'pipetype' ] ], keys => ['C'] },
    NODE     => { name => 'Node', kind => 'node', block => 'NODES',
                  fixed => [ [ 'id', 'id' ], [ 'elevation', 'num' ] ] },
    PIPE     => { name => 'Pipe', kind => 'element', block => 'PIPES',
                  fixed => [ [ 'id', 'id' ], [ 'n1', 'node' ], [ 'n2', 'node' ],
                             [ 'length', 'num' ], [ 'size', 'num' ] ],
                  rest => 'fittings', keys => [qw(C EQV EPS K)] },
    SUPPLY   => { name => 'Supply', kind => 'element', block => 'SUPPLIES',
                  fixed => [ [ 'id', 'id' ], [ 'node', 'node' ],
                             [ 'STATIC|CURVE', 'mode' ] ],
                  rest => 'supply', keys => ['Z'] },
    PUMP     => { name => 'Pump', kind => 'element', block => 'PUMPS',
                  fixed => [ [ 'id', 'id' ], [ 'in', 'node' ], [ 'out', 'node' ] ],
                  rest => 'curve' },
    HEAD     => { name => 'Head', kind => 'element', block => 'DISCHARGES',
                  otype => 'SPRINKLER',
                  fixed => [ [ 'id', 'id' ], [ 'node', 'node' ] ],
                  keys => [qw(K Q P Z)] },
    HYDRANT  => { name => 'Hydrant', kind => 'element', block => 'DISCHARGES',
                  otype => 'HYDRANT',
                  fixed => [ [ 'id', 'id' ], [ 'node', 'node' ] ],
                  keys => [qw(K Q P Z)] },
    HOSEREEL => { name => 'HoseReel', kind => 'element', block => 'DISCHARGES',
                  otype => 'HOSEREEL',
                  fixed => [ [ 'id', 'id' ], [ 'node', 'node' ] ],
                  keys => [qw(K Q P Z)] },
    FLOW     => { name => 'Flow', kind => 'element', block => 'DISCHARGES',
                  otype => 'FIXEDFLOW',
                  fixed => [ [ 'id', 'id' ], [ 'node', 'node' ] ],
                  keys => ['Q'], need => ['Q'] },
    BFP      => { name => 'BFP', kind => 'element', block => 'DEVICES',
                  fixed => [ [ 'id', 'id' ], [ 'n1', 'node' ], [ 'n2', 'node' ] ],
                  rest => 'curve' },
    PRV      => { name => 'PRV', kind => 'element', block => 'DEVICES',
                  fixed => [ [ 'id', 'id' ], [ 'n1', 'node' ], [ 'n2', 'node' ] ],
                  keys => ['DP'], need => ['DP'] },
    ORIFICE  => { name => 'Orifice', kind => 'element', block => 'DEVICES',
                  fixed => [ [ 'id', 'id' ], [ 'n1', 'node' ], [ 'n2', 'node' ] ],
                  keys => [qw(DP BORE DN PIPEDIA CD)] },
);

# The .hcx blocks written ahead of the elements, in this order.  The order
# matters: UNITS comes before everything it scales, OPTIONS before the pipes
# (FITTING_BASIS changes how a fitting string resolves), and NODES before every
# element, because a supply or outlet with no Z= takes its node's elevation,
# which must already have been read.
#
# The elements then follow in FILE order, each run of one kind under its own
# block header (.hcx allows a block to appear more than once).  Grouping them
# by block instead -- every pipe, then every pump, every supply ... -- would
# reorder the elements of a model whose .hcx listed devices before supplies,
# and the element order is the order of the report's schedules.  A converted
# example 06 then printed its supply row in a different place, and the
# acceptance test (identical reports) failed on that alone.
my @SETTING_BLOCKS = qw(PROJECT UNITS OPTIONS NODES);

# The command names in the order a template list or a pick list shows them.
our @COMMANDS = map { $CMD{$_}{name} }
    qw(TITLE PROJECT UNITS METHOD OPTION USE NODE PIPE SUPPLY PUMP HEAD
       HYDRANT HOSEREEL FLOW BFP PRV ORIFICE);

sub command_spec { $CMD{ uc($_[0] // '') } }

#------------------------------------------------------------------------------
# template_fields -- a command's field list as the status bar shows it.
#------------------------------------------------------------------------------
sub template_fields {
    my $c = shift;
    my @f = map { $_->[0] } @{ $c->{fixed} };
    my $rest = $c->{rest} // '';
    push @f, 'fittings ...'                         if $rest eq 'fittings';
    push @f, 'q1 p1 q2 p2 ...'                      if $rest eq 'curve';
    push @f, 'pressure | q1 p1 q2 p2 ...'           if $rest eq 'supply';
    push @f, map { "$_=" } @{ $c->{keys} || [] };
    return @f;
}

# The template as one line of text: "Pipe <id> <n1> ... [C=] [EQV=]".
sub template_text {
    my $c = command_spec(shift) or return '';
    my %key = map { ("$_=" => 1) } @{ $c->{keys} || [] };
    my %need = map { ("$_=" => 1) } @{ $c->{need} || [] };
    return join ' ', $c->{name},
        map { $key{$_} && !$need{$_} ? "[$_]" : "<$_>" } template_fields($c);
}

#------------------------------------------------------------------------------
# strip_comment -- the line without its // comment and line ending.
#------------------------------------------------------------------------------
sub strip_comment {
    my $l = shift // '';
    $l =~ s/\r?\n\z//;
    $l =~ s{//.*}{}s;
    return $l;
}

#------------------------------------------------------------------------------
# analyse -- the syntax of one .phc line.
#
# Returns a hash:
#   status    blank, ok, incomplete (fields still to be typed) or error
#   msg       why, for incomplete and error
#   key       the command's key in %CMD, once it is known
#   pos       the positional fields after the command word, as typed
#   opt       { KEY => value } for the KEY=value options, keys upper-cased
#   optorder  the option keys in the order typed
#   rest      the tokens after the fixed fields (fittings, curve points)
#   text      for Title and Project, the raw text
#
# $partial is true while the line is being typed and the cursor is at its end:
# a lone word that begins a command name is then "incomplete", not "unknown".
#------------------------------------------------------------------------------
sub analyse {
    my ($raw, $partial) = @_;
    my $code = strip_comment($raw);
    my %a = (status => 'ok', pos => [], opt => {}, optorder => [], rest => []);
    my $bad  = sub { %a = (%a, status => 'error',      msg => sprintf(shift, @_)); \%a };
    my $more = sub { %a = (%a, status => 'incomplete', msg => sprintf(shift, @_)); \%a };

    # '!' and '#' start a comment in .hcx, and the .hcx tokeniser this reader
    # shares would cut the line there without a word.  "Title JOB #12" would
    # lose "#12"; "Pipe P1 A B 3 # 50" would lose its size.  In .phc they are
    # simply not allowed outside a // comment, so nothing is cut silently.
    return $bad->("'%s' cannot be used in a .phc line; comments start with //", $1)
        if $code =~ /([!#])/;

    my @tk = HardyCross::Parse::tokenize($code);
    return { %a, status => 'blank' } unless @tk;

    my $word = uc $tk[0];
    my $c = $CMD{$word};
    unless ($c) {
        # Still typing the command word: incomplete if some command begins
        # with what has been typed so far.
        if ($partial && @tk == 1 && $code !~ /\s\z/
            && grep { index($_, $word) == 0 } keys %CMD) {
            return $more->('a command: %s', join(' ', @COMMANDS));
        }
        return $bad->("unknown command %s (commands are %s)", $tk[0], join(' ', @COMMANDS));
    }
    $a{key} = $word;

    #-------------------------------------------------- Title and Project
    # Their value is the rest of the RAW line, so a title keeps its spacing and
    # punctuation exactly as the .hcx PROJECT block does.
    if ($word eq 'TITLE' || $word eq 'PROJECT') {
        (my $t = $code) =~ s/^\s*\S+\s*//;
        if ($word eq 'PROJECT') {
            return $more->('a PROJECT field name, such as COMPANY or JOB') unless @tk > 1;
            push @{ $a{pos} }, uc $tk[1];
            # END is reserved: written into the .hcx PROJECT block it would end
            # the block, and every later field would be dropped without a word.
            return $bad->('END cannot be a PROJECT field name') if uc $tk[1] eq 'END';
            $t =~ s/^\S+\s*//;
        }
        $t =~ s/\s+\z//;
        return $more->('the text') unless length $t;
        $a{text} = $t;
        return \%a;
    }

    #-------------------------------------------------- every other command
    my @fixed = @{ $c->{fixed} };
    my %allowed = map { $_ => 1 } @{ $c->{keys} || [] };
    for my $t (@tk[1 .. $#tk]) {
        if ($t =~ /=/) {
            my ($k, $v) = split /=/, $t, 2;
            $k = uc $k;
            # A fixed-flow outlet's MINP= is accepted by the .hcx reader but
            # never used: the solver applies the flow and checks no pressure.
            # Accepting it here would let a designer believe a minimum
            # pressure was being enforced.  See README, "Fixed flows".
            return $bad->('MINP= is not supported on a Flow: PHCP applies the flow only '
                        . 'and does not check a minimum pressure')
                if $word eq 'FLOW' && $k eq 'MINP';
            return $bad->("%s= is not an option of %s%s", $k, $c->{name},
                          %allowed ? ' (it takes ' . join(' ', map { "$_=" } @{ $c->{keys} }) . ')'
                                   : ' (it takes no KEY= options)')
                unless $allowed{$k};
            return $bad->("%s= is given twice", $k) if exists $a{opt}{$k};
            return $bad->("%s= options come after the fixed fields; %s is still missing",
                          $k, $fixed[ @{ $a{pos} } ][0])
                if @{ $a{pos} } < @fixed;
            return $more->("a value after %s=", $k) unless length($v // '');
            if ($word eq 'UNITS') {
                $v = uc $v;
            } elsif (!HardyCross::Parse::is_num($v)) {
                return $bad->("%s=%s is not a number", $k, $v);
            }
            $a{opt}{$k} = $v;
            push @{ $a{optorder} }, $k;
        } elsif (@{ $a{pos} } < @fixed) {
            push @{ $a{pos} }, $t;
        } else {
            push @{ $a{rest} }, $t;
        }
    }

    # The fixed fields, each checked for its type.
    for my $i (0 .. $#{ $a{pos} }) {
        my ($label, $type) = @{ $fixed[$i] };
        my $v = $a{pos}[$i];
        if ($type eq 'num') {
            return $bad->("%s '%s' is not a number", $label, $v)
                unless HardyCross::Parse::is_num($v);
        } elsif ($type eq 'id' || $type eq 'node') {
            # END ends a block in .hcx, so an element or node called END would
            # end the block it was written into.
            return $bad->('END cannot be used as an id') if uc $v eq 'END';
        } elsif ($type eq 'option') {
            my $o = uc $v;
            return $bad->('METHOD has a command of its own: Method HW or Method DW')
                if $o eq 'METHOD';
            return $bad->("unknown option %s (options are %s)", $v, join(' ', @OPTIONS))
                unless $OPTION{$o};
            $a{pos}[$i] = $o;
        } elsif ($type eq 'value') {
            my $o = $a{pos}[0];
            if ($NUM_OPTION{$o}) {
                return $bad->("%s value '%s' is not a number", $o, $v)
                    unless HardyCross::Parse::is_num($v);
            } elsif ($o eq 'PROFILE') {
                # The .hcx parser acts on PROFILE EPANET and silently ignores
                # any other value; here any other value is an error.
                return $bad->('PROFILE takes EPANET') unless uc $v eq 'EPANET';
                $a{pos}[$i] = uc $v;
            } else {
                $a{pos}[$i] = uc $v;
            }
        } elsif ($type eq 'pipetype') {
            my $p = uc $v;
            unless ($p eq 'BORE') {
                HardyCross::Parse::ensure_db();
                return $bad->("unknown pipe type %s (the pipe database lists %s; "
                            . "BORE for a pipe given by its bore)",
                              $v, join(' ', HardyCross::PipeData::pipe_types()))
                    unless HardyCross::PipeData::pipe_type($p);
            }
            $a{pos}[$i] = $p;
        } elsif ($type eq 'mode') {
            my $m = uc $v;
            return $bad->("%s must be STATIC or CURVE", $v)
                unless $m eq 'STATIC' || $m eq 'CURVE';
            $a{pos}[$i] = $m;
        }
    }
    return $more->('%s', $fixed[ @{ $a{pos} } ][0]) if @{ $a{pos} } < @fixed;

    # What follows the fixed fields.
    my $rest = $c->{rest} // '';
    my @r = @{ $a{rest} };
    if ($rest eq 'curve' || ($rest eq 'supply' && $a{pos}[2] eq 'CURVE')) {
        for (@r) {
            return $bad->("curve value '%s' is not a number", $_)
                unless HardyCross::Parse::is_num($_);
        }
        return $more->('flow/pressure pairs: at least two') if @r < 4;
        return $more->('the pressure to pair with flow %s', $r[-1]) if @r % 2;
    } elsif ($rest eq 'supply') {
        return $more->('the static pressure') unless @r;
        return $bad->("unexpected field '%s' after the static pressure", $r[1]) if @r > 1;
        return $bad->("pressure '%s' is not a number", $r[0])
            unless HardyCross::Parse::is_num($r[0]);
    } elsif ($rest eq 'fittings') {
        # Checked against the database when the row is parsed: the fitting
        # codes a pipe can take depend on its type and size.
    } elsif (@r) {
        return $bad->("unexpected field '%s'", $r[0]);
    }

    # Options that must be present, and the combinations that must hold.
    for my $k (@{ $c->{need} || [] }) {
        return $more->('%s=', $k) unless exists $a{opt}{$k};
    }
    if ($word eq 'UNITS') {
        return $more->('at least one of %s', join(' ', map { "$_=" } @UNIT_KEYS))
            unless @{ $a{optorder} };
    }
    if ($c->{otype} && $c->{otype} ne 'FIXEDFLOW') {
        my $n = grep { exists $a{opt}{$_} } qw(K Q P);
        return $more->('any two of K=, Q=, P=') if $n < 2;
    }
    if ($word eq 'ORIFICE') {
        return $bad->('an Orifice takes DP= (to size the plate) or BORE= (a known bore), not both')
            if exists $a{opt}{DP} && exists $a{opt}{BORE};
        return $more->('DP= (to size the plate) or BORE= (a known bore)')
            unless exists $a{opt}{DP} || exists $a{opt}{BORE};
        return $more->('DN= or PIPEDIA= for the pipe the plate sits in')
            unless exists $a{opt}{DN} || exists $a{opt}{PIPEDIA};
    }
    return \%a;
}

# The node ids a line refers to, in field order.
sub nodes_used {
    my $a = shift;
    my $c = $CMD{ $a->{key} // '' } or return;
    return if $c->{kind} ne 'element';
    my @fixed = @{ $c->{fixed} };
    return map { $a->{pos}[$_] } grep { $fixed[$_][1] eq 'node' } 0 .. $#fixed;
}

#------------------------------------------------------------------------------
# hcx_row -- the .hcx row an element line means.
#
# Returns (block, row text).  $use is the Use in force: { type => 'ASAM' or
# 'BORE', c => C= or undef }.  Values are copied as typed, never reformatted,
# so the .hcx parser sees exactly the digits the designer wrote.
#------------------------------------------------------------------------------
sub hcx_row {
    my ($a, $use) = @_;
    my $c = $CMD{ $a->{key} };
    my @p = @{ $a->{pos} };
    my %o = %{ $a->{opt} };
    # The options in the order typed, as KEY=value, upper-case keys.
    my $opts = sub { map { "$_=$o{$_}" } grep { exists $o{$_} } @_ };
    my $key = $a->{key};

    return ('NODES', "$p[0] $p[1]") if $key eq 'NODE';

    if ($key eq 'PIPE') {
        $use ||= { type => 'BORE' };
        my @fit = @{ $a->{rest} };
        # The pipe's own C= wins over the Use line's.
        my $cv = $o{C} // $use->{c};
        if ($use->{type} eq 'BORE') {
            # With no pipe type there is no fitting table and no basis bore,
            # so a fitting cannot be resolved -- the .hcx parser refuses a
            # fitting string without TYPE= for the same reason.
            HardyCross::fail("pipe %s: fittings need a pipe type - put a Use <pipetype> "
                           . "line before it, or give the allowance as EQV=", $p[0])
                if @fit;
            return ('PIPES', join ' ', @p, (defined $cv ? "C=$cv" : ()),
                                        $opts->(qw(EQV EPS K)));
        }
        # The fittings go to the .hcx FIT= field joined by commas.  Each token
        # may be a code ("T"), a counted code ("2E"), or a whole office string
        # ("2E,1T" is split into two tokens by the shared tokeniser; "1E1T"
        # stays one): the database resolver reads all of them.
        return ('PIPES', join ' ', @p, "TYPE=$use->{type}",
                                    (@fit ? 'FIT=' . join(',', @fit) : ()),
                                    (defined $cv ? "C=$cv" : ()),
                                    $opts->(qw(EQV EPS K)));
    }
    if ($key eq 'SUPPLY') {
        return ('SUPPLIES', join ' ', @p, @{ $a->{rest} }, $opts->('Z'));
    }
    if ($key eq 'PUMP') {
        return ('PUMPS', join ' ', @p, @{ $a->{rest} });
    }
    if ($c->{otype}) {
        return ('DISCHARGES', join ' ', @p, $c->{otype}, $opts->(qw(K Q P Z)));
    }
    if ($key eq 'BFP') {
        return ('DEVICES', join ' ', @p, 'BFP', @{ $a->{rest} });
    }
    if ($key eq 'PRV') {
        return ('DEVICES', join ' ', @p, 'PRV', $opts->('DP'));
    }
    if ($key eq 'ORIFICE') {
        my $ty = exists $o{DP} ? 'ORIFICE_P' : 'ORIFICE_D';
        return ('DEVICES', join ' ', @p, $ty, $opts->(qw(DP BORE DN PIPEDIA CD)));
    }
    die "hcx_row: no translation for $key\n";    # a programming error
}

#------------------------------------------------------------------------------
# translate -- .phc text to .hcx text.
#
# Returns (hcx text, line map), where $map->[n] is the .phc line that .hcx line
# n (counting from 1) came from.  Fails, naming the .phc line, on anything the
# language itself does not allow.
#------------------------------------------------------------------------------
sub translate {
    my $text = shift // '';
    my @lines = split /\n/, $text, -1;
    my $at = sub { my $n = shift; HardyCross::fail("line %d: %s", $n, sprintf(shift, @_)) };

    # Read every line once.  An error stops the read at that line, as the .hcx
    # reader does.
    my @rows;
    for my $n (1 .. @lines) {
        my $a = analyse($lines[ $n - 1 ]);
        next if $a->{status} eq 'blank';
        $at->($n, '%s', $a->{status} eq 'incomplete'
                         ? "$CMD{ $a->{key} // '' }{name} needs $a->{msg}"
                         : $a->{msg})
            if $a->{status} ne 'ok' && $a->{key};
        $at->($n, '%s', $a->{msg}) if $a->{status} ne 'ok';
        push @rows, [ $n, $a ];
    }

    # First pass: the file-wide settings, wherever they appear.  Each may be
    # given once; a second setting is an error naming both lines, because a
    # silent "last one wins" in a file read in any order is a trap.
    my (%block, %seen);
    my $once = sub {
        my ($n, $what) = @_;
        $at->($n, '%s is already set on line %d', $what, $seen{$what}) if $seen{$what};
        $seen{$what} = $n;
    };
    for (@rows) {
        my ($n, $a) = @$_;
        my $k = $a->{key};
        next unless $CMD{$k}{kind} eq 'setting';
        if ($k eq 'TITLE') {
            $once->($n, 'TITLE');
            push @{ $block{PROJECT} }, [ "TITLE $a->{text}", $n ];
        } elsif ($k eq 'PROJECT') {
            $once->($n, $a->{pos}[0]);
            push @{ $block{PROJECT} }, [ "$a->{pos}[0] $a->{text}", $n ];
        } elsif ($k eq 'UNITS') {
            for my $q (@{ $a->{optorder} }) {
                $once->($n, "$q=");
                push @{ $block{UNITS} }, [ "$q $a->{opt}{$q}", $n ];
            }
        } elsif ($k eq 'METHOD') {
            $once->($n, 'Method');
            push @{ $block{OPTIONS} }, [ "METHOD $a->{pos}[0]", $n ];
        } elsif ($k eq 'OPTION') {
            $once->($n, "Option $a->{pos}[0]");
            push @{ $block{OPTIONS} }, [ "$a->{pos}[0] $a->{pos}[1]", $n ];
        }
    }

    # Second pass: nodes and elements, in file order.  Use is the one
    # positional command: it applies to the Pipe lines after it.  Before any
    # Use, a pipe is given by its bore with the .hcx default C of 120.
    my $use = { type => 'BORE' };
    my (%defined, %first_use, @used, @elems);
    for (@rows) {
        my ($n, $a) = @$_;
        my $k = $a->{key};
        my $kind = $CMD{$k}{kind};
        next if $kind eq 'setting';
        if ($kind eq 'use') {
            $use = { type => $a->{pos}[0], c => $a->{opt}{C} };
            next;
        }
        if ($kind eq 'node') {
            my $id = $a->{pos}[0];
            $at->($n, 'node %s already has a Node line, on line %d', $id, $defined{$id})
                if $defined{$id};
            $defined{$id} = $n;
        }
        for my $id (nodes_used($a)) {
            next if $first_use{$id};
            $first_use{$id} = $n;
            push @used, $id;
        }
        my ($blk, $row) = eval { hcx_row($a, $use) };
        unless (defined $blk) {
            my $e = $@;
            $at->($n, '%s', $e->{msg}) if HardyCross::is_model_error($e);
            die $e;
        }
        if ($blk eq 'NODES') { push @{ $block{NODES} }, [ $row, $n ] }
        else                 { push @elems, [ $blk, $row, $n ] }
    }

    # A node used but never defined.  The .hcx reader creates such a node at
    # elevation 0 without a word; a mistyped node name then becomes a new
    # node, and a forgotten elevation becomes zero.  In .phc every node needs
    # its Node line.  The converter writes one for every node, so converted
    # files are unaffected.
    my @undef = grep { !$defined{$_} } @used;
    if (@undef) {
        my $id = shift @undef;
        $at->($first_use{$id}, 'node %s has no Node line%s', $id,
              @undef ? ' (also ' . join(', ', map { "$_ on line $first_use{$_}" } @undef) . ')'
                     : '');
    }

    # Assemble the .hcx text: the setting blocks and NODES in the order above,
    # then the elements in file order, opening a new block whenever the kind
    # of element changes.  @map records, for each .hcx line, the .phc line it
    # came from (undef for block headers and END).
    my (@out, @map);
    my $emit = sub { push @out, $_[0]; $map[ scalar @out ] = $_[1] };
    for my $b (@SETTING_BLOCKS) {
        next unless $block{$b};
        $emit->($b, undef);
        $emit->("  $_->[0]", $_->[1]) for @{ $block{$b} };
        $emit->('END', undef);
    }
    my $open = '';
    for my $e (@elems) {
        my ($blk, $row, $n) = @$e;
        if ($blk ne $open) {
            $emit->('END', undef) if $open;
            $emit->($blk, undef);
            $open = $blk;
        }
        $emit->("  $row", $n);
    }
    $emit->('END', undef) if $open;
    return (join("\n", @out) . "\n", \@map);
}

#------------------------------------------------------------------------------
# read_string / read_model -- a .phc model, read into a network.
#
# The network is exactly what HardyCross::Parse::read_string builds from the
# translated .hcx text, so the solver, report and demand calculation see no
# difference between the two formats.  Its source_text is that .hcx text: the
# demand calculation re-reads it at trial supply pressures.
#------------------------------------------------------------------------------
sub read_string {
    my $text = shift;
    my ($hcx, $map) = translate($text);
    my $net = eval { HardyCross::Parse::read_string($hcx) };
    unless ($net) {
        my $e = $@;
        die $e unless HardyCross::is_model_error($e);
        # The parser numbers its errors by .hcx line; give the .phc line.
        if ($e->{msg} =~ /^line (\d+): (.*)\z/s && defined $map->[$1]) {
            HardyCross::fail("line %d: %s", $map->[$1], $2);
        }
        die $e;
    }
    $net->{phc_text} = $text;
    return $net;
}

sub read_model {
    my $path = shift;
    open my $fh, '<', $path or HardyCross::fail("cannot open input file %s", $path);
    # Slurped in a do-block so the undefined $/ cannot leak into the pipe
    # database load -- see HardyCross::Parse::read_model.
    my $text = do { local $/; <$fh> };
    close $fh;
    return read_string($text);
}

#==============================================================================
# The editor's line checker.
#==============================================================================

# The fitting codes in the database, read once from the file PipeData loaded.
# PipeData resolves fittings but does not list them; the pick list needs the
# codes and their descriptions, so they are read from the same file (and so
# always match what the resolver will accept).
my (%FITCODE, %KPCODE, %DNS);
sub fitting_tables {
    return if %FITCODE;
    HardyCross::Parse::ensure_db();
    my $path = HardyCross::PipeData::path();
    open my $fh, '<:encoding(UTF-8)', $path or return;
    local $/ = "\n";
    while (my $l = <$fh>) {
        chomp $l;
        next if $l =~ /^\s*(#|$)/;
        my @f = split /\|/, $l;
        if ($f[0] eq 'FIT') {
            $FITCODE{ $f[1] }{ $f[2] } //= ascii($f[3]);
        } elsif ($f[0] eq 'KPRIME') {
            $KPCODE{ $f[1] } //= ascii($f[2]);
        } elsif ($f[0] eq 'PIPE') {
            push @{ $DNS{ $f[1] } }, $f[2];
        }
    }
    close $fh;
}
# The user interface is 7-bit ASCII like the report: "90° elbow" is shown as
# "90 deg elbow".
sub ascii { my $s = shift // ''; $s =~ s/\x{B0}/ deg/g; $s =~ s/[^\x20-\x7E]//g; $s }

#------------------------------------------------------------------------------
# pipe_type_choices / fitting_choices -- the pick lists, as [code, description].
#------------------------------------------------------------------------------
sub pipe_type_choices {
    HardyCross::Parse::ensure_db();
    return ((map { [ $_, ascii(HardyCross::PipeData::pipe_type($_)->{name}) ] }
             HardyCross::PipeData::pipe_types()),
            [ 'BORE', 'pipes given by their bore, with no pipe type' ]);
}

# The fitting codes a pipe of this type can take: from the source that governs
# the given DN, or from every source the type uses when the DN is not known
# yet.  Under Use BORE there are none -- fittings need a pipe type.
sub fitting_choices {
    my ($type, $dn) = @_;
    return () if !defined $type || $type eq 'BORE';
    fitting_tables();
    my @dns = (defined $dn && grep { $_ == $dn } @{ $DNS{$type} || [] })
            ? ($dn) : @{ $DNS{$type} || [] };
    my (%label, @order);
    my %src = map { HardyCross::PipeData::governing_source($type, $_)->{table} => 1 } @dns;
    for my $s (sort keys %src) {
        my $tbl = $s eq 'PPI' ? \%KPCODE : ($FITCODE{$s} || {});
        for my $code (sort keys %$tbl) {
            push @order, $code unless exists $label{$code};
            $label{$code} //= $tbl->{$code};
        }
    }
    return map { [ $_, $label{$_} ] } @order;
}

#------------------------------------------------------------------------------
# step_id -- the next id in a series: P7 -> P8, N09 -> N10, A -> A2.
#------------------------------------------------------------------------------
sub step_id {
    my $id = shift // '';
    return $1 . sprintf('%0*d', length $2, $2 + 1) if $id =~ /^(.*?)(\d+)\z/;
    return $id . '2';
}

#------------------------------------------------------------------------------
# propose -- the likely next line after a complete element line.
#
# The same command with its ids stepped.  A pipe starts where the last one
# ended, keeps its length, size and options, and drops its fittings (the next
# pipe rarely has the same ones).  Settings and Use lines propose nothing.
#------------------------------------------------------------------------------
sub propose {
    my ($raw) = @_;
    my $a = analyse($raw);
    return undef unless $a->{status} eq 'ok';
    my $c = $CMD{ $a->{key} };
    return undef unless $c->{kind} eq 'element' || $c->{kind} eq 'node';
    my ($word) = strip_comment($raw) =~ /^\s*(\S+)/;
    my @p = @{ $a->{pos} };
    my @fixed = @{ $c->{fixed} };
    my @rest = @{ $a->{rest} };
    if ($a->{key} eq 'PIPE') {
        @p = (step_id($p[0]), $p[2], step_id($p[2]), @p[3, 4]);
        @rest = ();
    } else {
        for my $i (0 .. $#p) {
            $p[$i] = step_id($p[$i]) if $fixed[$i][1] =~ /^(id|node)\z/;
        }
    }
    return join ' ', $word, @p, @rest, map { "$_=$a->{opt}{$_}" } @{ $a->{optorder} };
}

#------------------------------------------------------------------------------
# check_line -- one line, checked as it is typed.
#
#   $line      the text of the line
#   $context   {
#                use     => 'ASAM' or 'BORE', or { type => .., c => .. }:
#                           the Use in force at this line
#                units   => { FLOW => 'LPS', ... }: the file's Units, so a
#                           value is checked in the unit it is written in
#                options => { FITTING_BASIS => 'STANDARD' }, likewise
#                nodes   => [ ids ] or { id => 1 }: the defined nodes
#                cursor  => the cursor's column (default: end of line)
#              }
#
# Returns a hash:
#   status    ok, incomplete or error (blank and comment lines are ok)
#   message   why, for incomplete and error
#   template  { command, text, fields => [...], current => field index or -1
#               for the command word } -- undef on a blank line
#   choices   [ [code, description], ... ] for a pipe-type or fitting field
#   proposal  the suggested next line, for a complete element line
#   undefined the node ids this line uses that are not in context nodes --
#             not an error on the line, since the Node line may come later
#
# A line the language accepts is then parsed, as its .hcx row, into a scratch
# network by the .hcx parser itself.  So "ok" means the parser accepts it too:
# a DN the pipe type does not make, a fitting the database lacks, or a head
# whose K cannot be derived is an error on the line as it is typed, by the
# same rule and in the same words as when the model is solved.
#------------------------------------------------------------------------------
sub check_line {
    my ($line, $ctx) = @_;
    $ctx ||= {};
    $line //= '';
    my $cursor = $ctx->{cursor} // length $line;
    my $use = $ctx->{use} // 'BORE';
    $use = { type => uc $use } unless ref $use;

    my $a = analyse($line, $cursor >= length(strip_comment($line)));
    my %r = (status => $a->{status} eq 'blank' ? 'ok' : $a->{status},
             message => $a->{msg} // '', choices => [], proposal => undef,
             undefined => []);
    return \%r if $a->{status} eq 'blank';

    my $c = $CMD{ $a->{key} // '' };
    $r{message} = "$c->{name} needs $a->{msg}" if $c && $a->{status} eq 'incomplete';

    #--------------------------------------------- which field is the cursor in
    # Words before the cursor; if the cursor sits inside or at the end of a
    # word, that word is the current one, otherwise a new one is starting.
    my $before = substr(strip_comment($line), 0, $cursor);
    my @w = split ' ', $before;
    my $idx = $before =~ /\S\z/ ? $#w : scalar @w;
    if ($c) {
        my @fields = template_fields($c);
        my $nfix = @{ $c->{fixed} };
        my $cur;
        if ($idx <= 0) {
            $cur = -1;
        } elsif ($a->{key} eq 'TITLE' || ($a->{key} eq 'PROJECT' && $idx > 2)) {
            $cur = $#{ $c->{fixed} };
        } elsif ($idx <= $nfix && !(defined $w[$idx] && $w[$idx] =~ /=/)) {
            $cur = $idx - 1;
        } elsif (defined $w[$idx] && $w[$idx] =~ /^([^=]+)=/) {
            my $k = uc($1) . '=';
            ($cur) = grep { $fields[$_] eq $k } 0 .. $#fields;
            $cur //= $#fields;
        } else {
            # Past the fixed fields: the rest field (fittings, curve points)
            # if the command has one, else its first option.  Either way it is
            # the field just after the fixed ones in the template.
            $cur = $nfix;
            $cur = $#fields if $cur > $#fields;
        }
        $r{template} = { command => $c->{name}, text => template_text($a->{key}),
                         fields => \@fields, current => $cur };

        #------------------------------------------------------- pick lists
        my $field = $cur >= 0 ? $fields[$cur] : '';
        if ($a->{key} eq 'USE' && $cur == 0) {
            $r{choices} = [ pipe_type_choices() ];
        } elsif ($a->{key} eq 'PIPE' && $field eq 'fittings ...') {
            my $sz = $a->{pos}[4];
            my $dn = defined $sz && HardyCross::Parse::is_num($sz) ? int($sz + 0.5) : undef;
            $r{choices} = [ fitting_choices($use->{type}, $dn) ];
        }
    } else {
        $r{template} = { command => '', text => '', fields => [], current => -1 };
    }
    return \%r unless $r{status} eq 'ok';

    #---------------------------------------------------- the parser's verdict
    my $net = HardyCross::Parse::new_net();
    my $ok = eval {
        my $units = $ctx->{units} || {};
        HardyCross::set_unit($net, $_, uc $units->{$_}) for grep { $units->{$_} } @UNIT_KEYS;
        my $opts = $ctx->{options} || {};
        HardyCross::Parse::parse_row($net, 'OPTIONS', [ $_, $opts->{$_} ])
            for grep { defined $opts->{$_} } sort keys %$opts;
        my $k = $a->{key};
        if ($k eq 'UNITS') {
            HardyCross::set_unit($net, $_, $a->{opt}{$_}) for @{ $a->{optorder} };
        } elsif ($k eq 'METHOD') {
            HardyCross::Parse::parse_row($net, 'OPTIONS', [ 'METHOD', $a->{pos}[0] ]);
        } elsif ($k eq 'OPTION') {
            HardyCross::Parse::parse_row($net, 'OPTIONS', [ @{ $a->{pos} } ]);
        } elsif ($CMD{$k}{kind} eq 'element' || $k eq 'NODE') {
            my ($blk, $row) = hcx_row($a, $use);
            HardyCross::Parse::parse_row($net, $blk, [ HardyCross::Parse::tokenize($row) ]);
        }
        1;
    };
    unless ($ok) {
        my $e = $@;
        die $e unless HardyCross::is_model_error($e);
        @r{qw(status message)} = ('error', $e->{msg});
        return \%r;
    }

    #------------------------------------------------- nodes, and what is next
    my $known = $ctx->{nodes};
    if ($known) {
        my %k = ref $known eq 'HASH' ? %$known : map { $_ => 1 } @$known;
        $r{undefined} = [ grep { !$k{$_} } nodes_used($a) ];
    }
    $r{proposal} = propose($line);
    return \%r;
}

1;
