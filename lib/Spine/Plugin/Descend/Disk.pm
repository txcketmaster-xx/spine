# -*- Mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
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

package Spine::Plugin::Descend::Disk;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin :keys);
use Spine::Data;
use Spine::Key::Blank;
use Spine::Plugin::DescendOrder;
use Spine::Plugin::Interpolate;

our ( $VERSION, $DESCRIPTION, $MODULE, $CURRENT_DEPTH, $MAX_NESTING_DEPTH );

$VERSION     = sprintf( "%d", q$Revision$ =~ /(\d+)/ );
$DESCRIPTION = "process disk based includes/branches";

$MODULE = { author      => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version     => $VERSION,
            hooks       => {
                       'DISCOVERY/Descend/resolve' => [
                                              { name => 'resolve_disk_descend',
                                                code => \&resolve,
                                                provides => ["disk_descend"] }
                       ],
                       "DISCOVERY/populate" => [
                                               { name => 'reserve_include_key',
                                                 code => \&reserve_key, }, ], }
          };
use File::Spec::Functions;

sub resolve {
    my ( $c, $key, $item ) = @_;

    # deal with legacy dirs that do not have proper uris
    # TODO: depreciate this once everyone uses uri's, should probably move to
    # a separate fixup plugin!
    unless ( $item->{uri} =~ m%[^:]+://% ) {
        # if the item has succedes we assume that it's
        # a config_group since it has a parent branch
        if ( exists $item->{dependencies}->{succedes} ) {
            $item->{uri} = "file:///"
              . catdir( $c->getval_last('include_dir'), $item->{uri} );
        } else {
            $item->{uri} = "file:///$item->{uri}";
        }
    }

    # we only deal with file URIs
    return PLUGIN_SUCCESS unless substr( $item->{uri}, 0, 5 ) eq "file:";

    my ( undef, $descend_item ) = ( $item->{uri} =~ m%file://([^/]*)/(.*)% );
    my $croot = $c->getval('c_croot');

    unless ( $descend_item =~ m#^/# ) {
        $descend_item = catfile( $croot, $descend_item );
    }

    # TODO: this isn't very nice. Taken from the old code. Should be based on a
    #       key. Also the first include is better then the second.
    foreach my $path (qw(include config/include)) {
        my $inc_file = catfile( $descend_item, $path );

        # An empty set is perfectly acceptable
        unless ( -f $inc_file ) {
            next;
        }

        # add in the item to $key, noteing that it succedes it's parent
        # by passing a merge parameter
        # XXX: might be worth moving this to a function within the DescendOrder
        #       plugin to hide the implementation...
        $c->read_key( {  uri         => "file:///$inc_file",
                         description => "file:///$inc_file descend key",
                         operators   => [ [ 'merge', $item->{name} ] ], },
                      $c->getkey(SPINE_HIERARCHY_KEY) );
    }
}

# Since the include keys get processed from the same location as config keys
# the resulting data seen by the user in printdata makes little sense. Actauly
# the data within include is pointless. So lets make sure it stays blank no
# matter what!
sub reserve_key {
    my $c = shift;
    $c->set( "include", new Spine::Key::Blank );
    return PLUGIN_SUCCESS;
}

1;
