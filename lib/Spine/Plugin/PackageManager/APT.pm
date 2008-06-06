
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

package Spine::Plugin::PackageManager::APT;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use IPC::Open3;
use File::Spec::Functions;


our ($VERSION, $DESCRIPTION, $MODULE);
my $CPATH;

$VERSION = sprintf("%d.%02d", q$Revision: 22 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "PackageManager::APT, APT implementation";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => {
                       "PKGMGR/Init"           => [ { name => 'APT Init',
                                                      code => \&init_apt } ],
                       "PKGMGR/CheckUpdates"   => [ { name => 'APT Check Update',
                                                      code => \&check_update } ],
                       # Update installation
                       "PKGMGR/Update"         => [ { name => 'APT Update',
                                                      code => \&update } ],
                       # Work out the deps of what is to be installed and resolve
                       # virtual provides
                       "PKGMGR/ResolveMissing" => [ { name => 'APT Resolve',
                                                      code => \&check_missing } ],
                       # install missing packages
                       "PKGMGR/Install"        => [ { name => 'APT Install',
                                                      code => \&install } ],
                       # remove packages
                       "PKGMGR/Remove"        => [ { name => 'APT Remove',
                                                      code => \&remove } ],
                     },

          };

our $PKGPLUGNAME = 'APT';
our $APT_BIN = "/usr/bin/apt-get";
our $APTCACHE_BIN = "/usr/bin/apt-cache";
our $DRYRUN = undef; 

sub _report_stderr {
    my ($c, $stderr) = @_;
    foreach (@{$stderr}) {
        $c->error("$_", 'err');
    }
}

# Initialize the apt environment for this instance. Most of this code was
# stolen from the original package manager plugin.
sub init_apt {
    my ($c, $pic, undef, $section) = @_;
    # Are we to deal with this?
    unless (exists $section->{$PKGPLUGNAME}) {
        return PLUGIN_SUCCESS;
    }

    if (exists $pic->{dryrun}) {
        $DRYRUN=1;
    }
    my %default_conf = ( cache_dir => '/var/cache/apt',
                         state_dir => '/var/state/apt',
                         conf_dir => '/etc/apt',
                         aptget_args => [],
                         aptget_bin => $c->getval('apt_bin') || $APT_BIN,
                       );
    unless (defined $pic->{package_config}->{PKGPLUGNAME}) {
        $pic->{package_config}->{PKGPLUGNAME} = {};
    }
    my $conf = $pic->{package_config}->{PKGPLUGNAME};
    while (my ($key, $value) = each %default_conf) {
        $conf->{$key} = $value unless exists $conf->{$key};
    }
        

    my $apt_conf_dir = $conf->{conf_dir};
    if ($pic->{dryrun})
    {
        #
        # We need to create the full /var/state/apt/... and /var/cache/apt/...
        # hierarchy in the overlay so we can completely compartmentalize our
        # dry runs.
        # TODO: this should probably be pulled out of the config file...
        my $overlay = $c->getval('c_tmpdir');

        foreach my $dir (catfile($conf->{cache_dir}, '/archives/partial'),
                         catfile($conf->{state_dir}, '/lists/partial'))
        {
            unless (Spine::Util::mkdir_p(catfile($overlay, $dir)))
            {
                $c->{c_failure} = "Failed to create directory \"$dir\"";
                return PLUGIN_ERROR;
            }
        }
    
        my $apt_conf_dir = catfile($overlay, $conf->{conf_dir});
        #FIXME push @{$conf->{aptget_args}}, '--option Dir=' . $c->getval('c_tmpdir');
    }
    #FIXME icky hack to make sure we have either a confdir or a conf
    #Catch no config problems.
    unless (-s catfile($conf->{conf_dir}, 'apt.conf') ||
            -s catfile($apt_conf_dir, 'apt.conf') ||
            -d catfile($conf->{conf_dir}, 'apt.conf.d') || 
            -d catfile($apt_conf_dir, 'apt.conf.d')) {
        $c->error("Could not find apt config for config dir", 'crit');
        return PLUGIN_ERROR;
    }
    #
    # Simple loop to allow us to add command line switches easily.  We
    # must default to using the currently installed files or apt-get gets
    # all pissy about missing files due to the "--option Dir=..." tidbit
    # above.
    #
    # rtilder    Tue Apr 10 12:39:19 PDT 2007 
    #
    foreach my $file ( ( [ '--config-file', 'apt.conf' ],
                         [ '--option Dir::Etc::rpmpriorities',
                           'rpmpriorities' ],
                         [ '--option Dir::Etc::Parts', 'apt.conf.d' ],
                         [ '--option Dir::Etc::sourcelist',
                           'sources.list' ] ) ) {
        my $conffile = catfile($apt_conf_dir, $file->[1]);

        unless (-s $conffile) {
            $conffile = catfile($conf->{conf_dir}, $file->[1]);
            unless (-s $conffile) {
                #FIXME icky hack to make sure we have either a confdir or a conf
                next if ($file->[1] =~ m/^(?:apt\.conf|apt\.conf\.d)$/);
            }
        }
        push @{$conf->{aptget_args}}, "$file->[0]=$conffile";
    }

    my $ret = run_apt($conf, "update");
    _report_stderr($c, $ret->{stderr});
    if ($ret->{rc} != 0) {
        return PLUGIN_ERROR;
    }
    
    my $node;
    return PLUGIN_FINAL;
}

