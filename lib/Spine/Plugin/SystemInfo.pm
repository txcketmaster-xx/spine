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

package Spine::Plugin::SystemInfo;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use Spine::Registry;

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d.%02d", q$Revision$ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Spine::Plugin system information harvester";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'DISCOVERY/populate'  => [ { name => 'sysinfo_init',
                                                    code => \&initialize,
                                                    position => HOOK_START, } ],
                     },
};

sub initialize {
    my $c = shift;

    my ($point, $rc, $platform);

    my $registry = new Spine::Registry();

    # Agnostic => any platform...
    # Platform => linux, macosx, bsd...
    $registry->create_hook_point(qw(Platform
                                    SystemInfo/Agnostic
                                    SystemInfo/Derived));

    $point = $registry->get_hook_point("SystemInfo/Agnostic");
    # HOOKME, go through ALL agnostic plugins
    $rc = $point->run_hooks_until(PLUGIN_FATAL, $c);
    if ($rc & PLUGIN_FATAL) {
        $c->error("An agnostic SystemInfo plugin failed", 'crit');
        return PLUGIN_ERROR;
    }

    # Only try to detect the platform if we don't know what it is...
    $platform = $c->getval('c_platform');
    unless (defined ($platform = $c->getval('c_platform'))) {
        $point = $registry->get_hook_point("Platform");
        # HOOKME, go through the platform plugins until we know what we are
        $rc = $point->run_hooks_until(PLUGIN_STOP, $c);
        if ($rc != PLUGIN_FINAL) {
            # Nothing implemented config for this instance...
            $c->error("Could not detect the platform", 'crit');
            return PLUGIN_ERROR;
        }
        $platform = $c->getval('c_platform');
    }

    # c_platform should now have been set...
    unless (defined $platform) {
        $c->error("The platform plugin failed to actually set c_platform", 'crit');
        return PLUGIN_ERROR;
    }

    $registry->create_hook_point("Platform/$platform");
    $point = $registry->get_hook_point("Platform/$platform");
    # HOOKME, go through the platform plugins until we know what we are
    $rc = $point->run_hooks_until(PLUGIN_STOP, $c);
    if ($rc & PLUGIN_FATAL) {
        # Nothing implemented config for this instance...
        $c->error("Error within a platform plugin", 'crit');
        return PLUGIN_ERROR;
    }

    # HOOKME, here is where you implement any derived information (based on above)
    $point = $registry->get_hook_point("SystemInfo/Derived");
    # HOOKME, go through ALL agnostic plugins
    $rc = $point->run_hooks_until(PLUGIN_FATAL, $c);
    if ($rc & PLUGIN_FATAL) {
        $c->error("A derive SystemInfo plugin failed", 'crit');
        return PLUGIN_ERROR;
    }

    return PLUGIN_SUCCESS;
}

1;
