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
use constant TIMEOUT   => 50;
use constant TEST_SIZE => 1000;
use Spine::Constants qw(:basic :chain);


# These will be called if there are missing requires or loops during tests
my %issue_cbs = (
    missing_cb => [
        sub {
            print STDERR "ERR: ($_[0]) requires missing ($_[1])\n";
          }
    ],
    loop_cb => [
        sub {
            print STDERR "ERR: loop detected " . join( "<-", @{$_[0]} ), "\n";
          }
    ] );

#
# Test that Spine::Chain works as expected
use Test::More qw(no_plan);

# Check we can use the module
BEGIN { use_ok('Spine::Chain'); }
require_ok('Spine::Chain');

my $chain = new Spine::Chain(%issue_cbs);
isa_ok( $chain, "Spine::Chain" );

my $item = 0;

# Test that we can add one item
is( $chain->add( name => "item_" . ++$item,
                 data => "item $item" ),
    SPINE_SUCCESS,
    "add one chain item" );

# Test that we can add one item
is( $chain->add( data => "item data" ),
    SPINE_FAILURE, "correct error when adding a bad item" );

# Test we cna add anohter 999 items
while ( $item < TEST_SIZE ) {
    $chain->add( name => "item_" . ++$item,
                 data => "item $item" ) == SPINE_SUCCESS
      or last;
}
is( $item, TEST_SIZE, "add " . ( TEST_SIZE - 1 ) . " items to the chain" );

my @items;

# Check that head returns 1000 items (as array then as hash)
eval {
    $SIG{ALRM} = sub { die "took too long" };
    alarm(TIMEOUT);
    @items = $chain->head();
    alarm(0);
};
ok( !$@, "call head (as array) within " . TIMEOUT . " seconds, $@" );
is( scalar(@items), TEST_SIZE, "head returns " . TEST_SIZE . " items" );
is( ref( $chain->head() ), "HASH", "call head (as scalar)" );

# Check that the order is the same since no extra order info
# was given i.e. tsort didn't reverse things
my $p = 0;
foreach (@items) {
    $p++;
    last if ( $_ ne "item $p" );
}
is( $p, TEST_SIZE, "insert order for " . TEST_SIZE . " items" );

# Test succedes
$chain = new Spine::Chain(%issue_cbs);
$chain->add( name => "test_1", data => "item 1" );
$chain->add( name     => "test_2",
             succedes => [ "test_4", "test_3" ],
             data     => "item 2" );
$chain->add( name => "test_3", data => "item 3" );
$chain->add( name => "test_4", data => "item 4" );
$chain->add( name => "test_5", data => "item 5" );
$chain->add( name     => "test_6",
             succedes => ["test_1"],
             data     => "item 6" );
is( join( ":", ( $chain->head() ) ),
    "item 1:item 4:item 3:item 2:item 5:item 6",
    "succedes ordering" );

# Test precedess
$chain = new Spine::Chain(%issue_cbs);
$chain->add( name => "test_0", data => "item 0" );
$chain->add( name => "test_1", data => "item 1" );
$chain->add( name     => "test_2",
             succedes => [ "test_4", "test_3" ],
             data     => "item 2" );
$chain->add( name => "test_3", data => "item 3" );
$chain->add( name => "test_4", data => "item 4" );
$chain->add( name => "test_5", data => "item 5" );
$chain->add( name     => "test_6",
             precedes => [ "test_1", "test_3" ],
             data     => "item 6" );
is( join( ":", ( $chain->head() ) ),
    "item 0:item 6:item 1:item 4:item 3:item 2:item 5",
    "precedess+succedes ordering" );

# Test Rules
$chain = new Spine::Chain(%issue_cbs);

# Create an order so items that provide SOMETHING_BEFORE come before
# SOMETHING with comes before SOMETHING_AFTER
$chain->add_provide_rule( provide  => "SOMETHING",
                          succedes => ["SOMETHING_BEFORE"],
                          precedes => ["SOMETHING_AFTER"] );
