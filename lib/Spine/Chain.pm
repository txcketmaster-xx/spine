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
package Spine::Chain;
use base qw(Exporter);

# Implements chains of topical items.
#
# It supports
#   provides  - things that the item provides (own name is autmatically added)
#   requires  - things that the item requires (it will error if it is missing)
#   precedes  - things that the item comes before
#   succedes  - things that the item comes after
#
# In the code all of these get converted into predecessors just before
# ordering the items in the chain.
use strict;
use Spine::Constants qw(:basic :chain);
our ( $VERSION, @EXPORT_OK, %EXPORT_TAGS );
$VERSION = sprintf( "%d", q$Revision$ =~ /(\d+)/ );
my $DEBUG = $ENV{SPINE_CHAIN_DEBUG} || 0;

# Settings can be passed to control how the chain works
#   merge_deps     - if set, dependances will be merged
#                    when a duplicate node name is added
#   remove_orphans - strip out nodes that have all there
#                    predecessors missing (not the same as
#                    never having any predecessors).
#   loop_cb        - the function ref and args to call if
#                    a loop is detected (the first argument is always
#                    an array referance of all the items seen during the
#                    loop (possibly repeated))
#   missing_cb     - the function to call and args if a dependancy
#                    is missing (the item that required it and the
#                    item required are always the first arguments)
#
# TODO....
#   soft_requires  - if this is set we just skip items with missing requires
#                    this will require something like remove_orphans in order
#                    to work since we need to keep going reaping any children
#                    who required something that had missing requires.
sub new {
    my $klass = shift;
    my (%settings) = @_;

    # chain is an array to maintain order
    # lookup speeds up getting chain items by name
    # clean is used to note when the order needs to be rebuilt
    my $self = { chain          => [],
                 lookup         => {},
                 prov_rules     => {},
                 lasterr        => undef,
                 settings       => \%settings, };
    $self = bless $self, $klass;

    return $self;
}

sub debug {
    my $lvl = shift;
    if ( $DEBUG >= $lvl ) {
        print STDERR "CHAIN DEBUG($lvl): ", @_, "\n";
    }
}

#   Add to the chain,
#   name = unique name (will be added as a provides)
#   data = the item
#   provides
#   requires
#   precedes
#   succedes
sub add {
    my ( $self, %settings ) = @_;
    if ( !defined $settings{name} || !defined $settings{name} ) {
        debug( 1, "attempt to add a badly formatted item to the chain" );
        return SPINE_FAILURE;
    }
    my ( $name, $data ) = ( $settings{name}, $settings{data} );
    debug( 3, "adding chain item ($name)" );

    # note that we will need to resort the chain
    $self->{clean} = undef;

    # Construct out chain item
    my $item = { data => $settings{data},
                 name => $settings{name}, };

    # Create hashes to undef for easy lookup
    foreach ( "provides", "requires", "precedes", "succedes" ) {
        $item->{$_} =
          exists $settings{$_}
          ? { map { $_ => undef } @{ $settings{$_} } }
          : {};
    }

    # we always provide ourself
    $item->{provides}->{ $settings{name} } = undef;

    # If we have seen this name before we remove the first
    # unless we have been told to merge nodes
    if ( exists $self->{lookup}->{$name} ) {
        unless ( exists $self->{settings}->{merge_deps} ) {
            debug( 3, "Clearing duplicate item ($name)" );
            $self->remove($name);
        } else {

            # Merge nodes
            $self->_merge( $item, $name );
        }
    }
    # If the items hasn't been stored yet then its
    # time to store our item, make it easy to find it again.
    unless ( exists $self->{lookup}->{$name} ) {
        $self->{lookup}->{$name} = $item;
        push @{ $self->{chain} }, $item;
    }
    return SPINE_SUCCESS;
}

sub last_error {
    my $self = shift;
    return undef unless ( exists $self->{lasterr} );
    return delete $self->{lasterr};
}

