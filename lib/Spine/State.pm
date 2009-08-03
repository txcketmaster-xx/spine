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

#
# A simple interface to some of the crap stored in /var/spine/
#

use strict;

package Spine::State;
our ($VERSION, $ERROR);

use File::stat;
use IO::File;
use Storable;

sub new
{
    my $klass = shift;
    my $config = shift;

    my $self = bless {}, $klass;

    $self->{StateDir} = $config->{spine}->{StateDir};
    $self->{_data}    = undef;

    return $self;
}


sub error {
    my $self = shift;

    if (scalar(@_) > 0)
    {
        $ERROR .= join("\n", @_) . "\n";
    }

    return $ERROR;
}


sub load
{
    my $self = shift;
    my $inst_file = $self->{StateDir} . '/installed';
    my $lastrun_file = $self->{StateDir} . '/lastrun';

    # Get the install date
    if (-f $inst_file)
    {
        my $sb = stat($inst_file);
        $self->{_installed} = $sb->ctime;
        undef $sb;
    }
    else
    {
        $self->{_installed} = 0;
    }

    if (not -f $lastrun_file or not -r $lastrun_file)
    {
        return undef;
    }

    # Get our last run's Spine::Data object
    my $data = retrieve($lastrun_file);

    if (not defined($data))
    {
        $self->error("Could not deserialize lastrun");
        return undef;
    }

    $self->{_data} = $data;

    return 1;
}


sub store
{
    my $self = shift;
    my $lastrun_file = $self->{StateDir} . '/lastrun';

    if (not defined($self->{_data}))
    {
        $ERROR = "No data to store!";
        return undef;
    }

    if (not defined(Storable::store($self->{_data}, $lastrun_file)))
    {
        $ERROR = "Storable had problems!";
        return undef;
    }

    chmod 0600, $lastrun_file;

    return 1;
}


sub installed
{
    my $self = shift;

    return $self->{_installed};
}


sub data
{
    my $self = shift;
    my $data = shift;

    if (defined($data))
    {
        $self->{_data} = $data;
    }

    return $self->{_data};
}


sub _getval
{
    my $self = shift;
    my $key  = shift;

    if (not defined($self->{_data}))
    {
        return undef;
    }

    return $self->{_data}->getval($key);
}


sub run_time
{
    my $self = shift;

    return $self->_getval('c_start_time');
}


sub release
{
    my $self = shift;

    return $self->_getval('c_release');
}

sub version
{
    my $self = shift;

    return $self->_getval('c_version');
}

1;
