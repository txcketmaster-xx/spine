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
use File::Spec::Functions;

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
                       "INIT" => [ { name => 'reserve_include_key',
                                     code => \&reserve_key, }, ], } };

sub resolve {
    my ( $c, $key, $item ) = @_;

    # we only deal with file URIs
    return PLUGIN_SUCCESS unless $item->{uri_scheme} eq "file";

    my $descend_item = $item->{uri_path};

    # FIXME: this implements the old config_groups stuff. Config groups should
    # pass in their whole path. Since this is a bit hack there are lots of
    # checks to make sure we really want to do this.
    #    Is the item a child of something?
    #    Did it have a pather without a uri_schema originally?
    #    Does it already have the include path int it?
    #    If it an absoule path?
    my $inc_path = $c->getval('include_dir');
    if (    exists $item->{dependencies}
         && $item->{name} !~ m/^file/
         && $descend_item !~ m/^$inc_path/
         && not file_name_is_absolute($descend_item) )
    {

        # we fixup both the path and uri because either could be
        # used later.
        $item->{uri_path} = catfile( $inc_path, $descend_item );
        $item->{uri} =~ s/$descend_item/$item->{uri_path}/;
        $descend_item = $item->{uri_path};
    }

    # TODO: this isn't very nice. Taken from the old code. Should be based on a
    #       key. Also the first include is better then the second.
    foreach my $path (qw(include config/include)) {

        # XXX: it is valid for descend_item to be blank if it's the CWD
        # cafile will add a slash to the start if we don't work around this.
        my $inc_file =
          ( length($descend_item) > 0 )
          ? catfile( $descend_item, $path )
          : $path;

        unless ( -f $inc_file || -f catfile( $c->{c_croot}, $inc_file ) ) {
            next;
        }

        # Read the key using the SPINE_HIERARCHY_KEY as the keyname so that
        # the results ket merged into the right place. The merge operator has
        # been given a parameter of the parent items so that dependancies get
        # stored.
        $c->read_key( { "operators" => [ [ "merge", $item ] ],
                        "uri"          => "file:$inc_file",
                        "keyname"      => SPINE_HIERARCHY_KEY,
                        "desctription" => "file:$inc_file descend key" } );
    }

    return PLUGIN_SUCCESS;
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
