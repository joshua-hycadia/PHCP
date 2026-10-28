#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# The read-only viewer: open a model, solve it, look at the results.  Kept for
# checking a model without any risk of editing it; the spreadsheet,
# phcp_gui.pl, is the program for building and changing one.
#==============================================================================
# phcp_viewer.pl -- the read-only PHCP viewer.
#
# The whole stack is Perl: parser, topology, solver, tables, pixels.  Nothing
# is compiled and there is no toolchain beyond the interpreter and Tk.
#
# It carries the same design rules as the Qt and Lisp front ends, because they
# are rules about reading numbers rather than about a toolkit:
#   - numbers right-aligned in a monospaced face, so decimal points stack
#   - units in the heading, never repeated in the cells
#   - headings uppercase and quiet; the data should win the page
#   - colour carries meaning only -- a fault is red, nothing else is coloured
#   - the model is never edited here: this front end reads and solves
#
# Four tabs, matching the Lisp build:
#   ELEMENTS     flows and velocities
#   NODES        elevation, pressure, total head
#   LOOPS        the fundamental loop set, real and pseudo marked.  The report
#                tells a reviewer to check this FIRST, because every number
#                downstream depends on the loop set being right.
#   CONVERGENCE  max |dQ| and max |sum hf| per iteration.  A run that crawls
#                onto tolerance and one that drops onto it look identical from
#                the final numbers alone; they are not the same run.

use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use Tk;
use Tk::NoteBook;
use Tk::HList;
use Tk::ItemStyle;
use HardyCross;
use HardyCross::Parse;

# --- design tokens, named once ---------------------------------------------
my $INK      = '#1D1D1F';
my $INK2     = '#6E6E73';
my $SURFACE  = '#FFFFFF';
my $SURFACE2 = '#FAFAFA';
my $ACCENT   = '#0B63CE';
my $BAD      = '#B3261E';
my $GOOD     = '#0B6B4F';
my $HAIR     = '#E8E8E6';
my $MONO     = 'Monospace 10';
my $UI       = 'Helvetica 9';
my $UI_B     = 'Helvetica 9 bold';
my $UNIT     = 8;                 # the spacing grid

my ($net, $path);
my (%tables, %styles);
my ($status, $summary);

