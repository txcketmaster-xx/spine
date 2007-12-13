# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Structured.pm,v 1.1.2.2 2007/09/13 16:15:16 rtilder Exp $

#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# (C) Copyright Ticketmaster, Inc. 2007
#

package Spine::Publisher::Structured;

use strict;

use base qw(Spine::Publisher);
use Spine::Constants qw(:publish :mime);

use File::Path;
use File::Basename qw(basename fileparse);
use File::Spec::Functions;

our $VERSION = sprintf("%d", q$Revision: 1 $ =~ /(\d+)/);

our $DEBUG = $ENV{SPINE_PUBLISHER_DEBUG} || 0;


sub new
{
    my $proto = shift;
    my $klass = ref($proto) || $proto;
    my %args = @_;

    my $self = $klass->SUPER::new(%args);

    bless $self, $klass;

    $self->{overlay_cache} = $self->populate_cache($args{overlay_cache});
    $self->{destinations} = $args{destinations} || { overlay => 1,
                                                     class_overlay => 2 };
    $self->{config_groups} = { '/' => [] };
    $self->{stack} = [ ['/', $self->{config_groups}->{'/'}] ];
    $self->{in_overlay} = 0;

    if (defined($args{groups}) and ref($args{groups}) eq 'ARRAY') {
        for my $path (@{$args{groups}}) {
            if (file_name_is_absolute($path)) {
                $path =~ s|^/+(.*)|$1|o;
            }
            $self->{config_groups}->{$path} = [];
        }
    }

    return $self;
}


sub generate
{
    my $self = shift;

    while (my ($cg_name, $cg) = each(%{$self->{config_groups}})) {
        unless (ref($cg) and ref($cg) eq 'ARRAY') {
            delete $self->{config_groups}->{$cg_name};
        }
        elsif (scalar(@{$cg}) == 0) {
            delete $self->{config_groups}->{$cg_name};
        }
    }

    return 1;
}


sub clean
{
    my $self = shift;

    return 1;
}


sub populate_cache
{
    my $self = shift;
    my $cache = shift;

    if (defined($cache) and ref($cache) eq 'HASH') {
        return $cache;
    }

    $cache = { 1 => { 'proc' => { n => 'proc', u => 0, g => 0, p => 0755,
                                  ot => 1, ct => 5 },
                      'root' => { n => 'root', u => 0, g => 0, p => 0750,
                                  ot => 1, ct => 5 },
                      'tmp' => { n => 'tmp', u => 0, g => 0, p => 01777,
                                 ot => 1, ct => 5 },
                    },
               2 => { },
             };

    foreach my $path (qw(. bin boot dev etc home lib mnt opt sbin sys usr var
                         etc/apt etc/ssh )) {
        my $duh = { n => $path, u => 0, g => 0, p => 0755, ot => 1, ct => 5 };
        $cache->{1}->{$path} = $duh;
    }

    foreach my $path (qw(. shared shared/bin shared/conf shared/init local
                         local/bin local/conf local/init)) {
        my $duh = { n => $path, u => 1141, g => 1014, p => 0755, ot => 1,
                    ct => 5 };
        $cache->{2}->{$path} = $duh;
    }

    return $cache;
}


sub check_cache
{
    my $self = shift;
    my $obj = shift;

    unless (exists($self->{overlay_cache}->{$obj->{ot}}->{$obj->{n}})) {
        return $obj;
    }

    my $cached = $self->{overlay_cache}->{$obj->{ot}}->{$obj->{n}};

    unless (scalar(keys(%{$cached})) == scalar(keys(%{$obj}))) {
        return $obj;
    }

    while (my ($k, $v) = each(%{$obj})) {
        unless (exists($cached->{$k}) and $cached->{$k} eq $v) {
            return $obj;
        }
    }

    return $cached;
}


