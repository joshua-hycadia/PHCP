#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# HardyCross/Window/Isometric.pm -- the ISOMETRIC tab of phcp_editor.pl.
#
# The network drawn, rather than typed.  A click places a point or a pipe;
# the drawing writes the .phc the NETWORK tab shows, and VALIDATE and
# CALCULATE run on that text as they do on typed commands.  Positions are
# //ISO comments, which the reader ignores, so the calculation is the
# commands.  Every decision -- where a point sits, what a click hits, what
# text is written -- is HardyCross::Isometric.  This file is the window.
#
# The window is one program: this file is package main, loaded by
# phcp_editor.pl, and uses that file's widgets and its editor buffer.
#==============================================================================
package main;

use strict;
use warnings;
use HardyCross::Isometric;
use HardyCross::Phc;

our ($UI, $UI_B, $UI_S, $MONO, %C, $mw, $ed, $settings, $toptabs, $POINTER);

our ($iso_cv, %iso);

my @TOOLS = (
    [ 'SELECT',    'SELECT',    'SELECT A POINT OR A PIPE, AND DRAG A POINT ALONG THE GRID' ],
    [ 'NODE',      'NODE',      'CLICK THE GRID TO PLACE A POINT' ],
    [ 'WATER',     'WATER',     'CLICK THE GRID TO PLACE A WATER SUPPLY' ],
    [ 'SPRINKLER', 'SPRINKLER', 'CLICK THE GRID TO PLACE A SPRINKLER' ],
    [ 'HYDRANT',   'HYDRANT',   'CLICK THE GRID TO PLACE A HYDRANT' ],
    [ 'HREEL',     'REEL',      'CLICK THE GRID TO PLACE A HOSE REEL' ],
    [ 'PIPE',      'PIPE',      'CLICK A POINT, THEN THE NEXT POINT ALONG AN AXIS' ],
    [ 'PUMP',      'PUMP',      'CLICK THE TWO POINTS THE PUMP JOINS' ],
    [ 'FIXEDFLOW', 'FLOW',      'CLICK A POINT TO PUT A FIXED FLOW ON IT' ],
    [ 'DELETE',    'DELETE',    'CLICK A POINT OR A PIPE TO REMOVE IT' ],
);

