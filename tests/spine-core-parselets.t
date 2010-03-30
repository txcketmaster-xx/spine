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
# Test that Spine::Registry + Spine::Data works as expected
use Test::More qw(no_plan);
use Spine::Data;
use Spine::Key;
use Helpers::Data;
use Spine::Constants qw(:basic :plugin);

my ( $data, $reg ) = Helpers::Data::new_data_obj("parselets");


# parse the key
# HOOKME Parselet expansion
my $registry = new Spine::Registry;
my $point    = $registry->get_hook_point('PARSE/key');

my $obj = new Spine::Key("test data\ntest data");
$obj->metadata_set( keyname     => "example_key",
                    description => "example_key key" );

# Test basic scalar to array ref conversion (Spine::Parselet::Basic)
my $rc;
$obj = $data->read_key($obj);
is( join( " ", @{ $obj->get() } ), "test data test data", "key data" )
;
# did it also make it into the tree in a hidden way?
is( join( " ", @{ $data->getvals("example_key") } ),
    "test data test data",
    "key data made it into Spine::Data" );


# Test that basic sclars are added to the array (Spine::Parselet::Operator)
$obj->set("some more data");
$obj = $data->read_key($obj, ["initial data"]);
is( join( " ", @{ $obj->get() } ),
    "initial data some more data",
    "key data after merge" );
# did it again make it into Spine::Data
is( join( " ", @{ $data->getvals("example_key") } ),
    "initial data some more data",
    "key data after merge is in Spine::Data" );

# Now lets test the remove syntax (both new and old style)
$obj->set("more\ndata\n-Some\nspine_remove(Silly)\nand me");
$obj = $data->read_key($obj, [ "Some", "Silly", "Data" ]);
is( join( " ", @{ $obj->get() } ),
    "Data more data and me",
    "key data after remove" );

$obj->set("=\nJust Me");
$obj = $data->read_key($obj, ["old data"]);

# check a json key
$obj->set("#%JSON\n{ foo: 'baa' }\n");
$obj = $data->read_key($obj);
is( $obj->get()->{foo}, "baa", "JSON/Complex decoded" );
