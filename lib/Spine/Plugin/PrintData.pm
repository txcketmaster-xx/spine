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

package Spine::Plugin::PrintData;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE, $PRINTALL, $PRINTDATA, $PRINTAUTH, $YAML);

$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);
$DESCRIPTION = "Features for debugging Spine data";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'PARSE/complete' => [ { name => 'key_dump',
                                               code => \&key_dump } ],
                       'PREPARE' => [ { name => 'printdata',
                                        code => \&printdata } ]
                     },
            cmdline => { options => { 'printdata|spinaltap' => \$PRINTDATA,
                                      'printauth|with-auth' => \$PRINTAUTH,
                                      'yaml' => \$YAML,
                                      'printall' => \$PRINTALL } }
          };


sub printdata
{
    my $c = shift;
    my $objects = [$c];
    my $names = [ref($c)];

    # Short circuit if we weren't passed the command line options.
    unless ($PRINTALL|$PRINTDATA|$PRINTAUTH)
    {
        return PLUGIN_SUCCESS;
    }

    # Make sure we don't save state
    $::SAVE_STATE = 0;

    require Data::Dumper;
    $Data::Dumper::Sortkeys = 1;

    if ($YAML) {
        require YAML::Syck;
        $YAML::Syck::SortKeys = 1;
    }

    if ($PRINTALL|$PRINTDATA)
    {
        if ($YAML) {
            print YAML::Syck::Dump($c);
        } else {
            my $data = new Data::Dumper($objects, $names);
            print $data->Dump();
        }
    }
    if ($PRINTALL|$PRINTAUTH)
    {
        require Spine::Plugin::Auth;
        if ($YAML) {
            print YAML::Syck::Dump($Spine::Plugin::Auth::AUTH);
        } else {
            my $data = new Data::Dumper([$Spine::Plugin::Auth::AUTH], \
                ['Spine::AuthData']);
            print $data->Dump();
        }
    }

    return PLUGIN_EXIT;
}


sub key_dump
{
    my $c = shift;

    if ($c->getval('c_verbosity') >= 3) {
        # Print out the entire list of available keys.
        my $keylist = join(' ', sort(keys %{$c}));
        $c->print(3, "available keys: $keylist");
    }

    return PLUGIN_SUCCESS;
}


1;
