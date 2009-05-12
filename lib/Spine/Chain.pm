# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Constants.pm 22 2007-12-12 00:35:55Z phil@ipom.com $

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
use Spine::Constants qw(SPINE_FAILURE SPINE_SUCCESS HOOK_START HOOK_MIDDLE HOOK_END);

our ($VERSION, @EXPORT_OK, %EXPORT_TAGS);
$VERSION = sprintf("%d.%02d", q$Revision: 22 $ =~ /(\d+)\.(\d+)/);

my $DEBUG = $ENV{SPINE_CHAIN_DEBUG} || 0;

sub new
{
    my $klass = shift;
    
    # chain is an array to maintain order
    # lookup speeds up getting hooks by name
    # clean is used to note when the order needs to be rebuilt
    my $self = { chain => [ ],
                 lookup => {},
                 prov_lookup => {},
                 provreq_lookup => {},
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

    my ($name, $what) = ($settings{name}, $settings{data});
    my ($provides, $reqs) = ($settings{provides} || [], $settings{requires} || []);
    my ($pre, $suc) = ($settings{predecessors} || [], $settings{successors} || []);
    my $pos = exists $settings{position} ? $settings{position} : HOOK_MIDDLE;

    debug(3, "adding chain item ($name)");

    # note that we will need to resort the chain
    $self->{clean} = undef;

    # If we have seen this name before we remove the first
    if (exists $self->{lookup}->{$name}) {
        debug(3, "Clearing duplicate item ($name)");
        $self->remove($name);
    }

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
    if ($pos eq HOOK_START) {
        debug(3, "placing at the start");
        push @{$item->{provides}}, HOOK_START;
    } elsif ($pos eq HOOK_END) {
        debug(3, "placing at the end");
        push @{$item->{requires}}, HOOK_START;
        push @{$item->{requires}}, HOOK_MIDDLE;
    } else {
        debug(3, "placing in the middle");
        push @{$item->{requires}}, HOOK_START;
        push @{$item->{provides}}, HOOK_MIDDLE;
    }
    
    # So to make it easy to position things based on provides and requires
    # we cheat by making two hashes one of what provides and one of
    # what requires and provides
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

    # time to store our item, make it easy to find it again.
    $self->{lookup}->{$name} = (push (@{$self->{chain}}, $item) -1);
    return SPINE_SUCCESS;
}

# delete an item by name
# FIXME, this has never been tested!
sub remove {
    my ($self, $name) = @_;

    # note that we will need to resort the chain
    $self->{clean} = undef;

    if (exists $self->{lookup}->{$name}) {
        my $pos = $self->{lookup}->{$name};
        delete $self->{lookup}->{$name};
        # If we provided something then we need to remove ourselves from
        # the lookup tables
        foreach my $prov (@{$self->{chain}->[$pos]->{provides}}) {
            @{$self->{provreq_lookup}->{$prov}} =
                        grep(!/^${name}$/,
                             @{$self->{provreq_lookup}->{$prov}});
            @{$self->{prov_lookup}->{$prov}} =
                        grep(!/^${name}$/,
                             @{$self->{prov_lookup}->{$prov}});
        }
	my $removed = splice (@{$self->{chain}}, $pos, 1);
	debug(3, "Removed duplicate ($removed->{name}) from position ($pos)");

    }
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

    my ($item, $implementer);

    debug(2, "resolving predecessors");

    #FIXME: some nasty duplication going on here, should be restructured
    foreach $item (@{$self->{chain}}) {
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
                      grep(!/^$item->{name}$/,@{$self->{provreq_lookup}->{$_}}));
                debug (3, "$item->{name}: Converted requirement ($_) to ",
                       "the following dual predecessors: ",
                       join(", ", grep(!/^$item->{name}$/,@{$self->{provreq_lookup}->{$_}})));
            }
        }
        
        # Check for successors, convert to successors predecessors...
        foreach (@{$item->{successors}}) {
            my $pos = $self->{lookup}->{$_};
            if (defined $pos) {
                push @{$self->{chain}->[$pos]->{predecessors}}, $item->{name};
                debug (3, "$item->{name}: Converted successor ($_): ",
                       "($item->{name}) now a predecessor for ($self->{chain}->[$pos]->{name})");
            }
        }
        
        # Store refs to the object rather then names.
        $item->{pre_ref} = [];
        foreach (@{$item->{predecessors}}) {
            if (exists $self->{lookup}->{$_}) {
                push (@{$item->{pre_ref}}, $self->{chain}->[$self->{lookup}->{$_}]);
            }
        }
    }
}

sub head {
    my $self = shift;

    if ($self->count() == 0) {
        debug(3, "empty chain");
        return undef
    }

    # if the chain is unsorted or has changed since
    # last sort then we sort and store the head of the
    # linked list
    unless (defined $self->{clean}) {


        debug(3, "resorting");
        $self->_resolve_predecessors;
        # Best to debug the structure before tsort since
        # it's a linked list after
        if ($DEBUG > 5) {
            print Dumper($self);
        }
        debug(2, "starting tsort");
        # Take the chain and make it a topically sorted linked list
        $self->{head} = tsort($self->{chain});
        if (!defined $self->{head}) {
            # TODO report error. Probably a loop
            debug(3, "loop detected");
            return undef;
        }
        debug(2, "now sorted");
        # So we don't resort unless needed.
        $self->{clean} = 1;
    }
    return $self->{head};
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
    for (0 ... ($total_items-1)) {
        for ($pos = 0 ; ; $pos++) {
            if (exists $items->[$pos]->{next}) {
                # We have processed this before so skip
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
