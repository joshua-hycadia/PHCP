#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# HardyCross/Window/Graph.pm -- part of the editor window, phcp_editor.pl:
# the GRAPH tab: a Q^1.85 water supply graph from figures typed in.
#
# The window is split one file to a tab so each can be read on its own.  It
# is still one program: this file is in package main, shares the window's
# globals (declared with our in phcp_editor.pl and named again below) and its
# widget helpers, and is loaded by phcp_editor.pl with use.  Nothing here
# decides anything; the decisions are in the HardyCross modules it calls.

package main;

use strict;
use warnings;

our ($UI, $UI_S_N, %C, $MONO, $UI_B, $UI_S, $mw, $settings, @dd_refresh);   # the window's globals, from phcp_editor.pl
#==============================================================================
# The GRAPH tab: a Q^1.85 water supply graph from figures typed in.
#
# Independent of the model: nothing here is read from the network or from a
# calculation, and nothing here changes them.  The supply as measured (A),
# the loss from the supply to the datum (B) and a pump (D) are typed as
# points; the tab draws them with the supply available at the datum (C =
# A - B) and with the pump (E = C + D), and up to ten duty points, each with
# the pressure available to it and its margin.  PRINT TO PDF writes the sheet;
# SAVE GRAPH keeps the figures in a .phg file.  Every decision -- what is
# wrong, where the curves go -- is HardyCross::Graph's; this is drawing.
#
# Left, the figures; right, the graph as it will print, redrawn as they are
# typed, and under it what is wrong with them, if anything.  A field at fault
# is shaded; a click on a problem goes to its field.
#==============================================================================
our $graph = HardyCross::Graph::new_graph();
our %gv = (fields => {}, saved => '');   # canvas, problems list, fields by name, path, saved text

