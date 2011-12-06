# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: TweakStartup.pm 240 2009-08-25 17:48:58Z richard $

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

$VERSION = sprintf('%d', q$Revision: 240 $ =~ /(\d+)/);
$DESCRIPTION = 'A variety of changes to tweak the boot process for the machine';

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { APPLY => [ { name => 'tweak_startup',
                                    code => \&tweak_startup } ] }
          };

use File::Basename;
use IO::File;

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

    my $init_dir = $c->getval('tweakstartup_init_dir') || qq(/etc/init.d);
    my $upstart_dir = $c->getval('tweakstartup_upstart_dir') || qq(/etc/init);

    # Action specific values
    my $stop = $c->getval('tweakstartup_execstop');
    my $no_start = $c->getval('tweakstartup_no_exec_start');
    my $services_ignore = $c->getvals('tweakstartup_ignore');
    my $services_on = $c->getvals('tweakstartup_startup');

    # Scripts we will process
    my @valid_scripts;

    # Data from the previous run
    my $last_services_on = [];
    if (defined($l)) 
    {
        $last_services_on = $l->getvals('tweakstartup_startup');
    }

    $DRYRUN = $c->getval('c_dryrun');

    # Build a list of services if the directories exist, upstart MUST
    # be first.
    foreach my $dir ($upstart_dir, $init_dir)
    {
        if ($dir)
        {
            foreach my $script (<$dir/*>)
            {
                if ("$dir" eq "$upstart_dir")
                {
                    next unless ($script =~ m/.*\.conf/);
                }
                elsif ("$dir" eq "$init_dir")
                {
                    next unless (-x "$script");
                }
                push(@valid_scripts, $script);
            }
         }   
    }     

    # Store a list of upstart jobs so we can ignore them if they match
    # an init.d job.
    my $upstart_jobs;

    foreach my $script (@valid_scripts)
    {
        my $service = '';
        my $type = '';
        if ($script =~ m/$upstart_dir\/.*/)
        {
            basename($script) =~ m/(.*)\.conf/;
            $service = $1;
            $type = 'upstart';
            # Ignore certain special jobs.
            next if (grep(/$service/, @{$services_ignore}));
            push(@{$upstart_jobs}, $service);

        } 
        elsif ($script =~ m/$init_dir\/.*/)
        {
            $service = basename($script);
            $type = 'init';
            # Ignore certain special jobs and anything controlled by upstart
            next if (grep(/$service/, @{$services_ignore}, @{$upstart_jobs}));
        }

        if (($service eq '') or ($type eq '')) 
        {
            $c->error("$script is unknown service or type", 'crit');
            return PLUGIN_FATAL;
        }

        # Get what the status of the service should be.
        my $conf_status = 'off';
        $conf_status = 'on' if (grep(/^${service}$/, @{$services_on}));
        #Get the current status of the service.
        my $current_status = is_service_enabled($c, $service, $type);

        # Change the startup status if necessary.
        if ($current_status ne $conf_status)
        {
            $c->cprint("turning $conf_status $service", 2);
            twiddle_service($c, $service, $conf_status, $type) or $rval++;;
        }

        # Stop any services that are not supposed to be running.
        if (($conf_status eq 'off') and ($stop) and ($current_status eq 'on'))
        {
            $c->cprint("stopping $service", 2);
            exec_initscript($c, $service, 'stop', 0, 0);
        }

        # Start services that have been turned on since the last time we ran
        if (($conf_status eq 'on') and !($no_start) and
                (scalar @{$last_services_on} >= 1 ))
        {
            if ((not grep(/^${service}$/, @{$last_services_on})) and
                (grep(/^${service}$/, @{$services_on})))
            {
                $c->cprint("starting $service", 2);
                # See if we should treat service start failures as an error
                if ($c->getval('tweakstartup_start_no_error'))
                {
                    exec_initscript($c, $service, 'start', 1, 0);
                }
                else
                {
                    exec_initscript($c, $service, 'start', 1, 0) or $rval++;
                }
            }
        }
    }

    return $rval ? PLUGIN_ERROR : PLUGIN_SUCCESS;
}

