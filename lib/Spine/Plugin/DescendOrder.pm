# -*- Mode: perl; cperl-continued-brace-offset: -4; cperl-indent-level: 4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: DescendOrder.pm,v 1.1.2.5.2.2 2007/10/02 22:52:36 phil Exp $

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
use Spine::Constants qw(:plugin);
use Spine::Data;
use Spine::Plugin::Interpolate;

our ($VERSION, $DESCRIPTION, $MODULE, $CURRENT_DEPTH, $MAX_NESTING_DEPTH);

$VERSION = sprintf("%d.%02d", q$Revision: 1.1.2.5.2.2 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Determines which policies to apply based on the spine-config" .
    " directory hierarchy layout";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'DISCOVERY/policy-selection' =>
                                            [ { name => 'descend',
                                                code => \&descend_order } ]
                     }
          };

use File::Spec::Functions;

$CURRENT_DEPTH = 0;
$MAX_NESTING_DEPTH = 15;


sub descend_order
{
    my $c = shift;

    #
    # FIXME
    #   As we make the descend order configurable and generic, we should stop
    #   populating variables that assume a certain descend order.
    #
    #   However, sadly, some of these are still in use, so they'll stay for
    #   now. c_host_dir was used by websys' motd.tt (fixed now), but in
    #   addition, removing it caused various templates to stop getting
    #   generated (!!), so clearly other things need it.
    #
    #   The network directory is additionally probably used by coresys, so I'm
    #   leaving it here for now, but it should too go away.
    #
    #   Phil    Wed Aug 15 17:39:29 PDT 2007
    #
    $c->{c_host_dir} = catfile('host', $c->{c_hostname_f});
    $c->{c_network_dir} = catfile('network', $c->{c_subnet});

    # Now that we have our primary policies, let's build the full list of
    # config groups we're going to need by walking this list and sucking in
    # any "config/include" files' contents we find.

    foreach my $dir (@{$c->{policy_hierarchy}}) {
        push @{$c->{c_hierarchy}}, get_includes($c, $dir);
        push @{$c->{c_hierarchy}}, $dir;
    }

    return PLUGIN_SUCCESS;
}


sub get_includes
{
    my $c = shift;
    my $directory = shift;

    my (@included, $entry);

    # FIXME  Too deep.  Log something.
    if (++$CURRENT_DEPTH > $MAX_NESTING_DEPTH) {
        goto empty_set;
    }

    foreach my $path (qw(include config/include)) {
        my $inc_file = catfile($directory, $path);

        # An empty set is perfectly acceptable
        unless (-f $inc_file) {
            next;
        }

        my $includes = $c->read_keyfile($inc_file);

        unless (defined($includes)) {
            next;
        }

        foreach my $entry (@{$includes})
        {
            $c->print(3, "including $entry");
            my $inc_dir = catfile($c->getval_last('include_dir'), $entry);
            $c->print(3, "including $inc_dir");

            # If it looks like an absolute path, assume that it's from the top
            # of the configuration root.
            if ($entry =~ m#^/#) {
                $inc_dir = catfile($c->{c_croot}, $entry);
            }

            my @i = get_includes($c, $inc_dir);

            if ($c->{include_ordering} eq 'post') {
                push @included, @i, $inc_dir;
            }
            else {
                push @included, $inc_dir, @i;
            }
        }
    }

    --$CURRENT_DEPTH;
    return wantarray ? @included : \@included;
}


1;