sub build_isometric {
    my $page = shift;
    my $bar = $page->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -padx => px(8), -pady => px(6));
    for my $t (@TOOLS) {
        my ($kind, $label) = @$t;
        $iso{tools}{$kind} = flat_button($bar, $label, sub { iso_set_tool($kind) })
            ->pack(-side => 'left', -padx => px([0, 4]));
    }
    my $bar2 = $page->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -padx => px(8), -pady => px([0, 6]));
    $iso{elev_label} = $bar2->Label(-text => 'ELEVATION', -font => $UI_S, -background => $C{paper},
        -foreground => $C{muted})->pack(-side => 'left');
    $iso{elev} = '0';
    my $ee = flat_entry($bar2, \$iso{elev}, 8);
    $ee->pack(-side => 'left', -padx => px([6, 12]));
    $ee->bind('<Return>' => sub { iso_status('ELEVATION SET. THE NEXT POINT IS PLACED THERE.') });
    $bar2->Label(-text => 'GRID M', -font => $UI_S, -background => $C{paper}, -foreground => $C{muted})
        ->pack(-side => 'left');
    $iso{gridvar} = '1';
    my $ge = flat_entry($bar2, \$iso{gridvar}, 6);
    $ge->pack(-side => 'left', -padx => px([6, 12]));
    $ge->bind('<Return>' => sub { iso_grid_apply() });
    $iso{btn}{FIT}  = flat_button($bar2, 'FIT',      sub { iso_fit(1) })->pack(-side => 'left', -padx => px([0, 4]));
    $iso{btn}{IN}   = flat_button($bar2, 'ZOOM IN',  sub { iso_zoom(1.25) })->pack(-side => 'left', -padx => px(4));
    $iso{btn}{OUT}  = flat_button($bar2, 'ZOOM OUT', sub { iso_zoom(1 / 1.25) })->pack(-side => 'left', -padx => px(4));
    $iso{status_w} = $bar2->Label(-text => '', -font => $UI, -background => $C{paper}, -foreground => $C{muted},
        -anchor => 'w')->pack(-side => 'left', -padx => px(12), -fill => 'x', -expand => 1);
    rule($page, 'x', -side => 'top');

    # The drawing.  Scrollbars, no divider: the results pane is already one,
    # and another would be counted with it.
    my $ef = $page->Frame(-background => $C{paper})->pack(-fill => 'both', -expand => 1);
    my $vsb = flat_scrollbar($ef, 'vertical')->pack(-side => 'right', -fill => 'y');
    my $hsb = flat_scrollbar($ef, 'horizontal')->pack(-side => 'bottom', -fill => 'x');
    $iso_cv = $ef->Canvas(-background => $C{paper}, -highlightthickness => 0, -borderwidth => 0,
        -confine => 1, -cursor => $POINTER, -takefocus => 1,
        -xscrollcommand => sub { $hsb->set(@_) },
        -yscrollcommand => sub { $vsb->set(@_) })->pack(-fill => 'both', -expand => 1);
    $vsb->configure(-command => sub { $iso_cv->yview(@_) });
    $hsb->configure(-command => sub { $iso_cv->xview(@_) });
    wheel_target($iso_cv);
    # Canvas::bind attaches a tag to items.  These are the widget's own keys,
    # so they go through CanvasBind, which is Tk::bind.  Ev('x') is the
    # coordinate in the widget; the test generates the click that way.
    $iso_cv->CanvasBind('<ButtonPress-1>'   => [ sub { my ($w, $x, $y) = @_; iso_press($w->canvasx($x), $w->canvasy($y)) }, Ev('x'), Ev('y') ]);
    $iso_cv->CanvasBind('<B1-Motion>'       => [ sub { my ($w, $x, $y) = @_; iso_motion($w->canvasx($x), $w->canvasy($y)) }, Ev('x'), Ev('y') ]);
    $iso_cv->CanvasBind('<ButtonRelease-1>' => [ sub { my ($w, $x, $y) = @_; iso_release($w->canvasx($x), $w->canvasy($y)) }, Ev('x'), Ev('y') ]);
    $iso_cv->CanvasBind('<Escape>'          => sub { $iso{from} = undef; $iso{drag} = undef; iso_status('CANCELLED'); iso_redraw() });
    $iso_cv->CanvasBind('<Delete>'          => sub { iso_delete_sel() });

    $iso{props} = $page->Frame(-background => $C{panel})->pack(-side => 'bottom', -fill => 'x');
    rule($iso{props}, 'x', -side => 'top');
    $iso{tool} = 'SELECT';
    iso_set_tool('SELECT');
}

# iso_invalidate -- the text was replaced (a file opened).  The next time the
# tab is shown it reads again and fits the new drawing.
sub iso_invalidate {
    $iso{source} = undef;
    $iso{had_fit} = 0;
    $iso{sel} = undef;
    $iso{from} = undef;
    $iso{drag} = undef;
}

sub iso_key {
    my $u = $settings && $settings->{units} ? $settings->{units} : {};
    return buffer() . "\0" . join(',', map { defined $u->{$_} ? $u->{$_} : '' }
        qw(LENGTH ELEVATION SIZE PRESSURE FLOW KFACTOR));
}

# iso_show -- read the network if it changed, and draw it.  Called when the
# tab is selected and after the text changes while it is showing.  It does
# not write: looking at the drawing never reformats the file.
sub iso_show {
    return unless $iso_cv && $toptabs && ($toptabs->{current} || '') eq 'ISOMETRIC';
    my $key = iso_key();
    my $reload = !defined $iso{source} || $iso{source} ne $key || !$iso{draw};
    if ($reload) {
        $iso{draw} = HardyCross::Isometric::read_network(buffer(), $settings->{units});
        $iso{source} = $key;
        $iso{sel} = undef;
        $iso{from} = undef;
        $iso{gridvar} = HardyCross::Isometric::clean_num($iso{draw}{grid});
        iso_fit(1) unless $iso{had_fit};
        $iso{had_fit} = 1;
        iso_props();
    }
    my $eu = $settings->{units}{ELEVATION} || 'M';
    $iso{elev_label}->configure(-text => "ELEVATION $eu") if $iso{elev_label};
    iso_redraw();
}

