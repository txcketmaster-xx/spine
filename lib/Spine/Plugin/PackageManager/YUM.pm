
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

# I really really recommend installing the meta parser plugin for yum,
# it will speed things up a lot.
#
# TODO: try to find a more direct YUM interface, or write a YUM plugin.
# a lot of this parsing of output will be prone to fail.
# TODO: CheckUpdate should probably only check for deps, new_deps and install
# items. Will need to be run just before the report
# TODO: pull out the regexs for parsing YUM so that it is easier to update
#
# XXX: there is lots of storing of 'version' in this code. It's there so
#      if we do ever get pinning in YUM we can use it.

package Spine::Plugin::PackageManager::YUM;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use IPC::Open3;
use Spine::Util qw(getbin);

our ($VERSION, $DESCRIPTION, $MODULE);
my $CPATH;

$VERSION = sprintf("%d.%02d", q$Revision: 22 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "PackageManager::YUM, YUM implementation";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => {
                       # Anything that we need to do at start up
                       "PKGMGR/Init"           => [ { name => 'YUM Init',
                                                      code => \&init_yum } ],
                       # Build a list of what needs to be updated
                       "PKGMGR/CheckUpdates"   => [ { name => 'YUM Check Update',
                                                      code => \&check_updates } ],
                       # Update installation
                       "PKGMGR/Update"         => [ { name => 'YUM Update',
                                                      code => \&apply_updates } ],
                       # Work out what is installed
                       "PKGMGR/Lookup"         => [ { name => 'YUM Lookup',
                                                      code => \&get_installed } ],
                       # Work out the deps of what is to be installed and resolve
                       # virtual provides
                       "PKGMGR/ResolveMissing" => [ { name => 'YUM Resolve',
                                                      code => \&check_missing } ],
                       # install missing packages
                       "PKGMGR/Install"        => [ { name => 'YUM Install',
                                                      code => \&install } ],
                       # remove packages
                       "PKGMGR/Remove"        => [ { name => 'YUM Remove',
                                                      code => \&remove } ],
                     },

          };

our $PKGPLUGNAME = 'YUM';
our $YUM_BIN;

sub _report_stderr {
    my ($c, $stderr) = @_;
    foreach (@{$stderr}) {
        $c->error("$_", 'err');
    }
}

sub init_yum {
    my ($c, $instance_conf, undef, $section) = @_;
    # Are we to deal with this?
    unless (exists $section->{$PKGPLUGNAME}) {
        return PLUGIN_SUCCESS;
    }

    $YUM_BIN = getbin('yum', $c->getvals('yum_bin'));
    unless (defined $YUM_BIN && -x $YUM_BIN) {
        $c->error("Could not find an yum executable");
        return PLUGIN_ERROR;
    }

    # TODO: make this read a db/config from the temp location
    # during dryrun
    # TODO: implement holding of package versions (with YUM good luck)
    return PLUGIN_FINAL;
}

sub get_installed {
    my ($c, $instance_conf, undef, $section) = @_;

    # Are we to deal with this?
    unless (exists $section->{$PKGPLUGNAME}) {
        return PLUGIN_SUCCESS;
    }

    my $s = $instance_conf->{store};

    # get yum to list the installed packages
    my $ret = run_yum(undef, "list installed");

    _report_stderr($c, $ret->{stderr});
    if ($ret->{rc} != 0) {
        return PLUGIN_ERROR;
    }

    my $node;
    foreach (@{$ret->{stdout}}) {
        chomp;
        if (m/([^\s]*)\.([^\.\s]+)\s*([^\s]+)\s.*$/) {
            # add the package into the installed store
            $s->create_node('installed',
                            'name', $1,
                            'arch', $2,
                            'version', $3);
        }
    }

    return PLUGIN_FINAL;
}

