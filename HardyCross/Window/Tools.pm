#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# HardyCross/Window/Tools.pm -- part of the editor window, phcp_editor.pl:
# the QUICK TOOLS tab: velocity, K-factor, K converter, pressure loss.
#
# The window is split one file to a tab so each can be read on its own.  It
# is still one program: this file is in package main, shares the window's
# globals (declared with our in phcp_editor.pl and named again below) and its
# widget helpers, and is loaded by phcp_editor.pl with use.  Nothing here
# decides anything; the decisions are in the HardyCross modules it calls.

package main;

use strict;
use warnings;

our ($UI_S_N, %C, $MONO, $MONO_B, $POINTER, $UI, $UI_B, $settings, @dd_refresh);   # the window's globals, from phcp_editor.pl
#==============================================================================
# The QUICK TOOLS tab: five small calculators, in three columns.
#
#   VELOCITY        a pipe type and size, and a flow: the bore and velocity
#   FITTINGS        a pipe type and size, and fittings: equivalent lengths
#   K-FACTOR        any two of K, Q and P: the third
#   K CONVERTER     a K-factor in any K unit, in all of them
#   PRESSURE LOSS   a pipe type and size, and a flow: the friction loss by
#                   Hazen-Williams and Darcy-Weisbach, side by side
#
# Each answers as it is typed, in the units set in the PROJECT tab (taken
# afresh each time the tab is opened).  Independent of the model, like the
# GRAPH tab.
# Every number is HardyCross::Tools's -- the database's bores and the
# solver's own loss formulas -- so a pipe here behaves exactly as in a model;
# this is drawing.
#==============================================================================
our %qt = (VEL => { type => 'ASAM', size => '', flow => '' },
           FIT => { type => 'ASAM', size => '', spec => '', c => '' },
           K   => { k => '', q => '', p => '', unit => '' },
           KCONV => { value => '', from => 'GPM/PSI' },
           LOSS => { type => 'ASAM', size => '', flow => '', length => '', c => '', eps => '' });
our %qtw;                        # the widgets, by tool and field; and each tool's result text

