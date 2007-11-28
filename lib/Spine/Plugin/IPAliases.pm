# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: IPAliases.pm,v 1.1.2.2.2.1 2007/10/02 22:01:36 phil Exp $

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

package Spine::Plugin::IPAliases;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use Spine::Util qw(resolve_address);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d.%02d", q$Revision: 1.1.2.2.2.1 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Spine::Plugin skeleton";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'PARSE/complete' => [ { name => 'ip_aliases',
                                               code => \&ip_aliases } ]
                     }
          };


sub ip_aliases
{
    my $c = shift;

    # Check for additional ip aliases (class-a1, class-a2, etc).
    # The number if aliases we look for is determined by the key
    # ipaliases_num (starting from 1, to the defined number).
    if (exists $c->{ipaliases_num})
    {
	my $hostname_p =  join('.', $c->{c_product}, $c->{c_cluster},
				$c->{c_bu}, $c->{c_tld});
	my $numalias = $c->getval('ipaliases_num');

	foreach my $alias (1 .. $numalias)
	{
	    my $ipalias_host = $c->{c_class} . $c->{c_instance} . '-a'
                               . $alias . '.' . $hostname_p;
	    $c->cprint("resolving alias $ipalias_host", 4);
	    my $ipalias_ip = resolve_address($ipalias_host);
	    $c->{'c_ip_address_a' . $alias} = $ipalias_ip if ($ipalias_ip);
	}
    }

    return PLUGIN_SUCCESS;
}


1;
