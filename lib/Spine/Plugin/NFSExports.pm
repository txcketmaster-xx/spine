# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: NFSExports.pm 163 2008-12-11 19:23:06Z cfb $

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

package Spine::Plugin::NFSExports;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use Spine::Util qw(simple_exec);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d", q$Revision: 163 $ =~ /(\d+)/);
$DESCRIPTION = "Uses the showmount command to present a list of available NFS mounts";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'PARSE/complete' => [ { name => 'nfs__exports',
                                               code => \&get_exports } ]
                     }
          };


sub get_exports
{
    my $c = shift;
    my $nfs_servers = $c->getvals('nfs_servers');
    my @exports;
    my $DEBUG = $c->getval('nfs_exports_plugin_debug');

    if ($DEBUG)
    {
	$c->cprint('NFS Servers are: ', join(' ', @{$nfs_servers}));
    }

    foreach my $server (@{$nfs_servers})
    {
        if ($DEBUG)
        {
            $c->cprint("Going through mounts on server $server");
        }

        my @showmount_res = simple_exec(inert => 1,
                                        exec  => 'showmount',
                                        args  => "--no-headers -e $server",
                                        c     => $c);


        for (@showmount_res)
        {
            if ($DEBUG > 2)
            {
                $c->cprint("    Processing output line: $_");
            }
            
            ( my $mount, my $perms ) = split;
            push @exports,"$server:$mount:$perms";
        }
    }

    $c->set('nfs_exports', \@exports);
    return PLUGIN_SUCCESS;
}


1;