sub iso_set_tool {
    my $kind = shift;
    $iso{tool} = $kind;
    $iso{from} = undef unless $kind eq 'PIPE' || $kind eq 'PUMP';
    for my $t (@TOOLS) {
        my $on = $t->[0] eq $kind;
        $iso{tools}{ $t->[0] }->configure(
            -background => $on ? $C{accent} : $C{paper},
            -foreground => $on ? '#FFFFFF' : $C{ink},
            -highlightbackground => $on ? $C{accent} : $C{line});
    }
    my ($hint) = map { $_->[2] } grep { $_->[0] eq $kind } @TOOLS;
    iso_status($hint || '');
    $iso_cv->configure(-cursor => $kind eq 'SELECT' ? $POINTER : 'crosshair') if $iso_cv;
}

sub iso_status {
    my $text = shift;
    return unless $iso{status_w};
    $iso{status_w}->configure(-text => uc($text), -foreground => $C{muted});
}
sub iso_fail {
    my $text = shift;
    return unless $iso{status_w};
    $iso{status_w}->configure(-text => uc($text), -foreground => $C{error});
}
sub iso_status_text { return $iso{status_w} ? $iso{status_w}->cget(-text) : '' }

sub iso_work_iz {
    my $d = $iso{draw} or return 0;
    my $m = HardyCross::Phc::length_metres($iso{elev}, $d->{units}{ELEVATION});
    return defined $m ? $m / ($d->{grid} || 1) : 0;
}

# iso_commit -- the drawing changed, so the network text changes with it.
# One undo step in the editor.  The source key is set before the recolour,
# which would otherwise read the text straight back and fit again.
sub iso_commit {
    return if $iso{busy};
    local $iso{busy} = 1;
    my $text = HardyCross::Isometric::write_network($iso{draw});
    if ($text ne buffer()) {
        discard_proposal();
        $ed->delete('1.0', 'end');
        $ed->insert('1.0', $text);
    }
    $iso{source} = iso_key();
    recolour();
    update_actions();
    update_status();
    set_title();
    iso_redraw();
    iso_props();
}

sub iso_grid_apply {
    my $err = HardyCross::Isometric::set_grid($iso{draw}, $iso{gridvar});
    if ($err) { iso_fail($err); return }
    iso_status('GRID SET. LENGTHS ALREADY ENTERED STAY UNTIL A POINT IS MOVED.');
    iso_commit();
}

#------------------------------------------------------------------------------
# Clicks.
#------------------------------------------------------------------------------
sub iso_press {
    my ($sx, $sy) = @_;
    return unless $iso{draw} && $iso{view};
    $iso_cv->focus if $iso_cv;
    my $d = $iso{draw};
    my $hit = HardyCross::Isometric::hit($d, $sx, $sy, $iso{view});
    my $tool = $iso{tool};

    if ($tool eq 'SELECT') {
        $iso{sel} = $hit;
        $iso{drag} = undef;
        if ($hit && $hit->{kind} eq 'node') {
            my $n = $d->{nodes}{ $hit->{name} };
            $iso{drag} = { name => $hit->{name}, ix => $n->{ix}, iy => $n->{iy}, iz => $n->{iz} };
        }
        iso_props();
        iso_redraw();
        iso_status($hit ? "$hit->{kind} $hit->{name}" : 'NOTHING THERE');
        return;
    }
    if ($tool eq 'DELETE') {
        if ($hit) { iso_delete_hit($hit) } else { iso_fail('CLICK A POINT OR A PIPE') }
        return;
    }
    if ($tool eq 'PIPE' || $tool eq 'PUMP') { iso_link_click($sx, $sy, $hit); return }
    if ($tool eq 'FIXEDFLOW') {
        unless ($hit && $hit->{kind} eq 'node') { iso_fail('CLICK A POINT'); return }
        my ($err, $name) = HardyCross::Isometric::add_fixedflow($d, $hit->{name});
        if ($err) { iso_fail($err); return }
        iso_status("$name ON $hit->{name}");
        iso_commit();
        return;
    }
    # A point tool.  A click on a point selects it; a click on the grid places one.
    if ($hit && $hit->{kind} eq 'node') {
        $iso{sel} = $hit;
        iso_props();
        iso_redraw();
        return;
    }
    my ($ix, $iy) = HardyCross::Isometric::cell_at($sx, $sy, $iso{view}, iso_work_iz());
    my ($err, $name) = HardyCross::Isometric::add_node($d, $tool, $ix, $iy, iso_work_iz(), $iso{elev});
    if ($err) { iso_fail($err); return }
    $iso{sel} = { kind => 'node', name => $name };
    iso_status("$tool $name PLACED");
    iso_commit();
}

