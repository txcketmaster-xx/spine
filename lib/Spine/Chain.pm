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

# Implements chains of topical items. Based on an old Chain system
# by either Ryan or Jeff.
#
# It supports
#   provides
#   requires
#   position
#   predecessors
#   successors
#
# In the code all of these get converted into predecessors just before
# ordering the items in the chain.

use strict;
use Spine::Constants qw(:basic :chain);

our ($VERSION, @EXPORT_OK, %EXPORT_TAGS);
$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);

my $DEBUG = $ENV{SPINE_CHAIN_DEBUG} || 0;

# Settings can be passed to control how the chain works
#   merge_deps     - if set, dependances will be merged
#                    when a duplicate node name is added
#   remove_orphans - strip out nodes that have all there
#                    predecessors missing (not the same as
#                    never having any predecessors).
sub new
{
    my $klass = shift;
    my (%settings) = @_;
    
    # chain is an array to maintain order
    # lookup speeds up getting chain items by name
    # clean is used to note when the order needs to be rebuilt
    my $self = { chain => [ ],
                 lookup => {},
                 prov_lookup => {},
                 provreq_lookup => {},
                 settings => \%settings,
                };

    return bless $self, $klass;
}


sub debug {
    my $lvl = shift;

    if ($DEBUG >= $lvl) {
        print STDERR "CHAIN DEBUG($lvl): ", @_, "\n";
    }
}


# Add to the chain,
#   name = unique name
#   data = the item
#   provides = array ref of what it provides
#   requires = array ref of requirements
#   position = placement in the chain, start middle, end
#   predecessors = names that must come before
#   successors = names that must come after
sub add {
    my ($self, %settings) = @_;

    if (!defined $settings{name} || !defined $settings{name}) {
        debug(1, "attempt to add a badly formatted item to the chain");
        return SPINE_FAILURE;
    }
    my ($name, $what) = ($settings{name}, $settings{data});
    my ($provides, $reqs) = ($settings{provides} || [], $settings{requires} || []);
    my ($pre, $suc) = ($settings{predecessors} || [], $settings{successors} || []);
    my $pos = (exists $settings{position} && 
               defined($settings{position})) ?
                   $settings{position} : CHAIN_MIDDLE;

    debug(3, "adding chain item ($name)");

    # note that we will need to resort the chain
    $self->{clean} = undef;

    # Construct out chain item, we don't store provides since
    # it is later setup to be a lookup.
    my $item = { data => $what,
                 name => $name,
                 requires => [@$reqs],
                 provides => [@$provides],
                 predecessors => [@$pre],
                 successors => [@$suc],
               };

    # Position gets converted into provides and requires
    # They will be later get converted to predecessors...
    if ($self->{settings}->{remove_orphans}) {
        # removal of orphans brakes when used with positon,
        # this is because everything in the middle or end
        # is a child of something.
        debug(3, "skiping placement (position) as remove_orphans is enabled");
    } elsif ($pos eq CHAIN_START) {
        debug(3, "placing at the start");
        push @{$item->{provides}}, CHAIN_START;
    } elsif ($pos eq CHAIN_END) {
        debug(3, "placing at the end");
        push @{$item->{requires}}, CHAIN_START;
        push @{$item->{requires}}, CHAIN_MIDDLE;
    } else {
        debug(3, "placing in the middle");
        push @{$item->{requires}}, CHAIN_START;
        push @{$item->{provides}}, CHAIN_MIDDLE;
    }
    
    # If we have seen this name before we remove the first
    # unless we have been told to merge nodes
    if (exists $self->{lookup}->{$name}) {
        unless (exists $self->{settings}->{merge_deps}) {
            debug(3, "Clearing duplicate item ($name)");
            $self->remove($name);
        } else {
            # Merge nodes
            $self->_merge($item, $name);
        }
    }
    
    # So to make it easy to position things based on provides and requires
    # we cheat by making two hashes one of what provides and one of
    # what requires and provides the same thing
    foreach (@{$item->{provides}}) {
        if (grep(/^$_$/, @$reqs)) {
            unless (exists $self->{provreq_lookup}->{$_}) {
                $self->{provreq_lookup}->{$_} = [];
            }
            push @{$self->{provreq_lookup}->{$_}}, $name;
        } else {
            unless (exists $self->{prov_lookup}->{$_}) {
                $self->{prov_lookup}->{$_} = [];
            }
            push @{$self->{prov_lookup}->{$_}}, $name;
        }
    }

    # If the items hasn't been stored yet then its
    # time to store our item, make it easy to find it again.
    unless (exists $self->{lookup}->{$name}) {
        $self->{lookup}->{$name} = $item;
        push @{$self->{chain}}, $item;
    }
    
    return SPINE_SUCCESS;
}

