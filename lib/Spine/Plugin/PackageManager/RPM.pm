
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

package Spine::Plugin::PackageManager::RPM;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use Spine::RPM;

our ( $VERSION, $DESCRIPTION, $MODULE );
my $CPATH;

$VERSION     = sprintf( "%d.%02d", q$Revision: 22 $ =~ /(\d+)\.(\d+)/ );
$DESCRIPTION = "PackageManager::RPM, RPM implementation";

$MODULE = {
    author      => 'osscode@ticketmaster.com',
    description => $DESCRIPTION,
    version     => $VERSION,
    hooks       => {
        "PKGMGR/ResolveInstalled/RPM" => [ 
            { name => 'RPM ResolveInstaledDeps',
              code => \&_resolve_deps } ],
        "PKGMGR/Lookup/RPM" => [
            { name => 'RPM ResolveInstaled',
              code => \&get_installed } ],

    },

};

sub _resolve_deps {
    my ( $c, $instance_conf, undef ) = @_;

    my $s = $instance_conf->{store};
    my @packages = $s->find_node( 'install', 'name' );
    my @remove = Spine::RPM->new->keep( $s->get_node_val( 'name', @packages ) );
    my %remove = map { $_ => undef } @remove;

    my @packages = $s->find_node( 'installed', 'name' );
    foreach ( $s->get_node_val( 'name', @packages ) ) {
        unless ( exists $remove{$_} ) {
            $s->create_node( 'deps', 'name', $_ );
        }
    }

    return PLUGIN_FINAL;
}

sub get_installed {
    my ( $c, $instance_conf, undef ) = @_;

    my $s = $instance_conf->{store};

    my $node;
    foreach ( split( /\n/, `rpm -qa  --qf "%{NAME}\t%{VERSION}\t%{ARCH}\n"` ) )
    {
        my ( $name, $version, $arch ) = split( /\t/, $_ );

        $s->create_node( 'installed', 'name', $name, 'arch', $arch, 'version',
                         $version );
    }

    return PLUGIN_FINAL;
}

1;
