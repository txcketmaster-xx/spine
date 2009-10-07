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

$VERSION     = sprintf( "%d.%02d", q$Revision$ =~ /(\d+)\.(\d+)/ );
$DESCRIPTION = "Parselet::Basic, processes Basic keys";

$MODULE = {
    author      => 'osscode@ticketmaster.com',
    description => $DESCRIPTION,
    version     => $VERSION,
    hooks       => {
        'PARSE/key' => [
            {  name => "Basic_Init",
               code => \&_init_key,
               provides => [ 'retrieve', 'basic_init' ], },
            {  name => "Basic_Parse_Lines",
               code => \&_preprocess,
               provides => [ 'preprocess', 'PARSE/key/line' ], },
            {  name => "Basic_Final",
               code => \&_parse_basic_key,
               # this does finalization
               provides => [ 'simple', 'basic_key' ], }, ], }, };

# preprocess keys that are scalars, scalar refs or filenames
sub _init_key {
    my ( $c, $data ) = @_;

    # Do we need to read a file?
    if ( exists $data->{source} && $data->{source} =~ m/^file:(.*)$/  
         && !defined $data->{obj} )
    {
        $data->{file} = $1;
        my $fh   = undef;
        my $file = $data->{file};
        unless ( -f $file ) {
            $file = catfile( $c->{c_croot}, $file );
            if ( -f $file ) {
                $data->{file} = $file;
            }
        }
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
        $data->{obj} = join('',  $fh->getlines());
        close($fh);

        # Is this a ref to a scalar
    } elsif ( ref( $data->{obj} ) eq "SCALAR" ) {
        $data->{obj} = ${$data->{obj}};
    }
    
    return PLUGIN_SUCCESS;
}

sub _preprocess {
    my ( $c, $data ) = @_;

    if (ref($data->{obj})) {
        return PLUGIN_SUCCESS;
    }

    my $registry = new Spine::Registry;

    my $lineno = 0;
    my $point  = $registry->get_hook_point("PARSE/key/line");
    my $buf = "";
    while ($data->{obj} =~ /([^\r\n]*[\r\n]*)/sog) {
        my $line = $1;
        $lineno++;
        
        my $rc = $point->run_hooks_until( PLUGIN_ERROR, $c, \$line,
                                          $lineno, $data );
        # This should never happen
        if ( $rc & PLUGIN_ERROR ) {
            $c->error( "Error parsing key line", 'crit' );
            return PLUGIN_ERROR;
        }
        $buf .= $line if defined $line;
    }
    $data->{obj} = $buf;
    return PLUGIN_SUCCESS;
}


# This gets called near the end, it will skip
# anything that has been turned into a ref
sub _parse_basic_key {
    my ( $c, $data ) = @_;

    # Skip refs, only scalars
    if ( ref( $data->{obj} ) ) {
        return PLUGIN_SUCCESS;
    }
#use Data::Dumper; print Dumper($data->{obj});


    # Ignore comments and blank lines.
    $data->{obj} =
      [ grep( !/^\s*(?:#.*)?$/, split( m/[\n\r]+/, $data->{obj} ) ) ];
    return PLUGIN_SUCCESS;
}

1;