# This function deals with resolving provide rules.
sub _resolve_order_info {
    my ( $self, $item, $result, @provlist ) = @_;

    # This is a recursive func but we need to initilize some stuff
    # the first time we are called
    unless ( defined $result ) {

        # we don't prepopulate provides as it's done as we
        # go along to track any loop potential.
        $result = { provides => {} };
        foreach my $type ( "requires", "succedes", "precedes" ) {
            $result->{$type} = { %{ $item->{$type} } };
        }
        @provlist = keys %{ $item->{provides} };
    }
    foreach my $pvitem (@provlist) {

        # skip if we have seen before (also stops any LOOPS)
        next if ( exists $result->{provides}->{$pvitem} );

        # Note that this is a provided item
        $result->{provides}->{$pvitem} = undef;

        # next item if there are no rules defined
        next unless ( exists $self->{prov_rules}->{$pvitem} );
        debug( 3, "provide rule detected for ($pvitem)" );

        # add in any succedes aditions
        foreach my $type ( "requires", "precedes", "succedes" ) {
            map { $result->{$type}->{$_} = undef }
              keys %{ $self->{prov_rules}->{$pvitem}->{$type} };
        }

        # next if there are no sup-provides
        next
          unless ( exists $self->{prov_rules}->{$pvitem}->{provides} );

        debug( 3, "sub-provide(s) detected for ($pvitem)" );

        $self->_resolve_order_info( undef, $result,
                                    keys %{
                                        $self->{prov_rules}->{$pvitem}
                                          ->{provides} } );
        debug( 4, "sub-provide (back)" );

    }

    # If first_call is '1' then it's time to return the results...
    if (wantarray) {
        return %$result;
    }
}

# If an item had a given 'provide' we automatically add provides, requires,
# succedes. Arguments can be like bellow...
#    provide => 'some_provide',
#    provides => [ 'addthis', 'andthis', ... ],
#    requires => [ 'addthis', 'andthis', ... ],
#    suceedes => [ 'addthis', 'andthis', ... ],
#    precedes => [ 'addthis', 'andthis', ... ],
sub add_provide_rule {
    my ( $self, %settings ) = @_;
    my $provide = delete $settings{provide};
    $self->{prov_rules}->{$provide} = {}
      unless exists $self->{prov_rules}->{$provide};
    foreach my $item ( keys %settings ) {
        $self->{prov_rules}->{$provide}->{$item} = {}
          unless exists $self->{prov_rules}->{$provide}->{$item};
        map { $self->{prov_rules}->{$provide}->{$item}->{$_} = undef }
          @{ $settings{$item} };
    }
}

# delete an item by name
# FIXME, this has never been tested!
sub remove {
    my ( $self, $name ) = @_;
    # note that we will need to resort the chain
    $self->{clean} = undef;
    if ( exists $self->{lookup}->{$name} ) {
        @{ $self->{chain} } =
          grep ( ( $_ ne $self->{lookup}->{$name} ), @{ $self->{chain} } );
        my $removed = delete $self->{lookup}->{$name};
        debug( 3, "Removed ($removed->{name})" );
        return $removed;
    }
    debug( 2, "Could not remove ($name), seems not to exists" );
    return undef;
}

# Merge a new node item into an existsing
sub _merge {
    my ( $self, $item, $name ) = @_;
    debug( 3, "Mergeing deps into item $name" );

    # check that it exists
    return undef unless ( exists $self->{lookup}->{$name} );
    my $dest_item = $self->{lookup}->{$name};

    # We assume the newest data item is the one wanted
    $dest_item->{data} = $item->{data} if exists $item->{data};

    # merge in deps...
    foreach my $dep ( "requires", "provides", "precedes", "succedes" ) {
        foreach ( keys %{ $item->{$dep} } ) {
            $dest_item->{$dep}->{$_} = undef;
        }
    }
    return $dest_item;
}

# this will remove orphans, those are nodes that at some point had succedes/requires
# listed but now all the items that it succeded/required are gone.
sub _remove_orphans {
    my ($self) = @_;
    debug( 4, "remove_orphans calld" );
    my @to_remove;
    foreach my $item ( @{ $self->{chain} } ) {

        # items are undef when removed
        next unless defined $item;
        my $strip = 0;
        debug( 6, "remove_orphans: looking at ($item->{name})" );
        foreach my $pre_name ( keys %{ $item->{succedes} },
                               keys %{ $item->{requires} } )
        {
            debug( 6, "remove_orphans: checking for ($pre_name)" );

            if ( exists $self->{lookup}->{$pre_name} ) {

                # It has an active parent so we will not strip
                debug( 6, "remove_orphans: keeping as ($pre_name) is active" );
                $strip = 0;
                last;
            }
            debug( 6, "remove_orphans: ($pre_name) is missing" );
            $strip = 1;
        }
        if ( $strip == 1 ) {
            push @to_remove, $item->{name};
        }
    }
    my $rc = 0;
    foreach (@to_remove) {
        debug( 6, "remove_orphans: removing $_" );
        $self->remove($_);
        $rc++;
    }
    return $rc;
}

# return how many items there are
sub count {
    my $self = shift;
    return scalar( @{ $self->{chain} } );
}

