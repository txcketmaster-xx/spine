# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: RestartServices.pm 286 2009-11-11 22:25:21Z rkhardalian $

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

$VERSION = sprintf("%d", q$Revision: 286 $ =~ /(\d+)/);
$DESCRIPTION = "Restart services listed in the \"startup\" key";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { APPLY => [ { name => 'restart_services',
                                    code => \&restart_services } ] },
          };


use File::stat;
use Spine::Util qw(exec_initscript exec_command);
use Fcntl;
use File::Spec::Functions;
# See Overlay.pm for the BEGIN block to set AnyDBM's load preferences
use AnyDBM_File;

my $DRYRUN;

sub restart_services
{
    my $c = shift;
    my $rval = 0;
    my %rshash;

    my $start_time = $c->getval('c_start_time');
    my $startup = $c->getvals('tweakstartup_startup');
    my $startup_ignore = $c->getvals('tweakstartup_ignore');
    my $restart_deps = $c->getvals('restart_deps');
    my $tmpdir = $c->getval('c_tmpdir');
    my $dbfile = catfile($c->{c_config}->{spine}->{StateDir},
                        'restart_deps.db');

    $DRYRUN = $c->getval('c_dryrun');

    tie my %entries, 'AnyDBM_File', $dbfile, O_RDWR, 0600
        unless $DRYRUN;

    # No restart dependencies?  Return a successful run
    unless ($restart_deps)
    {
        $c->print(3, "No dependencies defined.  Skipping.");
        undef %entries;
        untie %entries;
        return PLUGIN_SUCCESS;
    }

    foreach my $entry (@{$restart_deps})
    {
        my ($command, $key, $service);
        my @file_dependancies;
        my @fields = split(/:/, $entry);

        # Backwards compatibility with service-only restarts.
        # We'll assume that any restart dep which begins with
        # a "/" in field1 references a command rather than service.

        if ($fields[0] =~ /\//)
        {
            $service = "";
            $command = shift @fields;
        }
        else
        {
            $service = shift @fields;
            $command = shift @fields;
            next unless (grep(/^${service}$/i, @{$startup}) or
                             grep(/^${service}$/i, @{$startup_ignore}));
        }

        if ($DRYRUN)
        {
            @file_dependancies = map { glob($tmpdir . $_) } @fields;
        }
        else
        {
            @file_dependancies = map { glob($_) } @fields;
        }

        $key = join(':', $service, $command);
        push(@{$rshash{$key}}, @file_dependancies);
    }

    foreach my $key (sort keys %rshash)
    {
        my $take_action = 0;
        my ($service, $command) = split(/:/, $key);

        foreach my $file ( @{$rshash{$key}} )
        {
            next unless (-f "$file");
            if (exists $entries{$file}
                or stat($file)->mtime >= $start_time)
            {
                $take_action = 1;
                delete $entries{$file};
                last;
            }
        }

        if ($take_action)
        {
            if ($service)
            {
                $c->cprint("restarting service $service", 2);
                unless ($DRYRUN)
                {
                    exec_initscript($c, $service, $command, 1, 0)
                        or $rval++;
                }
            }
            else
            {
                $c->cprint("executing command $command", 2);
                unless ($DRYRUN)
                {
                    exec_command($c, $command, 1)
                        or $rval++;
                }
            }
            utime(time, time, @{$rshash{$key}});
        }
    }

    # ran the gauntlet, any entries in the %entries hash are
    # superfluous and can be removed
    undef %entries;
    untie %entries;

    return $rval ? PLUGIN_ERROR : PLUGIN_SUCCESS;
}


1;
