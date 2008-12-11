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

package Spine::Plugin::RestartServices;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);
$DESCRIPTION = "Restart services listed in the \"startup\" key";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { APPLY => [ { name => 'restart_services',
                                    code => \&restart_services } ] },
          };


use File::stat;
use File::Touch;
use Spine::Util qw(exec_initscript exec_command);

my $DRYRUN;

sub restart_services
{
    my $c = shift;
    my $rval = 0;

    my $start_time = $c->getval('c_start_time');
    my $service_bin = $c->getval('service_bin');

    my $startup = $c->getvals('startup');
    my $restart_deps = $c->getvals('restart_deps');
    my $touch = File::Touch->new( no_create => 1 );
    my $tmpdir = $c->getval('c_tmpdir');

    $DRYRUN = $c->getval('c_dryrun');

    # No restart dependencies?  Return a successful run
    unless ($restart_deps)
    {
        $c->print(3, "No dependencies defined.  Skipping.");
        return PLUGIN_SUCCESS;
    }

    foreach my $entry (@{$restart_deps})
    {
	my ($service, $command, @file_dependancies);
        my $take_action = 0;
	my @fields = split(/:/, $entry);

	# Backwards compatibility with service-only restarts.
	# We'll assume that any restart dep which begins with
	# a "/" in field1 references a command rather than service.
	if ($fields[0] =~ /\//)
	{
	    $command = shift @fields;
        }
	else
	{
	    $service = shift @fields;
	    $command = shift @fields;	

	    next unless grep(/^${service}$/i, @{$startup});
	}

        if ($DRYRUN)
        {
            @file_dependancies = map { $tmpdir . $_ } @fields;
        }
        else
        {
            @file_dependancies = @fields;
        }

        foreach my $file ( @file_dependancies )
        {
            next unless (-f "$file");

            my $sb = stat($file);

            if ($sb->mtime >= $start_time)
            {
                $take_action = 1;
                last;
            }
        }

        if ($take_action)
        {
	    if ($service)
	    {
            	$c->cprint("restarting service $service", 2);
                exec_initscript($c, $service, $command, 1)
		    or $rval++;
 	    }
	    else
	    {
		$c->cprint("executing command $command", 2);
                exec_command($c, $command, 1)
		    or $rval++;
	    }
            $touch->touch(@file_dependancies);
        }
    }

    return $rval ? PLUGIN_ERROR : PLUGIN_SUCCESS;
}


1;
