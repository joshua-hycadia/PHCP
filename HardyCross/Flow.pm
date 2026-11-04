#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# Flow.pm -- a drawn network, with no Tk in it.
#
# A sprinkler or hydrant model is already a picture: blocks (a supply, a
# junction, a head) and the pipes that join them.  This module is that
# picture.  The blocks are the things in the network, and a line drawn from
# one block to another is a pipe or a pump.  It is not a diagram of the
# calculation.  A grid has loops, and a loop is a closed ring of pipes; a
# diagram of steps cannot hold one, and a pipe is the connection itself, so
# there is nothing to put in a box between the two ends.
#
# The drawing is not a second model.  write_text turns it into .phc commands
# and the existing reader (HardyCross::Phc) is what accepts or refuses them,
# so a drawing cannot call good what a calculation would reject.  read_text
# does the reverse, for a file written by hand or by this module.  Copy
# commands (PC, NC) and CHANGEPIPE are turned into the blocks they stand for
# on the way in, and written back as ordinary NODE and PIPE lines: the
# picture has no copies in it, and the network is the same one.
#
# Where a block sits is kept on its own line as a comment, `// FLOW 120 80`.
# The reader already ignores a comment, so phcp.pl and the text editor open
# the file unchanged.  A file with no positions is laid out from its
# connections, supplies to the left.  Saving rewrites the file in a fixed
# order.  Notes at the top are kept.  Notes between commands are not: the
# picture does not know where a remark sat.
#
# Nothing here solves.  calculate hands the .phc to the same reader and the
# same solver the command line uses, then copies the pressures and flows
# back onto the blocks for the window to draw.

package HardyCross::Flow;

use strict;
use warnings;
use HardyCross;
use HardyCross::Phc;
use HardyCross::Parse;

# The blocks a person places.  A pump is not one of them: a pump, like a
# pipe, joins two blocks that already exist.
our @BLOCK_KINDS = qw(WATER NODE SPRINKLER HYDRANT HREEL);
my %BLOCK = map { $_ => 1 } @BLOCK_KINDS;
# A device sits in a pipe, one to a pipe, as the language allows.
our @DEVICE_KINDS = qw(BP BFP PRV OPP OFD PRA);
my %DEVICE = map { $_ => 1 } @DEVICE_KINDS;

# Soft failures (a bad edit) set this and return undef.  A file that cannot
# be read dies with a model error, the same way the reader does, because
# there is then no drawing to go on with.
our $ERROR;
sub error { $ERROR }
sub _soft { $ERROR = shift; return }

#==============================================================================
# A document.
#==============================================================================

# blank -- a new drawing.  Length is in metres, not the office default of
# millimetres: a length typed against a pipe is the pipe's length, and a
# drawing is read in the same unit the worked examples are written in.
sub blank {
    return {
        header  => [ '// DRAWN NETWORK' ],
        title   => 'UNTITLED',
        project => [],
        units   => { LENGTH => 'M', ELEVATION => 'M', SIZE => 'MM',
                     PRESSURE => 'KPA', FLOW => 'LPM', KFACTOR => 'LPM/KPA' },
        method  => 'HW',
        options => [],
        graphs  => [],
        areas   => [],
        nodes   => [],
        edges   => [],
        flows   => [],
        nseq => 0, eseq => 0, fseq => 0,
    };
}

# find -- the block, connection or fixed flow with this id, or undef.
sub find {
    my ($doc, $id) = @_;
    return undef unless defined $id;
    return (grep { $_->{id} eq $id } @{ $doc->{nodes} }, @{ $doc->{edges} }, @{ $doc->{flows} })[0];
}

sub _node { my ($d, $id) = @_; return (grep { $_->{id} eq $id } @{ $d->{nodes} })[0] }
sub _edge { my ($d, $id) = @_; return (grep { $_->{id} eq $id } @{ $d->{edges} })[0] }
sub _flow { my ($d, $id) = @_; return (grep { $_->{id} eq $id } @{ $d->{flows} })[0] }

sub _nid { my $d = shift; return 'n' . ++$d->{nseq} }
sub _eid { my $d = shift; return 'e' . ++$d->{eseq} }
sub _fid { my $d = shift; return 'f' . ++$d->{fseq} }

# fresh -- the next name of a prefix that the drawing does not already use.
sub fresh {
    my ($doc, $prefix) = @_;
    my %have = map { $_->{name} => 1 } @{ $doc->{nodes} }, @{ $doc->{edges} }, @{ $doc->{flows} };
    my $i = 1;
    $i++ while $have{ $prefix . $i };
    return $prefix . $i;
}

my %PREFIX = (WATER => 'W', NODE => 'N', SPRINKLER => 'S', HYDRANT => 'H', HREEL => 'HR');

sub _clone_use {
    my $u = shift || { type => 'BORE' };
    return { type => $u->{type},
             (defined $u->{c} && $u->{c} ne '' ? (c => $u->{c}) : ()) };
}

# clear_result -- drop the last calculation.  An edit has made it stale.
# Positions are not a result, and a block moved on the page is still the
# same block, so they stay.
sub clear_result {
    my $doc = shift;
    delete $doc->{solved};
    for my $n (@{ $doc->{nodes} }) { delete $n->{pressure} }
    for my $e (@{ $doc->{edges} }) { delete $e->{flow}; delete $e->{device_flow}; delete $e->{sized} }
    return $doc;
}

#==============================================================================
# Reading a .phc file.
#==============================================================================

# read_file / read_text -- the drawing in a .phc file.
#
# Dies, with the line, on anything the language refuses or that names a
# block the file never defines.  Copies are expanded.  A position comment
# is kept; a file that is missing any is laid out.
sub read_file {
    my $path = shift;
    open my $fh, '<', $path or HardyCross::fail('cannot read %s: %s', $path, $!);
    local $/;
    my $text = <$fh>;
    close $fh;
    return read_text($text);
}

