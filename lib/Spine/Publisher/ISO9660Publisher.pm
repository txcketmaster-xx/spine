# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: ISO9660Publisher.pm,v 1.1.4.2 2007/09/11 21:28:02 rtilder Exp $

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

package Spine::Publisher::ISO9660Publisher;

use strict;

use base qw(Spine::Publisher::FSBallPublisher);

use File::Temp qw(mkstemp);

our $VERSION = sprintf("%d", q$Revision: 1 $ =~ /(\d+)/);

our $ISOFS_CMD = '/usr/sbin/mkisofs -R -o ';
our $CMD_TAIL  = ' > /dev/null 2>&1';
our $GZIP_CMD  = '/usr/bin/gzip -9 -c ';


# Runs mksifofs then gzips the result
sub generate
{
    my $self = shift;
    my $ballname = defined($self->{ballname}) ? '-' . $self->{ballname}
                                              : '';

    $self->{_target} = mkstemp('/tmp/config-balls/spine-config'
                               . $self->{ballname} . '-' . $self->{revision}
                               . '.iso.XXXXXXXX');
    $self->{filename} = '/tmp/config-balls/spine-config' . $self->{ballname}
                        . '-' . $self->{revision} . '.iso.gz';

    my $cmd = "$ISFOS_CMD $self->{_target} $self->{top} $CMD_TAIL";

    my $rc = system($cmd);

    if (($rc >> 8) != 0) {
        warn("Failed to run \"$cmd\"");
        return undef;
    }

    $cmd = "$GZIP_CMD $self->{_target} > $self->{filename} $CMD_TAIL";

    $rc = system($cmd);

    if (($rc >> 8) != 0) {
        warn("Failed to run \"$cmd\"");
        return undef;
    }

    return $self->{filename};
}


1;
