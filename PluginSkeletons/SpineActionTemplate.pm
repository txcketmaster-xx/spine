# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:
#
# $Id: SpineActionTemplate.pm,v 1.1.18.2 2007/10/02 22:54:31 phil Exp $

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

#
# Description of what this package does
#

package Spine::Action::ReplaceMe;
our ($VERSION);

$VERSION = sprintf("%d.%02d", q$Revision: 1.1.18.2 $ =~ /(\d+)\.(\d+)/);

use strict;


sub run
{
    my $c = shift;  # This is the main Spine::Data object that gets passed
                    # to templates as the variable named "c"


    die "This is a default plugin, bitch!";
}


1;
