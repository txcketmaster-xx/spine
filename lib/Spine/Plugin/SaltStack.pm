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
                             EMIT => [ { name => 'overlay_metadata',
                                         code => \&overlay_metadata } ],
                           },
          };

use Spine::Util qw(simple_exec);
use File::Basename;
use File::Spec;
use File::Temp;

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


# A purpose-built plugin that uses saltstack to fix-up file
# ownerships/permissions/types in the temp overlays.  Required for
# setups like FileTree where the filesystem is mounted nodev, or where
# the configballs don't have proper ownerships applied.
sub overlay_metadata
{
    my $c = shift;
    my $overlay_dir = $c->getval('c_tmpdir');

    # emit a config file that points things in the right direction
    my $dir = File::Temp->newdir();
    $c->print(3, "using temp directory $dir");
    open(my $cfg, '>', File::Spec->catfile($dir->dirname, 'minion')) or
        return PLUGIN_ERROR;
    print $cfg <<EOF_MINION_CONFIG;
file_client: local
root_dir: $dir
log_level: warning
output: yaml
state_verbose: False
file_roots:
  base:
    - $dir
EOF_MINION_CONFIG
    close($cfg);

    # unserialize the metadata into a somewhat cogent data structure
    my %metadata;
    foreach my $line (@{ $c->getvals('spine_file_metadata') }) {
        chomp($line);
        $c->print(3, "candidate: $line");
        my ($path, $owner, $group, $mode) = split(':', $line);
        $path = File::Spec->catdir($overlay_dir, $path);
        next unless -e $path;
        $c->print(3, "found $path");
        $metadata{$path} = { 'owner' => 0, 'group' => 0, 'mode' => 0644 };
        $metadata{$path}->{'owner'} = $owner if $owner;
        $metadata{$path}->{'group'} = $group if $group;
        if ($mode) {
            $metadata{$path}->{'mode'} = oct($mode);
        } else {
            $metadata{$path}->{'mode'} |= 0111 if -d $path;
        }
    }

    # emit an SLS describing all the things needing fixing
    my $sls = File::Temp->new(DIR => $dir, UNLINK => 0, SUFFIX => '.sls');
    foreach my $path (keys %metadata) {
        my $owner = $metadata{$path}->{'owner'};
        my $group = $metadata{$path}->{'group'};
        my $mode = sprintf "%#o", $metadata{$path}->{'mode'};
        print $sls <<EOF_STATE;
# can't use the file state because the UGID might not be setup yet.
# this is actually simpler.
chmod -f $mode $path:
  cmd.run:
    - cwd: /
    - unless: test -h $path
chown -h -f $owner:$group $path:
  cmd.run:
    - cwd: /

EOF_STATE
    }
    close($sls);
    my ($state,) = fileparse($sls, '.sls');

    # the money shot
    my @res = simple_exec(merge_error => 1,
                          exec        => 'salt-call',
                          args        => ["--config-dir=$dir",
                                          'state.sls',
                                          $state],
                          c           => $c,
                          quiet       => 0,
                          inert       => 1);
    $c->print(3, @res);
    return PLUGIN_ERROR if ($? > 0);
}

1;