sub build_tools {
    my $page = shift;
    my $bar = $page->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -padx => px(14), -pady => px([10, 8]));
    $qtw{units} = $bar->Label(-text => '', -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted})
                      ->pack(-side => 'left');
    $qtw{db} = $bar->Label(-text => '', -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted})
                     ->pack(-side => 'right');
    rule($page, 'x', -side => 'top');
    # The calculators scroll, as the PROJECT tab does, so none is cut short
    # on a short window or with the results pane dragged up.
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
                                                                      -padx => px([0, 30])) } 1 .. 3;

    # card -- one calculator: a heading, a line on what it does, the fields,
    # its problems in red, and its answer.  Cards stack down their column.
    my $card = sub {
        my ($tool, $title, $about, $column, $lines) = @_;
        my $c = $col{$column}->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -anchor => 'n',
                                                                     -pady => px([0, 18]));
        $c->Label(-text => $title, -font => $UI_B, -background => $C{paper}, -foreground => $C{ink}, -anchor => 'w')
          ->pack(-fill => 'x');
        rule($c, 'x', -pady => px([4, 4]));
        $c->Label(-text => $about, -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted},
                  -anchor => 'w', -justify => 'left', -wraplength => px(360))->pack(-fill => 'x', -pady => px([0, 8]));
        my $g = $c->Frame(-background => $C{paper})->pack(-fill => 'x', -anchor => 'w');
        $qtw{$tool}{problems} = $c->Label(-text => '', -font => $UI, -background => $C{paper},
            -foreground => $C{error}, -anchor => 'w', -justify => 'left', -wraplength => px(360))
            ->pack(-fill => 'x', -pady => px([8, 4]));
        $qtw{$tool}{result} = $c->Text(-font => $MONO, -height => $lines // 10, -width => 48, -wrap => 'none',
            -relief => 'flat', -borderwidth => 0, -highlightthickness => 0, -background => $C{panel},
            -foreground => $C{ink}, -padx => px(10), -pady => px(8), -cursor => $POINTER, -takefocus => 0)
            ->pack(-fill => 'x');
        $qtw{$tool}{result}->tagConfigure('head', -font => $MONO_B);
        $qtw{$tool}{result}->tagConfigure('big', -font => $MONO_B, -foreground => $C{accent});
        $qtw{$tool}{result}->tagConfigure('muted', -foreground => $C{muted});
        $qtw{$tool}{result}->tagConfigure('warn', -foreground => $C{error}, -font => $MONO_B);
        return $g;
    };
    my $r = 0;
    my $label = sub {
        my ($g, $text) = @_;
        $g->Label(-text => $text, -font => $UI, -background => $C{paper}, -foreground => $C{muted}, -anchor => 'w')
          ->grid(-row => $r, -column => 0, -sticky => 'w', -pady => px(3), -padx => px([0, 12]));
    };
    my $entry = sub {
        my ($g, $tool, $field, $width, $note) = @_;
        my $e = flat_entry($g, \$qt{$tool}{ lc $field }, $width // 10);
        $e->grid(-row => $r, -column => 1, -sticky => 'w', -pady => px(3), -ipady => px(2));
        $e->bind('<KeyRelease>' => sub { tools_update($tool) });
        # A note naming a unit -- U:FLOW, U:LENGTH -- is redrawn when the
        # PROJECT tab's units change (tools_refresh).
        if ($note) {
            my $l = $g->Label(-text => '', -font => $UI_S_N, -background => $C{paper}, -foreground => $C{faint}, -anchor => 'w');
            $l->grid(-row => $r, -column => 2, -sticky => 'w', -padx => px([8, 0]));
            push @{ $qtw{notes} }, [ $l, $note ];
        }
        $qtw{$tool}{field}{$field} = $e;
        $r++;
        return $e;
    };
    # pipe -- PIPE TYPE and SIZE: the type a drop-down of the database's
    # types and BORE; the size a drop-down of that type's sizes, or for BORE
    # a field for the bore in mm.
    my $pipe = sub {
        my ($g, $tool) = @_;
        $label->($g, 'PIPE TYPE');
        my $t = drop_down($g, \$qt{$tool}{type}, [ HardyCross::Tools::pipe_types() ], sub {
            $qt{$tool}{size} = '';
            tools_sizes($tool);
            tools_update($tool);
        });
        $t->grid(-row => $r++, -column => 1, -sticky => 'w', -pady => px(3));
        $qtw{$tool}{field}{TYPE} = $t;
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
        my $be = flat_entry($f, \$qt{$tool}{size}, 10);
        $be->bind('<KeyRelease>' => sub { tools_update($tool) });
        my $bn = $f->Label(-text => '', -font => $UI_S_N, -background => $C{paper}, -foreground => $C{faint});
        push @{ $qtw{notes} }, [ $bn, 'BORE, U:SIZE' ];
        @{ $qtw{$tool} }{qw(size_mb size_menu size_entry size_note)} = ($mb, $m, $be, $bn);
        $qtw{$tool}{field}{SIZE} = $mb;
        tools_sizes($tool);
    };

    # VELOCITY.
    my $g = $card->('VEL', 'VELOCITY', 'THE VELOCITY IN A PIPE AT A FLOW.  THE BORE IS THE DATABASE\'S FOR THE TYPE AND SIZE.', 1, 8);
    $r = 0;
    $pipe->($g, 'VEL');
    $label->($g, 'FLOW');
    $entry->($g, 'VEL', 'FLOW', 10, 'U:FLOW');

    # FITTINGS.
    $g = $card->('FIT', 'FITTINGS', 'EQUIVALENT LENGTHS FROM THE DATABASE, AS FOR A MODEL\'S PIPE: THE SAME SOURCE '
        . 'AND CORRECTIONS.  FITTINGS AS ON A PIPE LINE: 2E 1T G (G GATE, C CHECK, B BUTTERFLY VALVE).', 1, 8);
    $r = 0;
    $pipe->($g, 'FIT');
    $label->($g, 'FITTINGS');
    $entry->($g, 'FIT', 'SPEC', 24);
    $label->($g, 'C FACTOR');
    $entry->($g, 'FIT', 'C', 10, 'BLANK: THE TYPE\'S');

    # K-FACTOR.
    $g = $card->('K', 'K-FACTOR', 'Q = K x SQRT(P).  GIVE ANY TWO OF K, Q AND P; THE THIRD IS FOUND.  CLEAR A FIELD TO SOLVE FOR IT.', 2, 7);
    $r = 0;
    $label->($g, 'K');
    $entry->($g, 'K', 'K', 10);
    $label->($g, 'K UNITS');
    my $ku = drop_down($g, \$qt{K}{unit}, [ @{ $HardyCross::Phc::UNIT_CHOICES{KFACTOR} } ], sub { tools_update('K') });
    $ku->grid(-row => $r++, -column => 1, -sticky => 'w', -pady => px(3));
    $g->Label(-text => 'K80 IS 8 IN LPM/KPA, 80 IN LPM/BAR, 5.6 IN GPM/PSI.', -font => $UI_S_N,
              -background => $C{paper}, -foreground => $C{faint}, -anchor => 'w', -wraplength => px(340), -justify => 'left')
      ->grid(-row => $r++, -column => 0, -columnspan => 3, -sticky => 'w', -pady => px([0, 4]));
    $label->($g, 'FLOW Q');
    $entry->($g, 'K', 'Q', 10, 'U:FLOW');
    $label->($g, 'PRESSURE P');
    $entry->($g, 'K', 'P', 10, 'U:PRESSURE');

    # K CONVERTER.
    $g = $card->('KCONV', 'K-FACTOR CONVERTER', 'A K-FACTOR IN ANY K UNIT, IN ALL OF THEM: US (GPM PER ROOT PSI) '
        . 'TO METRIC, OR BACK.  K5.6 (US) IS K80 (METRIC, L/MIN PER ROOT BAR).', 2, 5);
    $r = 0;
    $label->($g, 'K');
    $entry->($g, 'KCONV', 'VALUE', 10);
    $label->($g, 'GIVEN IN');
    my $kf = drop_down($g, \$qt{KCONV}{from}, [ @{ $HardyCross::Phc::UNIT_CHOICES{KFACTOR} } ], sub { tools_update('KCONV') });
    $kf->grid(-row => $r++, -column => 1, -sticky => 'w', -pady => px(3));

    # PRESSURE LOSS.
    $g = $card->('LOSS', 'PRESSURE LOSS', 'THE FRICTION LOSS IN A PIPE AT A FLOW, BY HAZEN-WILLIAMS AND BY DARCY-WEISBACH, '
        . 'WITH THE SOLVER\'S OWN FORMULAS.  BLANK: 1 M OF PIPE, AND THE TYPE\'S C AND ROUGHNESS FROM THE DATABASE.', 3, 11);
    $r = 0;
    $pipe->($g, 'LOSS');
    $label->($g, 'FLOW');
    $entry->($g, 'LOSS', 'FLOW', 10, 'U:FLOW');
    $label->($g, 'LENGTH');
    $entry->($g, 'LOSS', 'LENGTH', 10, 'U:LENGTH - BLANK: 1 M');
    $label->($g, 'C FACTOR (HW)');
    $entry->($g, 'LOSS', 'C', 10);
    $label->($g, 'ROUGHNESS (DW)');
    $entry->($g, 'LOSS', 'EPS', 10, 'U:SIZE - BLANK: THE TYPE\'S');

    tools_refresh();
}