$chain->add_provide_rule( provide  => "SOMETHING_AFTER",
                          succedes => [ "SOMETHING", "SOMETHING_BEFORE" ] );

$chain->add( name     => "test_0",
             data     => "item 0",
             provides => ["SOMETHING_AFTER"] );
$chain->add( name => "test_1", data => "item 1", provides => ["SOMETHING"] );
$chain->add( name     => "test_2",
             succedes => [ "test_4", "test_3" ],
             data     => "item 2",
             provides => ["SOMETHING"] );
$chain->add( name => "test_3", data => "item 3", provides => ["SOMETHING"] );
$chain->add( name => "test_4", data => "item 4", provides => ["SOMETHING"] );
$chain->add( name => "test_5", data => "item 5", provides => ["SOMETHING"] );
$chain->add( name     => "test_6",
             precedes => [ "test_1", "test_3" ],
             data     => "item 6",
             provides => ["SOMETHING"] );
$chain->add( name     => "test_7",
             data     => "item 7",
             provides => ["SOMETHING_BEFORE"] );
is( join( ":", ( $chain->head() ) ),
    "item 7:item 6:item 1:item 4:item 3:item 2:item 5:item 0",
    "precedess+succedes+rule ordering" );

# provides and requires
$chain = new Spine::Chain(%issue_cbs);
$chain->add_provide_rule( provide  => "SOMETHING",
                          succedes => ["SOMETHING_BEFORE"],
                          precedes => ["SOMETHING_AFTER"] );
$chain->add_provide_rule( provide  => "SOMETHING_AFTER",
                          succedes => [ "SOMETHING", "SOMETHING_BEFORE" ] );

$chain->add( name     => "test_0",
             data     => "item 0",
             provides => ["SOMETHING_AFTER"] );
$chain->add( name => "test_1", data => "item 1", provides => ["SOMETHING"] );
$chain->add( name     => "test_2",
             succedes => [ "test_4", "test_3" ],
             data     => "item 2",
             provides => [ "SOMETHING", ] );
$chain->add( name => "test_3", data => "item 3", provides => ["SOMETHING"] );
$chain->add( name => "test_4", data => "item 4", provides => ["SOMETHING"] );
$chain->add( name     => "test_5",
             data     => "item 5",
             provides => ["SOMETHING"],
             requires => ["foo"] );
$chain->add( name     => "test_6",
             precedes => [ "test_1", "test_3" ],
             data     => "item 6",
             provides => ["SOMETHING"] );
$chain->add( name     => "test_7",
             data     => "item 7",
             provides => ["SOMETHING_BEFORE"] );
$chain->add( name     => "test_8",
             data     => "item 8",
             provides => [ "SOMETHING", "foo" ] );
is( join( ":", ( $chain->head() ) ),
    "item 7:item 6:item 1:item 4:item 3:item 2:item 8:item 5:item 0",
    "precedess+succedes+rule+provides+requires ordering" );

# Test merge_deps
$chain = new Spine::Chain( merge_deps => 1,
                           %issue_cbs );
$chain->add( name => "test_1", data => "item 1" );
$chain->add( name => "test_2", data => "item 2" );
$chain->add( name => "test_3", data => "item 3", precedes => ["test_2"] );
is( join( ":", ( $chain->head() ) ), "item 1:item 3:item 2", "pre merge test" );
$chain->add( name     => "test_3",
             data     => "item 3 updated",
             precedes => ["test_1"] );
is( join( ":", ( $chain->head() ) ),
    "item 3 updated:item 1:item 2",
    "post merge test" );

# Test remove_orphans
$chain = new Spine::Chain( remove_orphans => 1,
                           %issue_cbs );
$chain->add( name => "test_0", data => "item 0" );
$chain->add( name => "test_1", data => "item 1", succedes => ["foo"] );
$chain->add( name => "test_2", data => "item 2", succedes => ["test_1"] );
$chain->add( name => "test_3", data => "item 3", succedes => ["test_2"] );
$chain->add( name => "test_4", data => "item 4", succedes => ["test_0"] );
is( join( ":", ( $chain->head() ) ), "item 0:item 4", "orphan removal" );
