# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: SystemInfo.pm 56 2008-05-14 14:50:13Z rtilder $

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

package Spine::Plugin::Platform::Linux;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use Spine::Registry;
use NetAddr::IP;

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d.%02d", q$Revision: 56 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Linux Platform Detection";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => {
                       'Platform'       => [ { name => 'platform_linux',
                                               code => \&check_for_linux }, ],
                       'Platform/linux' => [ { name => 'linux_ifinfo',
                                               code => \&get_ifinfo },
                                             { name => 'linux_virtual',
                                               code => \&get_virtual },
                                             { name => 'linux_distro',
                                               code => \&detect_distro ,
                                               position => HOOK_END, } ],
                       'Platform/linux/Distro' => [ { name => 'linux_distro_basic',
                                                          code => \&basic_distro ,
                                                          position => HOOK_END, } ],
                     }
          };

# Work out if this is a Linux platform.
sub check_for_linux {
    my $c = shift;
    my $registry = new Spine::Registry();

    my $uname = $c->getval('uname_bin') || "/bin/uname";

    return PLUGIN_SUCCESS unless  ( -x $uname );

    my $unamedata = qx/$uname -s/;
    return PLUGIN_SUCCESS unless ($? == 0 && $unamedata =~ m/^linux/i);
    
    $registry->create_hook_point(qw(Platform/linux
                                    Platform/linux/Distro));
    $c->{c_platform} = "linux";
    return PLUGIN_FINAL;
}

# Loop through the linux distro plugins and then call hook for
# that distro.
sub detect_distro {
    my $c = shift;

    my $registry = new Spine::Registry();

    my ($point,$rc);

    $point = $registry->get_hook_point('Platform/linux/Distro');
    # HOOKME, go through ALL linux distro plugins
    $rc = $point->run_hooks_until(PLUGIN_STOP, $c);
    if ($rc != PLUGIN_FINAL) {
        $c->error("A linux distro plugin failed", 'crit');
        return PLUGIN_ERROR;
    }

    # c_distro should now have been set...
    my $distro = $c->getval('c_distro');
    unless (defined $distro) {
        $c->error("The linux distro plugin failed to actually set c_distro", 'crit');
        return PLUGIN_ERROR;
    }

    # HOOKME, go through the platform plugins until we know what we are
    $registry->create_hook_point("Platform/linux/$distro");
    $point = $registry->get_hook_point("Platform/linux/$distro");
    $rc = $point->run_hooks_until(PLUGIN_FATAL, $c);
    if ($rc & PLUGIN_FATAL) {
        # Nothing implemented config for this instance...
        $c->error("Error within a linux distro plugin", 'crit');
        return PLUGIN_ERROR;
    }


    return PLUGIN_SUCCESS;
}


# detect the distro this should be called near the end so that it can be overridden
# TODO add in basic version detection
sub basic_distro {
    my $c = shift;

    my $distro = undef;
    my $distro_ver = undef;
    my $distro_base = undef;
    my ($data, $fd);

    if ( -f '/etc/debian_version' ) {
        $distro = "debian";
        $distro_base = "debian";
        if ( -f "/proc/version" && open($fd, "</proc/version")) {
            $data=join('', <$fd>);  
            close($fd);
            if ($data =~ /\(Debian (\d+.\d+).\d+-\d+\)/m) {
                $distro_ver = $1;
            }
        }

    } elsif ( -f '/etc/fedora-release') {
        $distro = "fedora";
        $distro_base = "redhat";
        if (open($fd, "</etc/fedora-release")) {
            $data=join('', <$fd>);
            close($fd);
            $data =~ /(?:\((Rawhide)\)|release (\d+))/;
            $distro_ver = lc($1);
        }
    } elsif ( -f '/etc/gentoo-release') {
        $distro = "gentoo";
        # TODO distro_ver

    } elsif ( -f '/etc/mandriva-release') {
        $distro = "mandriva";
        # TODO distro_ver

    } elsif ( -f '/etc/mandrake-release') {
        $distro = "mandrake";
        # TODO distro_ver

    } elsif ( -f '/etc/redhat-release') {
        $distro_base = "redhat";
        $distro = "redhat";
        if (open($fd, "</etc/redhat-release")) {
            $data=join('', <$fd>);
            close($fd);
            if ($data =~ /centos/i) {
                $distro = "centos";
            }
            if ($data =~ /\(Rawhide\)$/) {
                $distro_ver = 'rawhide';
            } elsif ($data =~ /release (\d+)/) {
                $distro_ver = $1;
            }
        }
        # XXX: is it ok to assume that this is in the path?
        my $rpm_bin = $c->getval('rpm_bin') || 'rpm';
        $data = qx/$rpm_bin -q ${distro}-release/;
        if ($? == 0) {
            $data =~ m/release-(\d+)/;
            $distro_ver = lc($1);
        }
            
    } elsif ( -f '/etc/SuSE-release') {
        $distro = "suse";
        # TODO distro_ver
    }

    # Slightly more involved detection
    if (!defined $distro && -f "/etc/issue") {
        return PLUGIN_ERROR unless open($fd, "</etc/issue");
        $data=join('', <$fd>);
        close($fd);
        if ($data =~ m/Ubuntu (\d+.\d+)/) {
            $distro = "ubuntu";
            $distro_ver = $1;
            $distro_base = "debian";
        }
    }

    return PLUGIN_SUCCESS unless (defined $distro);

    $c->{c_distro} = $distro;
    $c->{c_distro_ver} = $distro_ver;
    $c->{c_distro_base} = $distro_base || $distro;

    return PLUGIN_FINAL;
}

