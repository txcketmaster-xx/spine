
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

package Spine::Plugin::Parselet::Dynamic;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);


our ($VERSION, $DESCRIPTION, $MODULE);
my $CPATH;

my $init = 0;

$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);
$DESCRIPTION = "Parselet::Dynamic, detects if the object can be expanded";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'PARSE/key' => [ { name => "Dynamic", 
                                          code => \&check_dynamic,
                                          provides => ['dynamic', 'PARSE/key/dynamic'] } ],
                     },
          };

# This means we only have to check if the key is dynamic once
# and cut's down the number of plugins we have to cascade through
sub check_dynamic {
    my ($c, $obj) = @_;

    my $data = $obj->get();
    
    # only hash refs  / complex
    unless (ref($data) eq 'HASH') {
        return PLUGIN_SUCCESS;
    }


    # we support both dynamix_type and advanced_type
    # If the object contains dynamic_type then we
    # will kick it through the PARSE/key/dynamic phase
    unless (exists $data->{dynamic_type} ||
            exists $data->{advanced_type}) {
        return PLUGIN_SUCCESS;
    }

    my $registry = new Spine::Registry();

    # HOOKME: Dynamic complex keys
    my $point = $registry->get_hook_point("PARSE/key/dynamic");
    # HOOKME, go through ALL dynamic plugins
    my $rc = $point->run_hooks_until(PLUGIN_FATAL, $c, $obj);
    if ($rc & PLUGIN_FATAL) {
        $c->error("There was a problem getting key data", 'crit');
        return PLUGIN_ERROR;
    }
    return PLUGIN_SUCCESS;
}

1;
