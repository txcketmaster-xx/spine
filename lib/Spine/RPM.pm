# -*- mode: perl; cperl-set-style: BSD; index-tabs-mode: nil; -*-
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

package Spine::RPM;
use strict;
use RPM2;

use constant DEBUG => $ENV{SPINE_DEBUG} || 0;

sub new {
    my $class = shift;

    my $self = bless {
                      nodes => {},
                      db    => RPM2->open_rpm_db(@_),
                     }, $class;

    my $i = $self->db->find_all_iter();
    while (my $pkg = $i->next) {
        $self->add_package($pkg);
    }

    return $self;
}

sub db { shift->{db} }

sub keep {
    my ($self, @names) = @_;
    my %requires;
    my @requires;

    foreach my $name (@names) {
        foreach my $pkg ($self->db->find_by_name($name)) {
            my $node = $self->get_node($pkg);
            $requires{$node->name} = $node;
            push @requires, values %{$node->requires};
        }
    }

    while (@requires) {
        my $p = pop @requires;
        push @requires,
          grep { not exists $requires{$_->name} }
          values %{$p->requires};
        $requires{$p->name} = $p;
    }

    my @delete =
      grep { not exists $requires{$_} } sort keys %{$self->{nodes}};

    print STDERR "cleanup packages are : ",
      map { $_ . "\n" } sort keys %requires
      if DEBUG;
    print STDERR "Deleting attempted : ", map { $_ . "\n" } @delete
      if DEBUG;

    return grep { not exists $requires{$_} } $self->remove(@delete);
}

sub remove {
    my ($self, @names) = @_;

    my %removes;
    my @requires;

    foreach my $name (@names) {
        foreach my $pkg ($self->db->find_by_name($name)) {
            my $node = $self->get_node($pkg);
            $removes{$node->name} = $node;
            push @requires, values %{$node->requires};
        }
    }

    while (@requires) {
        my $p = pop @requires;
        push @requires,
          grep { not exists $removes{$_->name} } values %{$p->requires};
        $removes{$p->name} = $p;
    }

    print STDERR "Ideal removing yields :\n",
      map { "$_\n" } keys %removes
      if DEBUG;

    my %invalid;
    foreach my $pkg (keys %removes) {
        print STDERR "Looking at $pkg\n" if DEBUG;
        while (my ($dname, $dnode) =
               each %{$removes{$pkg}->required_by})
        {
            if (not exists $removes{$dname}) {
                print STDERR "Unsafe : $dname\n" if DEBUG;
                $invalid{$dname} = $dnode;
            }
            else {
                print STDERR "Safe : $dname\n" if DEBUG;
            }
        }
    }

    my @invalid = values %invalid;
    while (@invalid) {
        my $p = pop @invalid;
        push @invalid,
          grep { not exists $invalid{$_->name} } values %{$p->requires};
        $invalid{$p->name} = $p;
    }

    print STDERR "invalids:\n", map { "$_\n" } keys %invalid if DEBUG;

    my %safe;
    foreach my $pkg (keys %removes) {
        $safe{$pkg} = $removes{$pkg} unless exists $invalid{$pkg};
    }
    print STDERR "Removing yields :\n", map { "$_\n" } keys %safe
      if DEBUG;

    return sort { $a cmp $b } keys %safe;
}

sub add_package_iter {
    my ($self, $pkg, $iter, $desc) = @_;
    my $node = $self->get_node($pkg);
    while (my $req = $iter->next) {
        if (DEBUG) {
            my $is =
              $desc ? " is required($desc) by " : " is required by ";
            print STDERR $pkg->tag("Name"), $is, $req->tag('Name'),
              "\n";
        }
        my $req_node = $self->get_node($req);
        $node->required_by($req_node);
        $req_node->requires($node);
    }
}

sub add_package {
    my ($self, $pkg) = @_;
    my $node = $self->get_node($pkg);

    my @provides =
      ($pkg->tag('Provides'), $pkg->files(), $pkg->tag('Name'));

    foreach my $provide (@provides) {
        my $i = $self->db->find_by_requires_iter($provide);
        $self->add_package_iter($pkg, $i, $provide);
    }
}

sub get_node {
    my ($self, $pkg) = @_;
    if (not exists $self->{nodes}{$pkg->tag('Name')}) {
        $self->{nodes}{$pkg->tag('Name')} = Spine::RPM::Node->new($pkg);
    }
    return $self->{nodes}{$pkg->tag('Name')};
}

package Spine::RPM::Node;
use strict;

sub new {
    my ($class, $pkg) = @_;

    return
      bless {
             name        => $pkg->tag('Name'),
             pkg         => $pkg,
             required_by => {},
             requires    => {},
            }, $class;
}

sub name { shift->{name} }

sub required_by {
    my $self = shift;
    if (@_) {
        my $node = shift;
        $self->{required_by}{$node->name} = $node;
    }
    $self->{required_by};
}

sub requires {
    my $self = shift;
    if (@_) {
        my $node = shift;
        $self->{requires}{$node->name} = $node;
    }
    $self->{requires};
}

42;