# tools_refresh -- on opening the tab: the database may have changed in the
# DATABASE tab since, so the sizes and the answers are taken from it afresh.
sub tools_refresh {
    return unless $qtw{db};
    HardyCross::Parse::ensure_db();
    $qtw{db}->configure(-text => 'PIPE DATA: ' . uc(HardyCross::PipeData::dataset()));
    # The units: the PROJECT tab's, named in the bar and beside each field.
    my $u = tool_units();
    $qtw{units}->configure(-text => sprintf('UNITS AS IN THE PROJECT TAB: FLOW %s, PRESSURE %s, LENGTH %s, SIZE %s.  '
        . 'INDEPENDENT OF THE MODEL.', map { unit_name($_, $u->{$_}) } qw(FLOW PRESSURE LENGTH SIZE)));
    for my $n (@{ $qtw{notes} || [] }) {
        (my $t = $n->[1]) =~ s/U:(\w+)/unit_name($1, $u->{$1})/ge;
        $n->[0]->configure(-text => $t);
    }
    $qt{K}{unit} ||= $u->{KFACTOR};
    $_->() for @dd_refresh;
    for my $tool (qw(VEL FIT LOSS)) {
        $qt{$tool}{size} = '' if $qt{$tool}{type} ne $HardyCross::Tools::BORE
            && !grep { $_ eq $qt{$tool}{size} } HardyCross::Tools::sizes($qt{$tool}{type});
        tools_sizes($tool);
    }
    tools_update($_) for qw(VEL FIT K KCONV LOSS);
}

