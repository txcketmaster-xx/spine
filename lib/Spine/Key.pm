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
package Spine::Key;
use Scalar::Util qw(blessed);


# create the key and optinally set the data
sub new {
    my $klass = shift;
    my $data  = shift;

    my $self = { metadata => {}, };

    $self = bless $self, $klass;

    $self->set($data) if defined $data;
    return $self;
}

# get metadata by name or return undef
sub metadata {
    my ( $self, $name ) = @_;

    return
      exists $self->{metadata}->{$name} ? $self->{metadata}->{$name} : undef;
}

# set metadata by name
sub metadata_set {
    my ( $self, %pairs ) = @_;

    while ( my ( $key, $value ) = each %pairs ) {
        $self->{metadata}->{$key} = $value;
    }
}

# remove metadata by name
sub metadata_remove {
    my ( $self, $name ) = @_;

    if ( exists $self->{metadata}->{$name} ) {
        return delete $self->{metadata}->{$name};
    }
    return undef;
}

# get contained data
sub get {
    return ${$_[0]->get_ref()};
}

# used by Spine::Data for getval calls
# this is here because other keys might want to override
sub data_getref {
    $_[0]->get_ref()
}

# get a ref to the data, useful if data is a huge scalar to save memory
sub get_ref {
    my $self = shift;
    return exists $self->{data} ? \$self->{data} : \undef;
}

# This allows a key to decide what data to pass out into another keys
# replace method, it's up to the caller to place the data within
# the other key by calling replace
sub replace_helper {
    my ($self, $dst_key) = @_;
    return $self->get();
}

# basically the same as set but checks if the src is a obj
sub replace {
    my $self = shift;
    my $data = shift;
    
    if ($self->is_related($data)) {
        $data = $data->replace_helper($self);
    }
    
    $self->set($data);
}

# set the data
sub set {
    $_[0]->{data} = $_[1];
}

# is there any data in this key
sub does_exist {
    return exists $_[0]->{data};
}

# clear the key
# If the user really want's a blank key
# then they should create a new one since metadata
# is not cleared
sub clear {
    my $self = shift;
    delete $self->{data} if exists $self->{data};
    return undef;
}

# this is called when this key is being merged into another
# it's just here so it can be overriden
sub merge_helper {
    my ($self, $dst_key) = @_;
    return $self->get();
}


# merge some data into the key. If the incomming data is a Spine::Key it will
# call merge_helper from that key to get it's data
sub merge {
    my ( $self, $data, $opts ) = @_;

    # if the src is a Spine::Key then we call it's helper
    if ($self->is_related($data)) {
        $data = $data->merge_helper($self);
    }

    # No point merging if there is nothing to merge into
    return $self->set($data) unless exists( $self->{data} );

    my $rtype = ref( $self->{data} );
    my $dtype = ref($data);

    return undef unless ($rtype);
    return undef unless ( $rtype eq $dtype );

    if ( $rtype eq "HASH" ) {
        if ( exists $opts->{reverse} ) {
            $self->{data} = { %{ $self->{data} }, %{$data} };
        } else {
            $self->{data} = { %{$data}, %{ $self->{data} } };
        }
        return $self->{data};
    }

    if ( $rtype eq "ARRAY" ) {
        if ( exists $opts->{reverse} ) {
            unshift @{ $self->{data} }, @{$data};
        } else {
            push @{ $self->{data} }, @{$data};
        }

        #### TODO: write unique func
        #@{$data->{obj}} = uniqu(@{$data->{obj}}) if exists $opts->{uniqu};
        return $self->{data};
    }

    # we should never have been called
    # XXX: should we blank out data?
    return undef;
}

# keep, the oposite to remove
sub keep {
    my ( $self, $opts ) = @_;

    return undef unless exists $self->{data};

    my $rtype = ref( $self->{data} );

    my $newdata;
    if ( $rtype eq "ARRAY" ) {
        my $newdata;
        $newdata = [ grep /$opts/, @{ $self->{data} } ]
          if ( $rtype eq "ARRAY" );
        $self->set($newdata);
        return $self->{data};
    }

    foreach ( keys %{ $self->{data} } ) {
        delete $self->{data}->{$_} unless $_ =~ m/$opts/;
    }
    return $self->{data};
}

# remove items, take an re in this implementation
sub remove {
    my ( $self, $re ) = @_;

    return undef unless exists $self->{data};

    my $rtype = ref( $self->{data} );

    if ( $rtype eq "ARRAY" ) {
        my $newdata;
        $newdata = [ grep !/$re/, @{ $self->{data} } ];
        $self->set($newdata);
        return $self->{data};
    } elsif ( $rtype eq "HASH" ) {
        foreach ( keys %{ $self->{data} } ) {
            delete $self->{data}->{$_} if $_ =~ m/$re/;
        }
    }
    return $self->{data};
}

# is the last option passed in a Spine::Key?
sub is_related {
    return (defined $_[-1] && blessed $_[-1] && $_[-1]->isa("Spine::Key"));
}

# this gets called to work out if new data should be merged
# or the current data replaced (see operators)
sub merge_default {
    my $self         = shift;
    my $to_merge_ref = shift;

    if (    exists $self->{data}
         && ref( $self->{data} ) eq 'ARRAY'
         && ref($$to_merge_ref)  eq 'ARRAY' )
    {
        return 1;
    } else {
        return 0;
    }
}

1;
