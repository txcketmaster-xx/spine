# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id$

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

use strict;

package Spine::ConfigSource::FileSystem;
our ($VERSION, @ISA, $ERROR);

@ISA = qw(Spine::ConfigSource);
$VERSION = sprintf("%d.%02d", q$Revision$ =~ /(\d+)\.(\d+)/);

use IO::File;
use Spine::ConfigSource;

sub new
{
    my $klass = shift;

    my $self = new Spine::ConfigSource(@_);

    bless $self, $klass;

    for my $path (($self->{Path}, $self->{Config}->{FileSystem}->{Path}))
    {
        if (not defined($path) or $path =~ m|^\s*$|)
        {
            next;
        }

        if (not $self->_check_path($path))
        {
            $ERROR = "Invalid configuration root path!";
            undef $self;
            return undef;
        }

        $self->{Path} = $path;
        last;
    }

    return $self;
}


sub _check_path
{
    my $self = shift;
    my $path = shift;

    unless (-e $path and -d $path)
    {
        $ERROR = "\"$path\" doesn't exist or isn't a directory!";
        return 0;
    }

    unless (-r $path and -x $path)
    {
        $ERROR = "\"$path\" isn't readable or traversable!";
        return 0;
    }

    return 1;
}


sub check_for_update
{
    my $self = shift;
    my $prev = shift;

    my $new = $self->_check_release();

    unless (defined($new)) {
        return undef;
    }

    if ($prev < $new) {
        return $new;
    }

    return $prev;
}


sub retrieve
{
    my $self = shift;
    my $release = shift;

    return $self->check_for_update($release);
}


sub retrieve_latest
{
    my $self = shift;

    return $self->_check_release();
}


sub source_info
{
    my $self = shift;

    return "filesystem($self->{Path})";
}


1;
