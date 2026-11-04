#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# HardyCross/Window/Orifice.pm -- part of the editor window and the
# spreadsheet window: the ORIFICE PLATE tab.
#
# The window is split one file to a tab so each can be read on its own.  It
# is still one program: this file is in package main, shares the window's
# globals (declared with our in phcp_editor.pl or phcp_sheet.pl and named
# again below) and its widget helpers, and is loaded by both programs with
# use.  Nothing here decides a bore or a loss.  That is HardyCross::Tools::plate,
# which calls the solver's own orifice routines, so the two windows and a
# model cannot size a plate differently.
#
package main;

use strict;
use warnings;

our ($UI_S_N, %C, $MONO, $MONO_B, $POINTER, $UI, $UI_B, $settings, @dd_refresh);

#==============================================================================
# The ORIFICE PLATE tab: two calculators, side by side.
#
#   SIZE THE PLATE     a pipe, a flow and a net loss: the bore, as OPP sizes
#                      one, rounded to the bore step
#   DROP ACROSS A PLATE  a pipe, a flow and a bore: the net loss, as OFD
#
# Each answers as it is typed, in the units set in the PROJECT tab.  A blank
# CD is 0.596.  A blank bore step is the PROJECT tab's ORIF_STEP, or 0.5 mm
# when that is blank.  Independent of the model, like QUICK TOOLS.
#==============================================================================
our %op = (SIZE => { type => 'ASAM', size => '', flow => '', drop => '', cd => '', step => '' },
           DROP => { type => 'ASAM', size => '', flow => '', bore => '', cd => '' });
our %opw;

