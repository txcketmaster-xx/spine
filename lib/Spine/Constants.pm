# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
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

package Spine::Constants;
use base qw(Exporter);

our ($VERSION, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);

@EXPORT_OK = ();
%EXPORT_TAGS = ();

my $tmp;

use constant {
    PLUGIN_ERROR   => 1 << 0,
    PLUGIN_SUCCESS => 1 << 1,
    PLUGIN_FINAL   => 1 << 2,
    PLUGIN_EXIT    => 1 << 31,
    CHAIN_START    => "__START",
    CHAIN_MIDDLE   => "__MIDDLE",
    CHAIN_END      => "__END"
};
# This must be defined outside of the above hash block of PLUGIN_*.
# Don't change it.
use constant PLUGIN_FATAL => PLUGIN_ERROR | PLUGIN_EXIT;
# Both normal and error related reasons to stop running plugins
# this should never be returned from a plugin only used to match
use constant PLUGIN_STOP => PLUGIN_FATAL | PLUGIN_FINAL;

use constant {
    HOOK_START => CHAIN_START,
    HOOK_MIDDLE => CHAIN_MIDDLE,
    HOOK_END => CHAIN_END,
};

$tmp = [qw(CHAIN_START CHAIN_MIDDLE CHAIN_END)];;
push @EXPORT_OK, @{$tmp};
$EXPORT_TAGS{chain} = $tmp;

$tmp = [qw(PLUGIN_ERROR
           PLUGIN_EXIT
           PLUGIN_FATAL
           PLUGIN_STOP
           PLUGIN_FINAL
           PLUGIN_SUCCESS
	   HOOK_START
	   HOOK_MIDDLE
	   HOOK_END)];
push @EXPORT_OK, @{$tmp};
$EXPORT_TAGS{plugin} = $tmp;

use constant {
    SPINE_NOTRUN  => -1,
    SPINE_FAILURE => 0,
    SPINE_SUCCESS => 1
};

$tmp = [qw(SPINE_NOTRUN SPINE_FAILURE SPINE_SUCCESS)];
push @EXPORT_OK, @{$tmp};
$EXPORT_TAGS{basic} = $tmp;


1;