# iso_link_click -- the first click chooses the start.  The next click, on a
# point or on an empty cell along an axis, is the end; an empty cell grows a
# point there.  The end stays the start, so a run is drawn click by click.
sub iso_link_click {
    my ($sx, $sy, $hit) = @_;
    my $d = $iso{draw};
    if (!$iso{from}) {
        if ($hit && $hit->{kind} eq 'node') {
            $iso{from} = $hit->{name};
        } else {
            my ($ix, $iy) = HardyCross::Isometric::cell_at($sx, $sy, $iso{view}, iso_work_iz());
            my ($err, $name) = HardyCross::Isometric::add_node($d, 'NODE', $ix, $iy, iso_work_iz(), $iso{elev});
            if ($err) { iso_fail($err); return }
            $iso{from} = $name;
            iso_commit();
        }
        iso_status("FROM $iso{from}. CLICK THE NEXT POINT ALONG AN AXIS.");
        iso_redraw();
        return;
    }
    my $a = $d->{nodes}{ $iso{from} } or do { $iso{from} = undef; return };
    my $end;
    if ($hit && $hit->{kind} eq 'node' && $hit->{name} ne $iso{from}) {
        my $b = $d->{nodes}{ $hit->{name} };
        unless (HardyCross::Isometric::axis_aligned($a, $b)) {
            iso_fail('A PIPE RUNS ALONG ONE GRID AXIS');
            return;
        }
        $end = $hit->{name};
    } else {
        my ($ix, $iy) = HardyCross::Isometric::cell_at($sx, $sy, $iso{view}, iso_work_iz());
        ($ix, $iy, my $iz) = HardyCross::Isometric::snap_axis($a, $ix, $iy, iso_work_iz());
        if (abs($ix - $a->{ix}) < 1e-9 && abs($iy - $a->{iy}) < 1e-9 && abs($iz - $a->{iz}) < 1e-6) {
            iso_fail('CLICK A POINT ALONG THE AXIS');
            return;
        }
        $end = HardyCross::Isometric::node_at($d, $ix, $iy, $iz);
        if (!$end) {
            my $elev = HardyCross::Isometric::metres_to_token($d, $iz * ($d->{grid} || 1), 'ELEVATION');
            my ($err, $name) = HardyCross::Isometric::add_node($d, 'NODE', $ix, $iy, $iz, $elev);
            if ($err) { iso_fail($err); return }
            $end = $name;
        }
    }
    my ($err, $name) = $iso{tool} eq 'PUMP'
        ? HardyCross::Isometric::add_pump($d, $iso{from}, $end)
        : HardyCross::Isometric::add_pipe($d, $iso{from}, $end);
    if ($err) { iso_fail($err); return }
    my $from = $iso{from};
    $iso{from} = $end;
    $iso{sel} = { kind => $iso{tool} eq 'PUMP' ? 'pump' : 'pipe', name => $name };
    iso_status("$name FROM $from TO $end. CLICK THE NEXT POINT, OR ESC.");
    iso_commit();
}