sub check_update {
    _update(1,@_);
}

sub update {
    _update(undef,@_);
}

# FIXME lots of duplication of _install
sub _update {

    my ($checkrun, $c, $instance_conf, undef, $section) = @_;
    # Are we to deal with this?
    unless (exists $section->{$PKGPLUGNAME}) {
        return PLUGIN_SUCCESS;
    }   
    my $aptconf = $instance_conf->{package_config}->{PKGPLUGNAME};
    my $s = $instance_conf->{store};
    # only carry on if there are any packages to resolve
    my $ret;
    if ($checkrun || exists $instance_conf->{dryrun}) {
        $ret = run_apt($aptconf, "--dry-run -y upgrade");
    } else { 
        $ret = run_apt($aptconf, "-y upgrade");
    }   
    
    _report_stderr($c, $ret->{stderr});
    if ($ret->{rc} != 0) {
        return PLUGIN_ERROR;
    }   
    
    # Check out what the deps are and that we can find all the packages...
    foreach (@{$ret->{stdout}}) {
        if (m/^Inst\s+([^\s]+)\s/) {
                if ($checkrun) {
                    $s->create_node('updates', 'name', $1);
                }   
        }       
    }   
    return PLUGIN_FINAL;
}    


    

sub _install {
    my ($checkrun, $c, $instance_conf, undef, $section) = @_;

    # Are we to deal with this?
    unless (exists $section->{$PKGPLUGNAME}) {
        return PLUGIN_SUCCESS;
    }
    my $aptconf = $instance_conf->{package_config}->{PKGPLUGNAME};
    my $s = $instance_conf->{store};
    my @missing = $s->get_node_val('name',$s->find_node('missing', 'name'));
    # only carry on if there are any packages to resolve
    return PLUGIN_FINAL unless (@missing > 0);
    $c->cprint("Working out deps and provides for missing packages", 4);
    my $ret;
    if ($checkrun || exists $instance_conf->{dryrun}) {
        $ret = run_apt($aptconf, "--dry-run -y install", @missing);
    } else {
        $ret = run_apt($aptconf, "-y install", @missing);
    }

    _report_stderr($c, $ret->{stderr});
    if ($ret->{rc} != 0) {
        return PLUGIN_ERROR;
    }
    
    my $node;
    my $type = undef;
    my %found;
    my %missing = map { $_ => undef } @missing;
    # Check out what the deps are and that we can find all the packages...
    foreach (@{$ret->{stdout}}) {
        if (m/^Inst\s+([^\s]+)\s+\((?:[0-9]+:)?([^\s]+)\s+.*$/) {
                if (exists $missing{$1}) {
                    $found{$1} = undef;
                } else {
                    $s->create_node('new_deps', 'name', $1, 'version', $2) if $checkrun;
                }
        }
    }

    # check is there is anything we couldn't work out
    # XXX: we might never get here as apt answers with a error unlike YUM
    foreach (@missing) {
        next if exists $found{$_};
        $c->cprint("Could not find package ($_)", 2);
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
    my $aptconf = $instance_conf->{package_config}->{PKGPLUGNAME};

    # only carry on if there is anything to remove
    my @packages = $s->get_node_val('name', $s->find_node('remove', 'name'));
    if (@packages > 0) {
        $c->cprint(join(' ', "Removing:", @packages), 4);
        my $ret;
        if (exists $instance_conf->{dryrun}) {
            $ret = run_apt($aptconf, "--dry-run -y remove", @packages);
        } else {
            $ret = run_apt($aptconf, "-y remove", @packages);
        }

        _report_stderr($c, $ret->{stderr});
        if ($ret->{rc} != 0) {
            return PLUGIN_ERROR;
        }

        my (%removed);
        foreach (@{$ret->{stdout}}) {
            if (m/^(?:Removing|Remv)\s+([^\s]+)\s+/ ) {
                $removed{$1} = undef;
            }
        }
        # Work out what we didn't remove
        foreach (@packages) {
            unless (exists $removed{$_}) {
                $s->create_node('remove_fail', 'name', $_);
                $c->cprint("Failed to remove ($_)", 2);
            }
        }
    }

    return PLUGIN_FINAL;
}

sub check_missing {
    _install(1, @_);
}

sub install {
    _install(undef, @_);
}

sub run_apt {
    my $conf = shift;
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

    my $cmdline = join(' ', $conf->{aptget_bin}, @{$conf->{aptget_args}}, @args);

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
