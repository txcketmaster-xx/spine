# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: ClassInstances.pm,v 1.1.2.1.2.1 2007/10/02 22:01:35 phil Exp $

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

package Spine::Plugin::ClassInstances;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d.%02d", q$Revision: 1.1.2.1.2.1 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "A simple data discovery plugin that finds out how many instances of this class exist in the current product and cluster";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'DISCOVERY/populate' => [ { name => 'num_instances',
                                                   code => \&num_instances } ],
                     },
          };

use Spine::Util qw(resolve_address);

our ($MAXIMUM_INSTANCES);

$MAXIMUM_INSTANCES = 60;

sub num_instances
{
    my $c = shift;
    my $stop = $c->getvallast('max_num_instances');
    my $me = $c->getval('c_instance');
    my $counter = 1;

    my $class = $c->getval('c_class');

    # I still don't get why the subclass name prefixes the class name.  Seems
    # awfully backward.  But what do you expect from scary, large Norwegeian
    # nationals?
    #
    # rtilder    Tue Apr  3 10:59:16 PDT 2007
    #
    if (defined($c->getval('c_subclass'))) {
        $class = $c->getval('c_subclass') . '-' . $class;
    }

    my $meatybits = '.' . $c->getval('c_product');
    $meatybits .= '.' . $c->getval('c_cluster');
    $meatybits .= '.' . $c->getval('c_bu');
    $meatybits .= '.' . $c->getval('c_tld');

    # Try to pretend to have some sane defaults
    unless (defined($stop)) {
        $stop = $MAXIMUM_INSTANCES;
    }

    for my $i (1 .. $stop) {
        if ($i == $me) {
            next;
        }

        if (defined(resolve_address($class . $i . $meatybits))) {
            $counter++;
        }
    }

    $c->{'num_instances'} = $counter;

    return PLUGIN_SUCCESS;
}

1;
