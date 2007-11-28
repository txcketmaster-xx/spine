# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: DryRun.pm,v 1.1.2.4.2.1 2007/10/02 22:01:35 phil Exp $

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

package Spine::Plugin::DryRun;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE, $DRYRUN);

$VERSION = sprintf("%d.%02d", q$Revision: 1.1.2.4.2.1 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Spine::Plugin skeleton";

$MODULE = { author => 'websys@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'DISCOVERY/populate' => [ { name => 'dryrun',
                                                   code => \&is_dryrun } ]
                     },
            cmdline => { options => { dryrun => \$DRYRUN } }
          };


sub is_dryrun
{
    my $c = shift;

    # Make sure we don't save state
    $::SAVE_STATE = 0;

    $c->set('c_dryrun', $DRYRUN);

    return PLUGIN_SUCCESS;
}

1;
