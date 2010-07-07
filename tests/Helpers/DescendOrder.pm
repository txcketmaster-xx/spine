# -*- mode: cperl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
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


# small wrapper for loading descend order for testing descend plugins
package Helpers::DescendOrder;
use Helpers::Data;

sub init {
    my ($data, $reg) = @_;
    Helpers::Data::auto_load_plugin($data, $reg, "DescendOrder");
    my $point = $reg->get_hook_point("INIT");
    $point->run_hooks($data);
     
}

sub run {
    my ($data, $reg) = @_; 
    my $point = $reg->get_hook_point("DISCOVERY/policy-selection");
    $point->run_hooks($data);
       
}

1;