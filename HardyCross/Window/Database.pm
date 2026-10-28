#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# HardyCross/Window/Database.pm -- part of the editor window, phcp_editor.pl:
# the DATABASE tab: the pipe and fitting database, viewed and edited.
#
# The window is split one file to a tab so each can be read on its own.  It
# is still one program: this file is in package main, shares the window's
# globals (declared with our in phcp_editor.pl and named again below) and its
# widget helpers, and is loaded by phcp_editor.pl with use.  Nothing here
# decides anything; the decisions are in the HardyCross modules it calls.

package main;

use strict;
use warnings;

our ($MONO, $UI_B, $UI_S_N, %C, %dbv, $UI, $mw, $settings, $solved, $valid_text, $validation, $toptabs, %form, @dd_refresh);   # the window's globals, from phcp_editor.pl
#==============================================================================
# The DATABASE tab: the pipe and fitting database, viewed and edited.
#
# Read-only until EDIT THE DATABASE is ticked, because a change reaches every
# calculation made after it (decided 28 October 2026).  Four tables -- pipe
# types, pipe sizes, fittings, K' factors -- each with a filter; a click on a
# row puts it in the fields below, where it can be changed, added as a new
# row, or deleted.  SAVE CHANGES checks every row and the whole file, writes
# it, and makes it the database in use; the report then prints its new
# SHA-256.  Every decision is HardyCross::DbEdit's; this is drawing.
#
# Above the tables: where the database is -- the program's own (BUILT-IN), a
# copy beside the program, or a TEAM FOLDER chosen with CHOOSE FOLDER..., such
# as a folder on a network drive that every machine in a team points at.
#==============================================================================
sub build_database {
    my $page = shift;
    my $top = $page->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -padx => px(14), -pady => px([10, 6]));
    my $l1 = $top->Frame(-background => $C{paper})->pack(-fill => 'x');
    $dbv{origin} = $l1->Label(-text => '', -font => $UI_B, -padx => px(10), -pady => px(3))->pack(-side => 'left');
    $dbv{path} = $l1->Label(-text => '', -font => $MONO, -background => $C{paper}, -foreground => $C{ink})
                    ->pack(-side => 'left', -padx => px(10));
    $dbv{sha} = $l1->Label(-text => '', -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted})
                   ->pack(-side => 'left', -padx => px(6));
    $dbv{btn}{BUILTIN} = flat_button($l1, 'USE BUILT-IN', sub { db_use_builtin() })->pack(-side => 'right', -padx => px([6, 0]));
    $dbv{btn}{FOLDER}  = flat_button($l1, 'CHOOSE FOLDER...', sub { db_choose_folder() })->pack(-side => 'right', -padx => px(6));
    $dbv{btn}{RELOAD}  = flat_button($l1, 'RELOAD', sub { db_reload() })->pack(-side => 'right', -padx => px(6));

    my $l2 = $top->Frame(-background => $C{paper})->pack(-fill => 'x', -pady => px([10, 0]));
    $dbv{edit_box} = check_box($l2, 'EDIT THE DATABASE', \$dbv{editing}, sub { db_editing_changed() });
    $dbv{edit_box}{frame}->pack(-side => 'left');
    $dbv{btn}{SAVE} = flat_button($l2, 'SAVE CHANGES', sub { db_save() }, primary => 1)->pack(-side => 'left', -padx => px([16, 4]));
    $dbv{btn}{DISCARD} = flat_button($l2, 'DISCARD CHANGES', sub { db_reload(1) })->pack(-side => 'left', -padx => px(4));
    $dbv{note} = $l2->Label(-text => '', -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted},
                            -justify => 'left', -anchor => 'w')->pack(-side => 'left', -padx => px(14), -fill => 'x');
    my $ff = $l2->Frame(-background => $C{paper})->pack(-side => 'right');
    $ff->Label(-text => 'FILTER', -font => $UI, -background => $C{paper}, -foreground => $C{muted})->pack(-side => 'left');
    $dbv{filter} = '';
    my $fe = flat_entry($ff, \$dbv{filter}, 18)->pack(-side => 'left', -padx => px([8, 0]), -ipady => px(3));
    $fe->bind('<KeyRelease>' => sub { db_fill() });
    rule($page, 'x', -side => 'top');

    # The edit fields, under the tables.
    my $form = $page->Frame(-background => $C{panel})->pack(-side => 'bottom', -fill => 'x');
    rule($form, 'x', -side => 'top');
    $dbv{formrow} = $form->Frame(-background => $C{panel})->pack(-fill => 'x', -padx => px(14), -pady => px([8, 4]));
    my $fb = $form->Frame(-background => $C{panel})->pack(-fill => 'x', -padx => px(14), -pady => px([0, 8]));
    $dbv{btn}{UPDATE} = flat_button($fb, 'UPDATE ROW', sub { db_update() })->pack(-side => 'left', -padx => px([0, 4]));
    $dbv{btn}{ADD}    = flat_button($fb, 'ADD AS NEW ROW', sub { db_add() })->pack(-side => 'left', -padx => px(4));
    $dbv{btn}{DELETE} = flat_button($fb, 'DELETE ROW', sub { db_delete() })->pack(-side => 'left', -padx => px(4));
    $dbv{msg} = $fb->Label(-text => '', -font => $UI_B, -background => $C{panel}, -foreground => $C{muted},
                           -anchor => 'w', -justify => 'left')->pack(-side => 'left', -padx => px(14), -fill => 'x');

    my @kinds = map { $_->[0] } @HardyCross::DbEdit::TABLES;
    my %title = map { $_->[0] => $_->[1] } @HardyCross::DbEdit::TABLES;
    $dbv{tabs} = make_tabs($page, [ map { $title{$_} } @kinds ], sub {
        my $t = shift;
        ($dbv{kind}) = grep { $title{$_} eq $t } @kinds;
        db_fill();
        db_form();
    });
    db_reload(1);
}

