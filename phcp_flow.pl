#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# phcp_flow.pl -- a drawn network.
#
#   perl phcp_flow.pl [model.phc]
#
#   +------------------------------------------------------------------+
#   | NEW OPEN SAVE | VALIDATE CALCULATE | ARRANGE FIT      [ status ] |
#   +--------+----------------------------------------------+----------+
#   | SELECT |                                              |  card    |
#   | WATER  |   blocks, and the pipes drawn between them   |          |
#   | NODE   |                                              |          |
#   | ...    |                                              |          |
#   +--------+----------------------------------------------+----------+
#   | PLACE A BLOCK, THEN DRAG FROM A PORT TO CONNECT                 |
#   +------------------------------------------------------------------+
#
# The page is the network.  A supply, a junction or a head is a block; a
# line dragged from one block to another is a pipe, or a pump when that
# tool is on.  A device sits in the pipe it is given.  The text editor is
# a different program and is not changed by this one.
#
# THIS FILE IS ONLY THE WINDOW.  What a drawing contains, what .phc it
# writes, and whether that file calculates, is HardyCross::Flow, which has
# no Tk in it.  tools/test_flow.pl checks that without a display.
# tools/test_flow_window.pl drives this window; it loads the file without
# the event loop (see the end) and calls the handlers below.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use Tk;
use HardyCross;
use HardyCross::Phc;
use HardyCross::Flow;
use HardyCross::Parse;
use HardyCross::PipeData;
use File::Spec;

our %C = (
    paper     => '#FFFFFF',
    panel     => '#F6F7F9',
    line      => '#DDE1E6',
    hover     => '#EEF1F5',
    ink       => '#111111',
    muted     => '#6B7280',
    faint     => '#A3AAB4',
    accent    => '#1F5FBF',
    accent_dk => '#184C99',
    pipe      => '#3D4754',
    error     => '#C62828',
);
my %KIND_COLOR = (
    WATER => '#1F5FBF', NODE => '#374151', SPRINKLER => '#0E7490',
    HYDRANT => '#1B6B3A', HREEL => '#8A5A00',
);
our $POINTER = $^O eq 'MSWin32' ? 'arrow' : 'left_ptr';
our ($UI, $UI_B, $UI_S);
our ($BW, $BH) = (172, 86);     # a block, in page units; the view scales it

# The window's state.  One window, so package variables.
our ($mw, $canvas, $insp, $status_lbl);
our ($doc, $path, $saved_text, $valid_text, $sel, $tool, $zoom, $gesture);
our (%btn, %toolbtn, %FV);
our @FKEYS;
our ($building, $applying) = (0, 0);
our %WIRE;                      # edge id -> canvas points, for a click on a line

#------------------------------------------------------------------------------
# Fonts and a sharp window on Windows, the same choices as the text editor.
#------------------------------------------------------------------------------
sub dpi_aware {
    return unless $^O eq 'MSWin32';
    eval {
        require Win32::API;
        my $per = Win32::API->new('shcore', 'SetProcessDpiAwareness', 'I', 'I');
        if ($per) { $per->Call(1) } else { Win32::API->new('user32', 'SetProcessDPIAware', '', 'I')->Call() }
        1;
    };
}

sub pick_fonts {
    my %have = map { lc $_ => 1 } $mw->fontFamilies;
    my ($ui) = grep { $have{ lc $_ } } 'Segoe UI', 'DejaVu Sans', 'Liberation Sans', 'Helvetica Neue', 'Arial';
    $ui //= 'Helvetica';
    ($UI, $UI_B, $UI_S) = ([ $ui, 9 ], [ $ui, 10, 'bold' ], [ $ui, 8 ]);
}

sub flat {
    my ($parent, $text, $cmd) = @_;
    return $parent->Button(
        -text => $text, -command => $cmd,
        -relief => 'flat', -borderwidth => 0, -highlightthickness => 0,
        -bg => $C{panel}, -fg => $C{ink},
        -activebackground => $C{hover}, -activeforeground => $C{ink},
        -padx => 10, -pady => 6, -font => $UI, -cursor => $POINTER,
    );
}

