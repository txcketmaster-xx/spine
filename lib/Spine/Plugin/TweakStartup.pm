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

package Spine::Plugin::TweakStartup;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use Spine::Util qw(exec_initscript simple_exec);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf('%d', q$Revision$ =~ /(\d+)/);
$DESCRIPTION = 'A variety of changes to tweak the boot process for the machine';

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { APPLY => [ { name => 'tweak_startup',
                                    code => \&tweak_startup } ] }
          };

use File::Basename;

my $DRYRUN;

sub tweak_startup
{
    my $c = shift;
    my $l = shift;

    if (ref($l) == 'Spine::State')
    {
        $l = $l->data();
    }

    my $rval = 0;

    my $init_dir = $c->getval('init_dir');
    my $inetd_dir = $c->getval('inetd_dir');

    # Action specific values
    my $stop = $c->getval('startup_execstop');
    my $services_ignore = $c->getvals('startup_ignore');
    my $services_on = $c->getvals('startup');

    # Scripts we will process
    my @valid_scripts;

    # Data from the previous run
    my $last_services_on = [];
    if (defined($l)) 
    {
        $last_services_on = $l->getvals('startup');
    }

    $DRYRUN = $c->getval('c_dryrun');
    
    # Build a list of services if the directories exist.
    foreach my $dir ($init_dir, $inetd_dir)
    {
        if ($dir) 
        {
            foreach my $script (<$dir/*>)
            {
                next unless (-e "$script");
                push(@valid_scripts, $script);
            }
        }
    }

    foreach my $startscript (@valid_scripts)
    {
        my $service = basename($startscript);

        # We will not try to turn off these somewhat special
        # scripts in /etc/init.d/.
        next if (grep(/$service/, @{$services_ignore}));

        my $status = 'off';
        $status = 'on' if (grep(/^${service}$/, @{$services_on}));

        # Manipulate our runlevels.
        if (((is_service_enabled($c, $service)) and ($status =~ 'off')) or
            ((not is_service_enabled($c, $service)) and ($status =~ 'on')))
        {
            $c->cprint("turning $status $service", 2);
            config_init($c, $service, $status) or $rval++;
        }

        next if $startscript =~ m/$inetd_dir/;

        # Stop daemons that are not supposed to be running.
        if (($status eq 'off') and ($stop) and
            (is_service_enabled($c, $service)))
        {
            $c->cprint("stopping $service", 2);
            exec_initscript($c, $service, 'stop', 0);
        }

        # Start services that have been turned on since the last time we ran
        if (($status eq 'on') and (scalar @{$last_services_on} >= 1 ))
        {
            if ((not grep(/^${service}$/, @{$last_services_on})) and
                (grep(/^${service}$/, @{$services_on})))
            {
                $c->cprint("starting $service", 2);
                exec_initscript($c, $service, 'start', 1) or $rval++;
            }
        }
    }

    return $rval ? PLUGIN_ERROR : PLUGIN_SUCCESS;
}

sub config_init
{
    my ($c, $service, $status) = @_;
    return 1 if $DRYRUN;

    my @result = simple_exec(merge_error => 1,
                             inert       => 1,
                             exec        => 'chkconfig',
                             args        => [ $service, $status ],
                             c           => $c);
    if ($?)
    {
        $c->error("failed for $service [".join("", @result)."]", 'err');
        return 0;
    }
    return 1;
}

sub is_service_enabled
{
    my ($c, $service) = @_;

    my @result = simple_exec(merge_error => 1,
                             inert       => 1,
                             exec        => 'chkconfig',
                             args        => [ "--list",  $service ],
                             c           => $c);
   
    my @service_status = split /\s+/, join("", @result);

    if ($#service_status > 2) {
        # "traditional" output: we only want to deal with runlevels 3-5
        splice @service_status, 0, 4;
        return 1 if grep /\d+:on/, @service_status;
    } else {
        # xinetd output
        return 1 if $service_status[1] eq 'on';
    }
    return 0;
}

1;
