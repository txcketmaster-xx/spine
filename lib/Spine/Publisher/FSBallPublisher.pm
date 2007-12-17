# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: FSBallPublisher.pm,v 1.1.4.2 2007/09/13 16:15:16 rtilder Exp $

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

package Spine::Publisher::FSBallPublisher;

use strict;

use base qw(Spine::Publisher);
use Spine::Constants qw(:publish :mime);

use File::Path;
use File::Spec::Functions qw(:ALL);

# Default to using the 'nobody' user for all ownership
use constant {
    DEFAULT_UID        => 99,
    DEFAULT_GID        => 99,
    DEFAULT_FILE_PERMS => 0644,
    DEFAULT_DIR_PERMS  => 0755
};

our $VERSION = sprintf("%d", q$Revision: 1 $ =~ /(\d+)/);


sub new
{
    my $proto = shift;
    my $klass = ref($proto) || $proto;
    my %args = @_;

    my $self = bless {}, $klass;

    # Set up some sane defaults
    foreach my $default (( ['default_uid', DEFAULT_UID],
                           ['default_gid', DEFAULT_GID],
                           ['default_file_perms', DEFAULT_FILE_PERMS],
                           ['default_dir_perms', DEFAULT_DIR_PERMS]
                         )) {
        unless (exists($self->{$default->[0]})) {
            $self->{$default->[0]} = $default->[1];
        }
    }

    return $self;
}


sub generate
{
    my $self = shift;

    return undef;
}


sub clean
{
    my $self = shift;

    if (-f $self->{filename}) {
        unlink($self->{filename});
    }

    if (-d $self->{top}) {
        rmtree($self->{top});
    }

    return 1;
}


#
# Extraction callbacks
#
sub open_dir
{
    my $self = shift;
    my ($path, $fetched_rev, $props, $dirent) = @_;

    # Make sure the directory exists as defined in the config
    $self->apply_filesystem_change($path, $props, $dirent)
        or return undef;

    return 1;
}


sub close_dir
{
    my $self = shift;
    my $path = shift;

    return 1;
}


sub open_file
{
    my $self = shift;
    my ($path, $dirent, $props, $ref_to_content) = @_;

    $self->apply_filesystem_change($path, $props, $ref_to_content)
        or return undef;

    return 1;
}


# Support overlay and non-overlay directories
sub apply_filesystem_change
{
    my $self = shift;
    my $path = shift;
    my $props = shift;
    my $content = shift || undef;

    my (@ugid) = ($self->{default_uid}, $self->{default_gid});
    my $perms = $self->{default_file_perms};
    my $abspath = file_name_is_absolute($path) ? $path
                                               : catfile($self->{top}, $path);

    # De-ref here if we were pass in a reference
    if (defined($content) and ref($content)) {
        $content = ${$content};
    }

    #
    # First, let's make sure the filesystem entry exists
    #

    # Is it a device or named pipe?
    if (exists($props->{'spine:filetype'})) {
        my ($type, $major, $minor) = (undef, undef, undef);

        $type = 'b' if ($props->{'spine:filetype'} eq SPINE_FILETYPE_BLOCK);

        $type = 'c' if ($props->{'spine:filetype'} eq SPINE_FILETYPE_CHAR);

        $type = 'p' if ($props->{'spine:filetype'} eq SPINE_FILETYPE_PIPE);

        unless (defined($type)) {
            die('Unsupported device type "' . $props->{'spine:filetype'}
                . "\" for \"$path\"");
        }

        $major = $props->{'spine:majordev'};
        $minor = $props->{'spine:minordev'};

        eval { system("/bin/mknod $abspath $type $major $minor") };

        if ($@) {
            print STDERR "Failed to create device file \"$path\": $@\n";
            return undef;
        }
    }
    # Is it an an svn:special file?  a.k.a. a symlink
    elsif (exists($props->{'svn:special'})) {
        my (undef, $target) = split(/\s+/, $content, 2);
        symlink($target, $abspath);
    }
    # If $content is undefined, we can assume it to be a directory at this
    # point but only because we handled device files earlier
    elsif (not defined($content)) {
        $perms = $self->{default_dir_perms};

        # Make sure it exists
        unless (-d $abspath) {
            mkpath($abspath);
        }
    }
    # It's a plain file, apparently
    else {
        my $fh = new IO::File("> $abspath");

        unless (defined($fh)) {
            print STDERR "Failed to open \"$path\": $!\n";
            return undef;
        }

        $fh->syswrite($content, length($content));

        $fh->close();
    }

    # Set the appropriate permissions
    if (exists($props->{'spine:perms'})) {
        $perms = $props->{'spine:perms'};
    }

    # And the ownership
    if (exists($props->{'spine:ugid'})) {
        @ugid = split(/:/, $props->{'spine:ugid'}, 2);
        # FIXME  Should we do user and group name lookups here?  Mildly
        #        work intesive
    }

    chown @ugid, $abspath;
    chmod $perms, $abspath;

    return 1;
}


1;