# Will build out a predecessor referances for tsort out of
# items that are required or that it succedes.
sub _resolve_predecessors {
    my ($self) = shift;
    debug( 2, "resolving predecessors" );

    # Since we want to allow items to be changed after
    # this function is called we place derived order information
    # here so as not to taint the actaul items.
    my $item_info = {};
    my $tmp_info  = {};

    # We place any helpful lookupinfotmation here
    my $lookup_info = { provides          => {},
                        provides_requires => {},
                        provides_succedes => {}, };
    debug( 3, "setting up lookups and full item info" );

    # create lookups and expanded info for all items
    foreach my $item ( @{ $self->{chain} } ) {

        # get the full details that tell us where to place this item
        my $order_info = { $self->_resolve_order_info($item) };
        $item_info->{ $item->{name} } = $order_info;

        # Merge in any tmp info, these happen when something says
        # it precedes something that hasn't been processed yet (done bellow)
        if ( exists $tmp_info->{ $item->{name} } ) {
            map { $order_info->{succedes}->{$_} = undef }
              keys %{ delete $tmp_info->{ $item->{name} } };
        }

        # Now we need to convert precedes into sucedes for the items
        # they precedes.
        foreach my $pre ( keys %{ $order_info->{precedes} } ) {

            # If we have already processed the item that this precedes
            # then we add in the succedes there, otherwise we make a note
            # so that it can be added when it's processed (done above)
            if ( exists $item_info->{$pre} ) {
                $item_info->{$pre}->{succedes}->{ $item->{name} } = undef;
            } else {
                $tmp_info->{$pre} = {} unless exists $tmp_info->{$pre};
                $tmp_info->{$pre}->{ $item->{name} } = undef;
            }
        }

        # Fill in lookup info so we can quickly find out what provides something
        foreach ( keys %{ $order_info->{provides} } ) {
            my $sub_cat = "";

            # If an item both provides and requires/succedes the same thing
            # we note it separately as they have to be placed after the items
            # that provide. If we didn't we would get in to nasty loops
            if ( exists $order_info->{requires}->{$_} ) {
                $sub_cat = "_requires";
            } elsif ( exists $order_info->{succedes}->{$_} ) {
                $sub_cat = "_succedes";
            }
            $sub_cat = "provides$sub_cat";
            unless ( exists $lookup_info->{$sub_cat}->{$_} ) {
                $lookup_info->{$sub_cat}->{$_} = [];
            }
            push @{ $lookup_info->{$sub_cat}->{$_} }, $item->{name};
        }
    }
    debug( 3, "converting all requires/succedes to predecessor refs" );

    # go through the items again building out the final precesessors
    # this has to be done in a separate loop to the above since we need
    # need populated lookup information.
    foreach my $item ( @{ $self->{chain} } ) {
        $item->{pre_ref} = [];

        # At this point we only care about requires and succedes since
        # everything should have been converted to these.
        foreach my $type ( "requires", "succedes" ) {

            # for everything that comes before this item....
            foreach my $req ( keys %{ $item_info->{ $item->{name} }->{$type} } )
            {
                debug( 4, "$item->{name}: looking at $type ($req)" );
                my $found = 0;
                foreach ( "provides", "provides_requires", "provides_succedes" )
                {
                    next unless ( exists $lookup_info->{$_}->{$req} );
                    $found = 1;

                    # store referances to everything that must preceede
                    push @{ $item->{pre_ref} }, ( map { $self->{lookup}->{$_} }
                                              @{ $lookup_info->{$_}->{$req} } );
                    debug( 3,
                           "$item->{name}: Converted $type ($req) to ",
                           "predecessor referance to: ",
                           join( ", ", @{ $lookup_info->{$_}->{$req} } ) );
                }
                unless ( $found || $type ne "requires" ) {

                    # if something is required but not in the chain then
                    # we give up
                    debug( 1,
                           "$item->{name}: required ($req)"
                             . " which was not found " );

                    if ( exists $self->{settings}->{missing_cb} ) {
                        my $func = shift @{ $self->{settings}->{missing_cb} };
                        my $args = $self->{settings}->{missing_cb};
                        &$func( $item->{name}, $req, @$args );
                    }
                    $self->{lasterr} =
                      "$item->{name}: required ($req)" . " which was not found";
                    return SPINE_FAILURE;
                }

            }
        }
    }
    return SPINE_SUCCESS;
}

