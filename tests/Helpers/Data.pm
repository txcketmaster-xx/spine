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

package Helpers::Data;
use Spine::Data;
use Spine::Registry;
use Spine::Constants qw(:basic);
use File::Spec::Functions;

my %configs = (
              "basic" => { spine        => { Profile   => "fake_profile" },
                           fake_profile => { TestPoint => "TestCase" }, },
              "parselets" => {
                  spine            => { Profile => "parselet_profile" },
                  parselet_profile => {
                      "PARSE/key" => "Parselet::Basic"
                        . " Parselet::Complex"
                        . " Parselet::Operator"
                        . " Parselet::Dynamic"
                        . " Templates",
                      "PARSE/key/line"    => "Parselet::Operator",
                      "PARSE/key/complex" => "Parselet::JSON Parselet::Dynamic",
                      "PARSE/key/dynamic" => "Parselet::DNS", }, }, );

# a profile with the core plugins loaded
$configs{core_plugins} = { spine       => { Profile => "std_profile" },
                           std_profile => {
                                 "DISCOVERY/policy-selection" => "DescendOrder",
                                 "DISCOVERY/populate"         => "DescendOrder",
                                 %{ $configs{parselets}->{parselet_profile} } }
                         };

sub load_plugins {
    my ( $data, $registry ) = @_;

    my $config  = $data->getkey('c_config');
    my $profile = $config->{spine}->{Profile};

    while ( my ( $phase, $plugins ) = each( %{ $config->{$profile} } ) ) {
        my @plugins = split( /(?:\s*,?\s+)/, $plugins );
        foreach (@plugins) {
            unless ( $registry->load_plugin($_) == SPINE_SUCCESS ) {
                print STDERR "$phase: Failed to load ($_)!\n";
                return 0;
            }
        }
    }
    return 1;
}

# Allow more plugins to be loaded (fake the config some more)
sub add_plugin {
    my ( $data, $reg, $hook_point, $plugin ) = @_;
    my $config  = $data->getkey('c_config');
    my $profile = $config->{spine}->{Profile};
    if (exists $config->{$profile}->{$hook_point}) {
        $config->{$profile}->{$hook_point} .= " $plugin";
    } else {
        $config->{$profile}->{$hook_point} = "$plugin";
    }

}

# Load all hooks in a plugin automagically
# this beeing needed make me think we really need to redo reg
sub auto_load_plugin {
    my ($data, $reg, $plugin) = @_;
    # I know this may die, but that ok this is a test!
    $reg->load_plugin($plugin) || die("Could not load $plugin");
    # an magically load all hooks
    $plug = $reg->find_plugin($plugin);
    my $plug = $reg->{PLUGINS}->{$plug};
    foreach (keys %{$plug->{hooks}}) {
        add_plugin($data, $reg, $_, $plugin);
        $point = $reg->get_hook_point($_);
        $point->install_hook($plugin, $plug);
    }
    load_plugins($data, $reg);
}

sub new_data_obj {
    my $userconf = shift || "basic";
    my $croot    = shift || "test_root";

    my $conf = $configs{$userconf};

    my $reg = new Spine::Registry($conf);

    my $data = Spine::Data->new( croot   => $croot,
                                 config  => $conf,
                                 release => 1 );

    return undef unless load_plugins( $data, $reg );

    return $data, $reg;
}

1;
