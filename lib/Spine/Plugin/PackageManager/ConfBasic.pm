
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Skeleton.pm 22 2007-12-12 00:35:55Z phil@ipom.com $

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

package Spine::Plugin::PackageManager::ConfBasic;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);
my $CPATH;

$VERSION = sprintf("%d.%02d", q$Revision: 22 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "PackageManager::ConfBasic, basic config implementation";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { "PKGMGR/Config" => [ { name => 'install_packages',
                                              code => \&_process_config } ],
                     },
          };

our $PLUGNAME = 'basic';

sub _process_config {
    my ($c, $pic, $instance) = @_;

    # Are we to deal with this?
    unless ($pic->{package_config}->{implementer} eq $PLUGNAME) {
        return PLUGIN_SUCCESS;
    }

    my $s = $pic->{store};
    foreach (@{$c->getvals('packages')}) {
        $s->create_node('install', 'name', $_);
    }

    return PLUGIN_FINAL;
}

1;
