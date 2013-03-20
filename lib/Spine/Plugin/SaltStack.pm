# Copyright (C) 2013 Nicolas Simonds
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use strict;

package Spine::Plugin::SaltStack;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = 1.0;
$DESCRIPTION = 'Configuration management via SaltStack';

$MODULE = { author      => 'nic@submedia.net',
            description => $DESCRIPTION,
            version     => $VERSION,
            hooks       => { APPLY => [ { name => 'saltstack',
                                          code => \&saltstack } ],
                           },
          };

use Spine::Util qw(simple_exec);

sub saltstack
{
    my $c = shift;

    # If using grains and/or pillar data for host matching, it is
    # best practice to sync all dynamic data from the master before
    # running, to ensure that all definitions are up-to-date
    #
    $c->print(2, "syncing salt minion data");
    print simple_exec(merge_error => 1,
                      exec        => 'salt-call',
                      args        => ['--log-level=warning',
                                      '--out=yaml',
                                      'saltutil.sync_all',],
                      c           => $c,
                      quiet       => 0,
                      inert       => 0);
    return PLUGIN_ERROR if ($? > 0);

    # Run state.highstate and print the results.  Coerce into YAML
    # format so that we don't have to worry about how spine handles
    # the clown-colored default output
    $c->print(2, "applying salt highstate");
    print simple_exec(merge_error => 1,
                      exec        => 'salt-call',
                      args        => ['--log-level=warning',
                                      '--out=yaml',
                                      'state.highstate',],
                      c           => $c,
                      quiet       => 0,
                      inert       => 0);
    return PLUGIN_ERROR if ($? > 0);

    return PLUGIN_SUCCESS;
}


1;
