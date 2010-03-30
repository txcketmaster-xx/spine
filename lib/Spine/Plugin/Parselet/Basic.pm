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

package Spine::Plugin::Parselet::Basic;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use File::Spec::Functions;
use Spine::Registry;

our ( $VERSION, $DESCRIPTION, $MODULE );
my $CPATH;

$VERSION     = sprintf( "%d", q$Revision$ =~ /(\d+)/ );
$DESCRIPTION = "Parselet::Basic, processes Basic keys";

$MODULE = {
    author      => 'osscode@ticketmaster.com',
    description => $DESCRIPTION,
    version     => $VERSION,
    hooks       => {
        'PARSE/key' => [
            {  name     => "Basic_Init",
               code     => \&_init_key,
               provides => [ 'retrieve', 'basic_init' ], },
            {  name     => "Basic_Parse_Lines",
               code     => \&_preprocess,
               provides => [ 'preprocess', 'PARSE/key/line' ], },
            {  name => "Basic_Final",
               code => \&_parse_basic_key,

               # this does finalization
               provides => [ 'simple', 'basic_key' ], }, ], }, };

# preprocess keys that are scalars, scalar refs or filenames
sub _init_key {
    my ( $c, $obj ) = @_;

    # Do we need to read a file?
    my $source = $obj->metadata("uri");
    if (    $source
         && $source =~ m%^file://[^/]*/(.*)$%
         && !$obj->does_exist() )
    {
        my $file = $1;
        my $fh   = undef;

        unless ( -f $file ) {
            $file = catfile( $c->{c_croot}, $file );
        }

        $obj->metadata_set( 'file', $file );
        unless ( -r $file ) {
            $c->error( "Can't read file \"$file\"", 'crit' );
            return PLUGIN_ERROR;
        }
        $fh = new IO::File("<$file");
        unless ( defined($fh) ) {
            $c->error( "Failed to open \"$file\": $!", 'crit' );
            return PLUGIN_ERROR;
        }
        $c->print( 4, "reading key $file" );

        # Trun the file into an array
        $obj->set( join( '', $fh->getlines() ) );
        close($fh);
    }

    # make sure there is always a description
    unless ( defined $obj->metadata("description") ) {
        $obj->metadata_set( "description", $source );
    }

    return PLUGIN_SUCCESS;
}

# If we have a sclar then we allow plugins to process each line
sub _preprocess {
    my ( $c, $obj ) = @_;

    if ( ref( $obj->get() ) ) {
        return PLUGIN_SUCCESS;
    }

    my $registry = new Spine::Registry;

    my $lineno = 0;
    my $point  = $registry->get_hook_point("PARSE/key/line");
    my $buf    = "";
    my $data   = $obj->get();
    while ( $data =~ /([^\r\n]*[\r\n]*)/sg ) {
        my $line = $1;
        $lineno++;

        my $rc =
          $point->run_hooks_until( PLUGIN_ERROR, $c, \$line, $lineno, $obj );

        # This should never happen
        if ( $rc & PLUGIN_ERROR ) {
            $c->error( "Error parsing key line", 'crit' );
            return PLUGIN_ERROR;
        }
        $buf .= $line if defined $line;
    }
    $obj->set($buf);
    return PLUGIN_SUCCESS;
}

# This gets called near the end, it will skip
# anything that has been turned into a ref
sub _parse_basic_key {
    my ( $c, $obj ) = @_;

    # Skip refs, only scalars
    if ( $obj->does_exist() && ref( $obj->get() ) ) {
        return PLUGIN_SUCCESS;
    }

    # Ignore comments and blank lines.
    $obj->set( [ grep( !/^\s*(?:#.*)?$/, split( m/[\n\r]+/, $obj->get() ) ) ] );
    return PLUGIN_SUCCESS;
}

1;