sub set_status {
    my ($text, $colour) = @_;
    $status->configure(-text => "  " . uc($text), -foreground => $colour // $GOOD);
}

# ---------------------------------------------------------------------------
# Tables.
#
# Tk::HList gives real columns with per-column alignment, which is the one
# thing a schedule cannot do without.  A Text widget padded with spaces looks
# the same until the first proportional glyph and then does not.
# ---------------------------------------------------------------------------
sub make_table {
    my ($parent, $name, $cols) = @_;
    my $h = $parent->Scrolled('HList',
        -scrollbars => 'osoe',
        -header     => 1,
        -columns    => scalar @$cols,
        -background => $SURFACE,
        -foreground => $INK,
        -font       => $MONO,
        -highlightthickness => 0,
        -borderwidth => 0,
        -selectmode => 'single',
    )->pack(-fill => 'both', -expand => 1, -padx => $UNIT, -pady => $UNIT);

    for my $i (0 .. $#$cols) {
        my ($title, $width, $anchor) = @{ $cols->[$i] };
        # The heading takes the SAME anchor as the column beneath it.  A
        # right-aligned column of figures under a left-aligned title is the
        # commonest way a schedule stops lining up.
        my $head = $h->Label(-text => uc($title), -font => $UI_B,
                             -foreground => $INK2, -background => $SURFACE2,
                             -anchor => $anchor, -padx => 6);
        $h->header('create', $i, -itemtype => 'window', -widget => $head);
        $h->columnWidth($i, $width);
    }

    $styles{"$h-right"} = $h->ItemStyle('text',
        -anchor => 'e', -font => $MONO, -background => $SURFACE, -foreground => $INK);
    $styles{"$h-left"} = $h->ItemStyle('text',
        -anchor => 'w', -font => $MONO, -background => $SURFACE, -foreground => $INK);
    $styles{"$h-bad"} = $h->ItemStyle('text',
        -anchor => 'e', -font => $MONO, -background => $SURFACE, -foreground => $BAD);

    $tables{$name} = { hlist => $h, cols => $cols };
    return $h;
}

sub clear_table {
    my $name = shift;
    $tables{$name}{hlist}->delete('all');
}

sub add_row {
    my ($name, $values, $badcols) = @_;
    my $t = $tables{$name};
    my $h = $t->{hlist};
    my $e = $h->addchild('');
    for my $i (0 .. $#$values) {
        my $anchor = $t->{cols}[$i][2];
        my $key = ($badcols && $badcols->{$i}) ? "$h-bad"
                : $anchor eq 'e' ? "$h-right" : "$h-left";
        $h->itemCreate($e, $i, -text => $values->[$i], -style => $styles{$key});
    }
}

# ---------------------------------------------------------------------------
sub fmt { sprintf('%.*f', $_[1], $_[0]) }
sub sci { sprintf('%.3e', $_[0]) }

sub elem_kind {
    my $k = shift->{kind};
    my %name = (PIPE => 'PIPE', PUMP => 'PUMP',
                SUPPLY_STATIC => 'STATIC', SUPPLY_CURVE => 'CURVE',
                DISCHARGE => 'OUTLET', FIXED_DROP => 'PRV',
                ORIFICE => 'ORIFICE', ORIFICE_REQUIRED => 'ORIFICE_P',
                BFP => 'BFP');
    return $name{$k} // $k;
}

sub loop_is_pseudo {
    my $lp = shift;
    for my $step (@$lp) {
        my $e = $net->{elems}[ $step->[0] ];
        return 1 if $e->{n1} == $net->{iref} || $e->{n2} == $net->{iref};
    }
    return 0;
}

sub refresh {
    clear_table($_) for qw(elements nodes loops convergence);
    return unless $net;

    my $uf = $net->{f_flow};
    my $up = $net->{f_pres};
    my $ul = $net->{f_len};

    for my $ei (1 .. $#{ $net->{elems} }) {
        my $e = $net->{elems}[$ei];
        my $q = $e->{q};
        my $vel = $e->{kind} eq 'PIPE'
                ? HardyCross::pipe_velocity($q, $e->{dia}) : undef;
        # Reverse flow through a supply or a pump is physically impossible and
        # is the one thing worth colouring here.
        my $bad = ($q < -1e-6 && $e->{kind} =~ /^(SUPPLY_|PUMP)/) ? { 4 => 1 } : undef;
        add_row('elements', [
            $e->{id}, elem_kind($e),
            $net->{nodes}[ $e->{n1} ]{id}, $net->{nodes}[ $e->{n2} ]{id},
            fmt($q / $uf, 1),
            defined $vel ? fmt($vel, 2) : '-',
        ], $bad);
    }

    for my $i (1 .. $#{ $net->{nodes} }) {
        my $n = $net->{nodes}[$i];
        next if $n->{id} eq 'REF';
        add_row('nodes', [
            $n->{id}, fmt($n->{z} / $ul, 2),
            fmt(($n->{h} - $HardyCross::GAMMA_W * $n->{z}) / $up, 1),
            fmt($n->{h} / $up, 1),
        ]);
    }

    my $i = 0;
    for my $lp (@{ $net->{loops} }) {
        $i++;
        my $pseudo = loop_is_pseudo($lp);
        # Comma separated: a space inside a cell is fine in Tk, but commas
        # export cleanly and read as a list rather than as a sentence.
        my $sig = join ',', map {
            ($_->[1] > 0 ? '+' : '-') . $net->{elems}[ $_->[0] ]{id}
        } @$lp;
        add_row('loops', [ ($pseudo ? "PL$i" : "L$i"),
                           ($pseudo ? 'PSEUDO' : 'REAL'),
                           scalar @$lp, $sig ]);
    }

    my $h = $net->{history} // [];
    my $step = int(@$h / 60) || 1;
    for my $j (0 .. $#$h) {
        next unless $j % $step == 0 || $j == $#$h;
        my ($it, $dq, $res) = @{ $h->[$j] };
        add_row('convergence', [ $it, sci($dq / $uf), sci($res / $up) ]);
    }
}

sub solve_path {
    my $p = shift;
    my $n = eval { HardyCross::Parse::read_model($p) };
    unless ($n) {
        my $err = $@;
        $net = undef;
        refresh();
        $summary->configure(-text => '  ' . uc($p =~ s{.*/}{}r));
        # The engine refuses a model it cannot solve honestly rather than
        # returning different numbers.  Show the refusal in its own words: an
        # empty table with no explanation would look like a bug in the GUI.
        set_status('model refused - ' .
                   (HardyCross::is_model_error($err) ? $err->{msg} : $err), $BAD);
        return;
    }
    my $ok = eval { HardyCross::solve_model($n) };
    unless (defined $ok) {
        my $err = $@;
        $net = undef;
        refresh();
        set_status('error - ' .
                   (HardyCross::is_model_error($err) ? $err->{msg} : $err), $BAD);
        return;
    }
    ($net, $path) = ($n, $p);
    refresh();
    $summary->configure(-text => sprintf('  %s   |   %d LOOPS   |   %d ITERATIONS   |   CONTINUITY %s L/MIN',
        uc($p =~ s{.*/}{}r), scalar @{ $net->{loops} }, $net->{iters},
        sci(HardyCross::continuity_error($net))));
    set_status($ok ? 'converged' : 'did not converge - nothing here is usable',
               $ok ? $GOOD : $BAD);
}

# ---------------------------------------------------------------------------
my $mw = MainWindow->new;
$mw->title('PHCP - VIEWER');
$mw->geometry('1180x760');
$mw->configure(-background => $SURFACE2);
$mw->optionAdd('*Font' => $UI);

my $menu = $mw->Menu(-type => 'menubar', -font => $UI_B);
$mw->configure(-menu => $menu);
my $file = $menu->cascade(-label => 'FILE', -tearoff => 0);
$file->command(-label => 'OPEN...', -accelerator => 'Ctrl+O', -command => sub {
    my $f = $mw->getOpenFile(-filetypes => [['PHCP model', ['.phc', '.hcx']], ['All', '*']]);
    solve_path($f) if $f;
});
$file->separator;
$file->command(-label => 'QUIT', -accelerator => 'Ctrl+Q', -command => sub { $mw->destroy });
my $model = $menu->cascade(-label => 'MODEL', -tearoff => 0);
$model->command(-label => 'RE-SOLVE', -accelerator => 'F5',
                -command => sub { solve_path($path) if $path });

my $bar = $mw->Frame(-background => $SURFACE2)
             ->pack(-side => 'top', -fill => 'x', -padx => $UNIT, -pady => $UNIT);
$bar->Button(-text => 'OPEN...', -font => $UI_B, -command => sub {
    my $f = $mw->getOpenFile(-filetypes => [['PHCP model', ['.phc', '.hcx']], ['All', '*']]);
    solve_path($f) if $f;
})->pack(-side => 'left');
$bar->Button(-text => 'RE-SOLVE (F5)', -font => $UI_B,
             -command => sub { solve_path($path) if $path })
    ->pack(-side => 'left', -padx => $UNIT);
$summary = $bar->Label(-text => '', -font => $UI, -background => $SURFACE2,
                       -foreground => $INK2, -anchor => 'w')
              ->pack(-side => 'left', -padx => $UNIT * 2);

$status = $mw->Label(-text => '  READY', -font => $UI_B, -anchor => 'w',
                     -background => $SURFACE2, -foreground => $GOOD)
            ->pack(-side => 'bottom', -fill => 'x', -padx => $UNIT, -pady => $UNIT);

my $nb = $mw->NoteBook(-background => $SURFACE2, -font => $UI_B,
                       -inactivebackground => $SURFACE2)
           ->pack(-fill => 'both', -expand => 1, -padx => $UNIT);

make_table($nb->add('elements', -label => 'ELEMENTS'), 'elements',
    [ ['element', 120, 'w'], ['type', 140, 'w'], ['from', 90, 'w'],
      ['to', 90, 'w'], ['flow lpm', 130, 'e'], ['vel m/s', 110, 'e'] ]);
make_table($nb->add('nodes', -label => 'NODES'), 'nodes',
    [ ['node', 120, 'w'], ['elevation m', 150, 'e'],
      ['pressure kpa', 160, 'e'], ['total head kpa', 170, 'e'] ]);
make_table($nb->add('loops', -label => 'LOOPS'), 'loops',
    [ ['loop', 90, 'w'], ['kind', 110, 'w'], ['elements', 110, 'e'],
      ['signed element list', 700, 'w'] ]);
make_table($nb->add('convergence', -label => 'CONVERGENCE'), 'convergence',
    [ ['iteration', 130, 'e'], ['max |dQ| lpm', 200, 'e'],
      ['max |sum hf| kpa', 220, 'e'] ]);

$mw->bind('<F5>'          => sub { solve_path($path) if $path });
$mw->bind('<Control-q>'   => sub { $mw->destroy });

solve_path($ARGV[0]) if @ARGV;
MainLoop;
