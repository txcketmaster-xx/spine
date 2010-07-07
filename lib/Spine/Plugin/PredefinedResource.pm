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

package Spine::Plugin::PredefinedResource;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin :basic :keys);
use Spine::Registry;

our ( $VERSION, $DESCRIPTION, $MODULE, $DONTDELETE, $TMPDIR, @ENTRIES );

$VERSION = sprintf( "%d", q$Revision: 318 $ =~ /(\d+)/ );

$DESCRIPTION = "Parselet::Basic, processes Basic keys";

$MODULE = { author      => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version     => $VERSION,
            hooks       => {
                       "INIT" => [ { name => 'register_pdr_key',
                                     code => \&init } ], }, };

sub init {
    my $c = shift;
    $c->set( SPINE_PDR_KEY, new Spine::Plugin::PredefinedResource::Key() );
    return PLUGIN_SUCCESS;
}

1;

# The spine key interface to add predefined resources
package Spine::Plugin::PredefinedResource::Key;
use base qw(Spine::Key);
use Spine::Resource qw(resolve_resource add_pdr);

sub set {
    my ( $self, $item ) = @_;
    $self->merge($item);
}

sub get_ref {
    return \$Spine::Resource::PDRS;
}

sub merge {
    my ( $self, $item ) = @_;

    return undef
      unless ( ref($item) && exists $item->{name} && exists $item->{resource} );
    
    return add_pdr( $item->{name}, $item->{resource} );

}

1;
