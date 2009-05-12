
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Skeleton.pm 22 2007-12-12 00:35:55Z phil@ipom.com $

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

package Spine::Plugin::Parselet::Complex;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);


our ($VERSION, $DESCRIPTION, $MODULE);
my $CPATH;

my $init = 0;

$VERSION = sprintf("%d.%02d", q$Revision: 22 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Parselet::Complex, detects if the buffer is a complex key";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'PARSE/key' => [ { name => "Complex", 
                                          code => \&check_complex,
                                          provides => ['complex'] } ],
                     },
          };

sub create_phase {

    my $registry = shift;

    $registry->create_hook_point(qw(PARSE/key/complex));

    # We only want to do this once...
    $init = 1;
}


# This means we only have to check if the key is complex once
# and cut's down the number of plugins we have to cascade through
sub check_complex {
    my ($c, $data) = @_;

    # only scalars
    if (ref($data->{obj})) {
        return PLUGIN_SUCCESS;
    }

    # If the object contains something that looks
    # like an indication of a complex type we parse it
    # it's not a problem if we make a mistake however.
    unless ($data->{obj} =~ m/^#?%/) {
        return PLUGIN_SUCCESS;
    }

    my $registry = new Spine::Registry();
    # If this is the first one we have to create the
    # hook point
    create_phase($registry) unless ($init);
    # HOOKME: Complex keys
    my $point = $registry->get_hook_point("PARSE/key/complex");
    # HOOKME, go through ALL complex plugins
    my $rc = $point->run_hooks_until(PLUGIN_FATAL, $c, $data);
    if ($rc & PLUGIN_FATAL) {
        $c->error("There was a problem processing key data", 'crit');
        return PLUGIN_ERROR;
    }
    return PLUGIN_SUCCESS;
}

1;