# tool_units -- the PROJECT tab's units, each unset one at its default.
sub tool_units {
    return { map { $_ => ($settings->{units}{$_} || $HardyCross::Phc::UNIT_DEFAULT{$_}) }
             qw(FLOW PRESSURE LENGTH SIZE KFACTOR) };
}

# unit_name -- a unit as the window shows it: L/MIN, M HEAD, L/MIN/KPA^0.5.
sub unit_name {
    my ($q, $u) = @_;
    my %n = (LPM => 'L/MIN', LPS => 'L/S', M3H => 'M3/H', GPM => 'GPM', KPA => 'KPA', BAR => 'BAR', MPA => 'MPA',
             PSI => 'PSI');
    return $u eq 'M' ? 'M HEAD' : $n{$u} // $u if $q eq 'PRESSURE';
    if ($q eq 'KFACTOR') { my ($a, $b) = split m{/}, $u; return "$n{$a}/$n{$b}^0.5" }
    return $n{$u} // $u;
}

# tools_sizes -- the SIZE choice for a tool's pipe type: a drop-down of the
# type's sizes, or for BORE a field for the bore.
sub tools_sizes {
    my $tool = shift;
    my $w = $qtw{$tool};
    my $type = $qt{$tool}{type};
    $w->{size_menu}->delete(0, 'end');
    if ($type eq $HardyCross::Tools::BORE) {
        $w->{size_mb}->packForget;
        $w->{size_entry}->pack(-side => 'left', -ipady => px(2));
        $w->{size_note}->pack(-side => 'left', -padx => px([8, 0]));
        $qtw{$tool}{field}{SIZE} = $w->{size_entry};
    } else {
        $w->{size_entry}->packForget;
        $w->{size_note}->packForget;
        $w->{size_mb}->pack(-side => 'left');
        for my $dn (HardyCross::Tools::sizes($type)) {
            my $su = tool_units()->{SIZE};
            $w->{size_menu}->command(-label => sprintf('DN%-5s %8s %s', $dn,
                    sprintf($su eq 'IN' ? '%.3f' : '%.1f', HardyCross::Tools::show('SIZE', HardyCross::PipeData::bore($type, $dn), { SIZE => $su })),
                    unit_name('SIZE', $su)),
                -command => sub { $qt{$tool}{size} = $dn; tools_update($tool) });
        }
        $qtw{$tool}{field}{SIZE} = $w->{size_mb};
    }
    tools_show_size($tool);
}
sub tools_show_size {
    my $tool = shift;
    return if $qt{$tool}{type} eq $HardyCross::Tools::BORE;
    my $s = $qt{$tool}{size};
    $qtw{$tool}{size_mb}->configure(-text => sprintf('%-9s %s', length $s ? "DN$s" : 'CHOOSE', "\x{25BE}"));
}

