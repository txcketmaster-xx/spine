#!/usr/bin/perl -w
use strict;
use constant TIMEOUT => 5;
use constant TEST_SIZE => 1000;
use Spine::Constants qw(SPINE_FAILURE SPINE_SUCCESS HOOK_START HOOK_MIDDLE HOOK_END);
#
# Test that Spine::Chain works as expected
use Test::More qw(no_plan);

# Check we can use the module
BEGIN { use_ok('Spine::Chain'); }
require_ok('Spine::Chain');

my $chain = new Spine::Chain;
isa_ok($chain, "Spine::Chain");


my $item=0;
# Test that we can add one item
is($chain->add( name => "item_".++$item,
                data => "item $item"),
   SPINE_SUCCESS,
   "add one chain item");

# Test that we can add one item
is($chain->add( data => "item data"),
   SPINE_FAILURE,
   "correct error when adding a bad item");

# Test we cna add anohter 999 items
while ($item < TEST_SIZE) {
    $chain->add( name => "item_".++$item,
                 data => "item $item") == SPINE_SUCCESS or last;
}
is($item, TEST_SIZE, "add ".(TEST_SIZE - 1)." items to the chain");

my @items;
# Check that head returns 1000 items (as array then as hash)
eval {
   $SIG{ALRM} = sub { die "took too long" };
   alarm(TIMEOUT);
   @items = $chain->head();
   alarm(0);
};
ok(!$@, "call head (as array) within ".TIMEOUT." seconds");
is(scalar(@items), TEST_SIZE, "head returns ".TEST_SIZE." items");
is(ref($chain->head()), "HASH", "call head (as scalar)");

# Check that the order is the same since no extra order info
# was given i.e. tsort didn't reverse things
my $p=0;
foreach (@items) {
    $p++;
    last if ($_ ne "item $p");
}
is($p, TEST_SIZE, "insert order for ".TEST_SIZE." items");


# Test predecessors
$chain = new Spine::Chain;
$chain->add(name => "test_1", data => "item 1");
$chain->add(name => "test_2",
            predecessors => [ "test_4", "test_3" ],
	    data => "item 2");
$chain->add(name => "test_3", data => "item 3");
$chain->add(name => "test_4", data => "item 4");
$chain->add(name => "test_5", data => "item 5");
$chain->add(name => "test_6",
            predecessors => [ "test_1" ],
	    data => "item 6");
is (join(":", ($chain->head())),
    "item 1:item 4:item 3:item 2:item 5:item 6",
    "predecessors ordering");

# Test successors
$chain = new Spine::Chain;
$chain->add(name => "test_0", data => "item 0");
$chain->add(name => "test_1", data => "item 1");
$chain->add(name => "test_2",
            predecessors => [ "test_4", "test_3" ],
	    data => "item 2");
$chain->add(name => "test_3", data => "item 3");
$chain->add(name => "test_4", data => "item 4");
$chain->add(name => "test_5", data => "item 5");
$chain->add(name => "test_6",
            successors => [ "test_1", "test_3" ],
	    data => "item 6");
is (join(":", ($chain->head())),
    "item 0:item 6:item 1:item 4:item 3:item 2:item 5",
    "successors+predecessors ordering");

# Test positon
$chain = new Spine::Chain;
$chain->add(name => "test_0", data => "item 0",
            position => HOOK_END);
$chain->add(name => "test_1", data => "item 1");
$chain->add(name => "test_2",
            predecessors => [ "test_4", "test_3" ],
	    data => "item 2");
$chain->add(name => "test_3", data => "item 3");
$chain->add(name => "test_4", data => "item 4");
$chain->add(name => "test_5", data => "item 5");
$chain->add(name => "test_6",
            successors => [ "test_1", "test_3" ],
	    data => "item 6");
$chain->add(name => "test_7", data => "item 7",
            position => HOOK_START);
is (join(":", ($chain->head())),
    "item 7:item 6:item 1:item 4:item 3:item 2:item 5:item 0",
    "successors+predecessors+position ordering");

# provides and requires
$chain = new Spine::Chain;
$chain->add(name => "test_0", data => "item 0",
            position => HOOK_END);
$chain->add(name => "test_1", data => "item 1");
$chain->add(name => "test_2",
            predecessors => [ "test_4", "test_3" ],
	    data => "item 2");
$chain->add(name => "test_3", data => "item 3");
$chain->add(name => "test_4", data => "item 4");
$chain->add(name => "test_5", data => "item 5",
            requires => ["foo"]);
$chain->add(name => "test_6",
            successors => [ "test_1", "test_3" ],
	    data => "item 6");
$chain->add(name => "test_7", data => "item 7",
            position => HOOK_START);
$chain->add(name => "test_8", data => "item 8",
            provides => ["foo"]);
is (join(":", ($chain->head())),
    "item 7:item 6:item 1:item 4:item 3:item 2:item 8:item 5:item 0",
    "successors+predecessors+position+provides&requires ordering");

