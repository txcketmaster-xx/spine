
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: DNS.pm 318 2010-03-30 15:39:16Z richard $

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

package Spine::Plugin::Parselet::AdvancedKey;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ( $VERSION, $DESCRIPTION, $MODULE );
my $resolver;

$VERSION     = sprintf( "%d", q$Revision: 318 $ =~ /(\d+)/ );
$DESCRIPTION = "Parselet::AdvancedKey, Allows the user to load in advanced keys";

$MODULE = { author      => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version     => $VERSION,
            hooks       => {
                       'PARSE/key/dynamic' => [ { name     => "AdvancedKey",
                                                  code     => \&advanced_key,
                                                  provides => ['advanced_key'] }
                                              ], }, };

sub advanced_key {
    my ( $c, $obj, undef, $result_ref ) = @_;

    my $data = $obj->get();

    # Is it for us?
    unless ( $data->{advanced_type} =~ m/^(?:spine::)?key$/i ) {
        return PLUGIN_SUCCESS;
    }


    # the key type must be set and valid
    return PLUGIN_ERROR
      unless ( exists $data->{key}
               && $data->{key} =~ m/^[a-zA-Z]+$/ );

    my $plugin = "Spine::Key::$data->{key}";
    eval "require $plugin";

    if ($@) {
        $c->error("Failed to find or load $plugin");
        return PLUGIN_ERROR;
    }

    # We set the return ref to our new key
    $$result_ref = new $plugin;

    return PLUGIN_SUCCESS;
}

1;