sub iso_motion {
    my ($sx, $sy) = @_;
    return unless $iso{drag} && $iso{tool} eq 'SELECT';
    my $n = $iso{draw}{nodes}{ $iso{drag}{name} } or return;
    my ($ix, $iy) = HardyCross::Isometric::cell_at($sx, $sy, $iso{view}, $n->{iz});
    $iso{ghost} = [ $ix, $iy, $n->{iz} ];
    iso_redraw();
}

sub iso_release {
    return unless $iso{drag};
    my $g = $iso{ghost};
    my $drag = $iso{drag};
    $iso{drag} = undef;
    $iso{ghost} = undef;
    if ($g && ($g->[0] != $drag->{ix} || $g->[1] != $drag->{iy})) {
        my $err = HardyCross::Isometric::move_node($iso{draw}, $drag->{name}, @$g);
        if ($err) { iso_fail($err); iso_redraw(); return }
        iso_status("$drag->{name} MOVED. ITS PIPES TAKE THEIR LENGTH FROM THE GRID.");
        iso_commit();
    } else {
        iso_redraw();
    }
}

sub iso_delete_hit {
    my $hit = shift or return;
    my $err = HardyCross::Isometric::delete_item($iso{draw}, $hit->{kind}, $hit->{name});
    if ($err) { iso_fail($err); return }
    $iso{sel} = undef if $iso{sel} && $iso{sel}{name} eq $hit->{name};
    $iso{from} = undef if defined $iso{from} && $iso{from} eq $hit->{name};
    iso_status("$hit->{name} DELETED");
    iso_commit();
}
sub iso_delete_sel { iso_delete_hit($iso{sel}) }

# iso_click_cell / iso_widget_at -- for the window test, a grid point as a click.
sub iso_click_cell {
    my ($ix, $iy, $iz) = @_;
    $iz = iso_work_iz() unless @_ > 2;
    my ($sx, $sy) = HardyCross::Isometric::project($ix, $iy, $iz, $iso{view});
    iso_press($sx, $sy);
}
sub iso_widget_at {
    my ($ix, $iy, $iz) = @_;
    $iz = iso_work_iz() unless @_ > 2;
    my ($sx, $sy) = HardyCross::Isometric::project($ix, $iy, $iz, $iso{view});
    return (sprintf('%.0f', $sx - $iso_cv->canvasx(0)), sprintf('%.0f', $sy - $iso_cv->canvasy(0)));
}

#------------------------------------------------------------------------------
# Drawing.
#------------------------------------------------------------------------------
sub iso_fit {
    my $force = shift;
    return unless $iso_cv && $iso{draw};
    $iso_cv->update if $force;
    my $cw = $iso_cv->width;  $cw = 900 if $cw < 40;
    my $ch = $iso_cv->height; $ch = 520 if $ch < 40;
    my @n = grep { defined $_->{ix} } map { $iso{draw}{nodes}{$_} } @{ $iso{draw}{node_order} };
    unless (@n) {
        $iso{view} = { ox => $cw * 0.45, oy => $ch * 0.55, scale => 36 };
        iso_redraw();
        return;
    }
    my ($minx, $miny, $maxx, $maxy);
    my $one = { ox => 0, oy => 0, scale => 1 };
    for my $n (@n) {
        my ($x, $y) = HardyCross::Isometric::project($n->{ix}, $n->{iy}, $n->{iz}, $one);
        $minx = $x if !defined $minx || $x < $minx;
        $miny = $y if !defined $miny || $y < $miny;
        $maxx = $x if !defined $maxx || $x > $maxx;
        $maxy = $y if !defined $maxy || $y > $maxy;
    }
    my $w = ($maxx - $minx) || 1;
    my $h = ($maxy - $miny) || 1;
    my $s = ($cw - 120) / $w;
    my $sh = ($ch - 120) / $h;
    $s = $sh if $sh < $s;
    # A long imported run has to fit the canvas.  A short branch is kept
    # large enough to click (the cap).  Zoom in when a step is too small.
    $s = 2 if $s < 2;
    $s = 48 if $s > 48;
    $iso{view} = { ox => 60 - $minx * $s, oy => 60 - $miny * $s, scale => $s };
    iso_redraw();
}