sub build_graph {
    my $page = shift;
    my $bar = $page->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -padx => px(14), -pady => px([10, 8]));
    $gv{btn}{NEW}   = flat_button($bar, 'NEW GRAPH',     sub { graph_new() })->pack(-side => 'left', -padx => px([0, 4]));
    $gv{btn}{OPEN}  = flat_button($bar, 'OPEN GRAPH...', sub { graph_open() })->pack(-side => 'left', -padx => px(4));
    $gv{btn}{SAVE}  = flat_button($bar, 'SAVE GRAPH...', sub { graph_save() })->pack(-side => 'left', -padx => px(4));
    $bar->Frame(-background => $C{line}, -width => 1, -height => px(22))->pack(-side => 'left', -padx => px(10));
    $gv{btn}{PDF}   = flat_button($bar, 'PRINT TO PDF...', sub { graph_pdf() }, primary => 1)
                        ->pack(-side => 'left', -padx => px(4));
    $gv{file} = $bar->Label(-text => '', -font => $UI, -background => $C{paper}, -foreground => $C{muted})
                    ->pack(-side => 'left', -padx => px(12));
    $bar->Label(-text => 'INDEPENDENT OF THE MODEL - NOTHING HERE COMES FROM THE NETWORK.',
                -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted})->pack(-side => 'right');
    rule($page, 'x', -side => 'top');

    my $hp = divider($page, 'horizontal');
    my $left  = $page->Frame(-background => $C{paper});
    my $right = $page->Frame(-background => $C{paper});

    # The figures, in a scrolling form.
    my $sb = flat_scrollbar($left, 'vertical')->pack(-side => 'right', -fill => 'y');
    my $cv = $left->Canvas(-background => $C{paper}, -highlightthickness => 0, -borderwidth => 0,
                           -yscrollcommand => sub { $sb->set(@_) })->pack(-fill => 'both', -expand => 1);
    $sb->configure(-command => sub { $cv->yview(@_) });
    my $wrap = $cv->Frame(-background => $C{paper});
    $cv->createWindow(px(14), px(10), -window => $wrap, -anchor => 'nw');
    $wrap->bind('<Configure>' => sub {
        $cv->configure(-scrollregion => [ 0, 0, $wrap->reqwidth + px(28), $wrap->reqheight + px(20) ]);
    });
    wheel_target($cv);
    $gv{form} = $cv;
    $gv{wrap} = $wrap;

    my $heading = sub {
        my ($parent, $text, $note) = @_;
        my $h = $parent->Frame(-background => $C{paper})->pack(-fill => 'x', -pady => px([10, 0]));
        $h->Label(-text => $text, -font => $UI_B, -background => $C{paper}, -foreground => $C{ink})->pack(-side => 'left');
        $h->Label(-text => $note, -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted})
          ->pack(-side => 'left', -padx => px([8, 0])) if $note;
        rule($parent, 'x', -pady => px([3, 6]));
    };
    my $field = sub {
        my ($g, $name, $var, $width, $row, $col) = @_;
        my $e = flat_entry($g, $var, $width);
        $e->grid(-row => $row, -column => $col, -sticky => 'w', -pady => px(2), -padx => px([0, 6]), -ipady => px(2));
        $e->bind('<KeyRelease>' => sub { graph_changed() });
        $gv{fields}{$name} = $e;
        return $e;
    };
    # label -- a label; one naming a unit (U:FLOW, U:PRESSURE) is redrawn
    # when the graph's units change (graph_unit_labels).
    my $label = sub {
        my ($g, $text, $row, $col, %o) = @_;
        my $l = $g->Label(-text => $text, -font => $o{head} ? $UI_S : $UI, -background => $C{paper},
                          -foreground => $C{muted}, -anchor => 'w');
        $l->grid(-row => $row, -column => $col, -sticky => 'w', -padx => px([0, 10]), -columnspan => $o{span} // 1);
        push @{ $gv{ulabels} }, [ $l, $text ] if $text =~ /U:/;
    };

    # The sheet: project details and the axes.
    $heading->($wrap, 'SHEET');
    my $g = $wrap->Frame(-background => $C{paper})->pack(-fill => 'x');
    my $r = 0;
    for my $k (@HardyCross::Graph::PROJECT) {
        $label->($g, $HardyCross::Graph::PROJECT_LABEL{$k}, $r, 0);
        $field->($g, $k, \$graph->{project}{$k}, 30, $r++, 1);
    }
    $r = 0;
    # The units: the PROJECT tab's when a graph is begun; kept with it.
    for my $q (qw(FLOW PRESSURE)) {
        $label->($g, "$q UNIT", $r, 2);
        my $dd = drop_down($g, \$graph->{units}{$q},
                           $q eq 'FLOW' ? \@HardyCross::Graph::FLOW_UNITS : \@HardyCross::Graph::PRESSURE_UNITS,
                           sub { graph_changed() });
        $dd->grid(-row => $r++, -column => 3, -sticky => 'w', -pady => px(2));
    }
    for my $k (@HardyCross::Graph::AXIS) {
        $label->($g, $HardyCross::Graph::AXIS_LABEL{$k} . ($k eq 'QMAX' ? ', U:FLOW' : ', U:PRESSURE'), $r, 2);
        $field->($g, $k, \$graph->{axis}{$k}, 8, $r++, 3);
    }
    $label->($g, 'AXES LEFT BLANK ARE WORKED OUT FROM THE FIGURES', $r, 2, span => 2);

    # The curves: three tables side by side.
    $heading->($wrap, 'CURVES', 'FLOWS RISING FROM ROW TO ROW, NO GAPS');
    my $cf = $wrap->Frame(-background => $C{paper})->pack(-fill => 'x');
    my %note = (A => 'AT LEAST TWO POINTS', B => 'ONE POINT: A LOSS LINE THROUGH 0', D => 'FROM CHURN, NO FLOW; OR NONE');
    for my $c (@HardyCross::Graph::CURVES) {
        my $t = $cf->Frame(-background => $C{paper})->pack(-side => 'left', -anchor => 'n', -padx => px([0, 22]));
        $t->Label(-text => "$c  $HardyCross::Graph::CURVE_NAME{$c}", -font => $UI_B, -background => $C{paper},
                  -foreground => $C{ink}, -anchor => 'w')->pack(-fill => 'x');
        $t->Label(-text => $note{$c}, -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted},
                  -anchor => 'w')->pack(-fill => 'x', -pady => px([0, 4]));
        my $tg = $t->Frame(-background => $C{paper})->pack(-anchor => 'w');
        $label->($tg, '', 0, 0, head => 1);
        $label->($tg, 'FLOW U:FLOW', 0, 1, head => 1);
        $label->($tg, 'PRESSURE U:PRESSURE', 0, 2, head => 1);
        for my $i (0 .. $HardyCross::Graph::ROWS - 1) {
            $tg->Label(-text => $i + 1, -font => $UI_S_N, -background => $C{paper}, -foreground => $C{faint})
               ->grid(-row => $i + 1, -column => 0, -sticky => 'e', -padx => px([0, 6]));
            my $f = $field->($tg, $c . ($i + 1) . 'Q', \$graph->{$c}[$i][0], 9, $i + 1, 1);
            my $p = $field->($tg, $c . ($i + 1) . 'P', \$graph->{$c}[$i][1], 9, $i + 1, 2);
            # A problem names the row: both its fields are shaded.
            $gv{rows}{ $c . ($i + 1) } = [ $f, $p ];
        }
    }

    # The duty points.
    $heading->($wrap, 'DUTY POINTS', 'EACH A FLOW NEEDED AT A PRESSURE; THE NUMBER IS DRAWN ON THE GRAPH');
    my $dg = $wrap->Frame(-background => $C{paper})->pack(-anchor => 'w');
    $label->($dg, 'NO', 0, 0, head => 1);
    $label->($dg, 'DESCRIPTION', 0, 1, head => 1);
    $label->($dg, 'FLOW U:FLOW', 0, 2, head => 1);
    $label->($dg, 'PRESSURE U:PRESSURE', 0, 3, head => 1);
    for my $i (0 .. $HardyCross::Graph::DUTY_ROWS - 1) {
        my @w = ($field->($dg, 'DUTY' . ($i + 1) . 'L', \$graph->{duty}[$i][0], 5,  $i + 1, 0),
                 $field->($dg, 'DUTY' . ($i + 1) . 'D', \$graph->{duty}[$i][1], 34, $i + 1, 1),
                 $field->($dg, 'DUTY' . ($i + 1) . 'Q', \$graph->{duty}[$i][2], 9,  $i + 1, 2),
                 $field->($dg, 'DUTY' . ($i + 1) . 'P', \$graph->{duty}[$i][3], 9,  $i + 1, 3));
        $gv{rows}{ 'DUTY' . ($i + 1) } = \@w;
    }
    $gv{rows}{$_} = [ $gv{fields}{$_} ] for @HardyCross::Graph::AXIS;

    # The graph, and what is wrong.
    $gv{problems} = $right->Listbox(-font => $MONO, -height => 5, -relief => 'flat', -borderwidth => 0,
        -highlightthickness => 0, -background => $C{paper}, -foreground => $C{error},
        -selectbackground => $C{error_bg}, -selectforeground => $C{error}, -activestyle => 'none')
        ->pack(-side => 'bottom', -fill => 'x', -padx => px(10), -pady => px([0, 8]));
    $gv{problems}->bind('<ButtonRelease-1>' => sub { graph_go_to_problem() });
    rule($right, 'x', -side => 'bottom');
    $gv{canvas} = $right->Canvas(-background => $C{paper}, -highlightthickness => 0, -borderwidth => 0)
        ->pack(-fill => 'both', -expand => 1, -padx => px(6), -pady => px(6));
    $gv{canvas}->Tk::bind('<Configure>' => sub { graph_draw() });

    $hp->add($left, -width => px(820));
    $hp->add($right);
    $hp->pack(-fill => 'both', -expand => 1);
    $gv{saved} = graph_text();
    graph_changed();
}