# Will either return a linked list from the chain
# or an array or the data items
sub head {
    my $self = shift;
    if ( $self->count() == 0 ) {
        debug( 3, "empty chain" );
        return wantarray ? () : undef;
    }

    # if the chain is unsorted or has changed since
    # last sort then we sort and store the head of the
    # linked list
    unless ( defined $self->{clean} ) {
        debug( 3, "resorting" );

        # This will get the chain to the point
        # where each item has an array containign
        # refs to every item that must come before it
        unless ( $self->_resolve_predecessors() == SPINE_SUCCESS ) {
            debug( 1, "there was an error withing resolve_predecessors" );

            # There was probably a missing require
            return wantarray ? () : undef;
        }

        # If remove_orphans is defined then we strip out
        # orphans, each time one is removed we have to check
        # again that it hasn't created more.
        while ( exists $self->{settings}->{remove_orphans}
                && $self->_remove_orphans() )
        {
            debug( 3, "orphans removed" );
        }
        debug( 2, "starting tsort" );

        # Take the chain and make it a topically sorted linked list
        $self->{head} = tsort( $self->{chain} );

        # If it's an arry not a hash then there was a loop
        if ( ref( $self->{head} ) eq "ARRAY" ) {
            if ( exists $self->{settings}->{loop_cb} ) {
                my $func = shift @{ $self->{settings}->{loop_cb} };
                my $args = $self->{settings}->{loop_cb};
                &$func( $self->{head}, @$args );
            }
            $self->{lasterr} =
                "loop detected ("
              . join( ") is depended on by (", @{ $self->{head} } )
              . ") is...";

            debug( 3, $self->{lasterr} );
            return wantarray ? () : undef;
        }
        debug( 2, "now sorted" );

        # So we don't resort unless needed.
        $self->{clean} = 1;

        # We store an array as well in case it's wanted
        my $item = $self->{head};
        $self->{as_array} = [ $item->{data} ];
        while ( exists $item->{next} && defined $item->{next} ) {
            $item = $item->{next};
            push @{ $self->{as_array} }, $item->{data};
        }
    }
    return wantarray ? @{ $self->{as_array} } : $self->{head};
}

# TOPICAL SORT (based on apache httpd's tsort)
# This needs a array ref passed which contains an array of hashes
#
# The hash should contain predecessors where needed
# pre_ref => [ $predecessor_ref, ... ]
#
# It will alter the hash to contain a linked list
# of ->next values and return the head.
#
# It will strip out any existing next items so you can pass the
# array in many times.
sub tsort {
    my ($items) = @_;
    my ($item);
    my $itr_total = 0;

    # this is only used to debug loops in the chain, it is not needed
    # to sort.
    my @loop_track;

    # Create a reverse lookup, also used to track placed items
    my %pos_lookup;
    my $i = 0;
    foreach ( @{$items} ) {
        $pos_lookup{$_} = $i++;

        # This also strips out any next items that may be there.
        delete $_->{next} if exists $_->{next};
    }
    my $total_items = $i;
    my ( $pos, $pre_pos, $jump_counter );
    my ( $head, $tail ) = ( undef, undef );

    # You are talking about at least total_items*2 iterations to
    # work out the order. Not an issue for it's intended use...
    for ( 0 ... ( $total_items - 1 ) ) {
        for ( $pos = 0 ; ; $pos++ ) {
            if ( !defined $items->[$pos] || exists $items->[$pos]->{next} ) {

                # We have processed this before or it's been removed so skip
                next;
            } else {

                # If it exists but is not in the lookup table it has
                # already been placed
                $pre_pos = 0;
                while ( exists $items->[$pos]->{pre_ref}->[$pre_pos]
                     && !
                     exists $pos_lookup{ $items->[$pos]->{pre_ref}->[$pre_pos] }
                  )
                {
                    $pre_pos++;
                }
                if ( exists $items->[$pos]->{pre_ref}->[$pre_pos] ) {
                    push @loop_track, $items->[$pos]->{name};

                    # Set the pos to it's position and wrap round to process it
                    $pos =
                      $pos_lookup{ $items->[$pos]->{pre_ref}->[$pre_pos] } - 1;

                    # More jumps then items has to be a loop in predecessors.
                    if ( ++$jump_counter == $total_items ) {
                        return \@loop_track;
                    }
                    next;
                } else {

                    # We have found our man! So end of any jumping
                    $jump_counter = 0;
                    @loop_track   = ();
                    last;
                }
            }
        }
        if ( $pos != $_ ) {
            debug( 3,
                   "moving item ($items->[$pos]->{name}) from ($pos) to ($_)" );
        } else {
            debug( 4, "leaving item ($items->[$pos]->{name}) at ($pos)" );
        }

        # Alter the linked list adding the item.
        unless ( defined $tail ) {
            $head = $items->[$pos];
        } else {
            $tail->{next} = $items->[$pos];
        }
        $tail = $items->[$pos];
        $tail->{next} = undef;

        # Remove the item from out lookup so we know it has been placed
        delete $pos_lookup{ $items->[$pos] };
    }
    return $head;
}

1;