# TODO IPV6
# TODO resolve the netcard type
sub get_ifinfo {
    my $c = shift;
    my ($ip_address, $bcast, $netmask, $netcard);
    my $ip = $c->getval("ip_bin") || "/sbin/ip";
    
    $c->cprint("Getting interface information", 3);
    
    my ($ifname, $ifhash);
    my %interfaces;
    foreach (`$ip addr`) {
        if (m/^([0-9]+):\s+([^\s]+):\s+/) {
            $ifname = $2;
            $ifhash = $interfaces{$ifname} = { number => $1,
                                              v4 => {},
                                              v6 => {},
                                            };
        } elsif (m/inet\s+((?:[0-9]{1,3}){4})\/([0-9]+)\s.*\s(${ifname}[^\s])*/) {
            $ifhash->{v4}->{$1} = { subnet => $2,
                                    label => $3,
                                    address => $1 };
            if (m/brd\s+((?:[0-9]{1,3}){4})\s/) {
                $ifhash->{v4}->{$1}->{brodcast} = $1;
            }  
            if (m/scope\s+([^\s]+)\s/) {
                $ifhash->{v4}->{$1}->{scope} = $1;
            }
            if ($_ !~ m/secondary/) {
                $ifhash->{v4}->{base} = $interfaces{$ifname}->{v4}->{$1};
            }
        } elsif (m/link\/([^\s]+)\s((?:[0-9A-F]:){6})\s/) {
            $ifhash->{mac} = $2;
            $ifhash->{type} = $1;
        }
    }
     
    $c->{c_ipinterfaces} = \%interfaces;

    # Skip is something else has chosen the default
    return PLUGIN_SUCCESS if (exists $c->{c_local_ip_address});

    # Default to the interface with the default gateway for most things
    # FIXME: support multiple default routes
    foreach (`$ip route show`) {
        if (m/^default.*((?:[0-9]{1,3}){4}).*dev\s+([^\s]+)$/) {
            if (exists $interfaces{$2}->{v4}->{base}) {
                $c->{c_local_ip_address} = $interfaces{$2}->{v4}->{base}->{address};
                $c->{c_local_bcast} = $interfaces{$2}->{v4}->{base}->{broadcast};
                $c->{c_local_netmask} = $interfaces{$2}->{v4}->{base}->{subnet};
            }
        }
    }
    return PLUGIN_SUCCESS;
}

sub get_virtual {
    my $c = shift;

    $c->{c_is_virtual} = 0;

    my $fh = new IO::File('/sbin/lspci -n |');

    if (not $fh) {
        $c->{c_failure} = "Failed to run /sbin/lspci: $!";
        return PLUGIN_FATAL;
    }

    while (<$fh>) {
        # 15ad is the vendor ID for VMWare and 0405 is the device ID for their
        # virtual SVGA adapter so "15ad:0405" is the string we're looking for
        #
        # rtilder    Tue Jul 12 13:19:48 PDT 2005
        if (m/15ad:0405/i) {
            if (not $c->get_config_group($c->getval('virtual_common_path'))) {
                # Jesus but I hate how people who like perl use die() calls to
                # determine whether or not an exception has occured.
                $fh->close(); # make sure we don't have trailing FDs
                die "Couldn't include the VM config group!";
            }
            
            $c->{c_is_virtual} = "vmware";
            last;
        }
    }
    
    $fh->close();
    
    # We will do an additional check to see if this is a xen based vm.  
    # very easy to do as we simply check the existance of /proc/xen
    # based on input, I'm setting this to xen, it could be set to something
    # like 2 with a pseudo define where 1 = vmware, 2 = xen
    my $xen_indicator="/proc/xen";
    
    if ( -d $xen_indicator ) {
        $c->{c_is_virtual} = "xen";
    }
    
    return PLUGIN_SUCCESS;
}


1;