# delete an item by name
# FIXME, this has never been tested!
sub remove {
    my ($self, $name) = @_;

    # note that we will need to resort the chain
    $self->{clean} = undef;

    if (exists $self->{lookup}->{$name}) {
        # If we provided something then we need to remove ourselves from
        # the lookup tables
        foreach my $prov (@{$self->{lookup}->{$name}->{provides}}) {
            @{$self->{provreq_lookup}->{$prov}} =
                        grep(!/^${name}$/,
                             @{$self->{provreq_lookup}->{$prov}});
            @{$self->{prov_lookup}->{$prov}} =
                        grep(!/^${name}$/,
                             @{$self->{prov_lookup}->{$prov}});
        }
        @{$self->{chain}} = grep (($_ ne $self->{lookup}->{$name}), 
                                  @{$self->{chain}});
        my $removed = delete $self->{lookup}->{$name};
        debug(3, "Removed ($removed->{name})");
        return $removed;
    }
    debug(2, "Could not remove ($name), seems not to exists");
    return undef
}

# Merge a new node item into an existsing
sub _merge {
    my ($self, $item, $name) = @_;

    debug(3, "Mergeing deps into item $name");
    # check that it exists
    return undef unless (exists $self->{lookup}->{$name});

    my $dest_item = $self->{lookup}->{$name};

    # We assume the newest data item is the one wanted
    $dest_item->{data} = $item->{data};

    foreach my $dep ("requires", "provides",
                  "predecessors", "successors") {
        push @{$dest_item->{$dep}}, @{$item->{$dep}};
    }

    return $dest_item;
}

# this will remove orphans (nodes that have predecessors listed that
# do not exists). Once run it may have created more so it should be
# run untill it returns zero. That is unless you only care about single
# depth removal.
sub _remove_orphans {
    my ($self) = @_;

    debug(4, "remove_orphans calld");

    my @to_remove;

    foreach my $item (@{$self->{chain}}) {
        # items are undef when removed
        next unless defined $item;
        my $strip = 0;
        debug(6, "remove_orphans: looking at ($item->{name})");
        foreach my $pre_name (@{$item->{predecessors}}) {
           debug(6, "remove_orphans: checking for ($pre_name)");
           if (exists $self->{lookup}->{$pre_name}) {
               # It has an active parent so we will not strip
               debug(6, "remove_orphans: keeping ($pre_name) is active");
               $strip = 0;
               last;
           }
           debug(6, "remove_orphans: ($pre_name) is missing");
           $strip = 1;
        }
        if ($strip == 1) {
            push @to_remove, $item->{name};
        }
    }

    my $rc = 0;
    foreach (@to_remove) {
        debug(6, "remove_orphans: removing $_");
        $self->remove($_);
        $rc++;
    }

    return $rc;
}

# return how many items there are
sub count {
   my $self = shift;
   return scalar(@{$self->{chain}});
}

# Will build out a predecessor item for tsort out of
# items that are required.
sub _resolve_predecessors {
    my ($self) = shift;

    debug(2, "resolving predecessors");

    #FIXME: some nasty duplication going on here, should be restructured
    foreach my $item (@{$self->{chain}}) {
        # items are undef when removed
        next unless defined $item;

        # Check if the item has any requires, convert to predecessors
        foreach (@{$item->{requires}}) {
            debug(4, "$item->{name}: looking at requirement ($_)");
            if (exists $self->{prov_lookup}->{$_}) {
                push (@{$item->{predecessors}}, @{$self->{prov_lookup}->{$_}});
                debug (3, "$item->{name}: Converted requirement ($_) to ",
                       "the following predecessors: ",
                       join(", ", @{$self->{prov_lookup}->{$_}}));
            }
            # We have to grep out the name of the item, since something
            # can provide the same thing it requires (messy)
            if (exists $self->{provreq_lookup}->{$_}) {
                push (@{$item->{predecessors}},
                      grep(!/^$item->{name}$/,
                           @{$self->{provreq_lookup}->{$_}}));
                debug (3, "$item->{name}: Converted requirement ($_) to ",
                       "the following dual predecessors: ",
                       join(", ", grep(!/^$item->{name}$/,
                                       @{$self->{provreq_lookup}->{$_}})));
            }
        }
        
        # Check for successors, convert to successors predecessors...
        foreach (@{$item->{successors}}) {
            if (exists $self->{lookup}->{$_}) {
                push @{$self->{lookup}->{$_}->{predecessors}}, $item->{name};
                debug (3, "$item->{name}: Converted successor ($_): ",
                       "($item->{name}) now a predecessor for ",
                       "($self->{lookup}->{$_}->{name})");
            }
        }
    }
}

