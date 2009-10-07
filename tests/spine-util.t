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
use Helpers::Data;
use File::Spec::Functions;
use Spine::Constants qw(:basic);

my ($data, $reg) = Helpers::Data::new_data_obj();
isa_ok($data, "Spine::Data");

print "Testing Spine::Util\n";

# Check we can use the module
BEGIN { use_ok('Spine::Util');
        use_ok('Spine::Util::Exec') }
require_ok('Spine::Util');
require_ok('Spine::Util::Exec');

ok(my $tmp_dir = File::Spec->tmpdir(), "get a tmp dir");

ok(chdir($tmp_dir), "change to tmp");

#Test  mkdir_p
my $dir = File::Spec->catdir($tmp_dir, "spine_tests", "something");
ok(Spine::Util::mkdir_p($dir), "mkdir_p ($dir)");
ok(chdir("spine_tests"), "chdir ($dir)");
rmdir($dir);

# Test makedir
$dir = catdir($tmp_dir, "spine_tests", "somethingelse");
is(Spine::Util::makedir($dir), $dir, "makedir ($dir)");
rmdir($dir);

# Test find_exec
my $file_name = "examplefile";
my $file = catfile($tmp_dir, "spine_tests", $file_name);
open(FILE, ">$file");
close(FILE);
ok(chmod(0755, "$file"), "created executable ($file_name)");
ok(!Spine::Util::find_exec($data, $file_name), "find_exec error return");
$data->{$file_name.Spine::Util::Exec::EXEC_KEY_EXTN} = $file;
is(Spine::Util::find_exec($data, $file_name),
   $file, "find_exec " . $file_name . Spine::Util::Exec::EXEC_KEY_EXTN." key");
delete $data->{$file_name.Spine::Util::Exec::EXEC_KEY_EXTN};
$data->{+Spine::Util::Exec::COMPLEX_EXEC_KEY} = {$file_name => $file};
is(Spine::Util::find_exec($data, $file_name),
   $file, "find_exec ". Spine::Util::Exec::COMPLEX_EXEC_KEY . " key");
delete $data->{+Spine::Util::Exec::COMPLEX_EXEC_KEY};
$data->{+Spine::Util::Exec::SPINE_PATH_KEY} = [catdir($tmp_dir, "spine_tests")];
is(Spine::Util::find_exec($data, $file_name),
   $file, "find_exec ". +Spine::Util::Exec::SPINE_PATH_KEY . " key");
delete $data->{+Spine::Util::Exec::SPINE_PATH_KEY};
is(Spine::Util::find_exec($data, $file_name, "randomesomethign",
                         catdir($tmp_dir, "spine_tests")),
   $file, "find_exec path as arg");
unlink($file);

### Test Spine::Util::Exec
$data->{dryrun} = 0;

my %config = (c     => $data,
              exec  => "echo",
              quiet => 1,
              args  => [ "-ne", 'test 1\ntest 2\ntest 3' ],
              inert => 0);

my $exec_controler = Spine::Util::create_exec(%config);
ok($exec_controler, "create a exec controler (Spine::Util::Exec)");
ok($exec_controler->start(), "start: run command");
is($exec_controler->lasterror(), undef, "command started");

#readlines
my @res = $exec_controler->readlines();
is($res[0], "test 1\n", "readlines: check output line 1");
is($res[1], "test 2\n", "readlines: check output line 2");
is($res[2], "test 3", "readlines: check output line 3");

# readline
$exec_controler = Spine::Util::create_exec(%config);
ok($exec_controler->start(), "start: run command");
is($exec_controler->readline(), "test 1\n", "readline: check output line 1");
is($exec_controler->readline(), "test 2\n", "readline: check output line 2");
is($exec_controler->readline(), "test 3", "readline: check output line 3");

# input
$config{exec} = "cat";
$config{args} = "-";
$exec_controler = Spine::Util::create_exec(%config);
ok($exec_controler->start(), "start: run command");
is($exec_controler->readline(1), undef, "readline: timeout test");
ok($exec_controler->input("test text\n"),"input: send input");
is($exec_controler->readline(), "test text\n", "readline: check output");
ok($exec_controler->input("test more text\n"),"input: send input");
is($exec_controler->readline(), "test more text\n", "readline: check output");
ok($exec_controler->input("unfinished line"),"input: send input");
is($exec_controler->readline(1), undef, "readline: timeout test");
ok($exec_controler->isrunning(), "isrunning: check if it's still running");
ok($exec_controler->closeinput(), "colseinput: close input");
sleep(1);
is($exec_controler->isrunning(), 0, "isrunning: check if it's now stopped");
is($exec_controler->exitstatus(), 0, "exitstatus: did it exit cleanly");



# Cleanup
rmdir(catdir($tmp_dir, "spine_tests"));
