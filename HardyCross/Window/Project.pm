#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# HardyCross/Window/Project.pm -- part of the editor window, phcp_editor.pl:
# the PROJECT tab: title, project details, units, method and options.
#
# The window is split one file to a tab so each can be read on its own.  It
# is still one program: this file is in package main, shares the window's
# globals (declared with our in phcp_editor.pl and named again below) and its
# widget helpers, and is loaded by phcp_editor.pl with use.  Nothing here
# decides anything; the decisions are in the HardyCross modules it calls.

package main;

use strict;
use warnings;

our ($UI, $UI_B, $project_canvas, %C, $UI_S_N, $settings, %form);   # the window's globals, from phcp_editor.pl
#==============================================================================
# The PROJECT tab: the title and project details, the units, the method and
# the options.  Each field is tied to $settings; a change marks the file
# modified and turns CALCULATE off until VALIDATE is run again.  Text is
# kept in capitals as it is typed.
#==============================================================================
sub build_project {
    my $page = shift;
    # The form scrolls: on a short window, or with the results pane dragged
    # up, the CALCULATION options run below the bottom edge.  A canvas holds
    # the form, with the same thin scrollbar as the rest of the window.
    my $sb = flat_scrollbar($page, 'vertical')->pack(-side => 'right', -fill => 'y');
    my $cv = $page->Canvas(-background => $C{paper}, -highlightthickness => 0, -borderwidth => 0,
                           -yscrollcommand => sub { $sb->set(@_) })->pack(-fill => 'both', -expand => 1);
    $sb->configure(-command => sub { $cv->yview(@_) });
    my $wrap = $cv->Frame(-background => $C{paper});
    $cv->createWindow(px(18), px(12), -window => $wrap, -anchor => 'nw');
    $wrap->bind('<Configure>' => sub {
        $cv->configure(-scrollregion => [ 0, 0, $wrap->reqwidth + px(36), $wrap->reqheight + px(24) ]);
    });
    wheel_target($cv);
    $project_canvas = $cv;
    my $column = sub {
        my ($title) = @_;
        my $c = $wrap->Frame(-background => $C{paper})->pack(-side => 'left', -fill => 'y', -anchor => 'n', -padx => px([0, 26]));
        $c->Label(-text => $title, -font => $UI_B, -background => $C{paper}, -foreground => $C{ink}, -anchor => 'w')
          ->pack(-fill => 'x');
        rule($c, 'x', -pady => px([4, 8]));
        my $g = $c->Frame(-background => $C{paper})->pack(-fill => 'x');
        return $g;
    };
    my $row = 0;
    my $label = sub {
        my ($g, $text) = @_;
        $g->Label(-text => $text, -font => $UI, -background => $C{paper}, -foreground => $C{muted}, -anchor => 'w')
          ->grid(-row => $row, -column => 0, -sticky => 'w', -pady => px(3), -padx => px([0, 14]));
    };
    my $entry = sub {
        my ($g, $field, $var, $width) = @_;
        my $e = flat_entry($g, $var, $width);
        $e->grid(-row => $row, -column => 1, -sticky => 'w', -pady => px(3), -ipady => px(3));
        $e->bind('<KeyRelease>' => sub { settings_changed() });
        $form{$field} = $e;
        $row++;
    };

    my @f = @HardyCross::Editor::PROJECT_FIELDS;
    my $split = 9;           # PROJECT ... DATE in the first column
    my $g = $column->('PROJECT DETAILS');
    $row = 0;
    $label->($g, 'TITLE');
    $entry->($g, 'TITLE', \$settings->{title}, 34);
    for my $k (@f[0 .. $split]) {
        $settings->{project}{$k} //= '';
        $label->($g, HardyCross::Editor::project_label($k));
        $entry->($g, $k, \$settings->{project}{$k}, 34);
    }
    $g = $column->('DESIGN BASIS');
    $row = 0;
    for my $k (@f[ $split + 1 .. $#f ]) {
        $settings->{project}{$k} //= '';
        $label->($g, HardyCross::Editor::project_label($k));
        $entry->($g, $k, \$settings->{project}{$k}, 22);
    }

    $g = $column->('UNITS');
    $row = 0;
    for my $q (@HardyCross::Phc::UNIT_QUANTITIES) {
        $label->($g, $HardyCross::Editor::UNIT_LABEL{$q});
        my $dd = drop_down($g, \$settings->{units}{$q}, $HardyCross::Phc::UNIT_CHOICES{$q}, sub { settings_changed() },
                            $HardyCross::Phc::UNIT_DEFAULT{$q});
        $dd->grid(-row => $row, -column => 1, -sticky => 'w', -pady => px(3));
        $form{$q} = $dd;
        $row++;
    }

    # CALCULATION: each option with a plain label, its .phc name small and
    # grey beside it, and a line under it saying what it does and what a
    # blank means (HardyCross::Editor::@OPTION_FORM).
    $g = $column->('CALCULATION');
    $row = 0;
    my $help = sub {
        my ($text) = @_;
        $g->Label(-text => $text, -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted},
                  -justify => 'left', -anchor => 'w', -wraplength => px(300))
          ->grid(-row => $row++, -column => 0, -columnspan => 2, -sticky => 'w', -pady => px([0, 6]));
    };
    my $name = sub {
        my ($text, $key) = @_;
        my $f = $g->Frame(-background => $C{paper});
        $f->Label(-text => $text, -font => $UI, -background => $C{paper}, -foreground => $C{ink})->pack(-side => 'left');
        $f->Label(-text => $key, -font => $UI_S_N, -background => $C{paper}, -foreground => $C{faint})
          ->pack(-side => 'left', -padx => px([6, 0]));
        $f->grid(-row => $row, -column => 0, -sticky => 'w', -pady => px([3, 0]), -padx => px([0, 14]));
    };
    $name->('FRICTION FORMULA', 'METHOD');
    my $dd = drop_down($g, \$settings->{method}, [qw(HW DW)], sub { settings_changed() });
    $dd->grid(-row => $row++, -column => 1, -sticky => 'w', -pady => px([3, 0]));
    $form{METHOD} = $dd;
    $help->('HW HAZEN-WILLIAMS, THE SPRINKLER STANDARD\'S METHOD. DW DARCY-WEISBACH, WITH ROUGHNESS IN PLACE OF C.');
    for my $o (@HardyCross::Editor::OPTION_FORM) {
        unless (ref $o) {           # a subheading
            $g->Label(-text => $o, -font => $UI_B, -background => $C{paper}, -foreground => $C{ink}, -anchor => 'w')
              ->grid(-row => $row++, -column => 0, -columnspan => 2, -sticky => 'w', -pady => px([12, 4]));
            next;
        }
        my ($key, $text, $about, $choices) = @$o;
        $settings->{options}{$key} //= '';
        $name->($text, $key);
        if ($choices) {
            my $d = drop_down($g, \$settings->{options}{$key}, $choices, sub { settings_changed() });
            $d->grid(-row => $row, -column => 1, -sticky => 'w', -pady => px([3, 0]));
            $form{$key} = $d;
        } else {
            my $e = flat_entry($g, \$settings->{options}{$key}, 12);
            $e->grid(-row => $row, -column => 1, -sticky => 'w', -pady => px([3, 0]), -ipady => px(3));
            $e->bind('<KeyRelease>' => sub { settings_changed() });
            $form{$key} = $e;
        }
        $row++;
        $help->($about);
    }
}

# settings_changed -- after any change in the PROJECT tab.
sub settings_changed {
    for my $v (\$settings->{title}, \(@{ $settings->{project} }{ keys %{ $settings->{project} } }),
               \(@{ $settings->{options} }{ keys %{ $settings->{options} } })) {
        $$v = uc $$v if defined $$v && $$v =~ /[a-z]/;
    }
    set_title();
    update_actions();
    recolour();         # the units in force change what a line means
    update_status();
}

1;