sub iso_zoom {
    my $factor = shift;
    return unless $iso{view};
    my $old = $iso{view}{scale};
    my $s = $old * $factor;
    $s = 2 if $s < 2;
    $s = 80 if $s > 80;
    my ($cx, $cy) = ($iso_cv->canvasx($iso_cv->width / 2), $iso_cv->canvasy($iso_cv->height / 2));
    $iso{view}{ox} = $cx - ($cx - $iso{view}{ox}) * $s / $old;
    $iso{view}{oy} = $cy - ($cy - $iso{view}{oy}) * $s / $old;
    $iso{view}{scale} = $s;
    iso_redraw();
}

sub iso_redraw {
    return unless $iso_cv && $iso{draw} && $iso{view};
    my $cv = $iso_cv;
    my $d = $iso{draw};
    my $v = $iso{view};
    $cv->delete('all');
    iso_grid($d, $v);
    for my $p (@{ $d->{pipes} }) { iso_link($d, $v, $p->{start}, $p->{end}, $p->{name}, 'pipe', $p) }
    for my $p (@{ $d->{pumps} }) { iso_link($d, $v, $p->{in}, $p->{out}, $p->{name}, 'pump', $p) }
    for my $name (@{ $d->{node_order} }) {
        my $n = $d->{nodes}{$name};
        next unless defined $n->{ix};
        my ($ix, $iy, $iz) = ($n->{ix}, $n->{iy}, $n->{iz});
        if ($iso{ghost} && $iso{drag} && $iso{drag}{name} eq $name) {
            ($ix, $iy, $iz) = @{ $iso{ghost} };
        }
        my ($x, $y) = HardyCross::Isometric::project($ix, $iy, $iz, $v);
        my $sel = $iso{sel} && $iso{sel}{kind} eq 'node' && $iso{sel}{name} eq $name;
        my $from = defined $iso{from} && $iso{from} eq $name;
        iso_node_mark($x, $y, $n->{kind}, $sel || $from);
        $cv->createText($x, $y - px(14), -text => $name, -font => $UI_S, -fill => $C{ink},
            -anchor => 's', -tags => [ 'label', "node:$name" ]);
        my @ff = map { $_->{name} } grep { $_->{node} eq $name } @{ $d->{flows} };
        $cv->createText($x, $y + px(14), -text => join(' ', @ff), -font => $UI_S, -fill => $C{muted},
            -anchor => 'n') if @ff;
    }
    my @b = $cv->bbox('all');
    if (@b) {
        my $pad = px(40);
        $cv->configure(-scrollregion => [ $b[0] - $pad, $b[1] - $pad, $b[2] + $pad, $b[3] + $pad ]);
    }
}

sub iso_grid {
    my ($d, $v) = @_;
    my $cv = $iso_cv;
    my ($minx, $maxx, $miny, $maxy) = (0, 4, 0, 4);
    for my $name (@{ $d->{node_order} }) {
        my $n = $d->{nodes}{$name};
        next unless defined $n->{ix};
        $minx = $n->{ix} if $n->{ix} < $minx; $maxx = $n->{ix} if $n->{ix} > $maxx;
        $miny = $n->{iy} if $n->{iy} < $miny; $maxy = $n->{iy} if $n->{iy} > $maxy;
    }
    $minx -= 2; $maxx += 2; $miny -= 2; $maxy += 2;
    my $span = $maxx - $minx;
    $span = $maxy - $miny if $maxy - $miny > $span;
    my $step = 1;
    $step *= 2 while $span / $step > 24;
    my $iz = iso_work_iz();
    my $line = sub {
        my ($a, $b) = @_;
        $cv->createLine(@$a, @$b, -fill => $C{line}, -tags => 'grid');
    };
    for (my $i = $minx; $i <= $maxx; $i += $step) {
        $line->([ HardyCross::Isometric::project($i, $miny, $iz, $v) ],
                [ HardyCross::Isometric::project($i, $maxy, $iz, $v) ]);
    }
    for (my $j = $miny; $j <= $maxy; $j += $step) {
        $line->([ HardyCross::Isometric::project($minx, $j, $iz, $v) ],
                [ HardyCross::Isometric::project($maxx, $j, $iz, $v) ]);
    }
}