# db_open -- read the database in use into the tab; a file that cannot be
# read (a team folder off the network) is said so, and the tab shows nothing.
sub db_open {
    my $db = eval { HardyCross::Parse::ensure_db(); HardyCross::DbEdit::open_db(HardyCross::PipeData::path()) };
    $dbv{error} = $db ? undef : uc(ref $@ ? $@->{msg} : "$@");
    $dbv{error} =~ s/\s+\z// if $dbv{error};
    $dbv{db} = $db;
}

# db_reload -- read the database again from its file, losing unsaved edits
# (after asking, unless $quiet).
sub db_reload {
    my $quiet = shift;
    return if !$quiet && !db_ok_to_leave();
    db_open();
    $dbv{sel} = undef;
    db_header();
    db_fill();
    db_form();
    db_state();
    db_message($dbv{error} // '', $dbv{error} ? 1 : 0);
}

# db_header -- where the database is, its path and fingerprint.
sub db_header {
    my $o = HardyCross::PipeData::origin(HardyCross::PipeData::path() || HardyCross::PipeData::default_path());
    my $team = $o eq 'TEAM FOLDER';
    $dbv{origin}->configure(-text => $o, -foreground => $team ? $C{accent} : $C{muted},
                            -background => $team ? $C{accent_bg} : $C{hover});
    $dbv{path}->configure(-text => HardyCross::PipeData::path() || HardyCross::PipeData::default_path());
    my $sha = HardyCross::PipeData::sha256();
    $dbv{sha}->configure(-text => $sha ? 'FINGERPRINT ' . uc(substr $sha, 0, 12) : '');
}

# db_state -- buttons and fields on or off for read-only or editing.
sub db_state {
    my $ed = $dbv{editing} && $dbv{db};
    my $mod = $dbv{db} && $dbv{db}{modified};
    $dbv{btn}{$_}->configure(-state => $ed ? 'normal' : 'disabled') for qw(UPDATE ADD DELETE);
    $dbv{btn}{SAVE}->configure($mod && $ed
        ? (-state => 'normal', -background => $C{accent}, -highlightbackground => $C{accent})
        : (-state => 'disabled', -background => $C{panel}, -highlightbackground => $C{line}));
    $dbv{btn}{DISCARD}->configure(-state => $mod ? 'normal' : 'disabled');
    $_->configure(-state => $ed ? 'normal' : 'readonly') for @{ $dbv{entries} || [] };
    $dbv{note}->configure(-text => !$dbv{db} ? ''
        : $ed ? 'EDITING. CHANGES TAKE EFFECT WHEN SAVED, AND EVERY REPORT AFTER THEM PRINTS THE NEW FINGERPRINT.'
              : 'READ-ONLY. TICK EDIT THE DATABASE TO CHANGE IT.');
}

sub db_editing_changed { db_state() }

# db_cols -- the current table's columns.
sub db_cols { return @{ HardyCross::DbEdit::table($dbv{kind})->{cols} } }

# db_fill -- the current table, filtered: every row with a word beginning
# with each word of the filter.
sub db_fill {
    my $kind = $dbv{kind} or return;
    return unless $dbv{tabs};          # make_tabs selects its first tab before it returns
    my $page = $dbv{tabs}{page}{ HardyCross::DbEdit::table($kind)->{title} };
    $dbv{box}{$kind}->destroy if $dbv{box}{$kind};
    my @cols = db_cols();
    my ($h, $box) = hlist($page, scalar @cols);
    my $st = styles($h);
    $dbv{box}{$kind} = $box;
    $dbv{hlist} = $h;
    my @rows = $dbv{db} ? @{ HardyCross::DbEdit::rows($dbv{db}, $kind) } : ();
    my @w = map { length $_->[0] } @cols;
    my @shown = map { [ map { HardyCross::DbEdit::shown($_) } @{ $_->{fields} } ] } @rows;
    for my $r (@shown) { for my $i (0 .. $#w) { my $l = length($r->[$i] // ''); $w[$i] = $l if $l > $w[$i] } }
    my $num = sub { $cols[ $_[0] ][1] =~ /^(int|num)/ };
    heading($h, $_, pad($cols[$_][0], $w[$_], $num->($_) ? 'e' : 'w'), $st->{headm}) for 0 .. $#cols;
    my @words = grep { length } split ' ', uc($dbv{filter} // '');
    $dbv{shown_rows} = [];
    for my $k (0 .. $#rows) {
        # Each word of the filter must begin some word of the row: "50"
        # finds DN 50, not DN 150.
        my @tok = map { split ' ' } @{ $shown[$k] };
        next if grep { my $w = $_; !grep { index($_, $w) == 0 } @tok } @words;
        my $id = $rows[$k]{line};
        $h->add($id);
        $h->itemCreate($id, $_, -text => pad($shown[$k][$_] // '', $w[$_], $num->($_) ? 'e' : 'w'),
                       -style => $st->{w0}) for 0 .. $#cols;
        push @{ $dbv{shown_rows} }, $id;
    }
    $h->configure(-browsecmd => sub { $h->anchorClear; $dbv{sel} = shift; db_form() });
    if (defined $dbv{sel} && $h->info('exists', $dbv{sel})) { $h->selectionSet($dbv{sel}); $h->see($dbv{sel}) }
}

# db_form -- the edit fields for the current table, holding the selected row.
sub db_form {
    my $kind = $dbv{kind} or return;
    return unless $dbv{tabs};
    $_->destroy for $dbv{formrow}->children;
    my @cols = db_cols();
    my $l = defined $dbv{sel} && $dbv{db} ? $dbv{db}{lines}[ $dbv{sel} ] : undef;
    $l = undef unless $l && ($l->{kind} // '') eq $kind;
    $dbv{vals} = [ map { $l ? HardyCross::DbEdit::shown($l->{fields}[$_]) : '' } 0 .. $#cols ];
    $dbv{entries} = [];
    for my $i (0 .. $#cols) {
        my $f = $dbv{formrow}->Frame(-background => $C{panel})->pack(-side => 'left', -padx => px([0, 10]));
        $f->Label(-text => $cols[$i][0], -font => $UI_S_N, -background => $C{panel}, -foreground => $C{muted},
                  -anchor => 'w')->pack(-fill => 'x');
        my $w = $cols[$i][1] eq 'text' ? 30 : $cols[$i][1] eq 'code' ? 9 : 11;
        my $e = flat_entry($f, \$dbv{vals}[$i], $w)->pack(-ipady => px(3));
        $e->configure(-readonlybackground => $C{panel});
        push @{ $dbv{entries} }, $e;
    }
    db_state();
}

# db_message -- a line beside the row buttons: red for a problem.
sub db_message {
    my ($t, $bad) = @_;
    $dbv{msg}->configure(-text => $t, -foreground => $bad ? $C{error} : $C{accent});
}

sub db_update {
    return unless $dbv{editing} && $dbv{db};
    return db_message('SELECT A ROW TO CHANGE FIRST', 1) unless defined $dbv{sel};
    my $err = HardyCross::DbEdit::set_row($dbv{db}, $dbv{sel}, [ @{ $dbv{vals} } ]);
    return db_message($err, 1) if $err;
    db_fill();
    db_state();
    db_message('ROW CHANGED. SAVE CHANGES TO USE IT.');
}

sub db_add {
    return unless $dbv{editing} && $dbv{db};
    my ($err, $at) = HardyCross::DbEdit::add_row($dbv{db}, $dbv{kind}, [ @{ $dbv{vals} } ]);
    return db_message($err, 1) if $err;
    $dbv{sel} = $at;
    db_fill();
    db_state();
    db_message('ROW ADDED. SAVE CHANGES TO USE IT.');
}

sub db_delete {
    return unless $dbv{editing} && $dbv{db};
    return db_message('SELECT A ROW TO DELETE FIRST', 1) unless defined $dbv{sel};
    my $err = HardyCross::DbEdit::delete_row($dbv{db}, $dbv{sel});
    return db_message($err, 1) if $err;
    $dbv{sel} = undef;
    db_fill();
    db_form();
    db_message('ROW DELETED. SAVE CHANGES TO MAKE IT FINAL.');
}

#------------------------------------------------------------------------------
# db_save -- check, write, and use the edited database.  A model validated
# against the old data must be validated again: CALCULATE goes off.
#------------------------------------------------------------------------------
sub db_save {
    return unless $dbv{editing} && $dbv{db} && $dbv{db}{modified};
    my $r = HardyCross::DbEdit::save($dbv{db});
    unless ($r->{ok}) {
        my $p = $r->{problems}[0];
        my $where = defined $p->{line} ? ' (' . HardyCross::DbEdit::table($p->{kind})->{title} . ')' : '';
        $dbv{sel} = $p->{line} if defined $p->{line};
        db_fill();
        return db_message("NOT SAVED: $p->{message}$where", 1);
    }
    db_after_change();
    db_message("SAVED TO $r->{path}. VALIDATE THE MODEL AGAIN BEFORE CALCULATING.");
}

# db_after_change -- the database in use has changed: what was checked or
# calculated against the old one is out of date.
sub db_after_change {
    HardyCross::Editor::clear_cache();
    ($valid_text, $validation, $solved) = (undef, undef, undef);
    fill_results();
    fill_validation();
    db_header();
    db_fill();
    db_state();
    recolour();
    update_actions();
}

#------------------------------------------------------------------------------
# db_choose_folder / db_use_builtin -- where the database is kept, for this
# machine.  A folder with no database yet is offered a copy of the one in use,
# which is how a team starts its shared database.
#------------------------------------------------------------------------------
sub db_choose_folder {
    my $dir = shift;
    return unless db_ok_to_leave();
    $dir //= $mw->chooseDirectory(-title => 'FOLDER FOR THE PIPE AND FITTING DATABASE', -mustexist => 1);
    return unless defined $dir && length $dir;
    my $copy = 0;
    unless (-e File::Spec->catfile($dir, 'pipes.dat')) {
        my $a = shift // $mw->messageBox(-title => 'NO DATABASE IN THAT FOLDER', -icon => 'question',
            -type => 'YesNo', -message => "$dir HAS NO PIPES.DAT.\n\nCOPY THE DATABASE IN USE THERE, TO START "
            . "A SHARED DATABASE FOR THE TEAM?");
        return unless lc($a) eq 'yes';
        $copy = 1;
    }
    my $err = HardyCross::DbEdit::use_folder($dir, $copy);
    return db_message($err, 1) if $err;
    db_open();
    db_after_change();
    db_message("USING THE DATABASE IN $dir ON THIS MACHINE.");
}

sub db_use_builtin {
    return unless db_ok_to_leave();
    HardyCross::DbEdit::use_builtin();
    db_open();
    db_after_change();
    db_message('USING THE BUILT-IN DATABASE ON THIS MACHINE.');
}

# db_ok_to_leave -- true unless there are unsaved database edits the user
# wants to keep.
sub db_ok_to_leave {
    return 1 unless $dbv{db} && $dbv{db}{modified};
    my $a = $mw->messageBox(-title => 'UNSAVED DATABASE CHANGES', -icon => 'warning', -type => 'YesNo',
        -message => 'THE DATABASE HAS CHANGES THAT ARE NOT SAVED.  DISCARD THEM?');
    return lc($a) eq 'yes';
}

#------------------------------------------------------------------------------
# load_settings -- put a document's settings into the PROJECT tab.  The
# values are copied into the hash the fields are tied to, never by replacing
# it, so every field stays tied.
#------------------------------------------------------------------------------
sub load_settings {
    my $new = shift;
    $settings->{title} = $new->{title} // '';
    $settings->{project}{$_} = '' for keys %{ $settings->{project} };
    $settings->{project}{$_} = $new->{project}{$_} for keys %{ $new->{project} };
    $settings->{extra} = [ @{ $new->{extra} || [] } ];
    $settings->{units}{$_} = $new->{units}{$_} for @HardyCross::Phc::UNIT_QUANTITIES;
    $settings->{method} = $new->{method} // 'HW';
    $settings->{options}{$_} = $new->{options}{$_} // '' for @HardyCross::Phc::OPTIONS;
    $_->() for @dd_refresh;
}

# show_field -- the PROJECT tab, with one field focused and marked.
sub show_field {
    my $field = shift;
    select_tab($toptabs, 'PROJECT');
    my $w = $form{$field} or return;
    $w->focus;
    $w->configure(-highlightbackground => $C{error});
    $mw->after(2500, sub { $w->configure(-highlightbackground => $C{line}) if Tk::Exists($w) });
}

1;
