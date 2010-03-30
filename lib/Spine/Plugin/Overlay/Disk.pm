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
                       "PREPARE/Overlay/load" => [
                                             { name => "load_descent_overlays",
                                               code => \&descent_overlays } ], }
          };

use Spine::Constants qw(:basic);

sub build_disk_overlay {
    my $c        = shift;
    my $settings = shift;
 
    # we only deal with file URIs
    return PLUGIN_SUCCESS unless substr( $settings->{uri}, 0, 5 ) eq "file:";

    # XXX: we don't actauly support host yet, so it will be ignored
    my ( $host, $overlay ) = ( $settings->{uri} =~ m%file://([^/]*)/(.*)% );

    # does it start with a '/' if not then add in the croot as rsync gets upset
    # FIXME: use filespec absolute...
    unless ( $overlay =~ m%^/% ) {
        $overlay = catfile( $c->getval("c_croot"), $overlay );
    }

    my $target = catfile( $settings->{tmpdir}, $settings->{path} );

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
        $c->print( 3, "disk overlay ($settings->{uri}) src does not exist" );
        return PLUGIN_SUCCESS;
    }

    $c->print( 3, "building disk overlay from $overlay to " . $target );
    unless ( do_rsync( Config   => $c,
                       Inert    => 1,
                       Source   => $overlay,
                       Target   => $target,
                       Excludes => $settings->{excludes} ) )
    {
        return PLUGIN_FATAL;
    }

    return PLUGIN_FINAL;
}

sub descent_overlays {
    my ( $c, $branch ) = @_;

    # we only deal with file URIs
    return PLUGIN_SUCCESS unless substr( $branch->{uri}, 0, 5 ) eq "file:";

    my ( undef, $descend_item ) = ( $branch->{uri} =~ m%file://([^/]*)/(.*)% );

    # Note down any overlays related to this disk descend
    my @overlay_map = ('overlay:/');
    if ( exists $c->{'overlay_map'} ) {
        @overlay_map = @{ $c->getvals("overlay_map") };
    }

    my $croot = $c->getval('c_croot');

    if ( $descend_item =~ m#^/# ) {
        $descend_item = catfile( $croot, $descend_item );
    }

    for my $element (@overlay_map) {
        my ( $overlay, $target ) = split( /:/, $element );
        $overlay = "${descend_item}/${overlay}/";

        unless ( file_name_is_absolute($overlay) ) {
            $overlay = catfile( $croot, $overlay );
            $overlay .= '/';    # catfile() removes trailing slashes
        }

        # Add the overlay to the overlays key
        $c->getkey(SPINE_OVERLAY_KEY)->merge( { uri  => "file:///$overlay",
                                         bind => $target } );
    }

}

1;
