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

package Spine::Plugin::EthernetInterfaces;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);
$DESCRIPTION = "A quick data discovery plugin that harvests the ethernet interfaces on the machine";

$MODULE = { author => 'Nicolas "Sir Speedy" Simonds <nicolas.simonds@ticketmaster.com>',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'DISCOVERY/populate' => [ { name => 'ethernet_interfaces',
                                                   code => \&get_interfaces } ]
                     },
          };


sub get_interfaces
{
    my $c = shift;
    my @ints;

    open INPUT, "/proc/net/dev" or do {
        $c->cprint("Failed to open /proc/net/dev: $!");
        return PLUGIN_FATAL;
    };

    while (my $line = <INPUT>) {
        $line =~ m/^\s*(eth\d+)/ and push @ints, $1;
    }
    close INPUT;

    $c->set('c_ethernet_interfaces', \@ints);

    return PLUGIN_SUCCESS;
}


1;