sub check_missing {
    my ($c, $instance_conf, undef, $section) = @_;

    # Are we to deal with this?
    unless (exists $section->{$PKGPLUGNAME}) {
        return PLUGIN_SUCCESS;
    }

    my $s = $instance_conf->{store};
    my @missing = $s->find_node('missing', 'name');
    # only carry on if there are any packages to resolve
    return PLUGIN_FINAL unless (@missing > 0);
    $c->cprint("Working out deps and provides for missing packages", 4);
    # XXX: not adding -y makes it like a dryrun...
    # FIXME: the only way to work out provides is with debug, this isn't nice
    my $ret = run_yum("N\n", "-d 4 install", $s->get_node_val('name',@missing));

    _report_stderr($c, $ret->{stderr});
    if ($ret->{rc} != 0) {
        return PLUGIN_ERROR;
    }
    
    my $node;
    my $type = undef;
    my %found;
    foreach (@{$ret->{stdout}}) {
        # Find virtual provide and file provide items (-d 3 needed)
        if (m/^Matched\s+([^\s]+)\s+\-\s+([^\s]+)\.([^\s\.]+)\s+to require for\s+([^\s]+)\s*$/) {
            $c->cprint("$1 provides for: ($4)", 4);
            $node = $s->find_node('missing', 'name', $4);
            # Is the item resolved a missing package?
            if ($node) {
                if ($s->find_node('installed', 'name', $1)) {
                    # Translate items that are virtual and installed into install
                    $s->create_node('install',
                                    'name', $1,
                                    'provides', $4,
                                    'version', $2,
                                    'arch', $3);
                    next;
                }
                # The result is not installed so install it
                $s->remove_node($node);
                $s->create_node('missing',
                                'name', $1,
                                'provides', $4,
                                'version', $2,
                                'arch', $3);
            } else {
                # It's not missing so it's a dep
                $s->create_node('new_dep',
                                'name', $1,
                                'version', $2,
                                'arch', $3);
            }
        } elsif (m/^-+>\s+Package\s+([^\s]+)\.([^\s\.]+)\s+[0-9]+:([^\s]*)\s+set to be updated/) {
            # note that this package has been resolved.
            $found{$1} = undef;
        }
    }

    # check is there is anything we couldn't work out
    MISSING: foreach ($s->get_node_val('name', $s->find_node('missing', 'name'))) { 
        next if exists $found{$_};
        # XXX: I don't like this but if you have a virtual provides installed already
        # the install doesn't show you that this was the case in the install output
        # so we manually check if there is a virtual for this missing package...
        $c->cprint("Package ($_), checking if this is a virtual name", 4);
        my $ret = run_yum(undef, "-d 3 resolvedep", $s->get_node_val('name',@missing));
        _report_stderr($c, $ret->{stderr});
        if ($ret->{rc} != 0) {
            $c->error("Could not find package ($_)", 'crit');
            next MISSING;
        }
        foreach (@{$ret->{stdout}}) {
            if (m/^Matched\s+([^\s]+)\s+\-\s+([^\s]+)\.([^\s\.]+)\s+to require for\s+([^\s]+)\s*$/) {
                $c->cprint("installed $1 provides for: ($4)", 4);
                $node = $s->find_node('missing', 'name', $4);
                $s->remove_node($node);
                $s->create_node('install',
                                'name', $1,
                                'provides', $4,
                                'version', $2,
                                'arch', $3);
                next MISSING;
            }
        }
        $c->error("Could not find package ($_)", 'crit');
    }

    return PLUGIN_FINAL;
}

sub remove {
    my ($c, $instance_conf, undef, $section) = @_;

    # Are we to deal with this?
    unless (exists $section->{$PKGPLUGNAME}) {
        return PLUGIN_SUCCESS;
    }

    my $s = $instance_conf->{store};

    # only carry on if there is anything to remove
    my @packages = $s->get_node_val('name', $s->find_node('remove', 'name'));
    if (@packages > 0) {
        $c->cprint(join(' ', "Removing:", @packages), 4);
        my $ret;
        if (exists $instance_conf->{dryrun}) {
           $ret = run_yum("N\n", "erase", @packages);
        } else {
           $ret = run_yum(undef, "-y erase", @packages);
        }

        _report_stderr($c, $ret->{stderr});
        if ($ret->{rc} != 0) {
            return PLUGIN_ERROR;
        }

        my (%removed, $line);
        foreach (@{$ret->{stdout}}) {
            if ($instance_conf->{dryrun}) {
                if (m/\s*([^\s]+)\s+.*\sinstalled\s/) {
                    $removed{$1} = undef;
                }
                next;
            } elsif (m/^Removed:(.*)$/ ) {
                $line = $1;
                $line =~ s/\s*([^\s]+)\.[^\.]+\s*[^\s]+(?=\s|$)/\1 /g;
                %removed = map { $_ => undef } split(/\s+/, $line);
            }
        }
        # Work out what we didn't remove
        foreach (@packages) {
            unless (exists $removed{$_}) {
                $c->error("Failed to remove ($_)", 'crit');
            }
        }
    }

    return PLUGIN_FINAL;
}