# Creates the referances ready for tsort
sub _create_refs {
    my ($self) = shift;

    foreach my $item (@{$self->{chain}}) {
        # items are undef when removed
        next unless defined $item;

        # Store refs to the object rather then names.
        $item->{pre_ref} = [];
        foreach (@{$item->{predecessors}}) {
            if (exists $self->{lookup}->{$_}) {
                push (@{$item->{pre_ref}},
                      $self->{lookup}->{$_});
            }
        }
    }
}

# Will either return a linked list from the chain
# or an array or the data items
sub head {
    my $self = shift;

    if ($self->count() == 0) {
        debug(3, "empty chain");
        return wantarray ? () : undef
    }

    # if the chain is unsorted or has changed since
    # last sort then we sort and store the head of the
    # linked list
    unless (defined $self->{clean}) {

        debug(3, "resorting");
        $self->_resolve_predecessors;

        # If remove_orphans is defined then we strip out
        # orphans, each time one is removed we have to check
        # again that it hasn't created more.
        while (exists $self->{settings}->{remove_orphans}
               && $self->_remove_orphans()) {
            debug(3, "orphans removed");
        }

        # Convert name based predecessors to refs ready for tsort
        $self->_create_refs();

        debug(2, "starting tsort");
        # Take the chain and make it a topically sorted linked list
        $self->{head} = tsort($self->{chain});
        if (!defined $self->{head}) {
            # TODO report error. Probably a loop
            debug(3, "loop detected");
            return wantarray ? () : undef
        }
        debug(2, "now sorted");
        # So we don't resort unless needed.
        $self->{clean} = 1;

        # We store an array as well in case it's wanted
        my $item = $self->{head};
        $self->{as_array} = [ $item->{data} ];
        while (exists $item->{next} && defined $item->{next}) {
            $item = $item->{next};
            push @{$self->{as_array}}, $item->{data};
        }
    }

    return wantarray ? @{$self->{as_array}} : $self->{head};
}

# TOPICAL SORT (based on apache httpd's tsort)
# This needs a array ref passed which contains an array of hashes
#
# The hash should contain predecessors where needed
# predecessors => [ $predecessor_ref, ... ]
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

    # Create a reverse lookup, also used to track placed items
    my %pos_lookup;
    my $i = 0;
    foreach (@{$items}) {
        $pos_lookup{$_} = $i++;
        # This also strips out any next items that may be there.
        delete $_->{next} if exists $_->{next};
    }
    my $total_items = $i;

    my ($pos, $pre_pos, $jump_counter);
    my ($head, $tail) = (undef, undef);
   
    # You are talking about at least total_items*2 iterations to
    # work out the order. Not an issue for it's intended use...
    for (0 ... ($total_items - 1)) {
        for ($pos = 0 ; ; $pos++) {
            if (!defined $items->[$pos] || exists $items->[$pos]->{next}) {
                # We have processed this before or it's been removed so skip
                next;
            } else {
                # If it exists but is not in the lookup table it has already been placed
                $pre_pos=0;
                while (exists $items->[$pos]->{pre_ref}->[$pre_pos] &&
                    !exists $pos_lookup{$items->[$pos]->{pre_ref}->[$pre_pos]}) {
                    $pre_pos++;
                }
                if (exists $items->[$pos]->{pre_ref}->[$pre_pos]) {
                    # Set the pos to it's position and wrap round to process it
                    $pos = $pos_lookup{$items->[$pos]->{pre_ref}->[$pre_pos]} - 1;
                    # More jumps then items has to be a loop in predecessors.
                    if (++$jump_counter == $total_items) {
                        # Loop detected...
                        return undef;
                    }
                    next;
                } else {
                    # We have found our man! So end of any jumping
                    $jump_counter = 0;
                    last;
                }
            }
        }
        if ($pos != $_) {
            debug(3, "moving item ($items->[$pos]->{name}) from ($pos) to ($_)");
        } else {
            debug(4, "leaving item ($items->[$pos]->{name}) at ($pos)");
        }
        # Alter the linked list adding the item.
        unless (defined $tail) {
            $head = $items->[$pos];
        } else {
            $tail->{next} = $items->[$pos];
        }
        $tail = $items->[$pos];
        $tail->{next} = undef;
        # Remove the item from out lookup so we know it has been placed
        delete $pos_lookup{$items->[$pos]};
    }
    return $head;
}


1;
