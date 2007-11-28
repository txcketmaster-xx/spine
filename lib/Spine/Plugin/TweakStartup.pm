# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: TweakStartup.pm,v 1.1.2.4.2.1 2007/10/02 22:01:36 phil Exp $

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

package Spine::Plugin::TweakStartup;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d.%02d", q$Revision: 1.1.2.4.2.1 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "A variety of changes to tweak the boot process for the machine";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { APPLY => [ { name => 'tweak_startup',
                                    code => \&tweak_startup } ] }
          };


use File::Basename;

my ($DRYRUN, $CHKCONFIG, $SERVICE);


sub tweak_startup
{
    my $c = shift;
    my $l = shift;

    if (ref($l) == 'Spine::State') {
        $l = $l->data();
    }

    my $rval = 0;

    my $init_dir = $c->getval("init_dir");

    # Action specific values
    my $stop = $c->getval("startup_execstop");
    my $services_ignore = $c->getvals('startup_ignore');
    my $services_on = $c->getvals("startup");

    # Data from the previous run
    my $last_services_on = $l->getvals("startup");

    $DRYRUN = $c->getval('c_dryrun');
    $CHKCONFIG = $c->getval('chkconfig_bin');
    $SERVICE = $c->getval('service_bin');

    foreach my $startscript (<$init_dir/*>)
    {
        next unless (-x "$startscript");
        my $service = basename($startscript);

	# We will not try to turn off these somewhat special
        # scripts in /etc/init.d/.
        next if ( grep(/$service/, @{$services_ignore}) );

        my $status = "off";
        $status = "on" if ( grep(/^${service}$/, @{$services_on}) );

	# Stop daemons that are not supposed to be running.
	if ( ($status eq "off") and ($stop)
                and (is_service_enabled($c, $service)) )
	{
	    $c->cprint("stopping $service", 2);
            exec_initscript($c, $service, "stop", 0);
	}

        # Manipulate our runlevels.
        if ( ((is_service_enabled($c, $service)) and ($status =~ "off")) or
           ((not is_service_enabled($c, $service)) and ($status =~ "on")) )
        {
            $c->cprint("turning $status $service", 2);

            config_init($c, $service, $status) or $rval++;
        }


	# Start services that have been turned on since the last time we ran
	if (($status eq "on") and (scalar @{$last_services_on} >= 1 ))
	{
	    if ( (not grep(/^${service}$/, @{$last_services_on})) and
		 (grep(/^${service}$/, @{$services_on})) )
	    {
		$c->cprint("starting $service", 2);
                exec_initscript($c, $service, "start", 1) or $rval++;
	    }
	}
    }

    return $rval ? PLUGIN_ERROR : PLUGIN_SUCCESS;
}


sub config_init
{
    my ($c, $service, $status) = @_;
    return 1 if $DRYRUN;

    my $result = `$CHKCONFIG $service $status 2>&1`;
    if ($result)
    {
        $c->error("failed for $service [$result]", "err");
        return 0;
    }
    return 1;
}


sub exec_initscript
{
    my ($c, $service, $function, $report_error) = @_;
    return 1 if $DRYRUN;

    my $result = `$SERVICE $service $function 2>&1`;
    if ($? > 0 and $report_error > 0)
    {
        $c->error("failed to $function $service", 'err');
        return 0;
    }
    return 1;
}


sub is_service_enabled
{
    my ($c, $service) = @_;

    my $chkconfig_output = `$CHKCONFIG --list $service 2>/dev/null`;

    # We only want to deal with runlevels 3-5
    my (undef, undef, undef, undef, @service_status)
        = split /\s+/, $chkconfig_output;

    return 1 if grep /\d+:on/, @service_status;
    return 0;
}


1;
