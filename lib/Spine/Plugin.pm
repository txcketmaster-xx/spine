# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Plugin.pm,v 1.1.2.2.2.1 2007/10/02 22:01:28 phil Exp $

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

package Spine::Plugin;
use base qw(Spine::Singleton);

our ($VERSION, $DESCRIPTION, $MODULE, $DEBUG);

$VERSION = sprintf("%d.%02d", q$Revision: 1.1.2.2.2.1 $ =~ /(\d+)\.(\d+)/);

$MODULE = undef;

use Spine::Constants qw(:plugin);
use Spine::Registry qw(register_plugin);


sub _new_instance
{
    my $klass = shift;

    #my $self = $klass->SUPER::new();
    #bless $self, $klass;
    my $self = bless {}, $klass;

    no strict 'refs';
    my $module = ${ "$klass\::MODULE" };

    unless (defined($module) and ref($module) eq 'HASH') {
        print STDERR "Invalid plugin definition: \"$klass\"\n";
        undef $self;
        return undef;
    }

    unless ($self->register($module)) {
        print STDERR "Whoops.  Failed to register $klass plugin.\n";
        return undef;
    }

    return $self;
}


sub register
{
    return register_plugin(@_);
}


sub warn
{
    my $self = shift;

    print STDERR ref($self), ': ', @_, "\n";
}


sub print
{
    my $self = shift;

    print ref($self), ': ', @_, "\n";
}


sub error
{
    my $self = shift;

    print STDERR 'PLUGIN ERROR(', ref($self), '): ', @_, "\n";
}


sub debug
{
    my $self = shift;
    my $lvl = shift;

    if ($DEBUG >= $lvl) {
        print STDERR 'PLUGIN DEBUG(', ref($self), ":$lvl): ", @_, "\n";
    }
}


1;
