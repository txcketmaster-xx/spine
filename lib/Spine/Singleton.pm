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

use strict;

package Spine::Singleton;

our ($VERSION);

$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);

#############################################################################
#
# This is pretty much an exact copy of Class::Singleton with some slight
# changes for better readability.
#
############################################################################

sub instance
{
    my $class = shift;

    # get a reference to the _instance variable in the $class package
    no strict 'refs';
    my $instance = \${ "$class\::_instance" };

    return defined(${$instance}) ? ${$instance} : (${$instance} = $class->_new_instance(@_));
}


sub _new_instance
{
    return bless {}, shift;
}


# Alias new() to instance() for paranoia's sake
*new = *instance;


1;
