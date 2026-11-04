#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# FastEntry.pm -- decisions for the fast-entry window, without Tk.
#
# phcp_fast.pl is a second window onto the same .phc file the text editor
# edits.  Nothing here touches the editor.  A row becomes ordinary command
# lines, checked by HardyCross::Phc and HardyCross::Editor, so a line this
# window accepts is a line the solver accepts, and the text editor opens the
# file unchanged.
#
# Why the row works the way it does.  Almost every model is the same few
# commands repeated: a pipe run, a row of heads, a line of nodes.  The time
# goes on the keystrokes that do not change between one line and the next,
# and on leaving the keyboard to point at something.  So:
#
#   - the command is chosen once and stays until the next one is chosen
#   - a field that usually repeats (length, size, fittings, elevation, K) is
#     kept and offered again, already filled in
#   - the next pipe starts where the last one ended, and names step, using
#     the same proposal the text editor makes -- then fittings are put back,
#     because the editor's proposal drops them and a run usually keeps them
#   - a whole run is one name: P1-P12 or P1X12, H1-H15, N1-N20.  It expands
#     to ordinary lines.  There is no second file format
#   - one key copies a field from the previous line of the same command
#   - Enter adds the row.  Nothing is added that the reader would refuse
#
# The window draws.  This module decides.

package HardyCross::FastEntry;

use strict;
use warnings;
use HardyCross::Phc;
use HardyCross::Editor;

# A run longer than this is refused.  A real range of heads or nodes fits
# well under it; a slip (P1-P10000) should not write thousands of lines.
my $MAX_RUN = 500;

#==============================================================================
# The modes.  One command, the fields in the order the line carries them.
#
# sticky   offered again next time, over the top of the proposal
# rest     the remainder of the line (fittings, pairs, copies, names)
# opt      an optional field (HardyCross::Phc's opt list)
# text     the rest of the line is one value (a file name)
# burst    a range or a count in this field adds one line per name
# expand   a range or a count in this field adds names on the SAME line
# chain    a pipe run: each pipe starts where the previous one ended
# follow   on a run, these fields step with the name (or zip, if each is a run)
#==============================================================================