sub iso_link {
    my ($d, $v, $a_name, $b_name, $name, $kind, $rec) = @_;
    my ($a, $b) = ($d->{nodes}{$a_name}, $d->{nodes}{$b_name});
    return unless $a && $b && defined $a->{ix} && defined $b->{ix};
    my ($ax, $ay, $aiz) = ($a->{ix}, $a->{iy}, $a->{iz});
    my ($bx, $by, $biz) = ($b->{ix}, $b->{iy}, $b->{iz});
    if ($iso{ghost} && $iso{drag}) {
        ($ax, $ay, $aiz) = @{ $iso{ghost} } if $iso{drag}{name} eq $a_name;
        ($bx, $by, $biz) = @{ $iso{ghost} } if $iso{drag}{name} eq $b_name;
    }
    my ($x1, $y1) = HardyCross::Isometric::project($ax, $ay, $aiz, $v);
    my ($x2, $y2) = HardyCross::Isometric::project($bx, $by, $biz, $v);
    my $sel = $iso{sel} && $iso{sel}{kind} eq $kind && $iso{sel}{name} eq $name;
    $iso_cv->createLine($x1, $y1, $x2, $y2, -fill => $sel ? $C{accent} : $C{ink},
        -width => $sel ? px(3) : px(2), -tags => [ $kind, "$kind:$name" ]);
    my $label = $name;
    $label .= ' ' . $rec->{device}{kind} if $rec->{device};
    $iso_cv->createText(($x1 + $x2) / 2, ($y1 + $y2) / 2 - px(8), -text => $label,
        -font => $UI_S, -fill => $kind eq 'pump' ? $C{accent} : $C{muted}, -anchor => 's');
}

sub iso_node_mark {
    my ($x, $y, $kind, $on) = @_;
    my $r = px(6);
    my $cv = $iso_cv;
    my $ink = $on ? $C{accent} : $C{ink};
    if ($kind eq 'WATER') {
        $cv->createRectangle($x - $r, $y - $r, $x + $r, $y + $r, -fill => $C{accent}, -outline => $C{accent},
            -tags => 'node');
    } elsif ($kind eq 'SPRINKLER') {
        $cv->createOval($x - $r, $y - $r, $x + $r, $y + $r, -outline => $ink, -width => px(2), -tags => 'node');
        $cv->createLine($x - $r, $y, $x + $r, $y, -fill => $ink, -tags => 'node');
        $cv->createLine($x, $y - $r, $x, $y + $r, -fill => $ink, -tags => 'node');
    } elsif ($kind eq 'HYDRANT') {
        $cv->createPolygon($x, $y - $r - 2, $x + $r + 2, $y, $x, $y + $r + 2, $x - $r - 2, $y,
            -outline => $ink, -fill => $C{paper}, -width => px(2), -tags => 'node');
    } elsif ($kind eq 'HREEL') {
        $cv->createOval($x - $r, $y - $r, $x + $r, $y + $r, -outline => $ink, -width => px(2), -tags => 'node');
        $cv->createOval($x - $r + 3, $y - $r + 3, $x + $r - 3, $y + $r - 3, -outline => $ink, -tags => 'node');
    } else {
        $cv->createOval($x - px(4), $y - px(4), $x + px(4), $y + px(4), -fill => $ink, -outline => $ink,
            -tags => 'node');
    }
}

