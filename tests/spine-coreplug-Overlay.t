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
# Test that Spine::Plugin::Overlay works as expected

use Test::More qw(no_plan);
use Helpers::Data;
use Helpers::DescendOrder;
use File::Spec::Functions;
use Spine::Constants qw(:basic :plugin :keys);

# create a fake data obj using the basic profile
my ( $data, $reg ) = Helpers::Data::new_data_obj();

print "Testing Spine::Plugin::Overlay\n";

use Spine::Plugin::Overlay;

# create some dirs
ok( my $tmp_dir = File::Spec->tmpdir(), "get a tmp dir" );
my $test_dir = catdir( $tmp_dir, "spine_tests");
is( Spine::Util::makedir($test_dir), $test_dir, "makedir ($test_dir)" );
my $overlay_src = catdir( $test_dir, "overlay");
is( Spine::Util::makedir($overlay_src), $overlay_src, "makedir ($overlay_src)" );
my $overlay_dst = catdir( $test_dir, "overlay-dst");
is( Spine::Util::makedir($overlay_dst), $overlay_dst, "makedir ($overlay_dst)" );

$data->set( "c_tmpdir",  $test_dir );
$data->set( "c_tmplink", File::Spec->catdir( $tmp_dir, "spine-link" ) );

# does it create it's magic key ok?
Spine::Plugin::Overlay::init($data);
my $okey = $data->getkey(SPINE_OVERLAY_KEY);
isa_ok( $okey, "Spine::Plugin::Overlay::Key" );

# add an overlay
$okey->merge( { uri  => "some://uri/path",
                name => "test" } );

# get the bound overlays (hopefully zero)
my $items = $okey->get_bound();
is( scalar(@$items), 0, "No bound items" );

# bind an overlay
$okey->merge( { name => "test",
                bind => "/somewhere" } );
$items = $okey->get_bound();
is( scalar(@$items), 1, "One bound item" );

# add and bind in one (using simple syntax)
$okey->merge("another://uri/location");
$items = $okey->get_bound();
is( scalar(@$items), 2, "Two bound items" );

#check that they have the correct data
is( join( " ", map { $_->{name} } @$items ),
    "test another://uri/location",
    "Correct names" );

#check that they have the correct data
is( join( " ", map { $_->{path} } @$items ), "/somewhere /", "Correct paths" );


# Some tests require data from DescendOrder
Helpers::DescendOrder::init($data, $reg);

# test build_overlay. Not going to do much as no plugins are registers
is( Spine::Plugin::Overlay::build_overlay($data),
    PLUGIN_NOHOOKS, "build_overlays" );

# clear out all out test overlays
$okey->clear();

# TODO test out the rest of the overlay code in this kind of order...
# sync_attribs, find_changed, apply_overlay, clean_overlay, remove_tmpdir
## create some content
#open(FILE, ">" . catdir($overlay_src, "somefile"));
#print FILE "Test Data\n";
#close(FILE);
#
## bind an overlay
#$okey->merge( { name => "test overlay",
#                uri => "",
#                bind => "/somewhere" } );
