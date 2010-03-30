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
# Test that Spine::Plugin::DescendOrder works as expected

use Test::More qw(no_plan);
use Helpers::Data;
use File::Spec::Functions;
use Spine::Constants qw(:basic :plugin :keys);

# create a fake data obj using the basic profile
my ( $data, $reg ) = Helpers::Data::new_data_obj();

print "Testing Spine::Plugin::DescendOrder\n";

use Spine::Plugin::DescendOrder;

# does it create it's magic key ok?
Spine::Plugin::DescendOrder::init($data);
my $hkey = $data->getkey(SPINE_HIERARCHY_KEY);
isa_ok( $hkey, "Spine::Plugin::DescendOrder::Key" );

#can I add something?
$hkey->merge( { uri  => "fake://little/uri/1",
                name => "uri1" } );
my @items = $hkey->resolv_order();
is( scalar(@items), 1, "One item added to the SPINE_HIERARCHY_KEY" );
is( $items[0]->{name}, "uri1", "One correct item" );

# can I add something else
$hkey->merge( { uri  => "fake://little/uri/2",
                name => "uri2" } );
@items = $hkey->resolv_order();
is( scalar(@items), 2, "Second item added to the SPINE_HIERARCHY_KEY" );
is( $items[0]->{name} . " " . $items[1]->{name},
    "uri1 uri2", "Two correct items" );

# can I add an item that succeds the first item and preceds the second
$hkey->merge( {  uri          => "fake://little/uri/3",
                 name         => "uri3",
                 dependencies => { precedes => "uri2" } },
              $items[0] );
@items = $hkey->resolv_order();
is( scalar(@items), 3, "Third item added to the SPINE_HIERARCHY_KEY" );
is( $items[0]->{name} . " " . $items[1]->{name} . " " . $items[2]->{name},
    "uri1 uri3 uri2",
    "Two correct items" );

# now siince uri3 succedes (depends on) uri1, does remocving uri1 remove uri3
# as it should?
$hkey->remove("uri1");
@items = $hkey->resolv_order();
is( scalar(@items), 1, "One item left in SPINE_HIERARCHY_KEY" );
is( $items[0]->{name}, "uri2", "Dependancies removed cleanly" );