sub twiddle_service
{
    my ($c, $service, $status, $type) = @_;

    use feature "switch";
    given ($type) {
        when (/^upstart$/) {
            return twiddle_service_upstart($c, $service, $status);
        }
        when (/^init$/) {
            return twiddle_service_init($c, $service, $status);
        }
    }
}

sub twiddle_service_init
{
    my ($c, $service, $status) = @_;

    my @result = simple_exec(merge_error => 1,
                             inert       => 0,
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

sub twiddle_service_upstart
{
    my ($c, $service, $status) = @_;
    return 1 if $DRYRUN;
    my $upstart_dir = $c->getval('tweakstartup_upstart_dir') || qq(/etc/init);

    use feature "switch";
    given ($status) {
        when (/^on$/) {
            return 1 unless ( -e "$upstart_dir/$service.override" );
            my $override = new IO::File("< $upstart_dir/$service.override");

            if (not defined($override))
            {
                $c->error("failed to open $upstart_dir/$service.override", \
                    'err');
                return 0;
            }
            my @FILE;
            while (<$override>)
            {
                chomp;
                push(@FILE, $_);
            }
            $override->close();

            @FILE = grep !/^manual$/, @FILE;
            my $override = new IO::File("> $upstart_dir/$service.override");
            if (not defined($override))
            {
                $c->error("failed to open $upstart_dir/$service.override", \
                    'err');
                return 0;
            }    
            foreach my $line (<@FILE>) {
                print $override "$line\n";
            }    
            $override->close();
        }
        when (/^off$/) {
            my $override = new IO::File(">> $upstart_dir/$service.override");
            if (not defined($override))
            {
                $c->error("failed to open $upstart_dir/$service.override", \
                    'err');
                return 0;
            }
            print $override "manual\n";
            $override->close();
        }
        default {
            $c->error("unknown status of $status", 'err');
            return 0;
        }
    }
    return 1;
}

sub is_service_enabled
{
    my ($c, $service, $type) = @_;

    use feature "switch";
    given ($type) {
        when (/^upstart$/) {
            return is_service_enabled_upstart($c, $service);
        }
        when (/^init$/) {
            return is_service_enabled_init($c, $service);
        }
    }
}

sub is_service_enabled_upstart
{
    my ($c, $service) = @_;
    my $upstart_dir = $c->getval('tweakstartup_upstart_dir') || qq(/etc/init);

    return 'on' unless ( -e "$upstart_dir/$service.override" );

    my $override = new IO::File("< $upstart_dir/$service.override");

    my $rval = 'on';
    if (not defined($override))
    {
        # Assume its enabled
        return 'on';
    }

    while (<$override>)
    {
        if (m/^manual$/)
        {
            $rval = 'off';
            last;
        }
    }

    $override->close();

    return $rval;
}

sub is_service_enabled_init
{
    my ($c, $service) = @_;

    my $os = $c->getval('c_os_vendor');
    my @result = simple_exec(merge_error => 1,
                             inert       => 1,
                             exec        => 'chkconfig',
                             args        => [ "--list",  $service ],
                             c           => $c);
   
    my @service_status = split /\s+/, join("", @result);

    if ($#service_status > 2) {
        # On RHEL/CentOS we care about runlevels 3+
        if (($os eq 'redhatenterpriseserver') or ($os eq 'centos'))
        {
            # On RHEL/CentOS we care about runlevels 3+
            splice @service_status, 0, 4;
        }
        elsif ($os eq 'ubuntu')
        {
            # On Ubuntu we care about runlevels 2+
            splice @service_status, 0, 3;
        }    
        return 'on' if grep /\d+:on/, @service_status;
    } else {
        # xinetd output
        return 'on' if $service_status[1] eq 'on';
    }
    return 'off';
}

1;