sub read_text {
    my ($text) = @_;
    $ERROR = undef;
    # Units the file does not mention take the office default.  Writing them
    # back does not change a result: an omitted unit already meant that.
    my $doc = {
        header => [], title => undef, project => [],
        units => { %HardyCross::Phc::UNIT_DEFAULT },
        method => 'HW', options => [], graphs => [], areas => [],
        nodes => [], edges => [], flows => [],
        nseq => 0, eseq => 0, fseq => 0,
    };

    my @recs = _records($text, $doc);

    my (%node, @node_order, %pipe, @pipe_order, @pumps, @flowrecs);
    my (%change, %eqv, %device, %duty, %area, @area_order, %name_line, %seen);
    my $use = { type => 'BORE' };

    my $define_name = sub {
        my ($name, $line) = @_;
        HardyCross::fail('line %d: THE NAME %s IS ALREADY USED ON LINE %d',
                         $line, $name, $name_line{$name}) if $name_line{$name};
        $name_line{$name} = $line;
    };
    my $define_node = sub {
        my ($name, $line, $rec) = @_;
        HardyCross::fail('line %d: NODE %s IS ALREADY DEFINED ON LINE %d',
                         $line, $name, $node{$name}{line}) if $node{$name};
        $node{$name} = $rec;
        push @node_order, $name;
    };

    for my $r (@recs) {
        my ($a, $line) = ($r->{a}, $r->{line});
        my ($k, @p) = ($a->{key}, @{ $a->{pos} });
        for my $sk (HardyCross::Phc::setting_keys($a)) {
            HardyCross::fail('line %d: %s IS ALREADY SET ON LINE %d', $line, $sk, $seen{$sk})
                if $seen{$sk};
            $seen{$sk} = $line;
        }
        if ($k eq 'TITLE') {
            $doc->{title} = $a->{text};
        } elsif ($k eq 'PROJECT') {
            push @{ $doc->{project} }, { field => $p[0], text => $a->{text} };
        } elsif ($k eq 'UNITS') {
            $doc->{units}{ $p[0] } = $p[1];
        } elsif ($k eq 'METHOD') {
            $doc->{method} = $p[0];
        } elsif ($k eq 'OPTION') {
            push @{ $doc->{options} }, { name => $p[0], value => $p[1] };
        } elsif ($k eq 'USE') {
            $use = { type => $p[0], (defined $a->{opt}[0] ? (c => $a->{opt}[0]) : ()) };
        } elsif ($k eq 'PIPE') {
            $define_name->($p[0], $line);
            $pipe{ $p[0] } = { line => $line, use => _clone_use($use), start => $p[1], end => $p[2],
                               len => $p[3], size => $p[4], fits => [ @{ $a->{rest} } ] };
            push @pipe_order, $p[0];
        } elsif ($k eq 'PC') {
            my @rest = @{ $a->{rest} };
            while (my ($name, $s, $e) = splice @rest, 0, 3) {
                $define_name->($name, $line);
                $pipe{$name} = { line => $line, copy_of => $p[0], start => $s, end => $e, fits => [] };
                push @pipe_order, $name;
            }
        } elsif ($k eq 'CHANGEPIPE') {
            HardyCross::fail('line %d: PIPE %s ALREADY HAS A CHANGEPIPE, ON LINE %d',
                             $line, $p[0], $change{ $p[0] }{line}) if $change{ $p[0] };
            $change{ $p[0] } = { line => $line, len => $p[1], size => $p[2], fits => [ @{ $a->{rest} } ] };
        } elsif ($k eq 'EQV') {
            HardyCross::fail('line %d: PIPE %s ALREADY HAS AN EQV, ON LINE %d',
                             $line, $p[0], $eqv{ $p[0] }{line}) if $eqv{ $p[0] };
            $eqv{ $p[0] } = { line => $line, len => $p[1] };
        } elsif ($k eq 'NODE') {
            $define_node->($p[0], $line, { line => $line, kind => 'NODE', z => $p[1], x => $r->{x}, y => $r->{y} });
        } elsif ($k eq 'WATER') {
            $define_node->($p[0], $line, { line => $line, kind => 'WATER', z => $p[1], static => $p[2],
                                           pairs => [ @{ $a->{rest} } ], x => $r->{x}, y => $r->{y} });
        } elsif ($k eq 'SPRINKLER' || $k eq 'HYDRANT' || $k eq 'HREEL') {
            $define_node->($p[0], $line, { line => $line, kind => $k, z => $p[1], minflow => $p[2],
                                           k => $p[3], x => $r->{x}, y => $r->{y} });
        } elsif ($k eq 'NC') {
            for my $name (@{ $a->{rest} }) {
                $define_node->($name, $line, { line => $line, kind => 'COPY', source => $p[0] });
            }
        } elsif ($k eq 'FIXEDFLOW') {
            $define_name->($p[0], $line);
            push @flowrecs, { line => $line, name => $p[0], node => $p[1], q => $p[2],
                              (defined $a->{opt}[0] ? (minp => $a->{opt}[0]) : ()) };
        } elsif ($k eq 'PUMP') {
            $define_name->($p[0], $line);
            push @pumps, { line => $line, name => $p[0], from => $p[1], to => $p[2],
                           churn => $p[3], pairs => [ @{ $a->{rest} } ] };
        } elsif ($k eq 'SUPPLYGRAPH') {
            push @{ $doc->{graphs} }, $a->{text};
        } elsif ($k eq 'AREA') {
            push @area_order, $p[0] unless $area{ $p[0] };
            my $ar = $area{ $p[0] } //= { name => $p[0], outlets => [] };
            for my $o (@{ $a->{rest} }) {
                push @{ $ar->{outlets} }, $o unless grep { $_ eq $o } @{ $ar->{outlets} };
            }
        } elsif ($k eq 'PUMPDUTY') {
            HardyCross::fail('line %d: PUMP %s ALREADY HAS A DUTY, ON LINE %d',
                             $line, $p[0], $duty{ $p[0] }{line}) if $duty{ $p[0] };
            $duty{ $p[0] } = { line => $line, q => $p[1], p => $p[2] };
        } elsif ($DEVICE{$k}) {
            HardyCross::fail('line %d: PIPE %s ALREADY HAS A DEVICE, %s ON LINE %d',
                             $line, $p[0], $device{ $p[0] }{kind}, $device{ $p[0] }{line})
                if $device{ $p[0] };
            $device{ $p[0] } = { line => $line, kind => $k, a => $a };
        }
    }

    _resolve_nodes(\%node, \@node_order);
    _resolve_pipes(\%pipe, \@pipe_order);
    for my $name (keys %change) {
        my $p = $pipe{$name} or HardyCross::fail('line %d: PIPE %s IS NOT DEFINED', $change{$name}{line}, $name);
        $p->{len} = $change{$name}{len};
        $p->{size} = $change{$name}{size};
        $p->{fits} = [ @{ $change{$name}{fits} } ];
    }
    for my $name (keys %eqv) {
        $pipe{$name} or HardyCross::fail('line %d: PIPE %s IS NOT DEFINED', $eqv{$name}{line}, $name);
        $pipe{$name}{eqv} = $eqv{$name}{len};
    }
    $pipe{$_} or HardyCross::fail('line %d: PIPE %s IS NOT DEFINED', $device{$_}{line}, $_) for keys %device;

    my %id_of;
    for my $name (@node_order) {
        my $s = $node{$name};
        my $n = { id => _nid($doc), name => $name, kind => $s->{kind}, z => $s->{z},
                  x => $s->{x}, y => $s->{y} };
        if ($s->{kind} eq 'WATER') {
            $n->{static} = $s->{static};
            $n->{pairs} = [ @{ $s->{pairs} } ];
        } elsif ($s->{kind} ne 'NODE') {
            $n->{minflow} = $s->{minflow};
            $n->{k} = $s->{k};
        }
        $id_of{$name} = $n->{id};
        push @{ $doc->{nodes} }, $n;
    }
    my $need = sub {
        my ($name, $line) = @_;
        return $id_of{$name} if $id_of{$name};
        HardyCross::fail('line %d: NODE %s IS NOT DEFINED', $line, $name);
    };
    for my $name (@pipe_order) {
        my $p = $pipe{$name};
        my $e = { id => _eid($doc), kind => 'PIPE', name => $name,
                  from => $need->($p->{start}, $p->{line}), to => $need->($p->{end}, $p->{line}),
                  len => $p->{len}, size => $p->{size}, fits => [ @{ $p->{fits} } ],
                  use => _clone_use($p->{use}) };
        $e->{eqv} = $p->{eqv} if defined $p->{eqv};
        $e->{device} = _device_of($device{$name}) if $device{$name};
        push @{ $doc->{edges} }, $e;
    }
    for my $p (@pumps) {
        push @{ $doc->{edges} }, { id => _eid($doc), kind => 'PUMP', name => $p->{name},
                                   from => $need->($p->{from}, $p->{line}), to => $need->($p->{to}, $p->{line}),
                                   churn => $p->{churn}, pairs => [ @{ $p->{pairs} } ] };
    }
    for my $f (@flowrecs) {
        push @{ $doc->{flows} }, { id => _fid($doc), name => $f->{name},
                                   node => $need->($f->{node}, $f->{line}), q => $f->{q},
                                   (defined $f->{minp} ? (minp => $f->{minp}) : ()) };
    }
    my %by_name = map { $_->{name} => $_ } @{ $doc->{edges} };
    for my $name (sort { $duty{$a}{line} <=> $duty{$b}{line} } keys %duty) {
        my $e = $by_name{$name};
        my $bp = $e && $e->{device} && $e->{device}{kind} eq 'BP';
        HardyCross::fail('line %d: PUMPDUTY %s: NO PUMP OF THAT NAME, AND NO PIPE WITH A BOOSTER (BP) IN IT',
                         $duty{$name}{line}, $name)
            unless $e && ($e->{kind} eq 'PUMP' || $bp);
        $e->{duty} = { q => $duty{$name}{q}, p => $duty{$name}{p} };
    }
    for my $name (@area_order) {
        my $ar = $area{$name};
        for my $o (@{ $ar->{outlets} }) {
            my $n = $node{$o} or HardyCross::fail('AREA %s: %s IS NOT DEFINED', $name, $o);
            HardyCross::fail('AREA %s: %s IS NOT AN OUTLET (SPRINKLER, HYDRANT OR HREEL)', $name, $o)
                unless $n->{kind} =~ /^(SPRINKLER|HYDRANT|HREEL)\z/;
        }
        push @{ $doc->{areas} }, { name => $name, outlets => [ @{ $ar->{outlets} } ] };
    }

    # One missing position and the columns would not line up with the blocks
    # that do have one, so the whole drawing is laid out again.
    layout($doc, 1) if grep { !defined $_->{x} || !defined $_->{y} } @{ $doc->{nodes} };
    return $doc;
}

