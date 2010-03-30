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

package Spine::Plugin::Overlay::HTTP;
use base qw(Spine::Plugin);
use File::Spec::Functions;
use Spine::Constants qw(:plugin);
use Spine::Util qw(create_exec mkdir_p);

our ( $VERSION, $DESCRIPTION, $MODULE, $DONTDELETE, $TMPDIR, @ENTRIES );

$VERSION     = sprintf( "%d", q$Revision$ =~ /(\d+)/ );
$DESCRIPTION = "HTTP based overlays.";

$MODULE = { author      => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version     => $VERSION,
            hooks       => {
                       'PREPARE/Overlay/build' => [
                                                { name => 'build_http_overlay',
                                                  code => \&build_http_overlay }
                       ], } };

use Spine::Constants qw(:basic);

#TODO: might be good to re-implement using LWP
#TODO: implement excludes (probabley after LWP)
sub build_http_overlay {
    my $c        = shift;
    my $settings = shift;

    # we only deal with http URIs
    return PLUGIN_SUCCESS unless $settings->{uri} =~ m/^https?:/;

    my ( $proto, $host, $location ) =
      ( $settings->{uri} =~ m%([^:]*)://([^/]*)/(.*)% );

    # because wget needs to know how much to strip of the url we need
    # to be able to count the parts
    # FIXME: should use a file spec function....
    my @loc_parts = split( "/", $location );

    $c->print( 3, "building http based overlay from " . $settings->{uri} );

    # create the path within our tempory location
    mkdir_p( catfile( $settings->{tmpdir}, $settings->{path} ) );

    # create the wget exec object
    my $wget = create_exec(
                    exec => "wget",
                    args => [ "-N",
                              "--no-parent",
                              "-r",
                              "-nH",
                              "--progress=dot",
                              "--cut-dirs",
                              scalar(@loc_parts),
                              "-P",
                              catfile( $settings->{tmpdir}, $settings->{path} ),
                              $settings->{uri} ],
                    c           => $c,
                    merge_error => 1,
                    inert       => 1 );

    # this will normally be related to wget being missing, because we didn't
    # select "quiet" when we created the object the error should have been
    # printed.
    unless ( $wget->ready() ) {
        return PLUGIN_ERROR;
    }

    # GO
    $wget->start();

    my ( $src, $dst );
    my @remove;
    my $uri = $settings->{uri};

    while ( my $line = $wget->readline() ) {
        chomp($line);
        $c->cprint( $line, 5 );

        if ( $line =~ m%^-.*$uri(.*)$% ) {
            $src = $1;
            # src can be null if it's the first request
            unless ( $src ) {
                if ( $uri =~ m%/$% ) {
                    # The uri was a dir
                    $src = "/";
                } else {

                    # the uri was direct to a file
                    # XXX: this means it's important to have a traling '/' in
                    #      URIs
                    $src = $uri;
                    $src =~ s%.*/%%;
                }
            } else {
                $src = $1;
            }
        } elsif ( $line =~ m/^saving to:\s+.([^`']+).\s*$/i ) {
            $dst = $1;

            # If the file is index.html and the src was a directory
            # then we need to clean out the index file. If however
            # there really was an index.html file we want to keep it
            if ( $dst =~ m/index\.html$/ && $src =~ m%/$% ) {
                push @remove, $dst;
                $c->cprint( "Getting directory ($src)", 3 );
            } else {
                $c->cprint( "Getting ($src) as ($dst)", 3 );
            }
        }
    }
    
    # Just in case...
    $wget->isrunning() || $wget->wait();

    foreach (@remove) {
        $c->cprint("Removing index file ($_)", 3);
        unlink ($_);
    }

    # Did it exit with an error?
    return PLUGIN_ERROR unless ( $wget->exitstatus() == 0 );

    return PLUGIN_SUCCESS;
}

1;