# graph_text -- the figures as they would be saved, to tell whether they changed.
sub graph_text {
    my @f = (map({ $graph->{project}{$_} } @HardyCross::Graph::PROJECT), map({ $graph->{axis}{$_} } @HardyCross::Graph::AXIS),
             map({ $graph->{units}{$_} } qw(FLOW PRESSURE)),
             map({ map { @$_ } @{ $graph->{$_} } } @HardyCross::Graph::CURVES), map { @$_ } @{ $graph->{duty} });
    return join "\x00", map { $_ // '' } @f;
}
sub graph_modified { return graph_text() ne $gv{saved} }

# graph_unit_labels -- every label naming a unit, in the graph's units.
sub graph_unit_labels {
    my $u = HardyCross::Graph::units($graph);
    for my $l (@{ $gv{ulabels} || [] }) {
        (my $t = $l->[1]) =~ s/U:(FLOW|PRESSURE)/uc $HardyCross::Graph::UNIT_NAME{ $u->{$1} }/ge;
        $l->[0]->configure(-text => $t);
    }
}

# graph_changed -- after any change: capitals, a fresh check, the shading, the
# problems list and the drawing.  Run a moment after typing stops.
sub graph_changed {
    $mw->afterCancel($gv{job}) if $gv{job};
    $gv{job} = $mw->after(200, sub { $gv{job} = undef; graph_refresh() });
}
sub graph_refresh {
    $_ = uc for grep { defined } values %{ $graph->{project} };
    $_->[1] = uc $_->[1] for grep { defined $_->[1] } @{ $graph->{duty} };
    $_->[0] = uc $_->[0] for grep { defined $_->[0] } @{ $graph->{duty} };
    graph_unit_labels();
    my $chk = HardyCross::Graph::check($graph);
    $gv{check} = $chk;
    for my $w (values %{ $gv{fields} }) { $w->configure(-background => $C{paper}) }
    $gv{problems}->delete(0, 'end');
    for my $e (@{ $chk->{errors} }) {
        my ($where, $msg) = @$e;
        $_->configure(-background => $C{fault_bg}) for @{ $gv{rows}{$where} || [] };
        $gv{problems}->insert('end', $msg);
    }
    $gv{problems}->insert('end', '') unless @{ $chk->{errors} };
    $gv{btn}{PDF}->configure(-state => $chk->{ok} ? 'normal' : 'disabled');
    graph_set_title();
    graph_draw();
}
sub graph_set_title {
    my $name = defined $gv{path} ? ($gv{path} =~ s{.*[/\\]}{}r) : 'UNTITLED.PHG';
    $gv{file}->configure(-text => uc($name) . (graph_modified() ? ' *' : ''));
}

# graph_go_to_problem -- a click on a problem: focus the field at fault.
sub graph_go_to_problem {
    my ($i) = $gv{problems}->curselection;
    return unless defined $i;
    my $e = $gv{check}{errors}[$i] or return;
    my $w = ($gv{rows}{ $e->[0] } || [])->[0] or return;
    $w->focus;
    $w->selectionRange(0, 'end');
    # Scroll the form to it if it is out of sight.
    $gv{form}->update;
    my $y = $w->rooty - $gv{form}->rooty;
    if ($y < 0 || $y > $gv{form}->height - px(30)) {
        my $at = ($w->rooty - $gv{wrap}->rooty) / ($gv{wrap}->reqheight || 1);
        $gv{form}->yviewMoveto($at > 0.05 ? $at - 0.05 : 0);
    }
}

#------------------------------------------------------------------------------
# graph_draw -- the graph on the canvas, as it will print: the same curves,
# styles and letters as HardyCross::Graph::write_pdf, scaled to the pane.
#------------------------------------------------------------------------------
sub graph_draw {
    my $c = $gv{canvas} or return;
    $c->delete('all');
    my ($W, $H) = ($c->width, $c->height);
    return if $W < 50 || $H < 50;
    my $chk = $gv{check} or return;
    unless ($chk->{ok}) {
        $c->createText($W / 2, $H / 2, -text => 'THE GRAPH IS DRAWN WHEN THE FIGURES ARE COMPLETE - SEE BELOW',
                       -font => $UI, -fill => $C{muted});
        return;
    }
    my $sr = HardyCross::Graph::series($chk);
    # The key goes under the plot: a line for each curve and each duty point.
    my @names = grep { $sr->{lines}{$_} } qw(A B C D E);
    my $keyh = (@names + @{ $sr->{duty} }) * px(15) + px(12);
    my ($pl, $pr, $pt, $pb) = (px(56), $W - px(16), px(26), $H - px(44) - $keyh);
    return if $pb - $pt < px(60);
    my ($pw, $ph) = ($pr - $pl, $pb - $pt);
    my ($qmax, $pmax) = @{$sr}{qw(qmax pmax)};
    my $X = sub { $pl + ($_[0] > 0 ? ($_[0] / $qmax) ** 1.85 : 0) * $pw };
    my $Y = sub { $pb - $_[0] / $pmax * $ph };
    for my $p (@{ $sr->{yticks} }) {
        next if $p > $pmax + 1e-9;
        $c->createLine($pl, $Y->($p), $pr, $Y->($p), -fill => $C{line});
        $c->createText($pl - px(5), $Y->($p), -text => sprintf('%g', $p), -anchor => 'e', -font => $UI_S_N, -fill => $C{muted});
    }
    my $last = -1e9;
    for my $q (@{ $sr->{xticks} }) {
        next if $q > $qmax + 1e-9;
        my $x = $X->($q);
        $c->createLine($x, $pt, $x, $pb, -fill => $C{line});
        my $t = sprintf '%g', $q;
        next if $x - px(4) * length($t) < $last + px(6);
        $c->createText($x, $pb + px(4), -text => $t, -anchor => 'n', -font => $UI_S_N, -fill => $C{muted});
        $last = $x + px(4) * length $t;
    }
    my ($fu, $pu) = map { uc $HardyCross::Graph::UNIT_NAME{$_} } @{ $sr->{units} }{qw(FLOW PRESSURE)};
    $c->createText($pl - px(5), $pt - px(8), -text => "PRESSURE, $pu", -anchor => 'w', -font => $UI_S, -fill => $C{ink});
    $c->createText(($pl + $pr) / 2, $pb + px(26), -text => "FLOW, $fu, ON A FLOW^1.85 SCALE", -font => $UI_S, -fill => $C{ink});
    $c->createRectangle($pl, $pt, $pr, $pb, -outline => $C{ink});

    # Line styles as on the sheet: A thin, B dotted, C dashed, D dash-dot; the
    # curve designed against heavy and blue, so it reads first on the screen.
    my %dash = (A => '', B => '.', C => '-', D => '-.', E => '-');
    my %along = (A => 0.30, B => 0.62, C => 0.46, D => 0.78, E => 0.90);
    for my $n (@names) {
        my $design = $n eq $sr->{design};
        # Only the part inside the plot: the curve is cut into runs of points
        # between 0 and the top of the pressure axis.
        my @runs = ([]);
        for my $pt (@{ $sr->{lines}{$n} }) {
            if ($pt->[1] >= 0 && $pt->[1] <= $pmax) { push @{ $runs[-1] }, $X->($pt->[0]), $Y->($pt->[1]) }
            elsif (@{ $runs[-1] }) { push @runs, [] }
        }
        for my $xy (grep { @$_ >= 4 } @runs) {
            $c->createLine(@$xy, -fill => $design ? $C{accent} : $C{ink}, -width => $design ? px(3) : 1,
                           ($design || $dash{$n} eq '' ? () : (-dash => $dash{$n})), -tags => [ 'curve', "curve$n" ]);
        }
    }
    for my $n (@names) {
        my ($at) = grep { $X->($_->[0]) >= $pl + $along{$n} * $pw } @{ $sr->{lines}{$n} };
        next unless $at && $at->[1] >= 0 && $at->[1] <= $pmax;
        my ($x, $y) = ($X->($at->[0]), $Y->($at->[1]) - px(8));
        $c->createRectangle($x - px(6), $y - px(7), $x + px(6), $y + px(7), -fill => $C{paper}, -outline => '');
        $c->createText($x, $y, -text => $n, -font => $UI_B, -fill => $n eq $sr->{design} ? $C{accent} : $C{ink});
    }
    my $r = px(3);
    for my $cn (sort keys %{ $sr->{points} }) {
        for my $p (@{ $sr->{points}{$cn} }) {
            my ($x, $y) = ($X->($p->[0]), $Y->($p->[1]));
            next if $p->[1] > $pmax;
            $c->createOval($x - $r, $y - $r, $x + $r, $y + $r, -outline => $C{ink}, -fill => $C{paper});
        }
    }
    for my $d (@{ $sr->{duty} }) {
        next if $d->{q} > $qmax || $d->{p} > $pmax;
        my ($x, $y) = ($X->($d->{q}), $Y->($d->{p}));
        my $bad = $d->{margin} < 0;
        $c->createRectangle($x - $r, $y - $r, $x + $r, $y + $r, -fill => $bad ? $C{error} : $C{ink}, -outline => '');
        $c->createText($x + px(6), $y - px(6), -text => $d->{label}, -anchor => 'w', -font => $UI_S,
                       -fill => $bad ? $C{error} : $C{ink}, -tags => [ 'duty' ]);
    }
    # The key, under the plot: each curve with its line, then each duty
    # point against the curve designed against.
    my $ky = $pb + px(48);
    for my $n (@names) {
        my $design = $n eq $sr->{design};
        $c->createLine($pl, $ky, $pl + px(26), $ky, -fill => $design ? $C{accent} : $C{ink},
                       -width => $design ? px(3) : 1, ($design || $dash{$n} eq '' ? () : (-dash => $dash{$n})));
        $c->createText($pl + px(34), $ky, -anchor => 'w', -font => $design ? $UI_S : $UI_S_N, -tags => [ 'key' ],
                       -fill => $design ? $C{accent} : $C{ink},
                       -text => "$n  $HardyCross::Graph::CURVE_NAME{$n}" . ($design ? ' - DESIGNED AGAINST' : ''));
        $ky += px(15);
    }
    for my $d (@{ $sr->{duty} }) {
        $c->createRectangle($pl + px(10), $ky - px(3), $pl + px(16), $ky + px(3),
                            -fill => $d->{margin} < 0 ? $C{error} : $C{ink}, -outline => '');
        $c->createText($pl + px(34), $ky, -anchor => 'w', -font => $UI_S_N, -tags => [ 'key' ],
                       -fill => $d->{margin} < 0 ? $C{error} : $C{ink},
                       -text => sprintf('%s  %.4g %s AT %.4g %s - %s HAS %.4g %s, %s %.4g %s%s', $d->{label},
                                        $d->{q}, $fu, $d->{p}, $pu, $sr->{design}, $d->{avail}, $pu,
                                        $d->{margin} < 0 ? 'SHORT BY' : 'MARGIN', abs $d->{margin}, $pu,
                                        length $d->{desc} ? "  ($d->{desc})" : ''));
        $ky += px(15);
    }
}

#------------------------------------------------------------------------------
# Files: NEW GRAPH, OPEN GRAPH, SAVE GRAPH, PRINT TO PDF.
#------------------------------------------------------------------------------
sub graph_ok_to_discard {
    return 1 unless graph_modified();
    my $a = $mw->messageBox(-title => 'UNSAVED GRAPH', -icon => 'warning', -type => 'YesNo',
        -message => 'THE GRAPH HAS UNSAVED CHANGES.  DISCARD THEM?');
    return lc($a) eq 'yes';
}
# graph_load -- put a graph's figures in the tab.  The fields are tied to the
# graph held here, so the values are copied in, not the graph replaced.
sub graph_load {
    my $g = shift;
    $graph->{project}{$_} = $g->{project}{$_} for @HardyCross::Graph::PROJECT;
    $graph->{axis}{$_}    = $g->{axis}{$_}    for @HardyCross::Graph::AXIS;
    $graph->{units}{$_}   = HardyCross::Graph::units($g)->{$_} for qw(FLOW PRESSURE);
    $_->() for @dd_refresh;
    # Element by element: a list assigned to a row would make new scalars and
    # leave the fields tied to the old ones.
    for my $c (@HardyCross::Graph::CURVES) {
        for my $i (0 .. $HardyCross::Graph::ROWS - 1) { $graph->{$c}[$i][$_] = $g->{$c}[$i][$_] for 0, 1 }
    }
    for my $i (0 .. $HardyCross::Graph::DUTY_ROWS - 1) { $graph->{duty}[$i][$_] = $g->{duty}[$i][$_] for 0 .. 3 }
    graph_refresh();
}
sub graph_new {
    return unless graph_ok_to_discard();
    # A new graph takes the PROJECT tab's flow and pressure units.
    my $g = HardyCross::Graph::new_graph();
    $g->{units}{$_} = $settings->{units}{$_} || $g->{units}{$_} for qw(FLOW PRESSURE);
    graph_load($g);
    $gv{path} = undef;
    $gv{saved} = graph_text();
    graph_refresh();
    message('NEW GRAPH');
}
sub graph_open {
    my $file = shift;
    return unless graph_ok_to_discard();
    $file //= $mw->getOpenFile(-filetypes => [ [ 'PHCP GRAPH', '.phg' ] ]);
    return unless defined $file && length $file;
    my $g = eval { HardyCross::Graph::read_file($file) };
    unless ($g) { message("GRAPH NOT OPENED: $@", 1); return }
    graph_load($g);
    $gv{path} = $file;
    $gv{saved} = graph_text();
    graph_refresh();
    message("GRAPH OPENED: $file");
    return 1;
}
sub graph_save {
    my $file = shift;
    $file //= $mw->getSaveFile(-defaultextension => '.phg', -filetypes => [ [ 'PHCP GRAPH', '.phg' ] ],
        -initialfile => defined $gv{path} ? ($gv{path} =~ s{.*[/\\]}{}r) : 'GRAPH.PHG');
    return unless defined $file && length $file;
    my $ok = eval { HardyCross::Graph::write_file($graph, $file) };
    unless ($ok) { message("GRAPH NOT SAVED: $@", 1); return }
    $gv{path} = $file;
    $gv{saved} = graph_text();
    graph_set_title();
    message("GRAPH SAVED: $file");
    return 1;
}
sub graph_pdf {
    my $file = shift;
    graph_refresh();
    unless ($gv{check}{ok}) { message('THE GRAPH HAS PROBLEMS - SEE THE LIST UNDER IT', 1); return }
    my $base = defined $gv{path} ? ($gv{path} =~ s{.*[/\\]}{}r =~ s/\.phg\z//ir) : 'GRAPH';
    $file //= $mw->getSaveFile(-defaultextension => '.pdf', -initialfile => "${base}_GRAPH.PDF",
        -filetypes => [ [ 'PDF', '.pdf' ] ]);
    return unless defined $file && length $file;
    my $ok = eval { HardyCross::Graph::write_pdf($graph, $file,
                        model => defined $gv{path} ? ($gv{path} =~ s{.*[/\\]}{}r) : '') };
    message($ok ? "GRAPH WRITTEN TO $file" : 'GRAPH NOT WRITTEN: ' . ($@ // ''), !$ok);
    return $ok;
}

1;