sub basics
{
    my $self = shift;
    my ($path, $props) = @_;

    # Munge our path name if necessary
    if (scalar(@{$self->{stack}})) {
        my $cg_name = $self->{stack}->[0]->[0];
        $path =~ m/^$cg_name/ && $path =~ s|^$cg_name/?||;
    }

    my $obj = { n => $path };

    # Set the appropriate permissions
    if (defined($props->{'spine:perms'})) {
        $obj->{p} = oct($props->{'spine:perms'});
    }

    # And the ownership
    if (defined($props->{'spine:ugid'})) {
        ($obj->{u}, $obj->{g}) = split(/:/, $props->{'spine:ugid'}, 2);
    }

    # SELinux context
    if (defined($props->{'spine:selinux_context'})) {
        $obj->{se} = $props->{'spine:selinux_context'};
    }

    # If we're in an overlay, we do some munging of the dir property
    if ($self->{in_overlay}) {
        $obj->{n} =~ s|^$self->{in_overlay}/||g;
        $obj->{ot} = $self->{destinations}->{$self->{in_overlay}};
    }

    return $obj;
}


my @dests;
sub is_overlay_src
{
    my $self = shift;
    my $candidate = basename(+shift);

    unless (scalar(@dests)) {
        @dests = keys(%{$self->{destinations}});
    }

    foreach my $srcdir (@dests) {
        return 1 if $candidate eq $srcdir;
    }

    return undef;
}


#
# Only creates a new group if it doesn't exist one doesn't exist and will only
# append that group to the stack if the top of the stack isn't already that
# group
#
sub new_group
{
    my $self = shift;
    my $name  = shift;
    my $cg = $self->{stack}->[0];
    my $group = [$name, undef];

    # We haven't flagged the parent as a config group yet
    unless (exists($self->{config_groups}->{$name})) {
        $self->{config_groups}->{$name} = [];
    }
    $group->[1] = $self->{config_groups}->{$name};

    # If our config group isn't at the top of the stack, put it there
    if (not defined($cg) or $cg->[0] ne $name) {
        unshift @{$self->{stack}}, $group;
    }

    $DEBUG > 2 && print STDERR ", new group \"$name\"";

    # Always returns the current top of the stack
    return $self->{stack}->[0];
}


#
# "Callbacks"
#

#
# Directories can be classified into four types:
#
#    1. A directory that is part of an overlay and therefore important
#    2. A directory that is the container for an overlay and therefore marks
#       the beginning of an overlay tree
#    3. A directory that holds configuration data(a.k.a. key files,
#       a.k.a. '.../config/*')
#    4. Everything else.  This is what currently creates the hierarchy
#
sub open_dir
{
    my $self = shift;
    my ($path, $fetched_rev, $props, $dirent) = @_;

    my $name = basename($path);
    my $dir = dirname($path);

    my $top = $self->{stack}->[0];

    my $obj = $self->basics($path, $props);

    $DEBUG > 3 && print STDERR "Od \"$path\"";

    # If we're in an overlay, we can just append this to our list of entries
    # for the current config group
    if ($self->{in_overlay}) {
        $obj->{ct} = SPINE_TYPE_DIR;
        $obj->{m} = $dirent->time;
        push @{$top->[1]}, $self->check_cache($obj);
        $DEBUG > 3 && print STDERR ": already in overlay\n";
    }
    # If it's a defined config group, use it
    # This should only ever get triggered for explicitly defined groups passed
    # into the constructor via the "groups" parameter
    elsif (exists($self->{config_groups}->{$path})) {
        $DEBUG > 3 && print STDERR "Populating pre-defined group: \"$path\"\n";
        unshift @{$self->{stack}}, [$path, $self->{config_groups}->{$path}];
        #$self->new_group($dir);
    }
    # Are we descending into a new config key directory?
    elsif ($name eq 'config') {
        $top = $self->new_group($dir);
        $DEBUG > 3 && print STDERR ": enter config dir\n";
    }
    # Are we descending into a new overlay directory?
    elsif ($self->is_overlay_src($path)) {
#           and (exists($obj->{p}) or exists($obj->{u}) or exists($obj->{g}))) {
        $self->{in_overlay} = $name;
        $obj->{ot} = $self->{destinations}->{$name};
        $obj->{ct} = SPINE_TYPE_DIR;
        $obj->{m} = $dirent->time;
        $obj->{n}  = '.';

        $top = $self->new_group($dir);

        push @{$top->[1]}, $self->check_cache($obj);

        $DEBUG > 3 && print STDERR ": entering overlay\n";
    }
    else {
        $DEBUG > 3 && print STDERR ": unhandled directory \"$path\"\n";
    }

    return $obj;
}


