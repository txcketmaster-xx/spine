
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

package Spine::Plugin::PackageManager::ConfBasic;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ( $VERSION, $DESCRIPTION, $MODULE );
my $CPATH;

$VERSION     = sprintf( "%d.%02d", q$Revision: 22 $ =~ /(\d+)\.(\d+)/ );
$DESCRIPTION = "PackageManager::ConfBasic, basic config implementation";

$MODULE = { author      => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version     => $VERSION,
            hooks       => {
                       "PKGMGR/Config/ConfBasic" => [
                                                    { name => 'pkgmrg_config',
                                                      code => \&_process_config
                                                    } ], 
            }, 
};


# Parse the original packages type key (<PACKAGE>#<VERSION>.<ARCH>)
sub _process_config {
    my ( $c, $pic ) = @_;

    my $s = $pic->{store};

    my $key_name = 'packages';

    if ( $pic->{plugin_config}->{ConfBasic}->{'install-key'} ) {
        $key_name = $pic->{plugin_config}->{ConfBasic}->{'install-key'};
    }

    foreach ( @{ $c->getvals('packages') } ) {

        # This used to be the syntax passed to apt and still will be. Since
        # later config plugins will probably be complex keys we split it out
        # and leave it upto the APT/YUM/... implementation to work out how
        # to deal with the data in the store.
        m/^(.*?)(#.*)?(?:\.((?:(?:32|64)bit)|noarch))?$/;
        $s->create_node( 'install', 'name', $1, 'version', $2, 'arch', $3 );
    }

    return PLUGIN_FINAL;
}

1;
