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

package Spine::Plugin::Parselet::YAML;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use YAML::Syck;

# TODO: a whole lot more error checking and reporting of errors

our ($VERSION, $DESCRIPTION, $MODULE);
my $CPATH;

$VERSION = sprintf("%d.%02d", q$Revision: 22 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Parselet::YAML, processes YAML keys";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'PARSE/key/complex' => [ { name => "YAML", 
                                                  code => \&_parse_yaml_key ,
                                                  provides => ['YAML'] } ],
                     },
          };

sub _parse_yaml_key {
    my ($c, $data) = @_;

    # Skip refs, only scalars
    if (ref($data->{obj})) {
        return PLUGIN_SUCCESS;
    }

    if ( $data->{obj} =~ m/^#?%YAML\s+(\d+\.\d+)/ ) {
        return PLUGIN_ERROR if ($1 ne "1.0");

        $data->{obj} = YAML::Syck::Load($data->{obj});
        if (defined ($data->{obj})) {
            return PLUGIN_SUCCESS;
        }
        return PLUGIN_ERROR;
    }
    return PLUGIN_SUCCESS;
}

1;