sub open_file
{
    my $self = shift;
    my ($path, $dirent, $props, $ref_to_content) = @_;

    $DEBUG > 4 && print STDERR "Of \"$path\"\n";

    my $obj = $self->basics($path, $props);
    my (undef, undef, $is_template) = fileparse($path, '.tt');

    $obj->{c} = ${$ref_to_content};
    $obj->{ct} = SPINE_TYPE_FILE; # Default to a plain file

    # FIXME  This tags(inadvertently?) includes/... and auth/... files as
    #        key files to be parsed.  This is almost certainly not what we
    #        want
    # If we're not in an overlay, this must be a key file
    unless ($self->{in_overlay}) {
        $obj->{n} =~ s|^config/||;
        $obj->{ct} = SPINE_TYPE_KEY;
        goto out;
    }

    # Grab our file size and mtime
    $obj->{s} = $dirent->size;
    $obj->{m} = $dirent->time;

    #
    # Handle all our overlay properties
    #

    # Is it an an svn:special file?  a.k.a. a symlink
    if (exists($props->{'svn:special'})) {
        unless ($props->{'svn:special'} =~ m/^\*/) {
            print STDERR 'Unhandled svn:special type "',
                          $props->{'svn:special'}, "\" for \"$path\"\n";
            print STDERR "\$props = {\n";
            while (my ($k, $v) = each(%{$props})) {
                print STDERR "\t'$k' => '$v',\n";
            }
            print STDERR "};\n";
            print STDERR "\$content = \\'${$ref_to_content}'\n";
            print STDERR "Probably a bug in the Subversion perl bindings.\n";
            print STDERR "Treating as a symlink anyway.\n";
        }

        $obj->{ct} = SPINE_TYPE_LINK;
        $obj->{c} =~ s|^link\s+||o;
        $obj->{s} -= 5; # account for the removal of "link "
        $obj->{p} = 0777;
    }
    # Is it a device or named pipe?
    elsif (exists($props->{'spine:filetype'})) {
        $obj->{ct} = SPINE_TYPE_BLOCK
            if ($props->{'spine:filetype'} eq SPINE_FILETYPE_BLOCK);

        $obj->{ct} = SPINE_TYPE_CHAR
            if ($props->{'spine:filetype'} eq SPINE_FILETYPE_CHAR);

        $obj->{ct} = SPINE_TYPE_PIPE
            if ($props->{'spine:filetype'} eq SPINE_FILETYPE_PIPE);

        $obj->{mj} = $props->{'spine:majordev'};
        $obj->{mn} = $props->{'spine:minordev'};
        $obj->{c} = undef; # place holder for empty body
    }
    elsif ($is_template) {
        $obj->{ct} = SPINE_TYPE_TMPL;
        $obj->{n} =~ s|\.tt$||o;
    }

  out:
    # Push our new object onto our config group's list of objects
    push @{$self->{stack}->[0]->[1]}, $obj;

    return $obj;
}


sub close_dir
{
    my $self = shift;
    my $path = $_[0];
    my $which = 'continuing';

    $DEBUG > 3 && print STDERR "Cd \"$path\"";

    my $top = $self->{stack}->[0];

    my $base = basename($path);
    my $dir  = dirname($path);

    # If we aren't closing a config group, this is just a no op
    if (not defined($top) or $path eq $top->[0]) {
        $DEBUG > 3 && print STDERR "Popping $top->[0]\n";
        shift @{$self->{stack}};
        $which = 'terminating';
    }

    $DEBUG > 3 && print STDERR ": $which group: \"$top->[0]\"";

    # If we're closing an overlay , mark the fact
    if ($self->{in_overlay} and $dir eq $top->[0]
        and $self->is_overlay_src($base)) {
        $DEBUG > 3 && print STDERR ', leaving overlay type: "',
                               $self->{destinations}->{$self->{in_overlay}},
                               '"';
        $self->{in_overlay} = 0;
    }

    $DEBUG > 3 && print STDERR "\n";
    return [$top->[0], $top->[1]->[0]];
}


sub dirname
{
    my $path = shift;

    $path = File::Basename::dirname($path);

    return $path eq '.' ? '/' : $path;
}

1;
