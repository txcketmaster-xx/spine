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

package Spine::Plugin::FirstRun;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d.%02d", q$Revision$ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Spine::Plugin skeleton";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { EMIT => [ { name => 'first_run',
                                    code => \&first_run } ]
                     },
          };


use Spine::Util qw(mkdir_p safe_copy uid_conv gid_conv touch);

sub first_run
{
    my $c = shift;
    my $rval = 0;

    my $state_dir = $c->{c_config}->{spine}->{StateDir};
    my $service_bin = $c->getval('service_bin');
    my $stop_services = $c->getvals('stop_services');

    my $default_ugid = $c->getval('firstrun_default_ugid') || qq(0:0);
    my $default_mode = $c->getval('firstrun_default_mode')
        || qq(0755);

    my $dryrun = $c->getval('c_dryrun');

    # Modules.conf is replaced with kernel 2.6.
    my $modules_conf_file = "/etc/modules.conf";
    $modules_conf_file = "/etc/modprobe.conf"
	if (-f "/etc/modprobe.conf");

    for my $service (@{$stop_services})
    {	
        $c->print(2, "stopping $service");
        my $result = `$service_bin $service stop 2>&1`
	    unless ($dryrun);
    }

    return PLUGIN_SUCCESS if (-f "${state_dir}/installed");

    $c->print(2, "creating state directory $state_dir");
    unless ($dryrun)
    {
        mkdir_p("${state_dir}", 0755);
        safe_copy("/etc/fstab", "${state_dir}/") || $rval++;
        safe_copy("$modules_conf_file", "${state_dir}/")
            || $rval++;
    }

    if ( exists $c->{'firstrun_mkdirs'} )
    {
        for my $element ( @{$c->getvals("firstrun_mkdirs")} )
        {
            (my $dir, my $mode, my $ugid) = split( /,/, $element);
            $mode = $default_mode unless $mode;

            $ugid = $default_ugid unless $ugid;
            (my $uid, my $gid) = split( /:/, $ugid);

            $c->print(2, "creating directory $dir "
                . "[mode $mode | owner/group " 
                . uid_conv($uid) . ":"
                . gid_conv($gid) . "]");
                
            unless ($dryrun)
            {
                mkdir_p($dir, oct($mode));
                chown $uid, $gid, $dir;
            }
        }
    }

    if ($rval == 0)
    {
	touch("${state_dir}/installed") unless ($dryrun);
	return PLUGIN_SUCCESS;
    }
    else
    {
	return PLUGIN_FATAL;
    }
}

1;