my @MODES = (
    { key => 'USE', hotkey => 'U', group => 'PIPES', bar => 1,
      fields => [ f('PIPETYPE'), f('C', opt => 1) ],
      hint => 'THE PIPE TYPE USED BY LINES ADDED AT THE END. ENTER PUTS A USE LINE IN THE FILE WHEN IT DIFFERS FROM THE ONE IN FORCE. C BLANK KEEPS THE C ALREADY IN FORCE.' },
    { key => 'PIPE', hotkey => 'P', group => 'PIPES', chain => 1,
      fields => [ f('NAME', burst => 1), f('START'), f('END'),
                  f('LENGTH', sticky => 1), f('SIZE', sticky => 1), f('FITTINGS', sticky => 1, rest => 1) ],
      hint => 'ENTER ADDS THE ROW. A PROPOSED VALUE IS ALREADY FILLED IN: TYPE OVER IT, OR ENTER TO ACCEPT IT. TAB MOVES ON. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS PIPE. A NAME P1-P12 OR P1X12 ADDS THE WHOLE RUN, EACH PIPE STARTING WHERE THE LAST ENDED. LENGTH, SIZE AND FITTINGS STAY UNTIL YOU CHANGE THEM.' },
    { key => 'PC', hotkey => 'X', group => 'PIPES',
      fields => [ f('SOURCE'), f('COPIES', rest => 1) ],
      hint => 'ENTER ADDS THE ROW. COPIES ARE NAME START END, REPEATED. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS LINE.' },
    { key => 'CHANGEPIPE', hotkey => 'K', group => 'PIPES',
      fields => [ f('PIPE'), f('LENGTH', sticky => 1), f('SIZE', sticky => 1), f('FITTINGS', sticky => 1, rest => 1) ],
      hint => 'ENTER ADDS THE ROW. LENGTH, SIZE AND FITTINGS STAY UNTIL YOU CHANGE THEM. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS LINE.' },
    { key => 'EQV', hotkey => 'E', group => 'PIPES',
      fields => [ f('PIPE'), f('LENGTH', sticky => 1) ],
      hint => 'ENTER ADDS THE ROW. THE LENGTH STAYS UNTIL YOU CHANGE IT. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS LINE.' },

    { key => 'NODE', hotkey => 'N', group => 'NODES',
      fields => [ f('NAME', burst => 1), f('ELEVATION', sticky => 1) ],
      hint => 'ENTER ADDS THE ROW. THE ELEVATION STAYS. A NAME N1-N20 OR N1X20 ADDS EACH NODE AT THAT ELEVATION. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS NODE.' },
    { key => 'NC', hotkey => 'C', group => 'NODES',
      fields => [ f('SOURCE'), f('NAMES', rest => 1, expand => 1) ],
      hint => 'ENTER ADDS THE ROW. A RANGE IN THE NAMES, N2-N20, BECOMES EACH NAME ON THE ONE LINE. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS LINE.' },
    { key => 'WATER', hotkey => 'W', group => 'NODES',
      fields => [ f('NAME', burst => 1), f('ELEVATION', sticky => 1), f('STATIC', sticky => 1), f('POINTS', rest => 1) ],
      hint => 'ENTER ADDS THE ROW. ELEVATION AND STATIC STAY. EXTRA FLOW AND PRESSURE PAIRS GO IN POINTS. A NAME W1-W2 ADDS EACH SUPPLY THE SAME. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS LINE.' },
    { key => 'SPRINKLER', hotkey => 'S', group => 'NODES',
      fields => [ f('NAME', burst => 1), f('ELEVATION', sticky => 1), f('MINFLOW', sticky => 1), f('K', sticky => 1) ],
      hint => 'ENTER ADDS THE ROW. ELEVATION, MINFLOW AND K STAY. A NAME H1-H15 OR H1X15 ADDS EACH HEAD THE SAME. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS HEAD.' },
    { key => 'HYDRANT', hotkey => 'H', group => 'NODES',
      fields => [ f('NAME', burst => 1), f('ELEVATION', sticky => 1), f('MINFLOW', sticky => 1), f('K', sticky => 1) ],
      hint => 'ENTER ADDS THE ROW. ELEVATION, MINFLOW AND K STAY. A NAME HY1-HY4 ADDS EACH HYDRANT THE SAME. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS LINE.' },
    { key => 'HREEL', hotkey => 'R', group => 'NODES',
      fields => [ f('NAME', burst => 1), f('ELEVATION', sticky => 1), f('MINFLOW', sticky => 1), f('K', sticky => 1) ],
      hint => 'ENTER ADDS THE ROW. ELEVATION, MINFLOW AND K STAY. A NAME R1-R4 ADDS EACH REEL THE SAME. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS LINE.' },
    { key => 'FIXEDFLOW', hotkey => 'F', group => 'NODES', follow => ['NODE'],
      fields => [ f('NAME', burst => 1), f('NODE'), f('FLOW', sticky => 1), f('MINPRESSURE', sticky => 1, opt => 1) ],
      hint => 'ENTER ADDS THE ROW. FLOW AND MINPRESSURE STAY. ON A RUN THE NODE STEPS WITH THE NAME, UNLESS YOU GIVE A NODE FOR EACH, N1-N5. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS LINE.' },

    { key => 'PUMP', hotkey => 'M', group => 'DEVICES',
      fields => [ f('NAME'), f('IN'), f('OUT'), f('CHURN', sticky => 1), f('POINTS', rest => 1) ],
      hint => 'ENTER ADDS THE ROW. CHURN STAYS. POINTS IS FLOW PRESSURE, THEN ANOTHER PAIR, AND SO ON. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS PUMP.' },
    { key => 'PUMPDUTY', hotkey => 'Y', group => 'DEVICES',
      fields => [ f('PUMP'), f('FLOW', sticky => 1), f('PRESSURE', sticky => 1) ],
      hint => 'ENTER ADDS THE ROW. FLOW AND PRESSURE STAY. THE PUMP IS A PUMP NAME OR THE PIPE A BP SITS IN. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS LINE.' },
    { key => 'BP', hotkey => 'B', group => 'DEVICES',
      fields => [ f('PIPE'), f('CHURN', sticky => 1), f('POINTS', rest => 1) ],
      hint => 'ENTER ADDS THE ROW. CHURN STAYS. POINTS IS FLOW PRESSURE PAIRS. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS LINE.' },
    { key => 'BFP', hotkey => 'L', group => 'DEVICES',
      fields => [ f('PIPE'), f('POINTS', rest => 1) ],
      hint => 'ENTER ADDS THE ROW. POINTS IS FLOW LOSS PAIRS. ONE PAIR AT FLOW 0 IS A FIXED LOSS. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS LINE.' },
    { key => 'PRV', hotkey => 'V', group => 'DEVICES',
      fields => [ f('PIPE'), f('POINTS', rest => 1) ],
      hint => 'ENTER ADDS THE ROW. POINTS IS FLOW LOSS PAIRS. ONE PAIR AT FLOW 0 IS A FIXED DROP. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS LINE.' },
    { key => 'OPP', hotkey => 'O', group => 'DEVICES',
      fields => [ f('PIPE'), f('DROP'), f('CD', opt => 1) ],
      hint => 'ENTER ADDS THE ROW. THE PLATE IS SIZED FOR THE DROP. CD BLANK IS 0.596. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS LINE.' },
    { key => 'OFD', hotkey => 'D', group => 'DEVICES',
      fields => [ f('PIPE'), f('BORE'), f('CD', opt => 1) ],
      hint => 'ENTER ADDS THE ROW. THE BORE IS GIVEN AND THE DROP IS CALCULATED. CD BLANK IS 0.596. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS LINE.' },
    { key => 'PRA', hotkey => 'T', group => 'DEVICES',
      fields => [ f('PIPE'), f('RATIO'), f('MININLET', opt => 1), f('BAND', opt => 1) ],
      hint => 'ENTER ADDS THE ROW. THE RATIO IS WRITTEN 3:1 OR 1.5. MININLET BLANK IS NONE, BAND BLANK IS 5. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS LINE.' },

    { key => 'AREA', hotkey => 'A', group => 'OTHER',
      fields => [ f('NAME'), f('OUTLETS', rest => 1, expand => 1) ],
      hint => 'ENTER ADDS THE ROW. A RANGE IN THE OUTLETS, H1-H20, BECOMES EACH OUTLET ON THE ONE LINE. A SECOND LINE OF THE SAME NAME ADDS TO THE AREA. TAB MOVES. APOSTROPHE COPIES THAT FIELD FROM THE PREVIOUS LINE.' },
    { key => 'SUPPLYGRAPH', hotkey => 'G', group => 'OTHER',
      fields => [ f('FILE', text => 1) ],
      hint => 'ENTER ADDS THE ROW. THE FILE IS A WATER SUPPLY GRAPH, FROM THE MODEL\'S FOLDER. TAB MOVES.' },
    { key => 'LINE', hotkey => 'I', group => 'OTHER', raw => 1,
      fields => [ f('TEXT') ],
      hint => 'THE WHOLE LINE, AS IT WILL STAND IN THE FILE. FOR A COMMENT, START WITH //. SETTINGS BELONG IN THE BAR ABOVE, NOT ON A LINE HERE.' },
);
my %MODE = map { $_->{key} => $_ } @MODES;
my %HOT  = map { $_->{hotkey} => $_->{key} } grep { $_->{hotkey} } @MODES;

