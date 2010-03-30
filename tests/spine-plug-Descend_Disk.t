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
use Helpers::DescendOrder;
use File::Spec::Functions;
use Spine::Constants qw(:basic :plugin :keys);
use Spine::Plugin::Descend::Disk;

# create a fake data obj using the "core_plugins" profile
my ( $data, $reg ) = Helpers::Data::new_data_obj("core_plugins");
# load out descend plugin
Helpers::Data::auto_load_plugin($data, $reg, "Descend::Disk");
# init descend order
Helpers::DescendOrder::init($data, $reg);
                          
print "Testing Spine::Plugin::Descend::Disk\n";

# does it hide the "include" key in the Spine::Data tree using a Blank key?
Spine::Plugin::Descend::Disk::reserve_key($data);
my $ikey = $data->getkey("include");
isa_ok( $ikey, "Spine::Key::Blank" );

# Attempt to reslove a disk based descend branch
$data->set("policy_hierarchy", "file:///");

# kick off descend order
Helpers::DescendOrder::run($data, $reg);
#Spine::Plugin::DescendOrder::create_order($data);

# search for the items that should have been added
# this also checks that Spine::Data still has the correct data.
my @items = @{$data->getvals(SPINE_HIERARCHY_KEY)};
my $found = 0;
my $should_be_removed = 0;
foreach (@items) {
    $found++
      if (    $_->{uri} eq "file:///config_group/test/"
           || $_->{uri} eq "file:///config_group/second_test/" );
    $should_be_removed++ if ( $_->{uri} eq "file:///config_group/to-remove/" );
}
is($found, 2, "Disk descend resolves as expected");
is($should_be_removed, 0, "Removal later in the order works");

