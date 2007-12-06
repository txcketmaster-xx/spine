# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: PrintData.pm,v 1.1.2.7.2.1 2007/09/11 21:28:00 rtilder Exp $

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

our ($VERSION, $DESCRIPTION, $MODULE, $PRINTDATA, $WITHAUTH, $USEYAML);

$VERSION = sprintf("%d.%02d", q$Revision: 1.1.2.7.2.1 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Features for debugging Spine data";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'PARSE/complete' => [ { name => 'key_dump',
                                               code => \&key_dump } ],
                       'PREPARE' => [ { name => 'printdata',
                                        code => \&printdata } ]
                     },
            cmdline => { options => { printdata => \$PRINTDATA,
                                      'with-auth' => \$WITHAUTH,
                                      'use-yaml' => \$USEYAML } }
          };


sub printdata
{
    my $c = shift;
    my $objects = [$c];
    my $names = [ref($c)];

    # Short circuit if we weren't passed the command line option.
    unless ($PRINTDATA) {
        return PLUGIN_SUCCESS;
    }

    # Make sure we don't save state
    $::SAVE_STATE = 0;

    if ($WITHAUTH) {
        require Spine::Plugin::Auth;
        push @{$objects}, $Spine::Plugin::Auth::AUTH;
        push @{$names}, 'Spine::AuthData';
    }

    if ($USEYAML) {
        require YAML;
        require YAML::Dumper;
        my $d = new YAML::Dumper(indent_width => 4);

        foreach (@{$objects}) {
            print $d->dump($_);
        }
    }
    else {
        require Data::Dumper;
        $Data::Dumper::Sortkeys = 1;
        my $d = new Data::Dumper($objects, $names);
        print $d->Dump();
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
