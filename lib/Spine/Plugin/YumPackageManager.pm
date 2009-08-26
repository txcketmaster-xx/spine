# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id$

# Copyright (C) 2009 MySpace, Inc.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# Notes:
#  Yum support thanks to Nic Simonds (nicolas.simonds@myspace-inc.com)
#  Requires yum-utils (namely yumdownloader) to work correctly.
#  The version of yum-utils that ships with RHEL 5.1 and workalikes is
#  singularly awful, and requires some patching to make it work, 5.2 and above
#  look more promising.  This plugin is really slow, and makes a couple of
#  assumptions that are only applicable on Intel-like architectures.

use strict;

package Spine::Plugin::YumPackageManager;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);
$DESCRIPTION = "RPM package management using the yumdownloader utility";

$MODULE = { author => 'nicolas.simonds@myspace-inc.com',
                       description => $DESCRIPTION,
                       version => $VERSION,
                       hooks => { APPLY => [ { name => 'install_packages',
                                               code => \&install_packages } ],
                                  CLEAN => [ { name => 'clean_packages',
                                               code => \&clean_packages } ]
                                },
          };


use Spine::RPM;
use Spine::Util qw(mkdir_p simple_exec);
use File::Basename;

my $DRYRUN = 0;

sub install_packages
{
    my $c = shift;
    my $rval = 0;

    $c->print(2, "checking for new packages");
    my @install = find_packages($c);

    if ( scalar @install > 0 )
    {
        my $inst = join (" ", map { basename($_, '.rpm') } @install);
        $c->print(2, "installing packages \[$inst\]");


        my @result = simple_exec(merge_error => 1,
                                 exec        => 'rpm',
                                 args        => ["-U",
                                                 "--quiet",
                                                 "--nosignature",
                                                 "--nodigest",
                                                 @install],
                                 c           => $c,
                                 inert       => 0);
                                     
        if ($? > 0)
        {
            $c->error("package install failed \[".join("", @result)."\]", 'err');
            $rval++;
        }
    }   

    return $rval ? PLUGIN_ERROR : PLUGIN_SUCCESS;
}

# find_packages() - given a list of package names, return a list of
#                   URLs for packages to install
#
# shell out to yumdownloader to do the depsolve on inbound packages,
# then compare against what is currently installed.
#
# yum's logging was apparently designed by throwing tennis balls at a
# keyboard from across the room and saving the results.  different
# modules use different names with little-to-no-consistency between them,
# and the logging manager object basically needs to guess what output
# channel to connect them all to.  as such, some errors go out stderr,
# and others go out stdout, but you'll never be able to tell what's
# an error message and what's not without looking at the output first.
# bravo, guys.  it looks like pre-release versions are fixing this,
# though.
#
# squish stdout and stderr together and sift through the wreckage, we'll
# assume any line ending in ".rpm" is valid output and everything else
# is an error message
#
sub find_packages {
    my $c = shift;
    my $rval = 0;    
    my %install;
    my @err;
    my %rpmlist;
    my $shoot_self_in_head = 0;

    # initialize a hash table of every possible permutation of an
    # RPM package name.  enjoy the abuse!
    #
    my $rpm = Spine::RPM->new();
    my $i = $rpm->db->find_all_iter();
    while (my $pkg = $i->next) {
    my @rpm = map { $pkg->tag($_) } qw/name version release arch/;
    $rpmlist{sprintf('%s-%s-%s.%s', @rpm)} = undef;
    $rpmlist{sprintf('%s-%s-%s', @rpm[0..2])} = undef;
    $rpmlist{sprintf('%s-%s', @rpm[0..1])} = undef;
    $rpmlist{$rpm[0]} = undef;

    my @yumdl_res = simple_exec(merge_error => 1,
                                exec => 'yumdl',
                                inert => 1,
                                args => ["--urls",
                                         "--resolve",
                                         "-e0",
                                         "-d0",
                                         @{$c->getvals('packages')}]);
     
    foreach my $x (@yumdl_res)
    {
        unless ($x =~ m/\.rpm$/)
        {
            # vet the error message for any "benign" errors
            # that should be ignored (e.g., sqlite warnings)
            next if $x =~ m'sqlite cache needs updating, reading in metadata';

            # it ran the gauntlet, something must really be wrong
            push @err, $x;
            next;
        }
        chomp($x);
        my $file = basename($x, '.rpm');
        unless (exists $rpmlist{$file})
        {
            $install{$x} = undef;
        }
    }
    if ($?)
    {
        $c->error("yumdl failed: $!", 'crit');
        $shoot_self_in_head++;
    }
    if (scalar @err > 0)
    {
        $c->error("@err", 'err');
        $shoot_self_in_head++;
    }
    die if $shoot_self_in_head;
    return keys %install;
}

sub clean_packages
{
    my $c = shift;
    my $rval = 0;
    
    # strip off yum-style package.arch architectures for anything
    # we'd install
    my @packages;
    foreach my $package (@{$c->getvals('packages')})
    {
        $package =~ s/\.(i\d86|x86_64|noarch)$//;
        push @packages, $package;
    }

    $c->print(2, "checking for unauthorized packages");
    my @remove = Spine::RPM->new->keep(@packages);

    if ( scalar @remove > 0 )
    {
        my $remv = join (" ", @remove);
        $c->print(2, "removing packages \[$remv\]");

        my @result = simple_exec(merge_error => 1,
                                 exec        => 'rpm',
                                 args        => ["-e",
                                                 "--allmatches",
                                                 $remv],
                                 c           => $c,
                                 inert       => 0);
                                     
        if ($? > 0)
        {
            $c->error("package removal failed \[".join("", @result)."\]", 'err');
            $rval++;
        }
    }
}
return $rval ? PLUGIN_ERROR : PLUGIN_SUCCESS;
}

1;
