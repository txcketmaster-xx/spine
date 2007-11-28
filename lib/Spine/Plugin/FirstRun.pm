# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: FirstRun.pm,v 1.1.2.3.2.1 2007/10/02 22:01:36 phil Exp $

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

package Spine::Plugin::FirstRun;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d.%02d", q$Revision: 1.1.2.3.2.1 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Spine::Plugin skeleton";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { DISCOVERY => {},
                       PARSE => {},
                       PREPARE => {},
                       AUDIT => {},
                       EMIT => {},
                       APPLY => {},
                       CLEAN => {}
                     },
          };


use Spine::Util;

sub first_run
{
    my $c = shift;
    my $rval = 0;

    my $state_dir = $c->getval("state_dir");
    my $software = $c->getval("software_root");
    my $class = $c->getval("c_class");

    my $service_bin = $c->getval('service_bin');
    my $stop_services = $c->getvals('stop_services');

    # Modules.conf is replaced with kernel 2.6.
    my $modules_conf_file = "/etc/modules.conf";
    $modules_conf_file = "/etc/modprobe.conf"
	if (-f "/etc/modprobe.conf");

    for my $service (@{$stop_services})
    {	
        $c->cprint("stopping $service", 3);
        my $result = `$service_bin $service stop 2>&1`
	    unless ($c->getval('c_dryrun'));
    }

    return PLUGIN_SUCCESS if (-f "${state_dir}/installed");

    Spine::Util::mkdir_p("${state_dir}", 0755);
    Spine::Util::safe_copy("/etc/fstab", "${state_dir}/") || $rval++;
    Spine::Util::safe_copy("$modules_conf_file", "${state_dir}/") || $rval++;

    Spine::Util::mkdir_p("${software}", 0755);
    Spine::Util::mkdir_p("${class}/local", 0755);
    Spine::Util::mkdir_p("${class}/shared", 0755);

    if ($rval == 0)
    {
	Spine::Util::touch("${state_dir}/installed");
	return SPINE_SUCCESS;
    }
    else
    {
	return PLUGIN_FATAL;
    }
}

1;
