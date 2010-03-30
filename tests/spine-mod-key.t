#!/usr/bin/perl -w
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
use strict;

#
# Test that Spine::Util works as expected
use Test::More qw(no_plan);
use Spine::Constants qw(:basic);
use Spine::Key;

# test array code
my $key_obj = new Spine::Key( [ 'one', 'two', 'three' ] );

isa_ok( $key_obj, "Spine::Key" );

is( join( " ", @{ $key_obj->get() } ),
    "one two three",
    "Spine::Key->get() ARRAY" );

$key_obj->set( [ 'one', 'two' ] );
is( join( " ", @{ $key_obj->get() } ), "one two", "Spine::Key->set() ARRAY" );

$key_obj->merge( ['three'] );
is( join( " ", @{ $key_obj->get() } ),
    "one two three",
    "Spine::Key->merge() ARRAY" );

$key_obj->merge( ['zero'], { reverse => 1 } );
is( join( " ", @{ $key_obj->get() } ),
    "zero one two three",
    "Spine::Key->merge(reverse) ARRAY" );
$key_obj->remove("o");
is( join( " ", @{ $key_obj->get() } ), "three", "Spine::Key->remove() ARRAY" );

$key_obj = new Spine::Key( [ 'one', 'two', 'three' ] );
$key_obj->keep("o");
is( join( " ", @{ $key_obj->get() } ), "one two", "Spine::Key->keep() ARRAY" );

# Test hash code
$key_obj = new Spine::Key( { one => 1, two => 2, three => 3 } );

isa_ok( $key_obj, "Spine::Key" );

is( ref( $key_obj->get() ), "HASH", "Spine::Key->get() HASH" );

$key_obj->merge( { four => 4, five => 5 } );
my $result = $key_obj->get();
is( $result->{four} . $result->{five} . $result->{one},
    "451", "Spine::Key->merge() HASH" );