#------------------------------------------------------------------------------
# The fields of whatever is selected.  Return in a field writes it back.
#------------------------------------------------------------------------------
sub iso_props {
    return unless $iso{props};
    my $f = $iso{props};
    $_->destroy for $f->children;
    my $sel = $iso{sel};
    my $hint = $f->Label(-text => '', -font => $UI, -background => $C{panel}, -foreground => $C{muted},
        -anchor => 'w');
    unless ($sel && $iso{draw}) {
        $hint->configure(-text => 'SELECT A POINT OR A PIPE, OR CHOOSE A TOOL AND CLICK THE GRID.');
        $hint->pack(-side => 'left', -padx => px(14), -pady => px(8));
        return;
    }
    my $d = $iso{draw};
    my @fields;
    if ($sel->{kind} eq 'node') {
        my $n = $d->{nodes}{ $sel->{name} } or return;
        @fields = ([ 'NAME', $n->{name}, 10 ], [ 'ELEVATION', $n->{elev}, 8 ]);
        push @fields, [ 'STATIC', $n->{static}, 8 ] if $n->{kind} eq 'WATER';
        push @fields, [ 'MINFLOW', $n->{minflow}, 8 ], [ 'K', $n->{k}, 8 ] if $n->{kind} =~ /^(SPRINKLER|HYDRANT|HREEL)\z/;
        $hint->configure(-text => $n->{kind});
    } elsif ($sel->{kind} eq 'pipe') {
        my ($p) = grep { $_->{name} eq $sel->{name} } @{ $d->{pipes} };
        return unless $p;
        @fields = ([ 'NAME', $p->{name}, 10 ], [ 'LENGTH', $p->{len}, 8 ], [ 'SIZE', $p->{size}, 6 ],
                   [ 'FITTINGS', join(' ', @{ $p->{fits} || [] }), 16 ],
                   [ 'TYPE', $p->{use_type}, 8 ], [ 'C', defined $p->{use_c} ? $p->{use_c} : '', 6 ]);
        $hint->configure(-text => 'PIPE');
    } elsif ($sel->{kind} eq 'pump') {
        my ($p) = grep { $_->{name} eq $sel->{name} } @{ $d->{pumps} };
        return unless $p;
        @fields = ([ 'NAME', $p->{name}, 10 ], [ 'CHURN', $p->{churn}, 8 ],
                   [ 'FLOW', $p->{pairs}[0], 8 ], [ 'PRESSURE', $p->{pairs}[1], 8 ]);
        $hint->configure(-text => 'PUMP');
    }
    $hint->pack(-side => 'left', -padx => px([14, 8]), -pady => px(8));
    $iso{field} = {};
    for my $fd (@fields) {
        my ($lab, $val, $w) = @$fd;
        $f->Label(-text => $lab, -font => $UI_S, -background => $C{panel}, -foreground => $C{muted})
            ->pack(-side => 'left', -padx => px([8, 4]));
        my $var = $val;
        $var = '' unless defined $var;
        $iso{field}{$lab} = $var;
        my $e = flat_entry($f, \$iso{field}{$lab}, $w);
        $e->pack(-side => 'left', -pady => px(6));
        my $field = $lab;
        $e->bind('<Return>' => sub { iso_apply_field($field) });
    }
}

sub iso_apply_field {
    my $field = shift;
    return if $iso{busy} || !$iso{sel};
    my $sel = $iso{sel};
    my $value = $iso{field}{$field};
    my $err = $sel->{kind} eq 'node' ? HardyCross::Isometric::set_node($iso{draw}, $sel->{name}, $field, $value)
            : $sel->{kind} eq 'pump' ? HardyCross::Isometric::set_pump($iso{draw}, $sel->{name}, $field, $value)
            : HardyCross::Isometric::set_pipe($iso{draw}, $sel->{name}, $field, $value);
    if ($err) { iso_fail($err); return }
    $sel->{name} = $value if $field eq 'NAME' && defined $value && $value ne '';
    iso_status('CHANGED');
    iso_commit();
}

# iso_set_field -- the window test types into a field the way Return would.
sub iso_set_field {
    my ($field, $value) = @_;
    $iso{field}{$field} = $value;
    iso_apply_field($field);
}

1;
