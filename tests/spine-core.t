#!/usr/bin/perl -w
use strict;
#
# Test that Spine::Registry works as expected
use Test::More qw(no_plan);
use Spine::Data;

use Spine::Constants qw(:basic :plugin);

# Check we can use the module
BEGIN { use_ok('Spine::Registry'); }
require_ok('Spine::Registry');

# Create a fake config object
my $conf = {
    spine => { Profile => "fake_profile" },
    fake_profile => { TestPoint => "TestCase" },
};
my $reg = new Spine::Registry($conf);
isa_ok($reg, "Spine::Registry");

my $data = new Spine::Data ( croot => "whatever",
                             config => $conf,
                             release => 1);


# Attempt to load the Spine::Plugin::TestCase
is($reg->load_plugin("TestCase"), SPINE_SUCCESS, "register plugin");

# Attempt to create a hook point
ok($reg->create_hook_point("TestPoint"), "create hook point");

# get hook point
my $point = $reg->get_hook_point("TestPoint");
isa_ok($point, "Spine::Registry::HookPoint");

is($point->register_hooks(), SPINE_SUCCESS, "register hooks");
foreach my $hook (@{$point->{hooks}}) {
    ok($hook, "retrive a hook");
    is($point->run_hook($hook, $data, "test_data"),
       PLUGIN_SUCCESS, "run plugin for point");
}
   
my ($results, $rc, $errs) = $point->run_hooks_until(PLUGIN_SUCCESS, $data, "test_data");
is($rc, PLUGIN_SUCCESS, "run_hooks_until (rc)");
is($errs, 0, "run_hooks_until (error count)");
is($results->[0]->[0], "test",  "run_hooks_until (name return)");
