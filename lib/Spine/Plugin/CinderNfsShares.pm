# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# Copyright 2013 Metacloud, Inc
# All Rights Reserved
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use strict;

package Spine::Plugin::CinderNfsShares;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use Spine::Util qw(simple_exec);
use Quota;

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d", q$Revision: 240 $ =~ /(\d+)/);
$DESCRIPTION = "Plugin to create cinder volume nfs share files";

$MODULE = { author => 'cfb@metacloud.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { EMIT => [ { name => 'cinder_nfs_shares',
                                   code => \&cinder_nfs_shares } ]
                     },
          };


use Spine::Util qw(mkdir_p safe_copy uid_conv gid_conv touch);

sub cinder_nfs_shares {
    my $c = shift;
    my $enabled = $c->getval('enable_cinder_volume_nfs') || 0;
    my $tmpdir = $c->getval('c_tmpdir');
    my $default_backend = $c->getval('openstack-cinder-volume-default-nfs_backend') || qq(nfs-default);
    my $share_path = $c->getval('openstack-cinder-volume-default-nfs_shares_path') || qq(/etc/cinder/nfs);
    my $ugid = $c->getval('openstack-cinder-volume-default-nfs_share_path_ugid') || qq(0:0);
    my $mode = $c->getval('openstack-cinder-volume-default-nfs_share_path_mode') || qq(0755);

    # If cinder-volume NFS driver isn't enable we just return.
    if (! $enabled) {
        $c->print(2, "skipping, cinder-nfs volume driver not enabled");
        return PLUGIN_SUCCESS;
    }

    unless (-d $tmpdir) {
        $c->error("temp directory [$tmpdir] does not exist", 'crit');
        return PLUGIN_FATAL;
    }

    # Make sure our share path exists
    (my $uid, my $gid) = split( /:/, $ugid);
    my $path = "$tmpdir/$share_path";
    if (! -d $path) {
        mkdir_p($path, oct($mode)) || return PLUGIN_FATAL;
        chown $uid, $gid, $path;
    }

    # Loop through each share and generate files.
    for my $key ('nova-volume-nfs_shares', 'cinder-volume-nfs_shares') {
        if (exists $c->{"$key"}) {
            for my $element (@{$c->getvals("$key")}) {
                my $backend = $default_backend;
                my $nfs_path = $element;
                if ($element =~ m/.*\|.*/) {
                    ($backend, $nfs_path) = split( /\|/, $element);
                }
                open (OUTFILE, ">>$path/$backend.conf");
                print OUTFILE "$nfs_path\n";
                close (OUTFILE);
                chown $uid, $gid, "$path/$backend.conf";
            }
        }
    }
}
1;
