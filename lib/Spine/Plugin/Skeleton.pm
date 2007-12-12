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

package Spine::Plugin::Skeleton;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d.%02d", q$Revision$ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Spine::Plugin skeleton";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'DISCOVERY/populate' => [],
                       'DISCOVERY/policy-selection' => [],
                       'PARSE/initialize' => [],
                       'PARSE/pre-descent' => [],
                       'PARSE/post-descent' => [],
                       'PARSE/complete' => [],
                       PREPARE => [],
                       EMIT => [],
                       APPLY => [],
                       CLEAN => []
                     },
            cmdline => { _prefix => 'skeleton',
                         options => { },
                       },
          };


sub skeleton
{
    my $c = shift;

    if (0) {
        return PLUGIN_FATAL;
    }

    return PLUGIN_SUCCESS;
}

1;