sub f {
    my ($key, %o) = @_;
    return { key => $key, %o };
}

# modes -- every mode, in the order the window shows them.
sub modes { return @MODES }

# mode -- one mode by its command word, or undef.
sub mode { return $MODE{ uc(shift // '') } }

# hotkey -- the command word a single letter stands for, or undef.
sub hotkey { return $HOT{ uc(shift // '') } }

# groups -- the mode keys in each group, in strip order.  USE is not listed:
# the window keeps it in the bar above the row, where it applies to every
# line added afterwards.
sub groups {
    my %g;
    for my $m (@MODES) {
        next if $m->{bar};
        push @{ $g{ $m->{group} } }, $m->{key};
    }
    return map { [ $_, @{ $g{$_} || [] } ] } grep { $g{$_} } qw(PIPES NODES DEVICES OTHER);
}

# hint_for -- the one line under the row for this command.
sub hint_for {
    my $m = mode(shift) or return '';
    return $m->{hint};
}

# template_for -- the command's field template, as the text editor's status
# bar shows it.  LINE has none: it is the line itself.
sub template_for {
    my $m = mode(shift) or return '';
    return '' if $m->{raw};
    return HardyCross::Phc::template_text($m->{key});
}

#==============================================================================
# Names written as a run.
#==============================================================================

# expand_token -- one token as the list of names it stands for.
#
#   P1-P12    P1 .. P12     P1x12     P1*12     P1X12
#   spaces around the mark are ignored: "P1 - P12"
#
# A token with no mark is itself.  A mark that is not a run is an error,
# so a hyphenated slip is reported rather than stored as a name.
# Returns { ok, ids, message }.
sub expand_token {
    my $raw = shift // '';
    my $t = $raw;
    $t =~ s/^\s+|\s+\z//g;
    return { ok => 1, ids => [] } if $t eq '';
    (my $flat = $t) =~ s/\s+//g;

    if ($flat =~ /^(.*?)(\d+)(?:x|\*)(\d+)\z/i) {
        my ($pre, $start, $count) = ($1, $2, $3 + 0);
        return { ok => 0, message => 'A RUN NEEDS AT LEAST ONE' } if $count < 1;
        return { ok => 0, message => "A RUN IS AT MOST $MAX_RUN" } if $count > $MAX_RUN;
        my @ids;
        my $id = $pre . $start;
        for (1 .. $count) {
            push @ids, $id;
            $id = HardyCross::Phc::step_id($id);
        }
        return { ok => 1, ids => \@ids };
    }
    if ($flat =~ /^(.*?)(\d+)(?:\.\.|-)(.*)\z/) {
        my ($pre, $start, $rest) = ($1, $2, $3);
        if ($rest =~ /^(.*?)(\d+)\z/ && $1 eq $pre) {
            my ($from, $to) = ($start + 0, $2 + 0);
            return { ok => 0, message => 'A RUN GOES UPWARD, LOW TO HIGH' } if $to < $from;
            return { ok => 0, message => "A RUN IS AT MOST $MAX_RUN" } if $to - $from + 1 > $MAX_RUN;
            my @ids;
            my $id = $pre . $start;
            for (1 .. $MAX_RUN + 1) {
                push @ids, $id;
                last if $id =~ /(\d+)\z/ && $1 == $to;
                $id = HardyCross::Phc::step_id($id);
            }
            return { ok => 1, ids => \@ids };
        }
        return { ok => 0, message => 'A RUN KEEPS ONE PREFIX, AS IN P1-P12 OR N1-N20' };
    }
    return { ok => 1, ids => [ $t ] };
}

# looks_like_run -- true when the token has a run mark, whether or not the
# two ends agree.  Used to refuse a run on a command that adds one line.
sub looks_like_run {
    my $t = shift // '';
    $t =~ s/\s+//g;
    return $t =~ /\d(?:x|\*)\d\z/i || $t =~ /\d(?:\.\.|-)\D*\d\z/;
}

#==============================================================================
# Lines in the network.
#==============================================================================

# net_lines -- the network as lines, with no trailing blank from the final
# newline.  An empty network is an empty list.
sub net_lines {
    my $t = shift // '';
    return () if $t !~ /\S/;
    $t =~ s/\n\z//;
    return split /\n/, $t, -1;
}

# net_text -- lines back to the network text the editor keeps: a trailing
# newline when there is anything, and nothing at all when there is not.
sub net_text {
    my @l = @_;
    return @l ? join("\n", @l) . "\n" : '';
}

# replace_line -- the network with line $n (from 1) replaced.  Undef when
# there is no such line.
sub replace_line {
    my ($network, $n, $line) = @_;
    my @l = net_lines($network);
    return undef if $n < 1 || $n > @l;
    $l[ $n - 1 ] = $line;
    return net_text(@l);
}

# delete_line -- the network without line $n.  Undef when there is no such line.
sub delete_line {
    my ($network, $n) = @_;
    my @l = net_lines($network);
    return undef if $n < 1 || $n > @l;
    splice @l, $n - 1, 1;
    return net_text(@l);
}

# append_lines -- the network with lines added at the end.
sub append_lines {
    my ($network, @add) = @_;
    return net_text(net_lines($network), @add);
}

#==============================================================================
# A line taken apart, and put back together.
#==============================================================================

sub squash {
    my $s = shift // '';
    $s =~ s/^\s+|\s+\z//g;
    $s =~ s/\s+/ /g;
    return $s;
}

# fields_of_line -- a network line as the row that edits it.
#
# { ok, command, values => { NAME => ... }, message }
# A comment, a blank, or a line with no mode is command LINE and the whole
# line is TEXT, so it can be put back as it was.  ok is false when the line
# does not read: the window still offers it as TEXT, and says why.
sub fields_of_line {
    my $line = shift // '';
    if ($line !~ /\S/ || $line =~ /^\s*\/\//) {
        return { ok => 1, command => 'LINE', values => { TEXT => $line }, message => '' };
    }
    my $a = HardyCross::Phc::analyse($line);
    my $m = $a->{key} ? mode($a->{key}) : undef;
    # A line that does not read, or is not one of the row commands, is handed
    # back whole.  The window offers it as text so it can be repaired, and
    # nothing is lost.
    if ($a->{status} ne 'ok' || !$m || $m->{raw}) {
        return { ok => $a->{status} eq 'ok' ? 1 : 0, command => 'LINE',
                 values => { TEXT => $line },
                 message => $a->{status} eq 'ok' ? '' : ($a->{msg} // '') };
    }
    my %v;
    my ($pi, $oi) = (0, 0);
    for my $fd (@{ $m->{fields} }) {
        if    ($fd->{rest}) { $v{ $fd->{key} } = join ' ', @{ $a->{rest} } }
        elsif ($fd->{text}) { $v{ $fd->{key} } = $a->{text} // '' }
        elsif ($fd->{opt})  { $v{ $fd->{key} } = $a->{opt}[$oi++] // '' }
        else                 { $v{ $fd->{key} } = $a->{pos}[$pi++] // '' }
    }
    return { ok => 1, command => $m->{key}, values => \%v, message => '' };
}

# line_of -- one row as one command line, command padded as the files are.
# A LINE row is stored as typed, trailing spaces removed, so a comment keeps
# its wording.
sub line_of {
    my ($mode_key, $values) = @_;
    my $m = ref $mode_key ? $mode_key : mode($mode_key);
    return '' unless $m;
    if ($m->{raw}) {
        my $t = $values->{TEXT} // '';
        $t =~ s/[ \t]+\z//;
        return $t;
    }
    my @p;
    for my $fd (@{ $m->{fields} }) {
        push @p, squash($values->{ $fd->{key} } // '');
    }
    pop @p while @p && $p[-1] eq '';
    return sprintf '%-9s %s', $m->{key}, join(' ', @p);
}

#==============================================================================
# What the next row offers.
#==============================================================================

# last_of -- the 1-based index of the last line of this command, or undef.
sub last_of {
    my ($network, $mode_key) = @_;
    my @l = net_lines($network);
    for my $i (reverse 1 .. @l) {
        my $f = fields_of_line($l[ $i - 1 ]);
        return $i if $f->{ok} && $f->{command} eq $mode_key;
    }
    return undef;
}

# sticky_of -- the fields of this row that should be offered again.
sub sticky_of {
    my ($mode_key, $values) = @_;
    my $m = mode($mode_key) or return {};
    my %s;
    for my $fd (@{ $m->{fields} }) {
        $s{ $fd->{key} } = squash($values->{ $fd->{key} } // '') if $fd->{sticky};
    }
    return \%s;
}

# sticky_from_network -- those fields, taken from the last line of the
# command in the file.  The window uses this when a file is opened, so the
# first row continues the file instead of starting blank.
sub sticky_from_network {
    my ($network, $mode_key) = @_;
    my $i = last_of($network, $mode_key) or return {};
    my $f = fields_of_line((net_lines($network))[ $i - 1 ]);
    return sticky_of($mode_key, $f->{values});
}

# next_ghosts -- the values to fill the row with.
#
# The text editor's proposal (the name stepped, a pipe starting where the
# last ended, stepped again past a name already used) is the starting point.
# Sticky fields are then written over it.  That is deliberate for fittings:
# the proposal drops them, and a run of pipes usually keeps the same ones.
# $sticky is the session's values; a key that exists is used even when it is
# empty, so clearing fittings and adding the row keeps them clear.
sub next_ghosts {
    my ($network, $mode_key, $sticky) = @_;
    my $m = mode($mode_key) or return {};
    $sticky ||= {};
    my %g;
    my $i = last_of($network // '', $m->{key});
    if ($i) {
        my $p = HardyCross::Editor::proposal($network, $i);
        if (defined $p) {
            my $f = fields_of_line($p);
            %g = %{ $f->{values} } if $f->{ok} && $f->{command} eq $m->{key};
        }
    }
    for my $fd (@{ $m->{fields} }) {
        $g{ $fd->{key} } = $sticky->{ $fd->{key} } if $fd->{sticky} && exists $sticky->{ $fd->{key} };
    }
    return \%g;
}

# ditto -- one field from the previous line of this command, or undef.
# $except (a 1-based line) is skipped, so editing a line does not copy it
# onto itself.
sub ditto {
    my ($network, $mode_key, $field, $except) = @_;
    my @l = net_lines($network);
    for my $i (reverse 1 .. @l) {
        next if defined $except && $i == $except;
        my $f = fields_of_line($l[ $i - 1 ]);
        next unless $f->{ok} && $f->{command} eq uc($mode_key // '');
        my $v = $f->{values}{$field};
        return $v if defined $v && $v ne '';
    }
    return undef;
}

#==============================================================================
# The pipe type in force.
#==============================================================================

# use_in_force -- { type, c } at the end of the network.  Before any USE the
# type is BORE and c is unset (the reader takes C 120).
sub use_in_force {
    my ($settings, $network) = @_;
    my $s = $settings || HardyCross::Editor::new_settings();
    my ($full) = HardyCross::Editor::join_file($s, $network // '');
    my $scan = HardyCross::Editor::scan($full);
    my $u = $scan->{use_at}[-1] || { type => 'BORE' };
    return { type => $u->{type} // 'BORE', c => $u->{c} };
}

# same_use -- whether $want ({ type, c }) would leave the network as it is.
# A blank C means "keep the C in force".  BORE with C 120 and no USE line is
# the reader's own default, so it does not need a line to say so.
sub same_use {
    my ($have, $want) = @_;
    my $ht = uc($have->{type} // 'BORE');
    my $wt = uc($want->{type} // '');
    return 0 if $wt eq '' || $ht ne $wt;
    my $wc = squash($want->{c} // '');
    return 1 if $wc eq '';
    my $hc = $have->{c};
    return 1 if defined $hc && "$hc" eq $wc;
    return 1 if !defined $hc && $ht eq 'BORE' && $wc eq '120';
    return 0;
}

# use_line -- the USE line $want asks for, or undef when it is already in force.
sub use_line {
    my ($settings, $network, $want) = @_;
    return undef unless $want && length($want->{type} // '');
    my $have = use_in_force($settings, $network);
    return undef if same_use($have, $want);
    my $c = squash($want->{c} // '');
    my $body = $c ne '' ? uc($want->{type}) . ' ' . $c : uc($want->{type});
    return sprintf '%-9s %s', 'USE', $body;
}

#==============================================================================
# Adding a row.
#==============================================================================

# expand_row -- the command lines one row stands for.
# Returns ( $lines, $error, $field ) -- $lines is undef when $error is set.
sub expand_row {
    my ($mode_key, $values) = @_;
    my $m = ref $mode_key ? $mode_key : mode($mode_key);
    return (undef, 'UNKNOWN COMMAND', undef) unless $m;
    my %v = map { $_ => $values->{$_} } keys %{ $values || {} };

    if ($m->{raw}) {
        my $t = $v{TEXT} // '';
        $t =~ s/[ \t]+\z//;
        return (undef, 'THE LINE IS EMPTY', 'TEXT') if $t !~ /\S/;
        my $a = HardyCross::Phc::analyse($t);
        if ($a->{status} eq 'ok' && $a->{key}) {
            my $c = HardyCross::Phc::command_spec($a->{key});
            return (undef, "$c->{name} IS SET IN THE BAR ABOVE, NOT ON A LINE", 'TEXT')
                if $c && $c->{kind} eq 'setting';
        }
        return ([ $t ], undef, undef);
    }

    my $gap;
    for my $fd (@{ $m->{fields} }) {
        my $val = squash($v{ $fd->{key} } // '');
        if ($val eq '') { $gap //= $fd->{key} unless $fd->{rest} }
        elsif ($gap) {
            return (undef, "$gap IS EMPTY AND $fd->{key} IS SET. FIELDS GO BY POSITION, SO A LATER FIELD CANNOT SKIP AN EARLIER ONE", $gap);
        }
    }

    # A run mark in a field that is not expanded is a slip (a pump named
    # PM1x2, a length written 3-6).  A field the run steps - a fixed flow's
    # node - is allowed to be a run of its own, and is zipped below.
    my %steps = map { $_ => 1 } @{ $m->{follow} || [] };
    for my $fd (@{ $m->{fields} }) {
        next if $fd->{burst} || $fd->{expand} || $fd->{rest} || $steps{ $fd->{key} };
        my $val = squash($v{ $fd->{key} } // '');
        if (looks_like_run($val)) {
            return (undef, 'A RUN IS FOR A PIPE, A NODE, AN OUTLET, A WATER SUPPLY OR A FIXED FLOW', $fd->{key});
        }
    }

    my ($burst) = grep { $_->{burst} } @{ $m->{fields} };
    my @ids;
    if ($burst && squash($v{ $burst->{key} } // '') ne '') {
        my $ex = expand_token($v{ $burst->{key} });
        return (undef, $ex->{message}, $burst->{key}) unless $ex->{ok};
        @ids = @{ $ex->{ids} };
    }

    if (@ids > 1 && $m->{chain}) {
        for my $need (qw(START END)) {
            return (undef, "$need IS EMPTY. A RUN OF PIPES NEEDS THE FIRST PIPE'S START AND END; EACH LATER PIPE STARTS WHERE THE ONE BEFORE IT ENDED", $need)
                if squash($v{$need} // '') eq '';
            my $ex = expand_token($v{$need});
            return (undef, $ex->{message}, $need) unless $ex->{ok};
            return (undef, "$need IS ONE NODE. A RUN STEPS IT: THE NEXT PIPE STARTS WHERE THIS ONE ENDED", $need)
                if @{ $ex->{ids} } > 1;
        }
    }

    my %follow;
    for my $k (@{ $m->{follow} || [] }) {
        my $ex = expand_token($v{$k} // '');
        return (undef, $ex->{message}, $k) unless $ex->{ok};
        if (@{ $ex->{ids} } > 1) {
            return (undef, "$k HAS " . @{ $ex->{ids} } . " NAMES AND THE RUN HAS " . scalar(@ids)
                    . ". GIVE ONE NAME AND THE RUN STEPS IT, OR THE SAME COUNT AS THE RUN", $k)
                if @{ $ex->{ids} } != @ids;
            $follow{$k} = $ex->{ids};
        }
    }

    my %expanded;
    for my $fd (@{ $m->{fields} }) {
        next unless $fd->{expand};
        my @out;
        for my $tok (split ' ', squash($v{ $fd->{key} } // '')) {
            my $ex = expand_token($tok);
            return (undef, $ex->{message}, $fd->{key}) unless $ex->{ok};
            push @out, @{ $ex->{ids} };
        }
        $expanded{ $fd->{key} } = \@out;
    }

    @ids = (undef) unless @ids;
    my @lines;
    my %prev;
    for my $i (0 .. $#ids) {
        my %row = %v;
        $row{ $burst->{key} } = $ids[$i] if $burst && defined $ids[$i];
        if ($m->{chain} && $i > 0) {
            $row{START} = $prev{END};
            $row{END} = HardyCross::Phc::step_id($prev{END});
        }
        for my $k (@{ $m->{follow} || [] }) {
            if ($follow{$k}) {
                $row{$k} = $follow{$k}[$i];
            } elsif ($i > 0 && defined $prev{$k} && $prev{$k} ne '') {
                $row{$k} = HardyCross::Phc::step_id($prev{$k});
            }
        }
        $row{$_} = join(' ', @{ $expanded{$_} }) for keys %expanded;
        push @lines, line_of($m, \%row);
        %prev = map { $_ => squash($row{$_} // '') } keys %row;
    }
    return (\@lines, undef, undef);
}

# blame -- which field a checker's message is about, so the window can put
# the cursor there.
sub blame {
    my ($mode_key, $message, $values) = @_;
    my $m = ref $mode_key ? $mode_key : mode($mode_key);
    return undef unless $m && defined $message;
    for my $fd (@{ $m->{fields} }) {
        return $fd->{key} if $message =~ /\bNEEDS \Q$fd->{key}\E\b/;
        return $fd->{key} if $message =~ /\b\Q$fd->{key}\E IS EMPTY\b/;
    }
    return 'POINTS'   if $message =~ /FLOW PRESSURE|PAIR WITH FLOW|FLOWS AND PRESSURES/;
    return 'COPIES'   if $message =~ /NAME START END/;
    return 'OUTLETS'  if $message =~ /\bOUTLET\b/;
    return 'FITTINGS' if $message =~ /FITTING/;
    return 'TEXT'     if $m->{raw};
    if ($message =~ /(?:NODE|NAME) (\S+) IS ALREADY/) {
        my $name = $1;
        for my $fd (@{ $m->{fields} }) {
            my $val = squash($values->{ $fd->{key} } // '');
            return $fd->{key} if grep { $_ eq $name } split ' ', $val;
        }
        return $m->{fields}[0]{key};
    }
    return $m->{fields}[0]{key};
}

# preview -- the first line of the row, checked as it is typed.
#
# { status, message, field, count, choices, template }
# count is how many lines Enter would add.  Only the first is checked here;
# plan checks every line when the row is added.  choices is the pick list for
# $field (a pipe type or a fitting).
sub preview {
    my (%a) = @_;
    my $m = mode($a{mode});
    return { status => 'error', message => 'UNKNOWN COMMAND', field => undef, count => 0 }
        unless $m;
    my ($lines, $err, $field) = expand_row($m, $a{values} || {});
    if ($err) {
        return { status => 'error', message => $err, field => $field, count => 0, template => template_for($m->{key}) };
    }
    my $one = preview_line($a{settings}, $a{network}, $lines->[0], $a{field});
    $one->{count} = @$lines;
    $one->{template} = template_for($m->{key});
    $one->{field} = blame($m, $one->{message}, $a{values}) if $one->{status} ne 'ok' && !defined $one->{field};
    return $one;
}

# preview_line -- check_line for a line that is not in the network yet.
sub preview_line {
    my ($settings, $network, $line, $field) = @_;
    my $s = $settings || HardyCross::Editor::new_settings();
    my $temp = append_lines($network // '', $line);
    my ($full, $h) = HardyCross::Editor::join_file($s, $temp);
    my $n = $h + scalar(net_lines($temp));
    my $ctx = HardyCross::Editor::context_at($full, $n);
    $ctx->{cursor} = length($line);
    # An empty fittings field is a new word only when the line ends in a
    # space; otherwise the cursor is still in SIZE.  The window asks for
    # fittings with the field name.
    if (($field // '') eq 'FITTINGS') {
        my $base = $line;
        $base =~ s/\s+\z//;
        $line = $base . ' ';
        $ctx->{cursor} = length($line);
        # The line checked is the one with the trailing space, so the cursor
        # is past SIZE.  check_line tokenises that.
        my $r = HardyCross::Phc::check_line($line, $ctx);
        return { status => 'ok', message => '', field => undef, choices => $r->{choices} || [] };
    }
    my $r = HardyCross::Phc::check_line($line, $ctx);
    return { status => $r->{status}, message => $r->{message} // '', field => undef,
             choices => $r->{choices} || [] };
}

# choices_for -- the pick list for one field of the row: pipe types in a USE
# type, fittings on a pipe.
sub choices_for {
    my (%a) = @_;
    my $p = preview(%a, field => $a{field});
    return $p->{choices} || [];
}

# complete -- the codes in a pick list that start with $prefix.
# { matches => [ [code, description] ... ], unique => code or undef }
sub complete {
    my ($prefix, $choices) = @_;
    $prefix = uc($prefix // '');
    my @hit = grep { $prefix eq '' || index(uc($_->[0]), $prefix) == 0 } @{ $choices || [] };
    return { matches => \@hit, unique => (@hit == 1 ? $hit[0][0] : undef) };
}

#------------------------------------------------------------------------------
# plan -- add the row, or refuse it.
#
#   settings     the document settings (HardyCross::Editor::new_settings)
#   network      the network text
#   mode         the command
#   values       { FIELD => text }
#   use          { type, c }: the USE bar.  Used only when appending, and
#                only when it differs from the type in force -- a USE line is
#                put in immediately before the new lines
#   edit         1-based line to replace.  A run cannot replace one line
#
# Returns { ok, network, lines, message, field, warnings }.
# The caller's network is not changed; on failure no network is returned.
# warnings are nodes the new lines use that nothing has defined yet -- the
# row is still added, because a .phc file may name a node before it defines it.
#------------------------------------------------------------------------------
sub plan {
    my (%a) = @_;
    my $m = mode($a{mode});
    return _no('UNKNOWN COMMAND') unless $m;
    my $settings = $a{settings} || HardyCross::Editor::new_settings();
    my $network = $a{network} // '';

    my ($lines, $err, $field) = expand_row($m, $a{values} || {});
    return _no($err, $field) if $err;

    if ($a{edit} && @$lines != 1) {
        return _no('A RUN IS ADDED AT THE END. THIS LINE IS BEING EDITED, SO IT STAYS ONE LINE',
                   (grep { $_->{burst} } @{ $m->{fields} })[0]{key} // $m->{fields}[0]{key});
    }

    my @add = @$lines;
    if (!$a{edit} && $m->{key} ne 'USE' && $m->{key} ne 'LINE') {
        my $u = use_line($settings, $network, $a{use});
        unshift @add, $u if defined $u;
    }

    my $net = $a{edit}
        ? replace_line($network, $a{edit}, $add[0])
        : append_lines($network, @add);
    return _no('THERE IS NO LINE ' . $a{edit}) if !defined $net;

    my $chk = HardyCross::Editor::doc_check({ settings => $settings, network => $net });
    my $last = net_lines($net);
    my $first = $a{edit} ? $a{edit} : $last - @add + 1;
    my @idx = $a{edit} ? ($a{edit}) : ($first .. $last);
    for my $i (@idx) {
        my $st = $chk->{lines}[$i] || { status => 'error', message => 'THE LINE COULD NOT BE CHECKED' };
        next if $st->{status} eq 'ok';
        return _no($st->{message}, blame($m, $st->{message}, $a{values}), $i);
    }

    my %at = map { $_ => 1 } @idx;
    my @warn;
    for my $u (@{ $chk->{undefined} || [] }) {
        push @warn, "NODE $u->{node} IS NOT DEFINED YET" if $at{ $u->{line} };
    }
    return { ok => 1, network => $net, lines => \@add, message => '', field => undef, warnings => \@warn };
}

sub _no {
    return { ok => 0, message => $_[0] // '', field => $_[1], line => $_[2], warnings => [] };
}

1;
