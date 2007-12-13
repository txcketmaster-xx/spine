# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

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

package Spine::Publisher;

use strict;

use File::Temp qw(tempdir);
use File::Spec::Functions;
use IO::File;
use IO::Scalar;

use SVN::Core;
use SVN::Ra;

use Spine::Constants qw(:publish);

our $VERSION = sprintf("%d", q$Revision: 1 $ =~ /(\d+)/);


sub new
{
    my $proto = shift;
    my $klass = ref($proto) || $proto;
    my %args = @_;

    my $self = bless { pool => SVN::Pool->new_default_sub(),
                       filename => undef,
                       ra => undef,
                       top => undef,
                       url => delete($args{url}),
                       revision => delete($args{revision}),
                       %args
                     }, $klass;

    # Set up some sane defaults
    foreach my $default (( ['tempdir_template',
                            '/tmp/config-balls/robots-rule.XXXXXX'] )) {
        unless (exists($self->{$default->[0]})) {
            $self->{$default->[0]} = $default->[1];
        }
    }

    return $self;
}


# The primary external interface
sub build
{
    my $self = shift;
    my $url  = shift || $self->{url};
    my $rev  = shift || $self->{revision};

    # If we don't have any further arguments, we use the predefined modules
    unless (scalar(@_)) {
        @_ = @{$self->{modules}};
    }

    # Extract our filesystem
    unless ($self->extract($url, $rev, @_)) {
        die("Failed to extract!");
    }

    unless ($self->generate()) {
        die ("Failed to generate configball!");
    }

    return $self->{filename};
}


sub filename
{
    my $self = shift;

    return $self->{filename};
}


sub generate
{
    my $self = shift;

    return 1;
}


sub clean
{
    return 1;
}


sub extract
{
    my $self = shift;
    my $url = shift;
    my $rev = shift;

    unless (-d $self->{top}) {
        $self->{top} = tempdir($self->{tempdir_template}, CLEANUP => 0);
    }

    # Check out our modules to the path names in question
    foreach my $dir (@_) {
        if ($url ne $self->{url}) {
            $self->{ra} = new SVN::Ra(url => $url);

            unless (defined($self->{ra})) {
                print STDERR "Couldn't connect to \"$url\"! for \"$dir\"\n";
                goto error;
            }

            $self->{url} = $url;
            $self->{revision} = $rev;
        }

        # Aaaaaaaaaand extract
        $self->extract_dir($dir);
    }

    return 1;

  error:
    undef $self->{top};
    return undef;
}


sub extract_dir
{
    my $self = shift;
    my $path = shift;
    my $recurse = shift || 1;
    my $dirent = shift || undef;

    # @dir = (directory contents as a hash ref,
    #         actual fetched revision,
    #         properties of the entry itself as hash ref)
    my @dir = $self->{ra}->get_dir($path, $self->{revision});

    $self->open_dir($path, $dir[1], $dir[2], $dirent);

    # Now walk the dirent and populate as necessary.
    my (%files, @subdirs);
    while (my ($entry, $sub_dirent) = each(%{$dir[0]})) {
        # If it's a directory, append the list of subdirs to descend later
        if ($sub_dirent->kind == SVN_DIRECTORY) {
            push @subdirs, $entry;
            next;
        }

        $self->extract_file(catdir($path, $entry), $sub_dirent);
    }

    # Now descend the subdirectories
    foreach my $subdir (@subdirs) {
        $files{$subdir} = $self->extract_dir(catdir($path, $subdir), $recurse,
                                             $dir[0]->{$subdir});
    }

    $self->close_dir($path);
}


sub extract_file
{
    my $self = shift;
    my ($path, $dirent) = @_;

    my $abspath = catfile($self->{top}, $path);

    if (-e $abspath) {
        print STDERR "Odd.  $path seems to already exist before extraction.\n";
    }

    my $fh = new IO::Scalar();

    unless (defined($fh)) {
        print STDERR "Ruh-roh!  Couldn't open \"$path\": $!\n";
        return undef;
    }

    my (undef, $props) = $self->{ra}->get_file($path, $self->{revision}, $fh);

    # Note that we pass in the ref to the scalar payload
    $self->open_file($path, $dirent, $props, $fh->sref);

    defined($fh) and $fh->close();
}


sub open_dir
{
    my $self = shift;
    my ($path, $fetched_rev, $props, $dirent) = @_;

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

    return 1;
}

1;
