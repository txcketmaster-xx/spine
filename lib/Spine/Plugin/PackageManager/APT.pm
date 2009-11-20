
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
use Spine::Util;
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
                       "PKGMGR/Init/APT"           => [ { name => 'APT Init',
                                                      code => \&init_apt } ],
                       "PKGMGR/CheckUpdates/APT"   => [ { name => 'APT Check Update',
                                                      code => \&check_update } ],
                       # Update installation
                       "PKGMGR/Update/APT"         => [ { name => 'APT Update',
                                                      code => \&update } ],
                       # Work out the deps of what is to be installed and resolve
                       # virtual provides
                       "PKGMGR/ResolveMissing/APT" => [ { name => 'APT Resolve',
                                                      code => \&_check_missing } ],
                       # install missing packages
                       "PKGMGR/Install/APT"        => [ { name => 'APT Install',
                                                      code => \&install } ],
                       # remove packages
                       "PKGMGR/Remove/APT"        => [ { name => 'APT Remove',
                                                      code => \&remove } ],
                     },

          };

use constant PKGPLUGNAME => 'APT';

our $DRYRUN = undef; 

sub _report_stderr {
    my ($c, $stderr) = @_;
    foreach (@{$stderr}) {
        $c->error("$_", 'err');
    }
}


sub _split_pkg_name {
    my $pkg_name = shift;
    $pkg_name =~ m/^(.*)(#.*)?(?:\.((?:(?:32|64)bit)|noarch))?$/;
    # name. version, arch
    my ($name, $ver, $arch) = ($1, $2, $3);
    if ($arch eq "32bit") {
        $arch = "i386";
    } elsif ($arch eq "64bit") {
        $arch = "x86_64";
    }
    return $name, $ver, $arch;
}

sub _create_pkg_name {
    my $item = shift;
    return undef unless defined $item;
    my $node = $item->[1];
    my $name = $node->{name};
    if (exists $node->{version} && defined $node->{version}) {
        $name .= "#".$node->{version};
    }
    if (exists $node->{arch}) {
        if ($node->{arch} eq "x86_64") {
            $name .= ".64bit";
        } elsif ($node->{arch} =~ /^i.86$/) {   
            $name .= ".32bit";
        }
    }
    return $name;
}
 
# Initialize the apt environment for this instance. Most of this code was
# stolen from the original package manager plugin.
sub init_apt {
    my ($c, $pic, undef) = @_;

    if (exists $pic->{dryrun}) {
        $DRYRUN=1;
    }
    my %default_conf = ( cache_dir => '/var/cache/apt',
                         state_dir => '/var/state/apt',
                         conf_dir => '/etc/apt',
                         aptget_args => [],
                         aptget_bin =>  'apt-get',
                       );
    unless (exists $pic->{plugin_config}->{PKGPLUGNAME}) {
        $pic->{plugin_config}->{PKGPLUGNAME} = {};
    }
    my $conf = $pic->{plugin_config}->{PKGPLUGNAME};
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

    my ($checkrun, $c, $instance_conf, undef) = @_;

    my $aptconf = $instance_conf->{plugin_config}->{PKGPLUGNAME};
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

sub _check_missing {
    my ($c, $instance_conf) = @_;


    my $aptconf = $instance_conf->{plugin_config}->{PKGPLUGNAME};
    my $s = $instance_conf->{store};
    my @missing = $s->get_node_val('name',$s->find_node('missing', 'name'));
    
    # only carry on if there are any packages to resolve
    return PLUGIN_FINAL unless (@missing > 0);
    
    $c->cprint("Working out deps and provides for missing packages", 4);
    my $ret = run_apt($aptconf, "--dry-run -y install", @missing);

    _report_stderr($c, $ret->{stderr});
    if ($ret->{rc} != 0) {
        $c->error('Could not run apt-get','warning');
        return PLUGIN_ERROR;
    }
    
    my $node;
    my $type = undef;
    my %found;
    my %missing = map { $_ => undef } @missing;
    
    # Check out what the deps are and that we can find all the packages...
    my ($pkname, $pkver, $pkarch);
    foreach (@{$ret->{stdout}}) {
        # Find virtual provide 
        if (m/^Selecting\s+([^\s]+)\s+for\s+'([^']+)'/) {
            $c->cprint("$1 provides for: ($2)", 4);
            if (exists $missing{$2}) {
                $found{$2} = undef;
            }
            my $node = $s->find_node('missing', 'name', $2);
            if ($node) {
                $s->remove_node($node);
                
                if ($s->find_node('installed', 'name', $1)) {
                    $s->create_node('install',
                                    'name', $1,
                                    'provides', $2,
                                    'version', "N/A",
                                    'arch', "N/A");
                    next;
                }

                # The result is not installed so install it
                $s->create_node('missing',
                                'name', $1,
                                'provides', $2,
                                'version', "N/A",
                                'arch', "N/A");
            } else {
                # It's not missing so it's a dep
                $s->create_node('new_dep',
                                'name', $1,
                                'version', "N/A",
                                'arch', "N/A");
            }
        } elsif (m/^Inst\s+([^\s]+)\s+\((?:[0-9]+:)?([^\s]+)\s+.*$/) {
                if (exists $missing{$1}) {
                    $found{$1} = undef;
                } else {
                    $s->create_node('new_deps', 'name', $1, 'version', $2);
                }
        } elsif (m/^([^\s]+) is already the newest version/) {
            ($pkname, $pkver, $pkarch) = _split_pkg_name($1);
            if (exists $missing{$pkname}) {
                $found{$pkname} = undef;
            }
            my $node = $s->find_node('missing', 'name', $pkname);
            if ($node) {
                $s->remove_node($node);
                $s->create_node('installed',
                                'name', $pkname,
                                'version', $pkver,
                                'arch', $pkarch);
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

    

sub _install {
    my ($checkrun, $c, $instance_conf, undef) = @_;


    my $aptconf = $instance_conf->{plugin_config}->{PKGPLUGNAME};
    my $s = $instance_conf->{store};
    
    my @missing = $s->find_node('missing', 'name');
    return PLUGIN_FINAL unless (@missing > 0);
    @missing = map {  _create_pkg_name($_) } @missing;
    
    
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
        if (m/^Selecting.*package\s+([^\s]+).\s*$/) {
                my ($pkname, undef, undef) = _split_pkg_name($1);
                if (exists $missing{$pkname}) {
                    $found{$pkname} = undef;
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
    my ($c, $instance_conf, undef) = @_;


    my $s = $instance_conf->{store};
    my $aptconf = $instance_conf->{plugin_config}->{PKGPLUGNAME};

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

sub install {
    _install(undef, @_);
}

# Actually handles the exec'ing and IO
#sub _exec_apt
#{
#    my $c = shift;
#    my $conf = shift;
#    my @cmdline = @_;
#    my $pid = -1;
#
#    if (ref($_[0]) eq 'ARRAY')
#    {
#        # The plus sign is so that we actually call the shift function
#        @cmdline = @{ +shift };
#    }
#    
#    # NOTE: there is a split in the bellow lines because of an
#    #       apt-get 'feature'.
#    #          - If you pass arguments to apt-get as a single
#    #            argv then open3 splits it and it works.
#    #          - If you split them all out it also works.
#
#    # NOTE: passing blank arguments causes strange apt-get errors
#    #       like "E: Line 1 too long in source list" (it lies)
#    # rpounder Tue Aug 25 2009
#    #
#    my @fixed_cmdline;
#    foreach my $cmdpart (@{$conf->{aptget_args}}, @cmdline) {
#        push (@fixed_cmdline, split(' ', $cmdpart)) unless ($cmdpart eq '');
#    }
#
#    my $exec_c = create_exec(inert => 1,
#                             c     => $c,
#                             exec  => exists $conf->{aptget-bin} ?  $conf->{aptget-bin} : 'apt-get',
#                             args  => \@fixed_cmdline);
#
#    unless ($exec_c->start())
#    {
#        $c->error('apt-get failed to run it seems', 'err');
#        return undef;
#    }
#    
#    $exec_c->closeinput();
#    
#    my @foo = $exec_c->readlines();
#    my $stdout = [@foo];
#    
#    @foo = $exec_c->readerrorlines();
#    my $stderr = [@foo];
#
#    $exec_c->wait();
#   
#    # If there was an error, print it out
#    if ($exec_c->exitstatus() >> 8 != 0)
#    {
#        my $errormsg = extract_apt_error($c, $stderr);
#
#        $c->error("apt-get $apt_func failed \[$errormsg\]", 'err');
#
#        my $verb = $c->getval('c_verbosity');
#
 #       if ($verb > 1)
   #     {
   #         foreach (@{$stdout})
   #         {
   #             $c->error("\t$_", 'err');
  #          }
 #       }
#
#    3    if ($verb > 2)
   #     {
  #          $c->error("failed command \[".join(" ", "apt-get", @cmdline)."\]", 'err');
 #       }
#
#
 #       return undef;
#
 #   return $stdout;
#}


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

    my $cmdline = join(' ', $conf->{aptget_bin}, @{$conf->{aptget_args} ? $conf->{aptget_args} : []}, @args);

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
