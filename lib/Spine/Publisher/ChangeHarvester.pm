# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: ChangeHarvester.pm,v 1.1.4.2 2007/09/11 21:28:02 rtilder Exp $

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

package Spine::Publisher::ChangeHarvester;

use strict;

use SVN::Delta;
use base qw(SVN::Delta::Editor);

our $VERSION = sprintf("%d", q$Revision: 1 $ =~ /(\d+)/);

sub new
{
    my $klass = shift;
    my $self = $klass->SUPER::new(@_);
    bless($self,$klass);
    $self->{changes} = {};
    $self->SUPER::set_target_revision(-1);
    return $self;
}

sub changed
{
    my ($self, $path) = @_;

    unless (exists($self->{changes}->{$path})) {
        $self->{changes}->{$path} = undef;
    }
}

sub set_target_revision
{
    my $self = shift;
    my $target = shift;

    $self->SUPER::set_target_revision($target);
}

sub open_root
{
    # @_ == (base_revision, dir_pool)
    my $self = shift;
    print STDERR "open_root\n" if $self->{_debug};

    return [ $self, undef ];
}

sub delete_entry
{
    # @_ == (path, revision, parent_baton, pool)
    my $self = shift;
    my $path = shift;
    $self->changed($path);
    print STDERR "delete_entry: $path\n" if $self->{_debug};
}

sub add_directory
{
    # @_ == (path, parent_baton, copyfrom_path, copyfrom_revision, dir_pool)
    my $self = shift;
    my $path = shift;
    $self->changed($path);

    print STDERR "add_directory: $path\n" if $self->{_debug};
    return [$self, $path];
}

sub open_directory
{
    # @_ == (path, parent_baton, base_revision, dir_pool)
    my $self = shift;
    my $path = shift;

    print STDERR "open_directory: \"$path\"\n" if $self->{_debug};
    return [$self, $path];
}

sub change_dir_prop
{
    # @_ == (dir_baton, name, value, pool)
    my ($self, $dir_baton, $name, $value) = @_;

    print STDERR "change_dir_prop: ($name == \"$value\")\n" if $self->{_debug};
    $self->changed($dir_baton->[1]);
}

sub add_file
{
    # @_ == (path, parent_baton, copy_path, copy_revision, file_pool)
    my $self = shift;
    my $path = shift;

    print STDERR "add_file: $path\n" if $self->{_debug};
    $self->changed($path);

}

sub open_file
{
    # @_ == (path, parent_baton, base_revision, file_pool)
    my $self = shift;
    my $path = shift;

    print STDERR "open_file: $path\n" if $self->{_debug};
    $self->changed($path);

}

sub change_file_prop
{
    # @_ == (file_baton, name, value, pool)
    my ($self, $file_baton, $name, $value) = @_;

    print STDERR "change_file_prop: ($name == \"$value\")\n" if $self->{_debug};
    $self->changed($file_baton->[1]);
}


1;
