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

# A very dull key. Simply stops the key from taken on anything
# unless anohter Spine::Data::set happens against it
# This was initially created to hide the 'include' key from printdata

package Spine::Key::Blank;
use base qw(Spine::Key);

sub set {
    return;
}

sub get_ref {
    my $blank = undef;
    return \$blank;
}

sub merge {
    return;
}

sub metadata_set {
    return;
}
1;
