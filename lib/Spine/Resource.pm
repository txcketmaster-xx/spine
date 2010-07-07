# -*- Mode: perl; cperl-continued-brace-offset: -4; cperl-indent-level: 4; indent-tabs-mode: nil; -*-
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

package Spine::Resource;
use base qw(Exporter);
use URI::Split qw(uri_split uri_join);

our $VERSION = sprintf( "%d", q$Revision: 313 $ =~ /(\d+)/ );

our @EXPORT_OK = qw(resolve_resource add_pdr);

# can be set to a hash of standard pre-defined resources
our $PDRS = {  };

# This will take a resource hash and make sure it's valid
# and optinally resolve it from pre-defined resources
sub resolve_resource {
    my $resource;

    # allow the hash to be passed as array args
    if ( scalar(@_) > 1 ) {

        # if we do not have an even number we are
        # unable to convert to a hash ref
        unless ( scalar(@_) % 2 ) {
            $resource = {@_};
        } else {
            return undef;
        }
    } else {
        $resource = shift;
    }

    return undef unless defined $resource;

    # we assume a scalar is just the uri by it's self
    unless ( ref($resource) ) {
        $resource = { uri => $resource };
    }

    unless ( exists $resource->{uri} ) {

        # we use the name as the uri if none was given
        if ( exists $resource->{name} ) {
            $resource->{uri} = $resource->{name};
        } else {

            # if there is no uri then we are in trouble
            return undef;
        }
    }

    my %uri_parts;

    (  $uri_parts{scheme}, $uri_parts{authority}, $uri_parts{path},
       $uri_parts{query},  $uri_parts{fragment} )
      = uri_split( $resource->{uri} );

    # is this a scheme that represents a predefined resource
    if ( defined $uri_parts{scheme}
         && $uri_parts{scheme} =~ m/^pdr$/i )
    {

        # we need a path to lookup a pdr and to
        # check if there is a PDR for this path
        unless ( defined $uri_parts{path}
                 && exists $PDRS->{ $uri_parts{path} } )
        {
            return undef;
        }

        # merge in the master resource data
        my $master_resource = $PDRS->{ $uri_parts{path} };
        foreach ( keys %$master_resource ) {
            $resource->{$_} = $master_resource->{$_};
        }

        # if there was a fragment then we put this at the end of the uri
        if ( defined $uri_parts{fragment} ) {
            $resource->{uri} .= $uri_parts{fragment};

             # reprocess the new uri (just in case it's changed due to fragment)
              ( $uri_parts{scheme}, $uri_parts{authority},
                $uri_parts{path},   $uri_parts{query},
                $uri_parts{fragment} )
              = uri_split( $resource->{uri} );
        }
    }
    # save in all the uri parts
    foreach ( keys %uri_parts ) {
        $resource->{ "uri_" . $_ } = $uri_parts{$_};
    }

    # XXX: fixup to put file inplace if no uri_scheme is defined but a path is
    #      the user should try not to use paths without a uri_scheme for this reason
    # TODO: make the default uri_scheme and other data more configurable. i.e
    #       allow defautls to be passed in to resolve or even rules????
    if ( !defined $resource->{uri_scheme} && defined $resource->{uri_path} ) {
        $resource->{uri_scheme} = "file";
    }

    # we always want a name
    unless ( exists $resource->{name} ) {
        $resource->{name} = $resource->{uri};
    }
    $resource->{uri} = uri_join( $resource->{uri_scheme},
                                 $resource->{uri_authority},
                                 $resource->{uri_path},
                                 $resource->{uri_query},
                                 $resource->{uri_fragment} );

    return $resource;
}

sub add_pdr {
    my ( $name, $item ) = @_;

    $Spine::Resource::PDRS->{$name} = $item;
}

1;
