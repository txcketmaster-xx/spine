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

package Spine::Plugin::Overlay::Disk;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin :keys);
use File::Spec::Functions;
use Spine::Util qw(simple_exec do_rsync mkdir_p octal_conv uid_conv gid_conv);

our ( $VERSION, $DESCRIPTION, $MODULE, $DONTDELETE, $TMPDIR, @ENTRIES );

$VERSION     = sprintf( "%d", q$Revision$ =~ /(\d+)/ );
$DESCRIPTION = "Disk based overlays.";

$MODULE = { author      => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version     => $VERSION,
            hooks       => {
                       'PREPARE/Overlay/build' => [
                                                { name => 'build_disk_overlay',
                                                  code => \&build_disk_overlay }
                       ],
                       "PARSE/Overlay/load" => [
                                             { name => "load_descent_overlays",
                                               code => \&descent_overlays } ], }
          };

use Spine::Constants qw(:basic);

sub build_disk_overlay {
    my $c        = shift;
    my $item     = shift;
    
    my $resource = $item->{resource};

    # we only deal with file URIs    
    return PLUGIN_SUCCESS unless $resource->{uri_scheme} eq "file";

    # XXX: we don't actauly support host yet, so it will be ignored
    my $overlay = $resource->{uri_path};

    # does it start with a '/' if not then add in the croot as rsync gets upset
    # FIXME: use filespec absolute...
    unless ( $overlay =~ m%^/% ) {
        $overlay = catfile( $c->getval("c_croot"), $overlay );
    }

    my $target = catfile( $item->{tmpdir}, $item->{path} );

    # Deal with makeing sure '/' appears where needed and make sure the
    # src exists
    if ( -d $overlay ) {
        $overlay .= "/" unless ( $overlay =~ m%/^% );
        $target  .= "/" unless ( $target  =~ m%/^% );
    } elsif ( -f $overlay ) {
        if ( -d $target ) {
            $target .= "/" unless ( $target =~ m%/^% );
        }
    } else {
        $c->print( 3, "disk overlay ($item->{uri}) src does not exist" );
        return PLUGIN_SUCCESS;
    }

    $c->print( 3, "building disk overlay from $overlay to " . $target );
    unless ( do_rsync( Config   => $c,
                       Inert    => 1,
                       Source   => $overlay,
                       Target   => $target,
                       Excludes => $item->{excludes} ) )
    {
        return PLUGIN_FATAL;
    }

    return PLUGIN_FINAL;
}

sub descent_overlays {
    my ( $c, $branch ) = @_;

    # we only deal with file URIs
    return PLUGIN_SUCCESS unless $branch->{uri_scheme} eq "file";

    my $descend_item = $branch->{uri_path};

    # Note down any overlays related to this disk descend
    my @overlay_map = ('overlay:/');
    if ( exists $c->{'overlay_map'} ) {
        @overlay_map = @{ $c->getvals("overlay_map") };
    }

    my $default_path = $c->getval('c_croot');

    unless ( file_name_is_absolute($descend_item) ) {
        $descend_item = catfile( $default_path, $descend_item );
    }
    
    my $overlay_key = $c->getkey(SPINE_OVERLAY_KEY);
    unless ( defined $overlay_key ) {
        $c->error("Could not getkey (" . SPINE_OVERLAY_KEY . ")", 'crit');
        return PLUGIN_FATAL;
    }
    
    for my $element (@overlay_map) {
        my ( $overlay, $target ) = split( /:/, $element );
        $overlay = catfile( $descend_item, $overlay ) . "/";
        next unless ( -e $overlay );
        # Add the overlay to the overlays key
        $overlay_key->merge( { uri  => "file:$overlay",
                               bind => $target } );
    }

}

1;