sub install {
    my ($c, $instance_conf, undef, $section) = @_;

    # Are we to deal with this?
    unless (exists $section->{$PKGPLUGNAME}) {
        return PLUGIN_SUCCESS;
    }


    my $s = $instance_conf->{store};
    # Is there anything to install?
    my @packages = $s->get_node_val('name', $s->find_node('missing', 'name'));
    my (%installed, @deps);
    if (@packages > 0) {
        $c->cprint(join(' ', 'Installing:', @packages), 4);
        return PLUGIN_FINAL if exists $instance_conf->{dryrun};
        # XXX: it will not report in anyway if you try to install something
        # that does not exist, you have to check output....
        my $ret = run_yum(undef, "-y install", @packages);

        _report_stderr($c, $ret->{stderr});
        if ($ret->{rc} != 0) {
            return PLUGIN_ERROR;
        }

        # Detect what actually got installed
        my ($line);
        foreach (@{$ret->{stdout}}) {
            if (m/^Installed:(.+)$/) {
                $line = $1;
                $line =~ s/\s*([^\s]+)\.[^\.]+\s*[^\s]+(?=\s|$)/\1 /g;
                %installed = map { $_ => undef } split(/\s+/, $line);
                $c->cprint(join(' ', "Installed:", keys(%installed)), 4);
                next;
            }
            if (m/^Dependency Installed:(.+)$/) {
                $line = $1;
                $line =~ s/\s*([^\s]+)\.[^\.]+\s*[^\s]+(?=\s|$)/\1 /g;
                @deps = split(/\s+/, $line);
                $c->cprint(join(' ', "Dependencies Installed:", @deps), 4);
            }
        }
    }

    # tell the user about anything that couldn't install
    foreach ($s->get_node_val('name', $s->find_node('missing', 'name'))) {
        next if (exists $installed{$_});
        $c->error("Unable to install ($_)", "crit");
    }

    return PLUGIN_FINAL;
}

sub check_updates {
    my ($c, $instance_conf, undef, $section) = @_;

    # Are we to deal with this?
    unless (exists $section->{$PKGPLUGNAME}) {
        return PLUGIN_SUCCESS;
    }

    my $s = $instance_conf->{store};
    my @packages = $s->get_node_val('name', $s->find_node('deps', 'name')),
                    $s->get_node_val('name', $s->find_node('new_deps', 'name')),
                    $s->get_node_val('name', $s->find_node('install', 'name'));

    #XXX: this will update everything if there are no packages. This is known
    #     and probably what you want if there is no package list at all....
    my $ret = run_yum(undef, "-y --obsoletes check-update", @packages);
    
    # A return of 0 means nothing to update
    return PLUGIN_FINAL if $ret->{rc} == 0;

    # A return of 100 just means that there are packages to update
    # FIXME: seems to return 25600 outside of a shell???
    _report_stderr($c, $ret->{stderr});
    if ($ret->{rc} != 25600) {
        return PLUGIN_ERROR;
    }

    foreach (@{$ret->{stdout}}) {
        chomp;
        if (m/^([^\s]+)\.[^\.]+\s+([^\s]+)\s+updates/){
            $s->create_node('updates', 'name', $1);
        }
    }
    return PLUGIN_FINAL;
}

sub apply_updates {
    my ($c, $instance_conf, undef, $section) = @_;

    # Are we to deal with this?
    unless (exists $section->{$PKGPLUGNAME}) {
        return PLUGIN_SUCCESS;
    }

    my $s = $instance_conf->{store};
    my @packages = $s->get_node_val('name', $s->find_node('updates', 'name'));
    if (@packages > 0) {
        $c->cprint(join(' ', 'Updating:', @packages), 4);
        return PLUGIN_FINAL if exists $instance_conf->{dryrun};
        my $ret = run_yum(undef, "-y update --obsoletes");
        _report_stderr($c, $ret->{stderr});
        if ($ret->{rc} != 0) {
            return PLUGIN_ERROR;
        }
    }

    return PLUGIN_FINAL;
}

sub run_yum {
    my $input = shift;
    my @args = @_;
    my $pid = -1;

    if (ref($_[0]) eq 'ARRAY')
    {
        # The plus sign is so that we actually call the shift function
        @args = @{ +shift };
    }
    my $ret = { rc => 127,
                stdout => [],
                stderr => [] };

    unless (-x $YUM_BIN) {
        $ret->{stderr} = "command not executable ($YUM_BIN)\n";
        return $ret;
    }

    my $cmdline = join(' ', $YUM_BIN, @args);

    # Reset our fh handles
    my $stdin  = new IO::Handle();
    my $stdout = new IO::Handle();
    my $stderr = new IO::Handle();

    # IPC::Open3::open3()  If the filehandles you pass in are
    # IO::Handle objects and the command to run is pass in as an array,
    # it won't exec the command line properly.  However, if you join() it
    # head of time, it'll run just fine.
    eval { $pid = open3($stdin, $stdout, $stderr, $cmdline); };

    # Siphon off output and error data so we can then waitpid() to reap
    # the child process
    print $stdin $input if defined $input;
    $stdin->close();

    push @{$ret->{stdout}}, $stdout->getlines();
    push @{$ret->{stderr}}, $stderr->getlines();

    my $rc = waitpid($pid, 0);

    if ($rc != $pid)
    {
        $ret->{stderr} = ["failed to fork command ($cmdline)"];
        return $ret;
    }

    $ret->{rc} = $?;

    return $ret;

}

1;
