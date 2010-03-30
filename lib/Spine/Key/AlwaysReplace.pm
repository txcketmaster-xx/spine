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
# this key will always replace whats in it even if merge is called

package Spine::Key::Blank;
use base qw(Spine::Key);

# merge becomes set
sub merge {
    my ($self, $item) = @_;
    
    if ( $self->is_related($item) ) {
        $item = $item->merge_helper($item);
    }
    
    $self->set($item);
}

# set default to replace. might as well...
sub default_merge {
    return 0;
}

1;