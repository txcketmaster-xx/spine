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

# Implements chains of topical items. Based on an old Chain system
# by either Ryan or Jeff.

use strict;
use Spine::Constants qw(SPINE_FAILURE SPINE_SUCCESS HOOK_START HOOK_MIDDLE HOOK_END);

our ($VERSION, @EXPORT_OK, %EXPORT_TAGS);
$VERSION = sprintf("%d.%02d", q$Revision: 22 $ =~ /(\d+)\.(\d+)/);

sub new
{
    my $klass = shift;
    
    my $self = { chain => [ { name => HOOK_START, },
                            { name => HOOK_MIDDLE,
                              given_predecessors => [ HOOK_START ], },
                            { name => HOOK_END,
                              given_predecessors => [ HOOK_MIDDLE ], }, ],
                 lookup => {},
                 given_predecessors => {},
                 unclean => undef,
                 count => 0,
                };

    $self->{lookup}->{+HOOK_START} = 0;
    $self->{lookup}->{+HOOK_MIDDLE} = 1;
    $self->{lookup}->{+HOOK_END} = 2;

    return bless $self, $klass;
}

# Add to the chain,
#   name = unique name
#   what = the item
#   where = HOOK_START, HOOK_MIDDLE, HOOK_END
#   predecessors = array ref of names
#   successors = array ref of names
sub add {
    my ($self, $name, $what, $where, $predecessors, $successors) = @_;

    if ($name !~ m/^[:\w\s\d_\.-]+$/) {
        # TODO: report error and return something more
        die;
        return SPINE_FAILURE;
    }
    
    # note that we will need to resort the chain
    $self->{unclean} = undef;

    # Where is optional
    unless (defined $where) {
        $where = HOOK_MIDDLE;
    }

    # If we have seen this before we remove the first
    if (exists $self->{lookup}->{$name}) {
        $self->delete($name);
    }

    # Construct out chain item
    my $item = { data => $what,
                 name => $name,
                 given_predecessors => $predecessors || [],
                 successors => $successors || [],
               };

    # Force a start, middle and end order. Originally this was
    # done using three arrays, but the overhead for tsort is worth
    # the simpler code (IMHO)
    push @{$item->{successors}}, $where;
    if ( $where eq HOOK_MIDDLE ) {
        push @{$item->{given_predecessors}}, HOOK_START;
    } elsif ( $where eq HOOK_END ) {
        push @{$item->{given_predecessors}}, HOOK_MIDDLE;
    }

    # time to store our item, make it easy to find it again.
    $self->{lookup}->{$name} = (push (@{$self->{chain}}, $item) -1);
    $self->{count}++;
    return SPINE_SUCCESS;
}

# delete an item by name
sub delete {
    my ($self, $name) = @_;

    # note that we will need to resort the chain
    $self->{unclean} = undef;

    if (exists $self->{lookup}->{$name}) {
        my $pos = $self->{lookup}->{$name};
        delete $self->{chain}->[$pos];
        delete $self->{lookup}->{$name};
        $self->{count}--;
    }
}

# return how many items there are
sub count {
   my $self = shift;
   return $self->{count};
}

# Will build out a predecessor item for tsort out of given and inferred
# We do this now to allow items to be removed or overridden.
sub _resolve_predecessors {
    my ($self) = shift;

    # Clean up any passed runs.
    foreach (@{$self->{chain}}) {
        $_->{predecessors} = [];
    }

    my ($item, $dest_item);

    foreach $item (@{$self->{chain}}) {
        foreach (@{$item->{successors}}) {
            # If we know of the successor then inform it that
            # item is it's predecessor.
            if (exists $self->{lookup}->{$_}) {
                $dest_item = $self->{chain}->[$self->{lookup}->{$_}];
                push @{$dest_item->{predecessors}}, $item;
            }
        }
        foreach (@{$item->{given_predecessors}}) {
            # If we know about our predecessor then we will include it
            if (exists $self->{lookup}->{$_}) {
                $dest_item = $self->{chain}->[$self->{lookup}->{$_}];
                push @{$item->{predecessors}}, $dest_item;
            }
        }
    }
}

sub _error
{
    my $self = shift;

    #push @ERROR, join(@_);
    print STDERR "HOOK ERROR: ", @_, "\n";
}

sub _debug
{
    my $self = shift;
    my $lvl = shift;

    print STDERR "HOOK DEBUG: ", @_, "\n";
}

sub head {
    my $self = shift;
    # if the chain is unsorted or has changed since
    # last sort then we sort and store the head of the
    # linked list
    if (exists $self->{unclean}) {
        $self->_resolve_predecessors;
        # Take the chain and make it a topically sorted linked list
        $self->{head} = tsort($self->{chain});
        if (!defined $self->{head}) {
            # TODO report error. Probably a loop
            return undef;
        }

        # Clean out START, MIDDLE and END place holders
        # Don't really like this, might be better if tsort
        # stored 'last' as well as next.
        my $itr = $self->{head};
        while ($itr->{next}) {
            if ($itr->{next}->{name} =~ m/^{/) {
                $itr->{next} = $itr->{next}->{next};
            } else {
                $itr = $itr->{next};
            }
        }
        # Clean out START place holder.
        if (defined $self->{head} && $self->{head}->{name} eq HOOK_START) {
            $self->{head} = $self->{head}->{next};
        }
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
                while (exists $items->[$pos]->{predecessors}->[$pre_pos] &&
                    !exists $pos_lookup{$items->[$pos]->{predecessors}->[$pre_pos]}) {
                    $pre_pos++;
                }
                if (exists $items->[$pos]->{predecessors}->[$pre_pos]) {
                    # Set the pos to it's position and wrap round to process it
                    $pos = $pos_lookup{$items->[$pos]->{predecessors}->[$pre_pos]} - 1;
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