#==============================================================================
# The window.
#==============================================================================
sub build_window {
    dpi_aware();
    $mw = MainWindow->new(-title => 'PHCP FLOW');
    $mw->configure(-bg => $C{panel});
    $mw->geometry('1280x800');
    pick_fonts();
    $doc = HardyCross::Flow::blank();
    $saved_text = HardyCross::Flow::write_text($doc);
    $valid_text = undef;
    $sel = undef;
    $tool = 'SELECT';
    $zoom = 1;
    $gesture = undef;
    $path = undef;

    my $bar = $mw->Frame(-bg => $C{panel})->pack(-fill => 'x');
    flat($bar, 'NEW', \&file_new)->pack(-side => 'left');
    flat($bar, 'OPEN', \&file_open)->pack(-side => 'left');
    flat($bar, 'SAVE', \&file_save)->pack(-side => 'left');
    $bar->Frame(-bg => $C{line}, -width => 1)->pack(-side => 'left', -fill => 'y', -padx => 6, -pady => 6);
    flat($bar, 'VALIDATE', \&do_validate)->pack(-side => 'left');
    $btn{CALCULATE} = flat($bar, 'CALCULATE', \&do_calculate);
    $btn{CALCULATE}->pack(-side => 'left', -padx => 2);
    $bar->Frame(-bg => $C{line}, -width => 1)->pack(-side => 'left', -fill => 'y', -padx => 6, -pady => 6);
    flat($bar, 'ARRANGE', \&do_arrange)->pack(-side => 'left');
    flat($bar, 'FIT', \&fit_view)->pack(-side => 'left');
    $status_lbl = $bar->Label(
        -text => '', -anchor => 'e', -font => $UI, -bg => $C{panel}, -fg => $C{muted},
    )->pack(-side => 'right', -padx => 12);

    $mw->Frame(-bg => $C{line}, -height => 1)->pack(-fill => 'x');

    my $body = $mw->Frame(-bg => $C{panel})->pack(-fill => 'both', -expand => 1);
    my $pal = $body->Frame(-bg => $C{panel}, -width => 148)->pack(-side => 'left', -fill => 'y');
    $pal->packPropagate(0);
    $body->Frame(-bg => $C{line}, -width => 1)->pack(-side => 'left', -fill => 'y');

    my $held = $body->Scrolled('Canvas',
        -scrollbars => 'se', -bg => $C{paper}, -highlightthickness => 0,
        -width => 820, -height => 640, -cursor => $POINTER,
    )->pack(-side => 'left', -fill => 'both', -expand => 1);
    $canvas = $held->Subwidget('canvas');

    $body->Frame(-bg => $C{line}, -width => 1)->pack(-side => 'left', -fill => 'y');
    $insp = $body->Frame(-bg => $C{panel}, -width => 300)->pack(-side => 'left', -fill => 'y');
    $insp->packPropagate(0);

    $mw->Frame(-bg => $C{line}, -height => 1)->pack(-fill => 'x');
    $mw->Label(
        -text => 'PLACE A BLOCK, THEN DRAG FROM A PORT TO CONNECT.  F4 VALIDATES, F5 CALCULATES.',
        -anchor => 'w', -font => $UI_S, -bg => $C{panel}, -fg => $C{muted},
    )->pack(-fill => 'x', -padx => 10, -pady => 4);

    for my $name ('SELECT', @HardyCross::Flow::BLOCK_KINDS, 'PIPE', 'PUMP') {
        my $b = $pal->Button(
            -text => $name, -command => sub { set_tool($name) },
            -relief => 'flat', -borderwidth => 0, -highlightthickness => 0,
            -anchor => 'w', -font => $UI, -cursor => $POINTER,
            -padx => 12, -pady => 5,
        )->pack(-fill => 'x', -padx => 6, -pady => 1);
        $toolbtn{$name} = $b;
    }
    set_tool('SELECT');

    # Canvas::bind is for items.  These are the page itself, so Tk::bind.
    $canvas->Tk::bind('<Button-1>' => \&on_press);
    $canvas->Tk::bind('<B1-Motion>' => \&on_drag);
    $canvas->Tk::bind('<ButtonRelease-1>' => \&on_release);
    # The middle and the right button both pan: not every mouse has a middle.
    $canvas->Tk::bind('<Button-2>' => sub { $_[0]->scanMark($_[0]->XEvent->x, $_[0]->XEvent->y) });
    $canvas->Tk::bind('<B2-Motion>' => sub { $_[0]->scanDragto($_[0]->XEvent->x, $_[0]->XEvent->y, 1) });
    $canvas->Tk::bind('<Button-3>' => sub { $_[0]->scanMark($_[0]->XEvent->x, $_[0]->XEvent->y) });
    $canvas->Tk::bind('<B3-Motion>' => sub { $_[0]->scanDragto($_[0]->XEvent->x, $_[0]->XEvent->y, 1) });
    $canvas->Tk::bind('<Button-4>' => sub { zoom_by(1.1, $_[0]->XEvent) });
    $canvas->Tk::bind('<Button-5>' => sub { zoom_by(1 / 1.1, $_[0]->XEvent) });
    $canvas->Tk::bind('<MouseWheel>' => sub {
        my $e = $_[0]->XEvent;
        zoom_by(($e->delta // 0) > 0 ? 1.1 : 1 / 1.1, $e);
    });

    $mw->bind('<Delete>' => \&on_delete);
    $mw->bind('<BackSpace>' => \&on_delete);
    $mw->bind('<Escape>' => sub { set_tool('SELECT') });
    $mw->bind('<F4>' => \&do_validate);
    $mw->bind('<F5>' => \&do_calculate);
    $mw->bind('<Control-s>' => \&file_save);
    $mw->bind('<Control-o>' => \&file_open);
    $mw->bind('<Control-n>' => \&file_new);
    $mw->protocol('WM_DELETE_WINDOW' => \&file_quit);

    refresh_inspector();
    redraw();
    sync_calc();
    set_title();
    status('NEW DRAWING');
}

sub set_tool {
    my $name = shift;
    $tool = $name;
    for my $n (keys %toolbtn) {
        my $on = $n eq $tool;
        $toolbtn{$n}->configure(
            -bg => $on ? $C{accent} : $C{panel},
            -fg => $on ? '#FFFFFF' : $C{ink},
            -activebackground => $on ? $C{accent_dk} : $C{hover},
            -activeforeground => $on ? '#FFFFFF' : $C{ink},
        );
    }
}

sub status {
    my ($msg, $bad) = @_;
    return unless $status_lbl;
    $status_lbl->configure(-text => $msg // '', -fg => $bad ? $C{error} : $C{muted});
}

sub set_title {
    my $name = defined $path ? $path : 'UNTITLED.PHC';
    $name =~ s{.*[/\\]}{};
    my $star = HardyCross::Flow::write_text($doc) ne ($saved_text // '') ? ' *' : '';
    $mw->title("PHCP FLOW - \U$name\E$star");
}

# sync_calc -- CALCULATE is the highlight only while VALIDATE still matches
# the drawing.  Moving a block does not count: a position is a comment.
sub sync_calc {
    return unless $btn{CALCULATE};
    my $on = defined $valid_text && $valid_text eq eval { HardyCross::Flow::model_text($doc) };
    $btn{CALCULATE}->configure(
        -bg => $on ? $C{accent} : $C{panel},
        -fg => $on ? '#FFFFFF' : $C{faint},
        -activebackground => $on ? $C{accent_dk} : $C{panel},
        -activeforeground => $on ? '#FFFFFF' : $C{faint},
    );
}

sub note_edit {
    my $before = shift;
    my $after = eval { HardyCross::Flow::model_text($doc) };
    redraw();
    set_title();
    return if defined $before && defined $after && $before eq $after;
    $valid_text = undef;
    sync_calc();
}

#==============================================================================
# Drawing.
#==============================================================================
sub node_rect {
    my $n = shift;
    my ($x, $y) = ($n->{x} * $zoom, $n->{y} * $zoom);
    return ($x, $y, $x + $BW * $zoom, $y + $BH * $zoom);
}

sub redraw {
    return unless $canvas;
    $canvas->delete('all');
    %WIRE = ();
    my ($x0, $y0, $x1, $y1) = (0, 0, 400, 300);
    for my $n (@{ $doc->{nodes} }) {
        my ($a, $b, $c, $d) = node_rect($n);
        $x0 = $a if $a < $x0; $y0 = $b if $b < $y0;
        $x1 = $c if $c > $x1; $y1 = $d if $d > $y1;
    }
    $x0 -= 80; $y0 -= 60; $x1 += 480; $y1 += 320;
    $x1 = $x0 + 1400 if $x1 - $x0 < 1400;
    $y1 = $y0 + 900 if $y1 - $y0 < 900;
    $canvas->configure(-scrollregion => [ $x0, $y0, $x1, $y1 ]);

    unless (@{ $doc->{nodes} }) {
        $canvas->createText(48, 48, -anchor => 'nw', -font => $UI, -fill => $C{muted},
            -text => "CHOOSE A BLOCK ON THE LEFT, THEN CLICK THE PAGE.\nDRAG FROM A PORT TO ANOTHER BLOCK TO CONNECT THEM.",
            -tags => ['hint']);
    }
    draw_edge($_) for @{ $doc->{edges} };
    draw_node($_) for @{ $doc->{nodes} };
    draw_gesture() if $gesture && $gesture->{kind} eq 'wire';
}

sub draw_node {
    my $n = shift;
    my ($x1, $y1, $x2, $y2) = node_rect($n);
    my $on = defined $sel && $sel eq $n->{id};
    my $tag = [ 'node', 'node:' . $n->{id} ];
    $canvas->createRectangle($x1, $y1, $x2, $y2,
        -fill => $C{paper}, -outline => $on ? $C{accent} : $C{line}, -width => $on ? 2 : 1,
        -tags => $tag);
    $canvas->createRectangle($x1, $y1, $x1 + 5 * $zoom, $y2,
        -fill => $KIND_COLOR{ $n->{kind} } || $C{ink}, -outline => '', -tags => $tag);
    my $r = 5 * ($zoom < 1 ? $zoom : 1) + 3;
    for my $side (0, 1) {
        my $px = $side ? $x2 : $x1;
        my $py = ($y1 + $y2) / 2;
        $canvas->createOval($px - $r, $py - $r, $px + $r, $py + $r,
            -fill => $C{paper}, -outline => $C{accent}, -width => 1, -tags => [ @$tag, 'port' ]);
    }
    my $tx = $x1 + 12 * $zoom;
    $canvas->createText($tx, $y1 + 8 * $zoom, -anchor => 'nw', -text => $n->{kind},
        -fill => $KIND_COLOR{ $n->{kind} } || $C{ink}, -font => $UI_S, -tags => $tag);
    $canvas->createText($tx, $y1 + 24 * $zoom, -anchor => 'nw', -text => $n->{name},
        -fill => $C{ink}, -font => $UI_B, -tags => [ @$tag, 'name' ]);
    return if $zoom < 0.8;
    my $sub = 'EL ' . $n->{z};
    $sub .= '   ' . $n->{static} if $n->{kind} eq 'WATER';
    $sub .= '   K ' . $n->{k} if defined $n->{k};
    my @ff = map { $_->{name} } grep { $_->{node} eq $n->{id} } @{ $doc->{flows} };
    $sub .= '   ' . join(' ', @ff) if @ff;
    $canvas->createText($tx, $y1 + 46 * $zoom, -anchor => 'nw', -text => $sub,
        -fill => $C{muted}, -font => $UI_S, -tags => $tag);
    if (defined $n->{pressure}) {
        $canvas->createText($tx, $y1 + 64 * $zoom, -anchor => 'nw',
            -text => sprintf('%.1f %s', $n->{pressure}, $doc->{units}{PRESSURE}),
            -fill => $C{accent}, -font => $UI_S, -tags => [ @$tag, 'result' ]);
    }
}

sub draw_edge {
    my $e = shift;
    my $a = HardyCross::Flow::find($doc, $e->{from});
    my $b = HardyCross::Flow::find($doc, $e->{to});
    return unless $a && $b && $a->{kind};
    my ($x1, $y1, $s1) = port_toward_node($a, $b);
    my ($x2, $y2, $s2) = port_toward_node($b, $a);
    my @pts = curve($x1, $y1, $s1, $x2, $y2, $s2);
    $WIRE{ $e->{id} } = [ @pts ];
    my $on = defined $sel && $sel eq $e->{id};
    my $pump = $e->{kind} eq 'PUMP';
    $canvas->createLine(@pts,
        -fill => $on ? $C{accent} : ($pump ? $C{accent} : $C{pipe}),
        -width => $on ? 3 : 2, -capstyle => 'round', -joinstyle => 'round',
        -tags => [ 'wire', 'wire:' . $e->{id}, $pump ? 'pump' : 'pipe' ]);
    my $k = int(@pts / 4);                 # a point near the middle
    my ($mx, $my) = ($pts[2 * $k], $pts[2 * $k + 1]);
    if ($pump) {
        pump_box($e, $mx, $my);
    } else {
        my $label = $e->{name} . '  ' . $e->{size};
        $label .= '  AS ' . $e->{sized} if defined $e->{sized};
        $canvas->createText($mx, $my - 16, -text => $label, -font => $UI_S, -fill => $C{ink},
            -tags => [ 'wire', 'wire:' . $e->{id} ]);
        if (defined $e->{flow}) {
            $canvas->createText($mx, $my - 28, -font => $UI_S, -fill => $C{accent},
                -text => flow_text($e->{flow}),
                -tags => [ 'wire', 'result', 'wire:' . $e->{id} ]);
        }
        device_pill($e, $mx, $my) if $e->{device};
    }
}

sub pump_box {
    my ($e, $mx, $my) = @_;
    my $tag = [ 'wire', 'pump', 'wire:' . $e->{id} ];
    $canvas->createRectangle($mx - 46, $my - 16, $mx + 46, $my + 16,
        -fill => '#E8F0FC', -outline => $C{accent}, -width => 1, -tags => $tag);
    $canvas->createText($mx, $my - 4, -text => $e->{name}, -font => $UI_B, -fill => $C{accent}, -tags => $tag);
    $canvas->createText($mx, $my + 8, -text => defined $e->{flow} ? flow_text($e->{flow}) : 'PUMP',
        -font => $UI_S, -fill => $C{ink}, -tags => [ @$tag, defined $e->{flow} ? 'result' : () ]);
}

sub device_pill {
    my ($e, $mx, $my) = @_;
    my $t = $e->{device}{kind};
    my $w = 8 + length($t) * 7;
    my $tag = [ 'wire', 'device', 'wire:' . $e->{id} ];
    $canvas->createRectangle($mx - $w / 2, $my - 8, $mx + $w / 2, $my + 8,
        -fill => $C{paper}, -outline => $C{accent}, -tags => $tag);
    $canvas->createText($mx, $my, -text => $t, -font => $UI_S, -fill => $C{accent}, -tags => $tag);
}

sub port_toward_node {
    my ($n, $other) = @_;
    my ($x1, $y1, $x2, $y2) = node_rect($n);
    my ($ox1, $oy1, $ox2, $oy2) = node_rect($other);
    my $py = ($y1 + $y2) / 2;
    if (($ox1 + $ox2) / 2 >= ($x1 + $x2) / 2) { return ($x2, $py, 1) }
    return ($x1, $py, 0);
}

sub curve {
    my ($x1, $y1, $s1, $x2, $y2, $s2) = @_;
    my $dx = abs($x2 - $x1) * 0.45;
    $dx = 36 if $dx < 36;
    my ($c1x, $c2x) = ($x1 + ($s1 ? $dx : -$dx), $x2 + ($s2 ? $dx : -$dx));
    my @p;
    for my $i (0 .. 16) {
        my $t = $i / 16;
        my $u = 1 - $t;
        push @p, $u**3 * $x1 + 3 * $u * $u * $t * $c1x + 3 * $u * $t * $t * $c2x + $t**3 * $x2;
        push @p, $u**3 * $y1 + 3 * $u * $u * $t * $y1 + 3 * $u * $t * $t * $y2 + $t**3 * $y2;
    }
    return @p;
}

# flow_text -- how much water is moving, in the file's unit.  The solver's
# sign is which way along the pipe; the page shows the amount.
sub flow_text {
    my $q = abs(shift // 0);
    return sprintf($q >= 100 ? '%.0f %s' : '%.1f %s', $q, $doc->{units}{FLOW});
}

sub draw_gesture {
    my $n = HardyCross::Flow::find($doc, $gesture->{from}) or return;
    my ($x1, $y1, $x2, $y2) = node_rect($n);
    my $side = $gesture->{cx} >= ($x1 + $x2) / 2;
    my @pts = curve($side ? $x2 : $x1, ($y1 + $y2) / 2, $side ? 1 : 0,
                    $gesture->{cx}, $gesture->{cy}, $gesture->{cx} < ($x1 + $x2) / 2);
    $canvas->createLine(@pts, -fill => $C{accent}, -width => 2, -dash => [ 4, 3 ], -tags => ['gesture']);
}

#==============================================================================
# The pointer.
#==============================================================================
sub event_xy {
    my $e = $_[0]->XEvent;
    return ($canvas->canvasx($e->x), $canvas->canvasy($e->y));
}

sub hit_port {
    my ($cx, $cy) = @_;
    for my $n (reverse @{ $doc->{nodes} }) {
        my ($x1, $y1, $x2, $y2) = node_rect($n);
        my $py = ($y1 + $y2) / 2;
        for my $px ($x1, $x2) {
            return $n->{id} if ($cx - $px)**2 + ($cy - $py)**2 <= 12**2;
        }
    }
    return;
}

sub hit_node {
    my ($cx, $cy) = @_;
    for my $n (reverse @{ $doc->{nodes} }) {
        my ($x1, $y1, $x2, $y2) = node_rect($n);
        return $n if $cx >= $x1 && $cx <= $x2 && $cy >= $y1 && $cy <= $y2;
    }
    return;
}

sub hit_wire {
    my ($cx, $cy) = @_;
    my ($best, $bd);
    for my $e (@{ $doc->{edges} }) {
        my $pts = $WIRE{ $e->{id} } or next;
        for (my $i = 0; $i < @$pts - 2; $i += 2) {
            my $d = dist_seg($cx, $cy, $pts->[$i], $pts->[$i + 1], $pts->[$i + 2], $pts->[$i + 3]);
            if ($d <= 8 && (!defined $bd || $d < $bd)) { $bd = $d; $best = $e }
        }
    }
    return $best;
}

sub dist_seg {
    my ($px, $py, $x1, $y1, $x2, $y2) = @_;
    my ($dx, $dy) = ($x2 - $x1, $y2 - $y1);
    my $l2 = $dx * $dx + $dy * $dy;
    if ($l2 < 1e-6) { return sqrt(($px - $x1)**2 + ($py - $y1)**2) }
    my $t = (($px - $x1) * $dx + ($py - $y1) * $dy) / $l2;
    $t = 0 if $t < 0;
    $t = 1 if $t > 1;
    return sqrt(($px - ($x1 + $t * $dx))**2 + ($py - ($y1 + $t * $dy))**2);
}

sub on_press {
    my ($cx, $cy) = event_xy(@_);
    my ($wx, $wy) = ($cx / $zoom, $cy / $zoom);
    my $node = hit_node($cx, $cy);
    if ($tool ne 'SELECT' && $tool ne 'PIPE' && $tool ne 'PUMP') {
        if ($node) { select_id($node->{id}); return }
        my $n = HardyCross::Flow::add_node($doc, $tool, $wx - $BW / 2, $wy - $BH / 2);
        return status(HardyCross::Flow::error, 1) unless $n;
        $sel = $n->{id};
        note_edit(undef);
        refresh_inspector();
        return;
    }
    if ($tool eq 'PIPE' || $tool eq 'PUMP') {
        if ($node) {
            $gesture = { kind => 'wire', from => $node->{id}, cx => $cx, cy => $cy, edge => $tool };
            select_id($node->{id});
        }
        return;
    }
    my $port = hit_port($cx, $cy);
    if ($port) {
        $gesture = { kind => 'wire', from => $port, cx => $cx, cy => $cy, edge => 'PIPE' };
        redraw();
        return;
    }
    if ($node) {
        select_id($node->{id});
        $gesture = { kind => 'move', id => $node->{id}, cx => $cx, cy => $cy, ox => $node->{x}, oy => $node->{y} };
        return;
    }
    if (my $wire = hit_wire($cx, $cy)) { select_id($wire->{id}); return }
    select_id(undef);
}

sub on_drag {
    return unless $gesture;
    my ($cx, $cy) = event_xy(@_);
    if ($gesture->{kind} eq 'move') {
        my ($wx, $wy) = ($cx / $zoom, $cy / $zoom);
        my ($sx, $sy) = ($gesture->{cx} / $zoom, $gesture->{cy} / $zoom);
        HardyCross::Flow::move_node($doc, $gesture->{id},
            $gesture->{ox} + ($wx - $sx), $gesture->{oy} + ($wy - $sy));
        redraw();
        set_title();
    } else {
        $gesture->{cx} = $cx;
        $gesture->{cy} = $cy;
        redraw();
    }
}

sub on_release {
    return unless $gesture;
    my ($cx, $cy) = event_xy(@_);
    my $g = $gesture;
    $gesture = undef;
    if ($g->{kind} eq 'move') {
        my $n = HardyCross::Flow::find($doc, $g->{id});
        # A click selects.  It should not nudge the block by a pixel or two.
        if ($n && abs($n->{x} - $g->{ox}) * $zoom < 4 && abs($n->{y} - $g->{oy}) * $zoom < 4) {
            HardyCross::Flow::move_node($doc, $g->{id}, $g->{ox}, $g->{oy});
        }
        redraw();
        set_title();
        return;
    }
    my $node = hit_node($cx, $cy);
    if ($node && $node->{id} ne $g->{from}) {
        my $before = HardyCross::Flow::model_text($doc);
        my $e = HardyCross::Flow::add_edge($doc, $g->{edge}, $g->{from}, $node->{id});
        if ($e) {
            $sel = $e->{id};
            note_edit($before);
            refresh_inspector();
            return;
        }
        status(HardyCross::Flow::error, 1);
    }
    redraw();
}

sub on_delete {
    my $f = eval { $mw->focusCurrent };
    return if $f && eval { $f->isa('Tk::Entry') };
    delete_selected();
}

sub delete_selected {
    return unless defined $sel;
    my $before = HardyCross::Flow::model_text($doc);
    unless (HardyCross::Flow::remove($doc, $sel)) {
        status(HardyCross::Flow::error, 1);
        return;
    }
    $sel = undef;
    note_edit($before);
    refresh_inspector();
}

sub zoom_by {
    my ($factor, $e) = @_;
    my $cx = $canvas->canvasx($e->x);
    my $cy = $canvas->canvasy($e->y);
    my ($wx, $wy) = ($cx / $zoom, $cy / $zoom);
    my $nz = $zoom * $factor;
    $nz = 0.35 if $nz < 0.35;
    $nz = 2.5 if $nz > 2.5;
    return if abs($nz - $zoom) < 1e-6;
    $zoom = $nz;
    redraw();
    my ($nx, $ny) = ($wx * $zoom, $wy * $zoom);
    my ($x1, $y1, $x2, $y2) = split / /, $canvas->cget('-scrollregion');
    my $ww = $canvas->width || 1;
    my $wh = $canvas->height || 1;
    my ($sw, $sh) = ($x2 - $x1, $y2 - $y1);
    my $fx = $sw > $ww ? (($nx - $e->x) - $x1) / ($sw - $ww) : 0;
    my $fy = $sh > $wh ? (($ny - $e->y) - $y1) / ($sh - $wh) : 0;
    $fx = 0 if $fx < 0; $fx = 1 if $fx > 1;
    $fy = 0 if $fy < 0; $fy = 1 if $fy > 1;
    $canvas->xviewMoveto($fx);
    $canvas->yviewMoveto($fy);
}

sub fit_view {
    return unless @{ $doc->{nodes} };
    my ($x0, $y0, $x1, $y1);
    for my $n (@{ $doc->{nodes} }) {
        $x0 = $n->{x} if !defined $x0 || $n->{x} < $x0;
        $y0 = $n->{y} if !defined $y0 || $n->{y} < $y0;
        my ($r, $b) = ($n->{x} + $BW, $n->{y} + $BH);
        $x1 = $r if !defined $x1 || $r > $x1;
        $y1 = $b if !defined $y1 || $b > $y1;
    }
    $mw->update;
    my $cw = ($canvas->width || 800) - 80;
    my $ch = ($canvas->height || 600) - 80;
    $cw = 200 if $cw < 200;
    $ch = 200 if $ch < 200;
    my $zw = $cw / (($x1 - $x0) || 1);
    my $zh = $ch / (($y1 - $y0) || 1);
    $zoom = $zw < $zh ? $zw : $zh;
    # Below 1 the words no longer fit in the blocks, and a long main is
    # scrolled instead of shrunk.  A short branch may grow a little.
    $zoom = 1 if $zoom < 1;
    $zoom = 1.3 if $zoom > 1.3;
    redraw();
    $canvas->xviewMoveto(0);
    $canvas->yviewMoveto(0);
}

sub do_arrange {
    HardyCross::Flow::layout($doc, 1);
    redraw();
    set_title();
    status('ARRANGED');
}

#==============================================================================
# The card on the right.
#==============================================================================
sub select_id {
    my $id = shift;
    commit_form();
    $sel = $id;
    refresh_inspector();
    redraw();
}

sub refresh_inspector {
    return unless $insp;
    $building = 1;
    $_->destroy for $insp->children;
    %FV = ();
    @FKEYS = ();
    my $obj = defined $sel ? HardyCross::Flow::find($doc, $sel) : undef;
    if ($obj && $obj->{kind} && $obj->{kind} =~ /^(WATER|NODE|SPRINKLER|HYDRANT|HREEL)\z/) {
        card_node($obj);
    } elsif ($obj && $obj->{kind} && $obj->{kind} =~ /^(PIPE|PUMP)\z/) {
        card_edge($obj);
    } else {
        $sel = undef if $obj;          # a fixed flow is edited on its block
        card_file();
    }
    $building = 0;
}

sub card_head {
    my ($title, $sub) = @_;
    $insp->Label(-text => $title, -font => $UI_B, -bg => $C{panel}, -fg => $C{ink}, -anchor => 'w')
        ->pack(-fill => 'x', -padx => 12, -pady => [12, 0]);
    $insp->Label(-text => $sub, -font => $UI_S, -bg => $C{panel}, -fg => $C{muted}, -anchor => 'w')
        ->pack(-fill => 'x', -padx => 12, -pady => [0, 8]) if defined $sub && $sub ne '';
}

sub form_entry {
    my ($label, $key, $value) = @_;
    $FV{$key} = defined $value ? $value : '';
    push @FKEYS, $key;
    my $row = $insp->Frame(-bg => $C{panel})->pack(-fill => 'x', -padx => 12, -pady => 2);
    $row->Label(-text => $label, -width => 11, -anchor => 'w', -font => $UI_S,
        -bg => $C{panel}, -fg => $C{muted})->pack(-side => 'left');
    my $e = $row->Entry(
        -textvariable => \$FV{$key}, -font => $UI, -width => 16,
        -relief => 'flat', -highlightthickness => 1,
        -highlightbackground => $C{line}, -highlightcolor => $C{accent},
        -bg => $C{paper}, -fg => $C{ink}, -insertbackground => $C{ink},
    )->pack(-side => 'left', -fill => 'x', -expand => 1);
    $e->bind('<FocusOut>' => \&commit_form);
    $e->bind('<Return>' => \&commit_form);
}

sub form_menu {
    my ($label, $key, $value, $options, $rebuild) = @_;
    $value = '' unless defined $value;
    my @opt = @$options;
    unshift @opt, $value if $value ne '' && !grep { $_ eq $value } @opt;
    $FV{$key} = $value;
    push @FKEYS, $key;
    my $row = $insp->Frame(-bg => $C{panel})->pack(-fill => 'x', -padx => 12, -pady => 2);
    $row->Label(-text => $label, -width => 11, -anchor => 'w', -font => $UI_S,
        -bg => $C{panel}, -fg => $C{muted})->pack(-side => 'left');
    $row->Optionmenu(
        -options => \@opt, -variable => \$FV{$key}, -font => $UI,
        -relief => 'flat', -borderwidth => 1, -highlightthickness => 0,
        -bg => $C{paper}, -activebackground => $C{hover},
        -command => sub {
            return if $building || $applying;
            commit_form();
            # Rebuilding the card now would destroy this menu while its own
            # command is still running.
            if ($rebuild) { $mw->after(1, sub { refresh_inspector(); redraw() }) }
            else { redraw() }
        },
    )->pack(-side => 'left', -fill => 'x', -expand => 1);
}

sub card_button {
    my ($text, $cmd) = @_;
    flat($insp, $text, $cmd)->pack(-fill => 'x', -padx => 12, -pady => 4);
}

sub card_file {
    card_head('DRAWING', 'TITLE, METHOD AND UNITS. OPTIONS IN THE FILE ARE KEPT.');
    form_entry('TITLE', 'title', $doc->{title} // '');
    form_menu('METHOD', 'method', $doc->{method} // 'HW', [ 'HW', 'DW' ]);
    for my $q (@HardyCross::Phc::UNIT_QUANTITIES) {
        form_menu($q, "unit_$q", $doc->{units}{$q}, $HardyCross::Phc::UNIT_CHOICES{$q});
    }
    my $i = 0;
    for my $p (@{ $doc->{project} }) {
        form_entry($p->{field}, "project_$i", $p->{text});
        $i++;
    }
}

sub card_node {
    my $n = shift;
    my $sub = defined $n->{pressure}
        ? sprintf('%.1f %s', $n->{pressure}, $doc->{units}{PRESSURE}) : '';
    card_head($n->{kind}, $sub);
    form_entry('NAME', 'name', $n->{name});
    form_entry('ELEVATION', 'z', $n->{z});
    if ($n->{kind} eq 'WATER') {
        form_entry('STATIC', 'static', $n->{static});
        form_entry('CURVE', 'pairs', join ' ', @{ $n->{pairs} || [] });
    } elsif ($n->{kind} ne 'NODE') {
        form_entry('MIN FLOW', 'minflow', $n->{minflow});
        form_entry('K', 'k', $n->{k});
    }
    my @ff = grep { $_->{node} eq $n->{id} } @{ $doc->{flows} };
    if (@ff) {
        $insp->Label(-text => 'FIXED FLOW', -font => $UI_S, -bg => $C{panel}, -fg => $C{muted}, -anchor => 'w')
            ->pack(-fill => 'x', -padx => 12, -pady => [10, 2]);
        for my $fl (@ff) {
            form_entry('NAME', $fl->{id} . ':name', $fl->{name});
            form_entry('FLOW', $fl->{id} . ':q', $fl->{q});
            form_entry('MIN P', $fl->{id} . ':minp', $fl->{minp} // '');
        }
    }
    card_button('ADD FIXED FLOW', sub {
        commit_form();
        my $before = HardyCross::Flow::model_text($doc);
        my $f = HardyCross::Flow::add_fixedflow($doc, $n->{id});
        return status(HardyCross::Flow::error, 1) unless $f;
        note_edit($before);
        refresh_inspector();
    });
    card_button('DELETE', \&delete_selected);
}

sub card_edge {
    my $e = shift;
    my $sub = '';
    $sub = sprintf('%.1f %s', $e->{flow}, $doc->{units}{FLOW}) if defined $e->{flow};
    $sub .= ($sub ? '   ' : '') . 'AS ' . $e->{sized} if defined $e->{sized};
    card_head($e->{kind} eq 'PUMP' ? 'PUMP' : 'PIPE', $sub);
    form_entry('NAME', 'name', $e->{name});
    if ($e->{kind} eq 'PUMP') {
        form_entry('CHURN', 'churn', $e->{churn});
        form_entry('CURVE', 'pairs', join ' ', @{ $e->{pairs} || [] });
        form_entry('DUTY FLOW', 'duty_q', $e->{duty} ? $e->{duty}{q} : '');
        form_entry('DUTY P', 'duty_p', $e->{duty} ? $e->{duty}{p} : '');
    } else {
        form_entry('LENGTH', 'len', $e->{len});
        form_entry('SIZE', 'size', $e->{size});
        form_entry('FITTINGS', 'fits', join ' ', @{ $e->{fits} || [] });
        my @types = ('BORE');
        push @types, HardyCross::PipeData::pipe_types() if eval { HardyCross::Parse::ensure_db(); 1 };
        form_menu('TYPE', 'use_type', $e->{use}{type}, \@types);
        form_entry('C', 'use_c', $e->{use}{c} // '');
        form_entry('EQV', 'eqv', $e->{eqv} // '');
        form_menu('DEVICE', 'device', $e->{device} ? $e->{device}{kind} : 'NONE',
                  [ 'NONE', @HardyCross::Flow::DEVICE_KINDS ], 1);
        my $d = $e->{device};
        if ($d) {
            if ($d->{kind} eq 'BP') {
                form_entry('CHURN', 'churn', $d->{churn});
                form_entry('CURVE', 'pairs', join ' ', @{ $d->{pairs} || [] });
            } elsif ($d->{kind} eq 'BFP' || $d->{kind} eq 'PRV') {
                form_entry('CURVE', 'pairs', join ' ', @{ $d->{pairs} || [] });
            } elsif ($d->{kind} eq 'OPP') {
                form_entry('DROP', 'drop', $d->{drop});
                form_entry('CD', 'cd', $d->{cd} // '');
            } elsif ($d->{kind} eq 'OFD') {
                form_entry('BORE', 'bore', $d->{bore});
                form_entry('CD', 'cd', $d->{cd} // '');
            } elsif ($d->{kind} eq 'PRA') {
                form_entry('RATIO', 'ratio', $d->{ratio});
                form_entry('MIN INLET', 'mininlet', $d->{mininlet} // '');
                form_entry('BAND', 'band', $d->{band} // '');
            }
            if ($d->{kind} eq 'BP') {
                form_entry('DUTY FLOW', 'duty_q', $e->{duty} ? $e->{duty}{q} : '');
                form_entry('DUTY P', 'duty_p', $e->{duty} ? $e->{duty}{p} : '');
            }
        }
    }
    card_button('DELETE', \&delete_selected);
}

# commit_form -- write the card into the drawing.  Called when a field is
# left, so VALIDATE sees what is on the card and not the value before it.
sub commit_form {
    return if $building || $applying || !@FKEYS;
    $applying = 1;
    my $before = eval { HardyCross::Flow::model_text($doc) };
    my %f = map { $_ => $FV{$_} } @FKEYS;
    my $ok;
    my $obj = defined $sel ? HardyCross::Flow::find($doc, $sel) : undef;
    my $kind = $obj ? ($obj->{kind} // '') : '';
    if ($kind =~ /^(WATER|NODE|SPRINKLER|HYDRANT|HREEL)\z/) {
        my %node;
        $node{$_} = $f{$_} for grep { exists $f{$_} } qw(name z static pairs minflow k);
        $ok = HardyCross::Flow::apply($doc, $sel, \%node);
        if ($ok) {
            for my $fl (grep { $_->{node} eq $sel } @{ $doc->{flows} }) {
                my %ff;
                $ff{name} = $f{ $fl->{id} . ':name' } if exists $f{ $fl->{id} . ':name' };
                $ff{q} = $f{ $fl->{id} . ':q' } if exists $f{ $fl->{id} . ':q' };
                $ff{minp} = $f{ $fl->{id} . ':minp' } if exists $f{ $fl->{id} . ':minp' };
                $ok = HardyCross::Flow::apply($doc, $fl->{id}, \%ff);
                last unless $ok;
            }
        }
    } elsif ($kind eq 'PIPE' || $kind eq 'PUMP') {
        $ok = HardyCross::Flow::apply($doc, $sel, \%f);
    } else {
        my @proj;
        for my $i (0 .. $#{ $doc->{project} || [] }) {
            push @proj, $f{"project_$i"} if exists $f{"project_$i"};
        }
        $f{project} = \@proj if @proj;
        $ok = HardyCross::Flow::apply_file($doc, \%f);
    }
    $applying = 0;
    unless ($ok) {
        status((HardyCross::Flow::error() // 'NOT SAVED'), 1);
        return;
    }
    note_edit($before);
}

#==============================================================================
# Validate, calculate, files.
#==============================================================================
sub _err {
    my $e = shift;
    return HardyCross::is_model_error($e) ? $e->{msg} : "$e";
}

sub do_validate {
    commit_form();
    my $r = HardyCross::Flow::validate($doc);
    if ($r->{ok}) {
        $valid_text = $r->{text};
        status('VALID');
    } else {
        $valid_text = undef;
        status($r->{error}, 1);
    }
    sync_calc();
    return $r;
}

sub do_calculate {
    commit_form();
    my $now = eval { HardyCross::Flow::model_text($doc) };
    unless (defined $valid_text && defined $now && $valid_text eq $now) {
        status('VALIDATE FIRST', 1);
        return { ok => 0, error => 'VALIDATE FIRST' };
    }
    $mw->configure(-cursor => 'watch');
    $canvas->configure(-cursor => 'watch');
    status('COMPUTING');
    $mw->update;
    my $r = HardyCross::Flow::calculate($doc, progress => sub {
        status($_[0]);
        $mw->update;
    });
    $mw->configure(-cursor => $POINTER);
    $canvas->configure(-cursor => $POINTER);
    redraw();
    refresh_inspector();
    if ($r->{ok}) { status($r->{message}) }
    else { status($r->{error} || 'DID NOT CONVERGE', 1) }
    return $r;
}

sub ok_to_discard {
    return 1 if HardyCross::Flow::write_text($doc) eq ($saved_text // '');
    my $a = $mw->messageBox(-title => 'PHCP FLOW', -icon => 'question', -type => 'YesNo',
                            -message => 'THE DRAWING HAS CHANGED. DISCARD IT?');
    return ($a // '') =~ /yes/i;
}

sub file_new {
    return unless ok_to_discard();
    $building = 1;
    $doc = HardyCross::Flow::blank();
    $path = undef;
    $sel = undef;
    $valid_text = undef;
    $gesture = undef;
    $zoom = 1;
    $saved_text = HardyCross::Flow::write_text($doc);
    $building = 0;
    refresh_inspector();
    redraw();
    sync_calc();
    set_title();
    status('NEW DRAWING');
}

sub file_open {
    my $f = $mw->getOpenFile(
        -defaultextension => '.phc',
        -filetypes => [ [ 'PHCP MODEL', '.phc' ], [ 'ALL FILES', '*' ] ]);
    open_path($f) if defined $f && $f ne '';
}

# open_path -- load a .phc file onto the page.  $force skips the discard
# question; a test, and the file named on the command line, pass it.
sub open_path {
    my ($file, $force) = @_;
    return 0 unless defined $file && $file ne '';
    unless ($file =~ /\.phc\z/i) {
        status('A DRAWING OPENS A .PHC FILE', 1);
        return 0;
    }
    return 0 unless $force || ok_to_discard();
    my $d = eval { HardyCross::Flow::read_file($file) };
    unless ($d) {
        status(_err($@), 1);
        return 0;
    }
    $building = 1;
    $doc = $d;
    $path = $file;
    $sel = undef;
    $gesture = undef;
    $valid_text = undef;
    $saved_text = HardyCross::Flow::write_text($doc);
    $building = 0;
    refresh_inspector();
    redraw();
    $mw->update;
    fit_view();
    sync_calc();
    set_title();
    status('OPENED');
    return 1;
}

sub file_save {
    my $file = shift;
    $file = $path unless defined $file && $file ne '';
    return file_save_as() unless defined $file && $file ne '';
    commit_form();
    my $ok = eval { HardyCross::Flow::write_file($doc, $file); 1 };
    unless ($ok) { status(_err($@), 1); return 0 }
    $path = $file;
    $saved_text = HardyCross::Flow::write_text($doc);
    set_title();
    status('SAVED');
    return 1;
}

sub file_save_as {
    my $f = shift // $mw->getSaveFile(
        -defaultextension => '.phc',
        -initialfile => ((defined $path ? $path : 'UNTITLED.PHC') =~ s{.*[/\\]}{}r),
        -filetypes => [ [ 'PHCP MODEL', '.phc' ] ]);
    return 0 unless defined $f && $f ne '';
    $f .= '.phc' unless $f =~ /\.phc\z/i;
    $path = $f;
    return file_save($f);
}

sub file_quit {
    return unless ok_to_discard();
    $mw->destroy;
}

#==============================================================================
# Start.  A test sets $PHCP_FLOW_LOAD_ONLY and builds the window itself.
# An explicit flag, not "unless caller": a packaged program is loaded by
# the packager, where caller is set, and the window would never open.
#==============================================================================
sub main {
    my $file = shift;
    build_window();
    open_path($file, 1) if defined $file && $file ne '';
    MainLoop();
}

our $PHCP_FLOW_LOAD_ONLY;
main(@ARGV) unless $PHCP_FLOW_LOAD_ONLY;

1;
