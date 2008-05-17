
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

package Spine::Plugin::BasicKeyTypes;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use YAML::Syck;
use JSON::Syck;
use XML::Parser;

# TODO: a whole lot more error checking and reporting of errors

our ($VERSION, $DESCRIPTION, $MODULE);
my $CPATH;

$VERSION = sprintf("%d.%02d", q$Revision: 22 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "BasicKeyTypes, some basic keytpes used for parsing keys";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'DISCOVERY/populate' => [ { name => "install_basic_keytypes", 
                                                   code => \&_install_keytypes } ],
                     },
          };


sub _install_keytypes {
    my $c = shift;


    $c->install_keytype("YAML", '^#?%YAML\s+1.0',\&_parse_yaml_key);
    $c->install_keytype("YAML not version 1.0", '^#?%YAML\s+(?:[^1]|1.[^0])',\&_not_supported);
    $c->install_keytype("JSON", '^#?%JSON',\&_parse_json_key);
    $c->install_keytype("XML", '^<\?xml.*\sversion.*\>',\&_parse_xml_key);

    # The following are place holders for an idea. We will need to thing about
    # the implications on  _evaluate_key within Data.pm fist. Also how to deal
    # with removing items from complex arrays/hashes... 
    $c->install_keytype("ARRAY", "^#?%ARRAY",\&_not_supported);
    $c->install_keytype("HASH", "^#?%HASH",\&_not_supported);

    return PLUGIN_SUCCESS;
}

sub _not_supported {
    my ($c, undef, $file, $name) = @_;

    $c->error("Key type within ($file) is not supported, $name");
    return undef;
}

sub _parse_yaml_key {
    my ($c, $buf, $file, $name) = @_;

    return YAML::Syck::Load($buf);
}

sub _parse_json_key {
    my ($c, $buf, $file, $name) = @_;

    return JSON::Syck::Load($buf);
}

sub _parse_xml_key {
    my ($c, $buf, $file, $name) = @_;

    my $obj = new XML::Parser;
    return $obj->parse($buf);
}

1;