sub build_orifice {
    my $page = shift;
    my $bar = $page->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -padx => px(14), -pady => px([10, 8]));
    $opw{units} = $bar->Label(-text => '', -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted},
                              -anchor => 'w', -justify => 'left')->pack(-side => 'left', -fill => 'x');
    rule($page, 'x', -side => 'top');
    my $sb = flat_scrollbar($page, 'vertical')->pack(-side => 'right', -fill => 'y');
    my $cv = $page->Canvas(-background => $C{paper}, -highlightthickness => 0, -borderwidth => 0,
                           -yscrollcommand => sub { $sb->set(@_) })->pack(-fill => 'both', -expand => 1);
    $sb->configure(-command => sub { $cv->yview(@_) });
    my $row = $cv->Frame(-background => $C{paper});
    $cv->createWindow(px(14), px(10), -window => $row, -anchor => 'nw');
    $row->bind('<Configure>' => sub {
        $cv->configure(-scrollregion => [ 0, 0, $row->reqwidth + px(28), $row->reqheight + px(20) ]);
    });
    wheel_target($cv);
    my %col = map { $_ => $row->Frame(-background => $C{paper})->pack(-side => 'left', -fill => 'y', -anchor => 'n',
                                                                      -padx => px([0, 36])) } qw(SIZE DROP);

    my $card = sub {
        my ($mode, $title, $about, $lines) = @_;
        my $c = $col{$mode}->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -anchor => 'n');
        $c->Label(-text => $title, -font => $UI_B, -background => $C{paper}, -foreground => $C{ink}, -anchor => 'w')
          ->pack(-fill => 'x');
        rule($c, 'x', -pady => px([4, 4]));
        $c->Label(-text => $about, -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted},
                  -anchor => 'w', -justify => 'left', -wraplength => px(460))->pack(-fill => 'x', -pady => px([0, 8]));
        my $g = $c->Frame(-background => $C{paper})->pack(-fill => 'x', -anchor => 'w');
        $opw{$mode}{problems} = $c->Label(-text => '', -font => $UI, -background => $C{paper},
            -foreground => $C{error}, -anchor => 'w', -justify => 'left', -wraplength => px(460))
            ->pack(-fill => 'x', -pady => px([8, 4]));
        # Word wrap, so a long note stays inside the card.  The figures
        # themselves are one line: the label column plus the value fit the width.
        $opw{$mode}{result} = $c->Text(-font => $MONO, -height => $lines, -width => 54, -wrap => 'word',
            -relief => 'flat', -borderwidth => 0, -highlightthickness => 0, -background => $C{panel},
            -foreground => $C{ink}, -padx => px(10), -pady => px(8), -cursor => $POINTER, -takefocus => 0)
            ->pack(-fill => 'x');
        $opw{$mode}{result}->tagConfigure('head', -font => $MONO_B);
        $opw{$mode}{result}->tagConfigure('big', -font => $MONO_B, -foreground => $C{accent});
        $opw{$mode}{result}->tagConfigure('muted', -foreground => $C{muted});
        $opw{$mode}{result}->tagConfigure('warn', -foreground => $C{error}, -font => $MONO_B);
        return $g;
    };
    my $r = 0;
    my $label = sub {
        my ($g, $text) = @_;
        $g->Label(-text => $text, -font => $UI, -background => $C{paper}, -foreground => $C{muted}, -anchor => 'w')
          ->grid(-row => $r, -column => 0, -sticky => 'w', -pady => px(3), -padx => px([0, 12]));
    };
    my $entry = sub {
        my ($g, $mode, $field, $width, $note) = @_;
        my $e = flat_entry($g, \$op{$mode}{ lc $field }, $width // 10);
        $e->grid(-row => $r, -column => 1, -sticky => 'w', -pady => px(3), -ipady => px(2));
        $e->bind('<KeyRelease>' => sub { orifice_update($mode) });
        if ($note) {
            my $l = $g->Label(-text => '', -font => $UI_S_N, -background => $C{paper}, -foreground => $C{faint}, -anchor => 'w');
            $l->grid(-row => $r, -column => 2, -sticky => 'w', -padx => px([8, 0]));
            push @{ $opw{notes} }, [ $l, $note, $mode, $field ];
        }
        $opw{$mode}{field}{$field} = $e;
        $r++;
        return $e;
    };
    # The pipe: its type a drop-down of the database's types and BORE, its
    # size a drop-down of that type's sizes, or for BORE a field for the bore.
    my $pipe = sub {
        my ($g, $mode) = @_;
        $label->($g, 'PIPE TYPE');
        my $t = drop_down($g, \$op{$mode}{type}, [ HardyCross::Tools::pipe_types() ], sub {
            $op{$mode}{size} = '';
            orifice_sizes($mode);
            orifice_update($mode);
        });
        $t->grid(-row => $r++, -column => 1, -sticky => 'w', -pady => px(3));
        $opw{$mode}{field}{TYPE} = $t;
        $label->($g, 'SIZE');
        my $f = $g->Frame(-background => $C{paper});
        $f->grid(-row => $r++, -column => 1, -columnspan => 2, -sticky => 'w', -pady => px(3));
        my $mb = $f->Menubutton(-text => '', -font => $MONO, -relief => 'flat', -borderwidth => 0,
            -highlightthickness => 1, -highlightbackground => $C{line}, -background => $C{paper},
            -activebackground => $C{hover}, -foreground => $C{ink}, -anchor => 'w', -width => 11,
            -padx => px(6), -pady => px(3), -indicatoron => 0, -cursor => 'hand2');
        my $m = $mb->Menu(-tearoff => 0, -font => $MONO, -relief => 'flat', -borderwidth => 1,
            -activeborderwidth => 0, -background => $C{paper}, -foreground => $C{ink},
            -activebackground => $C{select}, -activeforeground => $C{ink});
        $mb->configure(-menu => $m);
        my $be = flat_entry($f, \$op{$mode}{size}, 10);
        $be->bind('<KeyRelease>' => sub { orifice_update($mode) });
        my $bn = $f->Label(-text => '', -font => $UI_S_N, -background => $C{paper}, -foreground => $C{faint});
        push @{ $opw{notes} }, [ $bn, 'PIPE BORE, U:SIZE', $mode, '' ];
        @{ $opw{$mode} }{qw(size_mb size_menu size_entry size_note)} = ($mb, $m, $be, $bn);
        $opw{$mode}{field}{SIZE} = $mb;
        orifice_sizes($mode);
    };

    $r = 0;
    my $g = $card->('SIZE', 'SIZE THE PLATE',
        'THE BORE FOR THIS NET LOSS AT THIS FLOW, AS OPP SIZES IT.  ROUNDED TO THE STEP.', 16);
    $pipe->($g, 'SIZE');
    $label->($g, 'FLOW');
    $entry->($g, 'SIZE', 'FLOW', 10, 'U:FLOW');
    $label->($g, 'DROP');
    $entry->($g, 'SIZE', 'DROP', 10, 'U:PRESSURE');
    $label->($g, 'CD');
    $entry->($g, 'SIZE', 'CD', 10, 'BLANK: 0.596');
    $label->($g, 'BORE STEP');
    $entry->($g, 'SIZE', 'STEP', 10, 'BLANK: PROJECT');

    $r = 0;
    $g = $card->('DROP', 'DROP ACROSS A PLATE',
        'THE NET LOSS ACROSS THIS BORE AT THIS FLOW, AS OFD WORKS IT OUT.', 14);
    $pipe->($g, 'DROP');
    $label->($g, 'FLOW');
    $entry->($g, 'DROP', 'FLOW', 10, 'U:FLOW');
    $label->($g, 'PLATE BORE');
    $entry->($g, 'DROP', 'BORE', 10, 'U:SIZE');
    $label->($g, 'CD');
    $entry->($g, 'DROP', 'CD', 10, 'BLANK: 0.596');

    orifice_refresh();
}