# _records -- the command lines, with a position comment lifted off first.
# Leading notes are kept on the document.  A position is `// FLOW x y` and
# nothing else in the comment, so a remark cannot be read as a coordinate.
sub _records {
    my ($text, $doc) = @_;
    my @out;
    my $started = 0;
    my $n = 0;
    for my $raw (split /\n/, $text // '', -1) {
        $n++;
        $raw =~ s/\r\z//;
        my $code = HardyCross::Phc::strip_comment($raw);
        if ($code =~ /^\s*$/) {
            push @{ $doc->{header} }, $raw if !$started && $raw =~ m{//};
            next;
        }
        $started = 1;
        my ($x, $y);
        if ($raw =~ m{//(.*)\z} && $1 =~ /^\s*FLOW\s+(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s*\z/) {
            ($x, $y) = ($1, $2);
        }
        my $a = HardyCross::Phc::analyse($raw);
        if ($a->{status} eq 'incomplete') {
            HardyCross::fail('line %d: %s NEEDS %s', $n, $a->{key} // 'THE LINE', $a->{msg});
        }
        HardyCross::fail('line %d: %s', $n, $a->{msg}) if $a->{status} ne 'ok';
        push @out, { line => $n, a => $a, x => $x, y => $y };
    }
    return @out;
}

sub _resolve_nodes {
    my ($nodes, $order) = @_;
    my $walk;
    $walk = sub {
        my ($name, $stack) = @_;
        my $n = $nodes->{$name} or return;
        return $n if $n->{kind} ne 'COPY';
        HardyCross::fail('line %d: NODE %s IS COPIED FROM ITSELF', $n->{line}, $name) if $stack->{$name};
        my $src = $nodes->{ $n->{source} }
            or HardyCross::fail('line %d: NODE %s, COPIED AS %s, IS NOT DEFINED', $n->{line}, $n->{source}, $name);
        local $stack->{$name} = 1;
        $src = $walk->($n->{source}, $stack);
        $n->{kind} = $src->{kind};
        $n->{z} = $src->{z};
        if ($src->{kind} eq 'WATER') {
            $n->{static} = $src->{static};
            $n->{pairs} = [ @{ $src->{pairs} } ];
        } elsif ($src->{kind} ne 'NODE') {
            $n->{minflow} = $src->{minflow};
            $n->{k} = $src->{k};
        }
        return $n;
    };
    $walk->($_, {}) for @$order;
}

sub _resolve_pipes {
    my ($pipes, $order) = @_;
    my $walk;
    $walk = sub {
        my ($name, $stack) = @_;
        my $p = $pipes->{$name}
            or HardyCross::fail('PIPE %s IS NOT DEFINED', $name);
        return $p if $p->{resolved};
        if ($p->{copy_of}) {
            HardyCross::fail('line %d: PIPE %s IS COPIED FROM ITSELF', $p->{line}, $name) if $stack->{$name};
            local $stack->{$name} = 1;
            my $s = $pipes->{ $p->{copy_of} }
                or HardyCross::fail('line %d: PIPE %s, COPIED AS %s, IS NOT DEFINED', $p->{line}, $p->{copy_of}, $name);
            $s = $walk->($p->{copy_of}, $stack);
            $p->{len} = $s->{len};
            $p->{size} = $s->{size};
            $p->{fits} = [ @{ $s->{fits} || [] } ];
            $p->{use} = _clone_use($s->{use});
        }
        $p->{resolved} = 1;
        return $p;
    };
    $walk->($_) for @$order;
}

# _device_of -- our device record from the line the reader analysed.
sub _device_of {
    my $d = shift;
    my ($k, $a) = ($d->{kind}, $d->{a});
    my $o = { kind => $k };
    if ($k eq 'BP') {
        $o->{churn} = $a->{pos}[1];
        $o->{pairs} = [ @{ $a->{rest} } ];
    } elsif ($k eq 'BFP' || $k eq 'PRV') {
        $o->{pairs} = [ @{ $a->{rest} } ];
    } elsif ($k eq 'OPP') {
        $o->{drop} = $a->{pos}[1];
        $o->{cd} = $a->{opt}[0] if defined $a->{opt}[0];
    } elsif ($k eq 'OFD') {
        $o->{bore} = $a->{pos}[1];
        $o->{cd} = $a->{opt}[0] if defined $a->{opt}[0];
    } elsif ($k eq 'PRA') {
        $o->{ratio} = $a->{pos}[1];
        $o->{mininlet} = $a->{opt}[0] if defined $a->{opt}[0];
        $o->{band} = $a->{opt}[1] if defined $a->{opt}[1];
    }
    return $o;
}

#==============================================================================
# Writing a .phc file.
#==============================================================================

# cmd -- one command, the word in a column of ten, as the examples are.
sub cmd {
    my ($word, @rest) = @_;
    my $head = length($word) >= 10 ? "$word " : sprintf('%-10s', $word);
    return $head . join(' ', grep { defined && $_ ne '' } @rest);
}

sub _coord {
    my $v = 0 + shift;
    return sprintf('%.0f', $v) if abs($v - sprintf('%.0f', $v)) < 1e-6;
    my $s = sprintf('%.4f', $v);
    $s =~ s/0+\z//;
    $s =~ s/\.\z//;
    return $s;
}

# write_text -- the drawing as .phc.  The reader can take the result as it
# stands.  model_text is the same text without the position comments, so a
# block moved on the page does not by itself make a validation stale.
sub write_text {
    my $doc = shift;
    my @out = @{ $doc->{header} || [] };
    push @out, '' if @out;

    push @out, cmd('TITLE', $doc->{title}) if defined $doc->{title} && $doc->{title} ne '';
    push @out, cmd('PROJECT', $_->{field}, $_->{text}) for @{ $doc->{project} };
    push @out, cmd('UNITS', $_, $doc->{units}{$_})
        for qw(LENGTH ELEVATION SIZE PRESSURE FLOW KFACTOR);
    push @out, cmd('METHOD', $doc->{method} // 'HW');
    push @out, cmd('OPTION', $_->{name}, $_->{value}) for @{ $doc->{options} };
    push @out, '';

    my %node = map { $_->{id} => $_ } @{ $doc->{nodes} };
    for my $n (@{ $doc->{nodes} }) {
        my @f = ($n->{name}, $n->{z});
        if ($n->{kind} eq 'WATER') { push @f, $n->{static}, @{ $n->{pairs} || [] } }
        elsif ($n->{kind} ne 'NODE') { push @f, $n->{minflow}, $n->{k} }
        my $line = cmd($n->{kind}, @f);
        $line .= sprintf(' // FLOW %s %s', _coord($n->{x}), _coord($n->{y}))
            if defined $n->{x} && defined $n->{y};
        push @out, $line;
    }
    push @out, '' if @{ $doc->{nodes} };

    my $prev = '';
    for my $e (grep { $_->{kind} eq 'PIPE' } @{ $doc->{edges} }) {
        my $key = $e->{use}{type} . "\0" . ($e->{use}{c} // '');
        if ($key ne $prev) {
            push @out, cmd('USE', $e->{use}{type}, $e->{use}{c});
            $prev = $key;
        }
        my ($a, $b) = ($node{ $e->{from} }, $node{ $e->{to} });
        HardyCross::fail('PIPE %s HAS NO START', $e->{name}) unless $a && $b;
        push @out, cmd('PIPE', $e->{name}, $a->{name}, $b->{name}, $e->{len}, $e->{size}, @{ $e->{fits} || [] });
        push @out, cmd('EQV', $e->{name}, $e->{eqv}) if defined $e->{eqv} && $e->{eqv} ne '';
        push @out, _device_line($e) if $e->{device};
    }
    for my $e (grep { $_->{kind} eq 'PUMP' } @{ $doc->{edges} }) {
        my ($a, $b) = ($node{ $e->{from} }, $node{ $e->{to} });
        HardyCross::fail('PUMP %s HAS NO START', $e->{name}) unless $a && $b;
        push @out, cmd('PUMP', $e->{name}, $a->{name}, $b->{name}, $e->{churn}, @{ $e->{pairs} || [] });
    }
    for my $f (@{ $doc->{flows} }) {
        my $n = $node{ $f->{node} } or HardyCross::fail('FIXED FLOW %s HAS NO NODE', $f->{name});
        push @out, cmd('FIXEDFLOW', $f->{name}, $n->{name}, $f->{q}, $f->{minp});
    }
    for my $e (@{ $doc->{edges} }) {
        next unless $e->{duty};
        my $bp = $e->{device} && $e->{device}{kind} eq 'BP';
        next unless $e->{kind} eq 'PUMP' || $bp;
        push @out, cmd('PUMPDUTY', $e->{name}, $e->{duty}{q}, $e->{duty}{p});
    }
    push @out, cmd('AREA', $_->{name}, @{ $_->{outlets} }) for @{ $doc->{areas} };
    push @out, cmd('SUPPLYGRAPH', $_) for @{ $doc->{graphs} };
    push @out, '';
    return join("\n", @out);
}

sub _device_line {
    my $e = shift;
    my $d = $e->{device};
    my $k = $d->{kind};
    return cmd('BP', $e->{name}, $d->{churn}, @{ $d->{pairs} || [] }) if $k eq 'BP';
    return cmd($k, $e->{name}, @{ $d->{pairs} || [] }) if $k eq 'BFP' || $k eq 'PRV';
    return cmd('OPP', $e->{name}, $d->{drop}, $d->{cd}) if $k eq 'OPP';
    return cmd('OFD', $e->{name}, $d->{bore}, $d->{cd}) if $k eq 'OFD';
    if ($k eq 'PRA') {
        # BAND is the second optional field.  With a band and no minimum the
        # minimum is written 0, which is the language's "no minimum", so the
        # band is not read as one.
        my @opt;
        if (defined $d->{band} && $d->{band} ne '') {
            @opt = (defined $d->{mininlet} && $d->{mininlet} ne '' ? $d->{mininlet} : '0', $d->{band});
        } elsif (defined $d->{mininlet} && $d->{mininlet} ne '') {
            @opt = ($d->{mininlet});
        }
        return cmd('PRA', $e->{name}, $d->{ratio}, @opt);
    }
    HardyCross::fail('UNKNOWN DEVICE %s', $k // '');
}

sub model_text {
    my $t = write_text(shift);
    $t =~ s/[ \t]*\/\/ FLOW -?\d+(?:\.\d+)? -?\d+(?:\.\d+)?//g;
    return $t;
}

sub write_file {
    my ($doc, $path) = @_;
    open my $fh, '>', $path or HardyCross::fail('cannot write %s: %s', $path, $!);
    print $fh write_text($doc);
    close $fh;
    return 1;
}

#==============================================================================
# Layout.
#
# Columns by distance from the nearest supply, so a branch reads left to
# right.  Inside a column the blocks are ordered by where their neighbours
# sit, a few times over, which takes the crossings out of a tree and most
# of them out of a small grid.  It is a picture for a person, not a solved
# coordinate: nothing hydraulic is read from it.
#==============================================================================
sub layout {
    my ($doc, $force) = @_;
    my @nodes = @{ $doc->{nodes} };
    return $doc unless @nodes;
    # A complete N{row}_{column} array is already a grid.  Depth from the
    # supply would lay the same mesh out on diagonals.
    return $doc if _layout_grid($doc, $force);
    my %adj;
    for my $e (@{ $doc->{edges} }) {
        push @{ $adj{ $e->{from} } }, $e->{to};
        push @{ $adj{ $e->{to} } }, $e->{from};
    }
    my @roots = grep { $_->{kind} eq 'WATER' } @nodes;
    @roots = ($nodes[0]) unless @roots;
    my %depth;
    my @q = map { [ $_->{id}, 0 ] } @roots;
    $depth{ $_->{id} } = 0 for @roots;
    while (@q) {
        my ($id, $d) = @{ shift @q };
        for my $nb (@{ $adj{$id} || [] }) {
            next if defined $depth{$nb};
            $depth{$nb} = $d + 1;
            push @q, [ $nb, $d + 1 ];
        }
    }
    my $max = 0;
    for my $d (values %depth) { $max = $d if $d > $max }
    for my $n (@nodes) { $depth{ $n->{id} } = $max + 1 unless defined $depth{ $n->{id} } }

    my %layer;
    push @{ $layer{ $depth{ $_->{id} } } }, $_ for @nodes;
    my @levels = sort { $a <=> $b } keys %layer;
    @{ $layer{$_} } = sort { $a->{name} cmp $b->{name} } @{ $layer{$_} } for @levels;
    my %index;
    my $reindex = sub {
        my $i = 0;
        $index{ $_->{id} } = $i++ for @{ $layer{ $_[0] } };
    };
    $reindex->($_) for @levels;
    for (1 .. 4) {
        for my $lv (@levels) {
            @{ $layer{$lv} } = sort {
                my $ba = _bary($a->{id}, \%adj, \%index);
                my $bb = _bary($b->{id}, \%adj, \%index);
                $ba <=> $bb || $a->{name} cmp $b->{name};
            } @{ $layer{$lv} };
            $reindex->($lv);
        }
    }
    for my $lv (@levels) {
        my $i = 0;
        for my $n (@{ $layer{$lv} }) {
            if ($force || !defined $n->{x} || !defined $n->{y}) {
                $n->{x} = 48 + $lv * 300;
                $n->{y} = 48 + $i * 160;
            }
            $i++;
        }
    }
    return $doc;
}

# _layout_grid -- place N0_0, N0_1, N1_0, ... in the rows and columns their
# names give.  Only when those names fill a rectangle, so an ordinary branch
# is left to the depth layout.  A stub that is not named that way (the grid's
# extra head on the corner) is set beside the block it joins, and does not
# pull the mesh onto a diagonal.
sub _layout_grid {
    my ($doc, $force) = @_;
    my @nodes = @{ $doc->{nodes} };
    return 0 if @nodes < 4;
    my (%cell, $maxr, $maxc, @extra);
    for my $n (@nodes) {
        if (($n->{name} // '') =~ /^N(\d+)_(\d+)\z/) {
            my ($r, $c) = ($1 + 0, $2 + 0);
            return 0 if $cell{"$r,$c"};
            $cell{"$r,$c"} = $n;
            $maxr = $r if !defined $maxr || $r > $maxr;
            $maxc = $c if !defined $maxc || $c > $maxc;
        } else {
            push @extra, $n;
        }
    }
    my $cells = keys %cell;
    return 0 if $cells < 4;
    return 0 unless $cells == ($maxr + 1) * ($maxc + 1);
    # A handful of stubs may sit on the rectangle.  A drawing that is mostly
    # other names is not this grid.
    return 0 if @extra > $cells * 0.05;
    for my $key (keys %cell) {
        my ($r, $c) = split /,/, $key;
        my $n = $cell{$key};
        next unless $force || !defined $n->{x} || !defined $n->{y};
        $n->{x} = 48 + $c * 240;
        $n->{y} = 48 + $r * 150;
    }
    for my $n (@extra) {
        next unless $force || !defined $n->{x} || !defined $n->{y};
        my ($x, $y) = (48 - 240, 48);
        for my $e (@{ $doc->{edges} }) {
            my $oid = $e->{from} eq $n->{id} ? $e->{to}
                    : $e->{to} eq $n->{id}   ? $e->{from}
                    :                          undef;
            next unless defined $oid;
            my $o = find($doc, $oid);
            if ($o && defined $o->{x}) { $x = $o->{x} - 240; $y = $o->{y}; last }
        }
        $n->{x} = $x;
        $n->{y} = $y;
    }
    return 1;
}

sub _bary {
    my ($id, $adj, $index) = @_;
    my @v = grep { defined } map { $index->{$_} } @{ $adj->{$id} || [] };
    return 0 unless @v;
    my $s = 0;
    $s += $_ for @v;
    return $s / @v;
}

#==============================================================================
# Edits.
#==============================================================================

sub add_node {
    my ($doc, $kind, $x, $y) = @_;
    $ERROR = undef;
    $kind = uc($kind // '');
    return _soft('UNKNOWN BLOCK') unless $BLOCK{$kind};
    my $n = { id => _nid($doc), kind => $kind, name => fresh($doc, $PREFIX{$kind}),
              x => $x, y => $y, z => '0' };
    if ($kind eq 'WATER') { $n->{static} = '900'; $n->{pairs} = [] }
    elsif ($kind eq 'SPRINKLER') { $n->{minflow} = '-50'; $n->{k} = '80' }
    elsif ($kind eq 'HYDRANT') { $n->{minflow} = '600'; $n->{k} = '80' }
    elsif ($kind eq 'HREEL') { $n->{minflow} = '-220'; $n->{k} = '7.5' }
    push @{ $doc->{nodes} }, $n;
    clear_result($doc);
    return $n;
}

sub add_edge {
    my ($doc, $kind, $from, $to) = @_;
    $ERROR = undef;
    $kind = uc($kind // '');
    return _soft('A CONNECTION IS A PIPE OR A PUMP') unless $kind eq 'PIPE' || $kind eq 'PUMP';
    return _soft('CHOOSE TWO DIFFERENT BLOCKS') if !defined $from || !defined $to || $from eq $to;
    return _soft('NO SUCH BLOCK') unless _node($doc, $from) && _node($doc, $to);
    my $e = { id => _eid($doc), kind => $kind, from => $from, to => $to,
              name => fresh($doc, $kind eq 'PUMP' ? 'PMP' : 'P') };
    if ($kind eq 'PIPE') {
        # A new pipe takes the type of the pipe before it, so a run of heads
        # stays on the one pipe type instead of dropping back to a bore.
        my ($prev) = grep { $_->{kind} eq 'PIPE' } reverse @{ $doc->{edges} };
        $e->{use} = $prev ? _clone_use($prev->{use}) : { type => 'BORE', c => '120' };
        $e->{len} = '10';
        $e->{size} = '100';
        $e->{fits} = [];
    } else {
        $e->{churn} = '850';
        $e->{pairs} = [ '2500', '800' ];
    }
    push @{ $doc->{edges} }, $e;
    clear_result($doc);
    return $e;
}

sub add_fixedflow {
    my ($doc, $node) = @_;
    $ERROR = undef;
    return _soft('NO SUCH BLOCK') unless _node($doc, $node);
    my $f = { id => _fid($doc), name => fresh($doc, 'FF'), node => $node, q => '300', minp => '200' };
    push @{ $doc->{flows} }, $f;
    clear_result($doc);
    return $f;
}

sub move_node {
    my ($doc, $id, $x, $y) = @_;
    $ERROR = undef;
    my $n = _node($doc, $id) or return _soft('NO SUCH BLOCK');
    $n->{x} = $x;
    $n->{y} = $y;
    return $n;
}

sub remove {
    my ($doc, $id) = @_;
    $ERROR = undef;
    if (my $n = _node($doc, $id)) {
        $doc->{edges} = [ grep { $_->{from} ne $id && $_->{to} ne $id } @{ $doc->{edges} } ];
        $doc->{flows} = [ grep { $_->{node} ne $id } @{ $doc->{flows} } ];
        for my $a (@{ $doc->{areas} }) {
            $a->{outlets} = [ grep { $_ ne $n->{name} } @{ $a->{outlets} } ];
        }
        # An area with nothing in it cannot be written: the command needs an outlet.
        $doc->{areas} = [ grep { @{ $_->{outlets} } } @{ $doc->{areas} } ];
        $doc->{nodes} = [ grep { $_->{id} ne $id } @{ $doc->{nodes} } ];
    } elsif (_edge($doc, $id)) {
        $doc->{edges} = [ grep { $_->{id} ne $id } @{ $doc->{edges} } ];
    } elsif (_flow($doc, $id)) {
        $doc->{flows} = [ grep { $_->{id} ne $id } @{ $doc->{flows} } ];
    } else {
        return _soft('NOTHING TO DELETE');
    }
    clear_result($doc);
    return 1;
}

# apply -- the fields from the card on the right, as the strings typed.
# A field that is not in the hash is left as it was.  The reader is still
# the judge of a finished file; this only stops a name that collides, a
# number that is not one, and a device the language does not have.
sub apply {
    my ($doc, $id, $f) = @_;
    $ERROR = undef;
    $f ||= {};
    # A card that merely lost focus must not wipe a calculation.  The result
    # is dropped only when the .phc itself changed.
    my $before = eval { model_text($doc) };
    my $ok;
    if (my $n = _node($doc, $id)) { $ok = _apply_node($doc, $n, $f) }
    elsif (my $e = _edge($doc, $id)) { $ok = _apply_edge($doc, $e, $f) }
    elsif (my $fl = _flow($doc, $id)) { $ok = _apply_flow($doc, $fl, $f) }
    else { return _soft('NOTHING SELECTED') }
    my $after = eval { model_text($doc) };
    clear_result($doc) if !defined $before || !defined $after || $before ne $after;
    return $ok ? 1 : undef;
}

sub _check_name {
    my ($doc, $name, $self) = @_;
    return 'A NAME IS REQUIRED' if !defined $name || $name eq '';
    return "'~' IS RESERVED FOR NAMES PHCP MAKES ITSELF" if $name =~ /~/;
    return 'END CANNOT BE A NAME' if uc $name eq 'END';
    return 'A NAME CANNOT CONTAIN A SPACE, COMMA OR ='
        if $name =~ /[\s,;=!#]/ || $name =~ /[^\x21-\x7E]/;
    for my $o (@{ $doc->{nodes} }, @{ $doc->{edges} }, @{ $doc->{flows} }) {
        return "THE NAME $name IS ALREADY USED" if $o->{name} eq $name && $o->{id} ne $self;
    }
    return;
}

sub _numlist {
    my ($s, $even) = @_;
    $s //= '';
    $s =~ s/^\s+|\s+\z//g;
    return ([], undef) if $s eq '';
    my @t = split /\s+/, $s;
    for (@t) {
        return (undef, "'$_' IS NOT A NUMBER") unless HardyCross::Parse::is_num($_);
    }
    return (undef, 'FLOWS AND PRESSURES COME IN PAIRS') if $even && @t % 2;
    return (\@t, undef);
}

sub _fits {
    my $s = shift // '';
    $s =~ s/^\s+|\s+\z//g;
    return ([], undef) if $s eq '';
    my @t = split /\s+/, $s;
    for (@t) {
        return (undef, "'$_' IS NOT A FITTING: A CODE WITH AN OPTIONAL COUNT, SUCH AS 2E")
            unless /^\d*[A-Za-z][A-Za-z0-9]*\z/;
    }
    return (\@t, undef);
}

sub _length_ok {
    my ($label, $value, $allow_neg) = @_;
    my $m = HardyCross::Phc::length_metres($value, 'M');
    return "$label '$value' IS NOT A LENGTH" unless defined $m;
    return "$label CANNOT BE NEGATIVE" if !$allow_neg && $m < 0;
    return;
}

sub _apply_node {
    my ($doc, $n, $f) = @_;
    if (exists $f->{name} && $f->{name} ne $n->{name}) {
        my $err = _check_name($doc, $f->{name}, $n->{id});
        return _soft($err) if $err;
        for my $a (@{ $doc->{areas} }) {
            $_ eq $n->{name} and $_ = $f->{name} for @{ $a->{outlets} };
        }
        $n->{name} = $f->{name};
    }
    if (exists $f->{z}) {
        my $err = _length_ok('ELEVATION', $f->{z}, 1);
        return _soft($err) if $err;
        $n->{z} = $f->{z};
    }
    if ($n->{kind} eq 'WATER') {
        if (exists $f->{static}) {
            return _soft("STATIC '$f->{static}' IS NOT A NUMBER")
                unless HardyCross::Parse::is_num($f->{static});
            return _soft('STATIC CANNOT BE NEGATIVE') if $f->{static} < 0;
            $n->{static} = $f->{static};
        }
        if (exists $f->{pairs}) {
            my ($p, $err) = _numlist($f->{pairs}, 1);
            return _soft($err) if $err;
            return _soft('A CURVE CANNOT FALL BELOW ZERO') if grep { $_ < 0 } @$p;
            $n->{pairs} = $p;
        }
    } elsif ($n->{kind} ne 'NODE') {
        if (exists $f->{minflow}) {
            return _soft("MINFLOW '$f->{minflow}' IS NOT A NUMBER")
                unless HardyCross::Parse::is_num($f->{minflow});
            $n->{minflow} = $f->{minflow};
        }
        if (exists $f->{k}) {
            return _soft("K '$f->{k}' IS NOT A NUMBER") unless HardyCross::Parse::is_num($f->{k});
            return _soft('K CANNOT BE NEGATIVE') if $f->{k} < 0;
            $n->{k} = $f->{k};
        }
    }
    return 1;
}

sub _device_default {
    my $k = shift;
    return { kind => 'BFP', pairs => [ '0', '35' ] } if $k eq 'BFP';
    return { kind => 'PRV', pairs => [ '0', '150' ] } if $k eq 'PRV';
    return { kind => 'BP', churn => '800', pairs => [ '1000', '700' ] } if $k eq 'BP';
    return { kind => 'OPP', drop => '50' } if $k eq 'OPP';
    return { kind => 'OFD', bore => '25' } if $k eq 'OFD';
    return { kind => 'PRA', ratio => '3:1' } if $k eq 'PRA';
    return;
}

sub _apply_duty {
    my ($e, $f) = @_;
    my $q = exists $f->{duty_q} ? $f->{duty_q} : ($e->{duty} ? $e->{duty}{q} : '');
    my $p = exists $f->{duty_p} ? $f->{duty_p} : ($e->{duty} ? $e->{duty}{p} : '');
    $q //= '';
    $p //= '';
    if ($q eq '' && $p eq '') { delete $e->{duty}; return 1 }
    return _soft('A DUTY NEEDS A FLOW AND A PRESSURE') if $q eq '' || $p eq '';
    return _soft("DUTY FLOW '$q' IS NOT A NUMBER") unless HardyCross::Parse::is_num($q);
    return _soft("DUTY PRESSURE '$p' IS NOT A NUMBER") unless HardyCross::Parse::is_num($p);
    return _soft('A DUTY CANNOT BE NEGATIVE') if $q < 0 || $p < 0;
    my $bp = $e->{device} && $e->{device}{kind} eq 'BP';
    return _soft('A DUTY BELONGS ON A PUMP OR A BOOSTER') unless $e->{kind} eq 'PUMP' || $bp;
    $e->{duty} = { q => $q, p => $p };
    return 1;
}

sub _apply_edge {
    my ($doc, $e, $f) = @_;
    if (exists $f->{name} && $f->{name} ne $e->{name}) {
        my $err = _check_name($doc, $f->{name}, $e->{id});
        return _soft($err) if $err;
        $e->{name} = $f->{name};
    }
    if ($e->{kind} eq 'PUMP') {
        if (exists $f->{churn}) {
            return _soft("CHURN '$f->{churn}' IS NOT A NUMBER") unless HardyCross::Parse::is_num($f->{churn});
            return _soft('CHURN CANNOT BE NEGATIVE') if $f->{churn} < 0;
            $e->{churn} = $f->{churn};
        }
        if (exists $f->{pairs}) {
            my ($p, $err) = _numlist($f->{pairs}, 1);
            return _soft($err) if $err;
            return _soft('A PUMP NEEDS A FLOW AND A PRESSURE') unless @$p;
            return _soft('A CURVE CANNOT FALL BELOW ZERO') if grep { $_ < 0 } @$p;
            $e->{pairs} = $p;
        }
        return unless _apply_duty($e, $f);
        return 1;
    }

    if (exists $f->{len}) {
        my $err = _length_ok('LENGTH', $f->{len}, 0);
        return _soft($err) if $err;
        $e->{len} = $f->{len};
    }
    if (exists $f->{size}) {
        return _soft("SIZE '$f->{size}' IS NOT A NUMBER") unless HardyCross::Parse::is_num($f->{size});
        return _soft('SIZE CANNOT BE NEGATIVE') if $f->{size} < 0;
        $e->{size} = $f->{size};
    }
    if (exists $f->{fits}) {
        my ($fits, $err) = _fits($f->{fits});
        return _soft($err) if $err;
        $e->{fits} = $fits;
    }
    if (exists $f->{use_type}) {
        my $t = uc $f->{use_type};
        HardyCross::Parse::ensure_db();
        return _soft("UNKNOWN PIPE TYPE $t") unless $t eq 'BORE' || HardyCross::PipeData::pipe_type($t);
        $e->{use} //= { type => 'BORE' };
        $e->{use}{type} = $t;
    }
    if (exists $f->{use_c}) {
        if ($f->{use_c} eq '') { delete $e->{use}{c} }
        else {
            return _soft("'$f->{use_c}' IS NOT A NUMBER") unless HardyCross::Parse::is_num($f->{use_c});
            return _soft('C CANNOT BE NEGATIVE') if $f->{use_c} < 0;
            $e->{use}{c} = $f->{use_c};
        }
    }
    if (exists $f->{eqv}) {
        if ($f->{eqv} eq '') { delete $e->{eqv} }
        else {
            my $err = _length_ok('EQV', $f->{eqv}, 0);
            return _soft($err) if $err;
            $e->{eqv} = $f->{eqv};
        }
    }
    if (exists $f->{device}) {
        my $k = uc $f->{device};
        $k = 'NONE' if $k eq '';
        if ($k eq 'NONE') {
            delete $e->{device};
            delete $e->{duty};
        } else {
            return _soft("UNKNOWN DEVICE $k") unless $DEVICE{$k};
            # A change of device starts from that device's own figures.  The
            # card still shows the previous device's fields until it is
            # drawn again, and those must not be written onto the new one.
            my $changed = !$e->{device} || $e->{device}{kind} ne $k;
            if ($changed) {
                $e->{device} = _device_default($k);
                delete $e->{duty} unless $k eq 'BP';
                return 1;
            }
            my $d = $e->{device};
            if ($k eq 'BP') {
                if (exists $f->{churn} && $f->{churn} ne '') {
                    return _soft("CHURN '$f->{churn}' IS NOT A NUMBER") unless HardyCross::Parse::is_num($f->{churn});
                    $d->{churn} = $f->{churn};
                }
                if (exists $f->{pairs}) {
                    my ($p, $err) = _numlist($f->{pairs}, 1);
                    return _soft($err) if $err;
                    return _soft('A BOOSTER NEEDS A FLOW AND A PRESSURE') unless @$p;
                    $d->{pairs} = $p;
                }
            } elsif ($k eq 'BFP' || $k eq 'PRV') {
                if (exists $f->{pairs}) {
                    my ($p, $err) = _numlist($f->{pairs}, 1);
                    return _soft($err) if $err;
                    return _soft('A LOSS CURVE NEEDS A FLOW AND A LOSS') unless @$p;
                    $d->{pairs} = $p;
                }
            } elsif ($k eq 'OPP') {
                $d->{drop} = $f->{drop} if exists $f->{drop} && $f->{drop} ne '';
                if (exists $f->{cd}) {
                    my $err = _optional_num($d, 'cd', $f->{cd});
                    return _soft($err) if $err;
                }
            } elsif ($k eq 'OFD') {
                $d->{bore} = $f->{bore} if exists $f->{bore} && $f->{bore} ne '';
                if (exists $f->{cd}) {
                    my $err = _optional_num($d, 'cd', $f->{cd});
                    return _soft($err) if $err;
                }
            } elsif ($k eq 'PRA') {
                $d->{ratio} = $f->{ratio} if exists $f->{ratio} && $f->{ratio} ne '';
                if (exists $f->{mininlet}) {
                    if ($f->{mininlet} eq '') { delete $d->{mininlet} } else { $d->{mininlet} = $f->{mininlet} }
                }
                if (exists $f->{band}) {
                    if ($f->{band} eq '') { delete $d->{band} } else { $d->{band} = $f->{band} }
                }
            }
        }
    }
    if (exists $f->{duty_q} || exists $f->{duty_p}) {
        return unless _apply_duty($e, $f);
    }
    return 1;
}

sub _optional_num {
    my ($d, $key, $value) = @_;
    if (!defined $value || $value eq '') { delete $d->{$key}; return }
    return "'$value' IS NOT A NUMBER" unless HardyCross::Parse::is_num($value);
    $d->{$key} = $value;
    return;
}

sub _apply_flow {
    my ($doc, $fl, $f) = @_;
    if (exists $f->{name} && $f->{name} ne $fl->{name}) {
        my $err = _check_name($doc, $f->{name}, $fl->{id});
        return _soft($err) if $err;
        $fl->{name} = $f->{name};
    }
    if (exists $f->{q}) {
        return _soft("FLOW '$f->{q}' IS NOT A NUMBER") unless HardyCross::Parse::is_num($f->{q});
        return _soft('FLOW CANNOT BE NEGATIVE') if $f->{q} < 0;
        $fl->{q} = $f->{q};
    }
    if (exists $f->{minp}) {
        if ($f->{minp} eq '') { delete $fl->{minp} }
        else {
            return _soft("MINPRESSURE '$f->{minp}' IS NOT A NUMBER") unless HardyCross::Parse::is_num($f->{minp});
            return _soft('MINPRESSURE CANNOT BE NEGATIVE') if $f->{minp} < 0;
            $fl->{minp} = $f->{minp};
        }
    }
    return 1;
}

# apply_file -- the title, the method, the units, and the text of project
# fields that are already there.  Options, areas and supply graphs are part
# of the file and are written back as they were read; the card does not
# pretend to edit them.
sub apply_file {
    my ($doc, $f) = @_;
    $ERROR = undef;
    $f ||= {};
    # Check the whole card before changing anything, so a bad unit does not
    # leave the method half-applied and a calculation looking current.
    my ($title, $method, %units);
    if (exists $f->{title}) {
        my $t = $f->{title};
        $t =~ s/^\s+|\s+\z//g;
        $title = length $t ? $t : undef;
    }
    if (exists $f->{method}) {
        $method = uc $f->{method};
        return _soft('METHOD IS HW OR DW') unless $method eq 'HW' || $method eq 'DW';
    }
    for my $q (@HardyCross::Phc::UNIT_QUANTITIES) {
        my $key = "unit_$q";
        next unless exists $f->{$key};
        my $a = HardyCross::Phc::analyse("UNITS $q $f->{$key}");
        return _soft($a->{status} eq 'incomplete' ? "UNITS NEEDS $a->{msg}" : $a->{msg})
            if $a->{status} ne 'ok';
        $units{$q} = $a->{pos}[1];
    }
    my @project;
    if ($f->{project}) {
        my $i = 0;
        for my $text (@{ $f->{project} }) {
            last unless $doc->{project}[$i];
            $text =~ s/\s+\z//;
            return _soft('A PROJECT FIELD NEEDS ITS TEXT') if $text eq '';
            push @project, $text;
            $i++;
        }
    }
    my $before = eval { model_text($doc) };
    $doc->{title} = $title if exists $f->{title};
    $doc->{method} = $method if exists $f->{method};
    $doc->{units}{$_} = $units{$_} for keys %units;
    my $i = 0;
    $doc->{project}[$i++]{text} = $_ for @project;
    my $after = eval { model_text($doc) };
    clear_result($doc) if !defined $before || !defined $after || $before ne $after;
    return 1;
}

#==============================================================================
# Checking and calculating, both by the existing program.
#==============================================================================

sub _msg {
    my $e = shift;
    return 'UNKNOWN ERROR' unless defined $e;
    my $m = HardyCross::is_model_error($e) ? $e->{msg} : "$e";
    $m =~ s/\s+\z//;
    return $m;
}

# validate -- write the drawing and give it to the reader.  ok, or the
# reader's own message.  text is the model without positions, which is what
# a later CALCULATE is allowed to solve.
sub validate {
    my $doc = shift;
    my $text = write_text($doc);
    my $net = eval { HardyCross::Phc::read_string($text, '.') };
    if (!$net) {
        return { ok => 0, error => _msg($@), text => model_text($doc) };
    }
    return { ok => 1, text => model_text($doc) };
}

# calculate -- the command line's calculation on the drawing: read, solve,
# size a pipe given size 0, and where the file has design areas solve the
# one that governs.  Pressures and flows are copied onto the blocks only
# when the run converged.  A run that did not is not a result, so the
# picture is left without figures.
sub calculate {
    my ($doc, %arg) = @_;
    clear_result($doc);
    my $text = write_text($doc);
    my $net = eval { HardyCross::Phc::read_string($text, '.') };
    return { ok => 0, error => _msg($@) } unless $net;
    my $progress = $arg{progress};
    my $ok = eval { HardyCross::solve_model($net) };
    return { ok => 0, error => _msg($@) } if $@;
    if ($net->{auto_sizing}) {
        require HardyCross::Sizing;
        ($net, $ok) = eval { HardyCross::Sizing::size($net, $ok, progress => $progress) };
        return { ok => 0, error => _msg($@) } if $@ || !defined $net;
    }
    if ($net->{areas} && !defined $net->{design_area}) {
        require HardyCross::Areas;
        ($net, $ok) = eval { HardyCross::Areas::governing($net, $ok, progress => $progress) };
        return { ok => 0, error => _msg($@) } if $@ || !defined $net;
    }
    my ($gov) = grep { $_->{governs} } @{ $net->{area_results} || [] };
    my $msg = $ok ? 'CONVERGED' : 'DID NOT CONVERGE - THE FIGURES ARE NOT A RESULT TO USE';
    $msg .= sprintf(', %d ITERATIONS', $net->{iters}) if defined $net->{iters};
    $msg .= ", AREA $gov->{name} GOVERNS" if $ok && $gov;
    $doc->{solved} = { converged => $ok ? 1 : 0, iters => $net->{iters},
                       area => $gov ? $gov->{name} : undef };
    return { ok => 0, error => $msg, message => $msg } unless $ok;

    my (%press, %flow);
    for my $i (1 .. $#{ $net->{nodes} }) {
        my $n = $net->{nodes}[$i];
        next if $n->{id} eq 'REF' || $n->{id} =~ /~\z/;
        $press{ $n->{id} } = ($n->{h} - $HardyCross::GAMMA_W * $n->{z}) / $net->{f_pres};
    }
    for my $i (1 .. $#{ $net->{elems} }) {
        my $e = $net->{elems}[$i];
        $flow{ $e->{id} } = $e->{q} / $net->{f_flow};
    }
    for my $n (@{ $doc->{nodes} }) {
        $n->{pressure} = $press{ $n->{name} } if exists $press{ $n->{name} };
    }
    my %sized;
    for my $u (@{ ($net->{sizing} || {})->{units} || [] }) {
        $sized{$_} = $u->{token} for @{ $u->{pipes} };
    }
    for my $e (@{ $doc->{edges} }) {
        $e->{flow} = $flow{ $e->{name} } if exists $flow{ $e->{name} };
        if ($e->{device}) {
            my $id = $e->{name} . '.' . $e->{device}{kind};
            $e->{device_flow} = $flow{$id} if exists $flow{$id};
        }
        $e->{sized} = $sized{ $e->{name} } if exists $sized{ $e->{name} };
    }
    return { ok => 1, message => $msg };
}

1;