#------------------------------------------------------------------------------
# tools_update -- a calculator worked out again: its problems, each field at
# fault shaded, and its answer.
#------------------------------------------------------------------------------
sub tools_update {
    my $tool = shift;
    my $w = $qtw{$tool} or return;
    tools_show_size($tool) if $w->{size_mb};
    my $f = $qt{$tool};
    my $u = tool_units();
    my $res = $tool eq 'VEL'   ? HardyCross::Tools::velocity(%$f, units => $u)
            : $tool eq 'FIT'   ? HardyCross::Tools::fittings(%$f)
            : $tool eq 'K'     ? HardyCross::Tools::kfactor(%$f, unit => $f->{unit} || $u->{KFACTOR}, units => $u)
            : $tool eq 'KCONV' ? HardyCross::Tools::kconvert(%$f)
            :                    HardyCross::Tools::loss(%$f, units => $u);
    # Answers in the units chosen: sh(quantity, value) and the unit's name.
    my $sh = sub { HardyCross::Tools::show($_[0], $_[1], $u) };
    my %un = map { $_ => unit_name($_, $u->{$_}) } keys %$u;
    $qtw{$tool}{last} = $res;
    for my $e (values %{ $w->{field} }) { $e->configure(-highlightbackground => $C{line}) }
    my $t = $w->{result};
    $t->configure(-state => 'normal');
    $t->delete('1.0', 'end');
    # Before anything is typed there is nothing to complain about: show what
    # is needed, quietly, rather than a list of problems.
    my $empty = !grep { defined && /\S/ } map { $f->{$_} } grep { !/^(type|unit|from)\z/ } keys %$f;
    if (!$res->{ok}) {
        if ($empty) {
            $w->{problems}->configure(-text => '');
            $t->insert('end', $tool eq 'K' ? 'GIVE ANY TWO OF K, Q AND P.' : $tool eq 'KCONV' ? 'GIVE A K.'
                            : $tool eq 'FIT' ? 'CHOOSE A SIZE AND GIVE THE FITTINGS.'
                            : 'CHOOSE A SIZE AND GIVE A FLOW.', 'muted');
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
    my $line = sub { my ($l, $v, $tag) = @_; $t->insert('end', sprintf('%-18s', $l), 'muted'); $t->insert('end', "$v\n", $tag // '') };
    if ($tool eq 'VEL') {
        $line->('VELOCITY', sprintf('%.2f M/S', $res->{velocity}), 'big');
        $t->insert('end', "\n");
        $line->('BORE', sprintf('%.4g %s', $sh->('SIZE', $res->{bore}), $un{SIZE}));
        $line->('AREA', sprintf('%.6f M2', $res->{area}));
        $line->('FLOW', sprintf('%.4g %s', $sh->('FLOW', $res->{q}), $un{FLOW})
                        . ($u->{FLOW} eq 'LPM' ? sprintf('  (%.3f L/S)', $res->{q} / 60) : sprintf('  (%.1f L/MIN)', $res->{q})));
        $t->insert('end', "\n");
        my $lim = $settings->{options}{VEL_LIMIT};
        $lim = 6 unless defined $lim && $lim =~ /^\s*[\d.]+\s*$/ && $lim > 0;
        $line->('AGAINST THE LIMIT', sprintf('%.1f M/S: %s', $lim, $res->{velocity} > $lim ? 'ABOVE IT' : 'WITHIN IT'),
               $res->{velocity} > $lim ? 'head' : '');
        $t->insert('end', '(THE PROJECT TAB\'S VELOCITY LIMIT)', 'muted');
    } elsif ($tool eq 'KCONV') {
        for my $x (qw(GPM/PSI LPM/BAR LPM/KPA LPS/BAR LPS/KPA)) {
            $line->($x eq 'GPM/PSI' ? 'US' : 'METRIC', sprintf('%.3f %s', $res->{all}{$x}, unit_name('KFACTOR', $x)),
                    $x eq $res->{from} ? '' : 'big');
        }
    } elsif ($tool eq 'FIT') {
        for my $row (@{ $res->{rows} }) {
            $t->insert('end', sprintf("%2d x %-4s %-26.26s %6.2f M\n", $row->{count}, $row->{code}, $row->{label},
                                      $row->{total}));
        }
        $line->('TOTAL', sprintf('%.2f M', $res->{total}) . ($u->{LENGTH} eq 'M' ? ''
              : sprintf('  (%.4g %s)', $sh->('LENGTH', $res->{total}), $un{LENGTH})), 'big');
        $t->insert('end', "FROM $res->{source}\n", 'muted');
    } elsif ($tool eq 'K') {
        my %name = (K => 'K', Q => 'FLOW Q', P => 'PRESSURE P');
        my %val = (K => sprintf('%.3f %s', $res->{k}, unit_name('KFACTOR', $res->{unit})),
                   Q => sprintf('%.4g %s', $sh->('FLOW', $res->{q}), $un{FLOW}),
                   P => sprintf('%.4g %s', $sh->('PRESSURE', $res->{p}), $un{PRESSURE}));
        $line->("$name{ $res->{solved} } =", $val{ $res->{solved} }, 'big');
        $t->insert('end', "\n");
        $line->($name{$_}, $val{$_}) for grep { $_ ne $res->{solved} } qw(K Q P);
        $t->insert('end', "\n");
        $line->('K, LPM/KPA', sprintf('%.3f', $res->{k_kpa}));
        $line->('K, LPM/BAR', sprintf('%.3f', $res->{k_bar}));
        $line->('K, GPM/PSI', sprintf('%.3f', $res->{k_us}));
    } else {
        $t->insert('end', sprintf("%-18s%13s %13s\n", '', 'HAZEN-WILLIAMS', 'DARCY-WEISBACH'), 'head');
        $t->insert('end', sprintf("%-18s", "LOSS, $un{PRESSURE}/M"), 'muted');
        $t->insert('end', sprintf("%13.5g %14.5g\n", $sh->('PRESSURE', $res->{hw}{per_m}), $sh->('PRESSURE', $res->{dw}{per_m})), 'big');
        if ($res->{length} != 1) {
            $t->insert('end', sprintf("%-18s", sprintf('OVER %g %s', $sh->('LENGTH', $res->{length}), $un{LENGTH})), 'muted');
            $t->insert('end', sprintf("%13.5g %14.5g\n", $sh->('PRESSURE', $res->{hw}{total}), $sh->('PRESSURE', $res->{dw}{total})), 'big');
            $t->insert('end', sprintf("%-18s%13s %14s\n", '', $un{PRESSURE}, $un{PRESSURE}), 'muted');
        }
        $line->('DW AGAINST HW', sprintf('%+.1f %%', $res->{diff_pct}));
        $line->('BORE, VELOCITY', sprintf('%.4g %s, %.2f M/S', $sh->('SIZE', $res->{bore}), $un{SIZE}, $res->{velocity}));
        $line->('C, ROUGHNESS', sprintf('%g (HW), %.4g %s (DW)', $res->{c}, $sh->('SIZE', $res->{eps}), $un{SIZE}));
        # An assumed roughness is said so, in red: none given, none published.
        $line->('', 'ROUGHNESS ASSUMED: THE PROGRAM DEFAULT', 'warn') if $res->{eps_src} eq 'DEFAULT';
        $line->('REYNOLDS NUMBER', sprintf('%.0f, %s', $res->{dw}{re}, $res->{dw}{regime}));
        $line->('FRICTION FACTOR', sprintf('%.5f (DARCY)', $res->{dw}{f}));
    }
    $t->configure(-state => 'disabled');
    return $res;
}

1;