# orifice_step_default -- the bore step in millimetres when the field is
# left blank: the PROJECT tab's ORIF_STEP, in the size unit, or 0.5 mm.
sub orifice_step_default {
    my $u = tool_units();
    my $raw = $settings->{options}{ORIF_STEP};
    if (defined $raw && $raw =~ /\S/ && HardyCross::Tools::is_num($raw) && $raw > 0) {
        return $raw * HardyCross::Tools::factor('SIZE', $u->{SIZE});
    }
    return 0.5;
}

# orifice_refresh -- on opening the tab.  Units and the blank bore step come
# from the PROJECT tab, and the sizes from the database as it stands now.
sub orifice_refresh {
    return unless $opw{units};
    my $u = tool_units();
    $opw{units}->configure(-text => sprintf('UNITS AS IN THE PROJECT TAB: FLOW %s, PRESSURE %s, SIZE %s.  '
        . 'INDEPENDENT OF THE MODEL.', map { unit_name($_, $u->{$_}) } qw(FLOW PRESSURE SIZE)));
    my $step = HardyCross::Tools::show('SIZE', orifice_step_default(), $u);
    for my $n (@{ $opw{notes} || [] }) {
        my ($w, $t) = @$n;
        if ($t eq 'BLANK: PROJECT') {
            $w->configure(-text => sprintf('BLANK: %g %s', $step, unit_name('SIZE', $u->{SIZE})));
        } else {
            (my $s = $t) =~ s/U:(\w+)/unit_name($1, $u->{$1})/ge;
            $w->configure(-text => $s);
        }
    }
    $_->() for @dd_refresh;
    for my $mode (qw(SIZE DROP)) {
        $op{$mode}{size} = '' if ($op{$mode}{type} // '') ne $HardyCross::Tools::BORE
            && !grep { $_ eq $op{$mode}{size} } HardyCross::Tools::sizes($op{$mode}{type});
        orifice_sizes($mode);
        orifice_update($mode);
    }
}

# orifice_sizes -- the SIZE choice for a card's pipe type.
sub orifice_sizes {
    my $mode = shift;
    my $w = $opw{$mode} or return;
    my $type = $op{$mode}{type};
    # The choice sits in a frame, packed, as it does on QUICK TOOLS.  An
    # empty menu has no entries; delete is only safe once one has been added.
    $w->{size_menu}->delete(0, 'end') if defined $w->{size_menu}->index('end');
    if ($type eq $HardyCross::Tools::BORE) {
        $w->{size_mb}->packForget;
        $w->{size_entry}->pack(-side => 'left', -ipady => px(2));
        $w->{size_note}->pack(-side => 'left', -padx => px([8, 0]));
        $w->{field}{SIZE} = $w->{size_entry};
    } else {
        $w->{size_entry}->packForget;
        $w->{size_note}->packForget;
        $w->{size_mb}->pack(-side => 'left');
        for my $dn (HardyCross::Tools::sizes($type)) {
            my $su = tool_units()->{SIZE};
            $w->{size_menu}->command(-label => sprintf('DN%-5s %8s %s', $dn,
                    sprintf($su eq 'IN' ? '%.3f' : '%.1f', HardyCross::Tools::show('SIZE', HardyCross::PipeData::bore($type, $dn), { SIZE => $su })),
                    unit_name('SIZE', $su)),
                -command => sub { $op{$mode}{size} = $dn; orifice_update($mode) });
        }
        $w->{field}{SIZE} = $w->{size_mb};
    }
    orifice_show_size($mode);
}

sub orifice_show_size {
    my $mode = shift;
    return if ($op{$mode}{type} // '') eq $HardyCross::Tools::BORE;
    my $s = $op{$mode}{size};
    $opw{$mode}{size_mb}->configure(-text => sprintf('%-9s %s', length $s ? "DN$s" : 'CHOOSE', "\x{25BE}"));
}

# orifice_update -- one card worked out again.
sub orifice_update {
    my $mode = shift;
    my $w = $opw{$mode} or return;
    orifice_show_size($mode);
    my $f = $op{$mode};
    my $u = tool_units();
    my $res = HardyCross::Tools::plate(%$f, mode => $mode, units => $u, step_default => orifice_step_default());
    my $sh = sub { HardyCross::Tools::show($_[0], $_[1], $u) };
    my %un = map { $_ => unit_name($_, $u->{$_}) } keys %$u;
    $opw{$mode}{last} = $res;
    for my $e (values %{ $w->{field} }) { $e->configure(-highlightbackground => $C{line}) }
    my $t = $w->{result};
    $t->configure(-state => 'normal');
    $t->delete('1.0', 'end');
    my @watched = $mode eq 'SIZE' ? qw(size flow drop cd step) : qw(size flow bore cd);
    my $empty = !grep { defined && /\S/ } @{$f}{@watched};
    if (!$res->{ok}) {
        if ($empty) {
            $w->{problems}->configure(-text => '');
            $t->insert('end', $mode eq 'SIZE'
                ? 'CHOOSE A PIPE SIZE, AND GIVE A FLOW AND A DROP.'
                : 'CHOOSE A PIPE SIZE, AND GIVE A FLOW AND A BORE.', 'muted');
        } else {
            $w->{problems}->configure(-text => join "\n", map { $_->[1] } @{ $res->{errors} });
            for my $e (@{ $res->{errors} }) {
                my $fw = $w->{field}{ $e->[0] } or next;
                $fw->configure(-highlightbackground => $C{error});
            }
            $t->insert('end', 'NO ANSWER UNTIL THE FIELDS ARE PUT RIGHT.', 'muted');
        }
        $t->configure(-state => 'disabled');
        return $res;
    }
    $w->{problems}->configure(-text => '');
    # The label column is wide enough for the longest name, plus a gap, so
    # a value never sits against its label.  CD and the bore step come
    # straight after the answer: they are what the bore was worked from,
    # and the results pane leaves room for about ten lines before a scroll.
    my $line = sub {
        my ($l, $v, $tag) = @_;
        $t->insert('end', sprintf('%-24s', $l), 'muted');
        $t->insert('end', "$v\n", $tag // ());
    };
    $line->('BORE', sprintf('%.4g %s', $sh->('SIZE', $res->{bore}), $un{SIZE}), 'big');
    if ($mode eq 'SIZE' && abs($res->{bore} - $res->{bore_exact}) > 1e-6) {
        $line->('ROUNDED FROM', sprintf('%.4g %s', $sh->('SIZE', $res->{bore_exact}), $un{SIZE}));
    }
    $line->('NET LOSS', sprintf('%.4g %s', $sh->('PRESSURE', $res->{drop}), $un{PRESSURE}), 'big');
    if ($mode eq 'SIZE') {
        $line->('ASKED', sprintf('%.4g %s', $sh->('PRESSURE', $res->{target}), $un{PRESSURE}));
    }
    $line->('CD', $res->{cd_default} ? sprintf('%.3f  (THE DEFAULT)', $res->{cd}) : sprintf('%.4g', $res->{cd}));
    if ($mode eq 'SIZE') {
        $line->('BORE STEP', $res->{step} > 0
            ? sprintf('%.4g %s', $sh->('SIZE', $res->{step}), $un{SIZE})
            : 'NOT ROUNDED');
    }
    $line->('FLOW', sprintf('%.4g %s', $sh->('FLOW', $res->{q}), $un{FLOW})
                    . ($u->{FLOW} eq 'LPM' ? sprintf('  (%.3f L/S)', $res->{q} / 60) : sprintf('  (%.1f L/MIN)', $res->{q})));
    $line->('PIPE BORE', sprintf('%.4g %s', $sh->('SIZE', $res->{pipedia}), $un{SIZE}));
    $line->('BETA, D/D', sprintf('%.3f', $res->{beta}));
    $line->('VELOCITY IN THE BORE', sprintf('%.2f M/S', $res->{velocity}));
    $line->('VELOCITY IN THE PIPE', sprintf('%.2f M/S', $res->{pipe_velocity}));
    my $lim = $settings->{options}{VEL_LIMIT};
    $lim = 6 unless defined $lim && $lim =~ /^\s*[\d.]+\s*$/ && $lim > 0;
    $line->('PIPE AGAINST THE LIMIT', sprintf('%.1f M/S: %s', $lim, $res->{pipe_velocity} > $lim ? 'ABOVE IT' : 'WITHIN IT'),
            $res->{pipe_velocity} > $lim ? 'warn' : '');
    $line->('TAPPING DIFFERENTIAL', sprintf('%.4g %s', $sh->('PRESSURE', $res->{differential}), $un{PRESSURE}));
    $line->('PERMANENT-LOSS RATIO', sprintf('%.3f', $res->{ratio}));
    $t->insert('end', "\n");
    if ($res->{limit} eq 'WIDE') {
        $t->insert('end', "A BORE ALMOST AS LARGE AS THE PIPE STILL DROPS MORE THAN ASKED.\n", 'warn');
    } elsif ($res->{limit} eq 'TIGHT') {
        $t->insert('end', "EVEN A VERY SMALL BORE DOES NOT DROP THIS MUCH.\n", 'warn');
    } elsif (!$res->{fits}) {
        $t->insert('end', "THE ROUNDED BORE IS NOT SMALLER THAN THE PIPE.\n", 'warn');
    } elsif ($mode eq 'SIZE') {
        my $delta = $res->{drop} - $res->{target};
        if (abs($delta) >= 0.05) {
            $t->insert('end', sprintf("AT THE ROUNDED BORE THE NET LOSS IS %.4g %s %s WHAT WAS ASKED.\n",
                abs($sh->('PRESSURE', $delta)), $un{PRESSURE}, $delta > 0 ? 'ABOVE' : 'BELOW'), 'muted');
        }
        $t->insert('end', "THE BORE IS ROUNDED TO THE STEP, AS AN OPP PLATE IS.\n", 'muted');
    }
    $t->insert('end', "THE NET LOSS IS THE TAPPING DIFFERENTIAL TIMES THE ISO 5167 PERMANENT-LOSS RATIO.\n", 'muted');
    $t->configure(-state => 'disabled');
    return $res;
}

1;
