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

package Spine::Plugin::DescendOrder;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin :keys);
use Spine::Data;
use Spine::Plugin::Interpolate;
use File::Spec::Functions;

our ( $VERSION, $DESCRIPTION, $MODULE, $ABORT, $CURRENT_DEPTH,
      $MAX_NESTING_DEPTH );

$VERSION = sprintf( "%d", q$Revision$ =~ /(\d+)/ );
$DESCRIPTION =
    "Determines which policies to apply based on the spine-config"
  . " directory hierarchy layout";

$MODULE = { author      => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version     => $VERSION,
            hooks       => {
                       "INIT" => [{ name => 'init_descend_order',
                                                  code => \&init,
                                                  provides => ["hierarchy_key"]
                                                }, ],
                       "DISCOVERY/policy-selection" => [
                                              { name => 'create_descend_order',
                                                code => \&create_order,
                                                provides => ["hierarchy"] }, ],
                     } };

use constant POLICY_KEY => "policy_hierarchy";

# put the special descend key in place
sub init {
    my ($c) = shift;

    $c->set( SPINE_HIERARCHY_KEY,
             new Spine::Plugin::DescendOrder::Key( \&resolve, [$c] ) );

    return PLUGIN_SUCCESS;
}

# load the policy key into the descend key
sub create_order {
    my ($c) = @_;

    my $descend_key = $c->getkey(SPINE_HIERARCHY_KEY);
    my $policy_key  = $c->getkey(POLICY_KEY);

    $descend_key->merge($policy_key);
    return PLUGIN_SUCCESS;
}

# This is a callback that gets used each time an item is added to the
# policy_hirearchy key
sub resolve {
    my ( $descend_key, $item, $c ) = @_;

    my $registry = new Spine::Registry;
    my $point    = $registry->get_hook_point('DISCOVERY/Descend/resolve');
    my ( undef, $rc, undef ) =
      $point->run_hooks_until( PLUGIN_STOP, $c, $descend_key, $item );
    return $rc;
}

# The following package is a special implementation of a spine key
# just for descend items
#
# You can think of set/get calls as a way to store standard data
# merge is magic and actaully puts the data into the chain as well as
# building dependancies between items
package Spine::Plugin::DescendOrder::Key;
use base qw(Spine::Key);
use Spine::Resource qw(resolve_resource);

sub new {
    my $klass = shift;

    # These are used to resolve items as they are added
    # so we expand a descend item when added
    my $add_cb   = shift;
    my $add_args = shift;

    my $chain = new Spine::Chain( merge_deps     => 1,
                                  remove_orphans => 1 );

    my $self = Spine::Key->new();

    $self = bless( $self, $klass );

    # store the call back for later use.
    $self->metadata_set( "add_callback" => [ $add_cb, $add_args ] );
    $self->metadata_set( "chain"        => $chain );

    return $self;
}

# item is always a hash containing at least name uri and posiably dependencies
sub _add {
    my ( $self, $item ) = @_;

    my $chain = $self->metadata("chain");

    if ( exists $item->{dependencies} && defined $item->{dependencies} ) {
        my $deps = $item->{dependencies};

        # the user might have passed dependencies as single items
        # outside of array refs if they only have one item i.e succedes => "foo"
        # rather then succedes => [ "foo" ], lets clean up!
        foreach ( keys %$deps ) {
            $deps->{$_} = [ $deps->{$_} ] unless ( ref( $deps->{$_} ) );
        }

    }

    # the item to be added to the chain and protentiall also the dependancies
    my %to_add = (name => $item->{name},
                  data => $item,
                  %{ exists $item->{dependencies} ? $item->{dependencies} : {} }
                 );

    # We use the uri as the name if no name is given
    $chain->add(%to_add);

    # FIXME: at this point we do a call to resolv_order
    # to detect loops, it's not very clean to do this
    # for every addition so I will REFACTOR this
    # TODO: log loop errors
    return undef unless ( $self->resolv_order() );

    # call the add callback with will expand this item
    # this includes resolving related overlays, config and
    # child descend location.
    my $cb_info = $self->metadata("add_callback");
    &{ $cb_info->[0] }( $self, $item, @{ $cb_info->[1] } );
}

sub remove {
    my ( $self, $name ) = @_;

    # If passed the item rather then name we might as well deal with it.
    # Also since we will add items using the uri as the name if no name is given
    # deal with that two.
    if ( ref($name) ) {
        if ( exists $name->{name} ) {
            $name = $name->{name};
        }
        $name = $name->{uri};
    }

    my $chain = $self->metadata("chain");
    $chain->remove($name);
}

sub resolv_order {
    my ($self) = @_;
    return $self->metadata("chain")->head();
}

sub data_getref {
    my $self = shift;
    return \[ $self->metadata("chain")->head() ];
}

# merge in some new branches, parent can relate to either
# the parent item or name or undef if it's a root item
sub merge {
    my ( $self, $item, $parent ) = @_;

    my $deps = undef;

    if ( $self->is_related($item) ) {
        $item = $item->merge_helper($self);
    }

    # Recursive call if we have more then one item
    if ( ref($item) eq "ARRAY" ) {
        foreach (@$item) {
            $self->merge( $_, $parent );

        }
        return undef;
    }
    

    my $resource = resolve_resource($item);
    
    unless ( defined $resource ) {
        # TODO, attempt to give an indication as to why????
        return undef;
    }

    if ( defined $parent ) {

        # make sure it's the name not the item it self
        if ( ref($parent) ) {
            $parent = $parent->{name};
        }

        # add it as a dependency
        $resource->{dependencies} = {}
          unless exists( $resource->{dependencies} );
        $resource->{dependencies}->{succedes} = []
          unless exists( $resource->{dependencies}->{succedes} );
        push @{ $resource->{dependencies}->{succedes} }, $parent;
    }

    # add the item to the key
    $self->_add($resource);

    # finally blank anything pending within data
    # all data is used for is pending stuff to merge anyhow
    $self->clear();
}

# I don't think you would ever use this but it's here in case....
sub replace {
    my $self = shift;

    #blank out the chain
    my $chain = new Spine::Chain( merge_deps     => 1,
                                  remove_orphans => 1 );

    $self->metadata_set( "chain", $chain );

    # add in the replacement data
    $self->merge(@_);
}

# This is used to tell operators that this key should be merged by default
sub merge_default() {
    return 1;
}

1;
