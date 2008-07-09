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

package Spine::Plugin::SystemInfo;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d.%02d", q$Revision$ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Spine::Plugin system information harvester";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'DISCOVERY/populate' => [ { name => 'sysinfo',
                                                   code => \&get_sysinfo },
                                                 { name => 'netinfo',
                                                   code => \&get_netinfo },
                                                 { name => 'distro',
                                                   code => \&get_distro },
                                                 { name => 'architecture',
                                                   code => \&get_hw_arch },
                                                 { name => 'is_virtual',
                                                   code => \&is_virtual },
                                                 { name => 'num_procs',
                                                   code => \&get_num_procs } ,
                                                 { name => 'hardware_platform',
                                                   code => \&get_hardware_platform } , 
                                                 { name => 'current_kernel_version',
                                                   code => \&get_current_kernel_version } ]
                     }
          };


use File::Basename;
use File::Spec::Functions;
use IO::File;
use NetAddr::IP;
use RPM2;


#
# This should really be a much more generic in terms of populating data about
# the devices on the PCI bus and use linux/drivers/pci/pci.ids.  Should really
# just gather various stuff from /proc really.
#
# rtilder    Fri Sep 10 16:17:11 PDT 2004
#
sub get_sysinfo
{
    my $c = shift;
    my ($ip_address, $bcast, $netmask, $netcard);
    my $ifconfig = $c->getval("ifconfig_bin");
    my $iface = $c->getval("primary_iface");

    $c->cprint( "retrieving system information", 3);

    my $platform = `uname`;
    chomp $platform;
    $platform = lc($platform);

    if ($platform =~ m/linux/i)
    {
        # Grab the network_device_map key contents as a hash so we can walk it
        # more quickly
        my %devs = @{$c->getvals('network_device_map')};

        # We walk the PCI bus to determine which network card we have
        open(PCI, '/sbin/lspci |');
        while (<PCI>) {
            next unless m/Ethernet/;
            # FIXME  This is kind of dumb.  We don't provide any kind of
            #        interface to driver mapping and we really should
            while (my ($re, $card) = each(%devs)) {
                $netcard = $card if m/$re/;
            }
	}
	$netcard = 'unknown' unless $netcard;
        close (PCI);

	my $cmd = $ifconfig . " eth" . $iface;
	foreach my $line (`$cmd`)
	{
	    if ($line =~
		m/
		\s*inet\s+addr:(\d+\.\d+\.\d+\.\d+)
		\s*Bcast:(\d+\.\d+\.\d+\.\d+)
		\s*Mask:(\d+\.\d+\.\d+\.\d+)
		/xi )
	    {
                $ip_address = $1;
		$bcast = $2;	
                $netmask = $3;
	    }
        }
    }

    $c->{c_platform} = $platform;
    $c->{c_local_ip_address} = $ip_address;
    $c->{c_local_bcast} = $bcast;
    $c->{c_local_netmask} = $netmask;
    $c->{c_netcard} = $netcard;

    $c->get_values("platform/$platform");

    return PLUGIN_SUCCESS;
}


sub get_netinfo
{
    my $c = shift;
    my $c_root = $c->getval("c_croot");

    $c->print(3, "examining local network");

    my ($subnet, $network, $netmask, $bcast);
    my $nobj = new NetAddr::IP($c->getval('c_ip_address'));

    unless (defined($nobj)) {
        $c->{c_failure} = "No IP address found for $c->{c_hostname_f}";
        return PLUGIN_FATAL;
    }

    foreach my $net (<${c_root}/network/*>)
    {
	next if ($net =~ m/^\.+/);
	$net = basename($net);
	$net =~ s@-@/@g;

	my $sobj = new NetAddr::IP($net);

	if ($nobj->within($sobj))
	{
	    $net =~ s@/@-@g;
	    $subnet = $net;
	    $network = $sobj->network->addr;
	    $netmask = $sobj->mask();
	    $bcast = $sobj->broadcast->addr;
	    last;
	}
    }

    $c->{c_subnet} = $subnet;
    $c->{c_network} = $network;
    $c->{c_bcast} = $bcast;
    $c->{c_netmask} = $netmask;

    unless (defined $c->{c_subnet})
    {
	$c->{c_failure} = "network for $c->{c_ip_address} is not defined";
	return PLUGIN_FATAL;
    }

    return PLUGIN_SUCCESS;
}


sub is_virtual
{
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

            $c->{c_is_virtual} = 1;
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


sub get_distro
{
    my $c = shift;

    my $release_pkgs = $c->getvals('linux_release_packages');
    my $distro_map = $c->getvals('linux_distro_map');

    unless ($release_pkgs and $distro_map)
    {
        # Try the old names
        if (not $release_pkgs)
        {
            $release_pkgs = $c->getvals('release_packages');
        }

        if (not $distro_map)
        {
            $distro_map = $c->getvals('distro_map');
        }

        unless ($release_pkgs and $distro_map)
        {
            die "Either the release_packages or distro_map keys are defined or are empty!  Not good!";
        }
    }

    # We need to be certain that we unique-ify the release_pkgs list.
    my %uniques = map { $_ => undef } @{$release_pkgs};
    my @uniques = keys(%uniques);
    undef %uniques;
    $release_pkgs = \@uniques;

    # We *don't* need to unique-ify the distro_map because it's a hash so
    # perl automagically does this for us with the following assignment.
    #
    # Perl: Furthering the Cause of Pathetically Lazy Programmers Everywhere

    my %release_map = @{ $distro_map };
    my $release_pkg;
    my @matches;

    my $db = RPM2->open_rpm_db();

    # Find out what our distro release package is
    foreach my $relpkg (@{$release_pkgs}) {
        my $i = $db->find_by_name_iter($relpkg);

        while (my $pkg = $i->next) {
            $c->print(3, 'Release package: ', $pkg->as_nvre);

            while (my ($k, $v) = each(%release_map)) {
                if (_pkg_vr($pkg) eq $k) {
                    push @matches, $k;
                    # We assign here instead of keeping a separate list because
                    # we die if @matches has more than one element
                    $release_pkg = $relpkg;
                    $c->print(0, "found a distro release package: $k");
                }
            }
        }
    }

    if (scalar(@matches) > 1) {
        die 'Multiple release packages installed.  DANGER!  ' . join(' ', @matches);
    }

    unless ($release_pkg) {
        die "No release matching package found!  Not good!";
    }

    my $distro_pkg = pop @matches;
    ($c->{c_distro_name}, $c->{c_distro_version}, $c->{c_distro}) =
        split(/,\s*/, $release_map{$distro_pkg}, 3);

    $c->{c_distro_pkg} = $release_pkg;

    #
    # Backward compatible cruft
    #
    $c->{c_distro_release} = $c->{c_distro};
    $c->{c_distro_dir} = catfile($c->{c_platform_dir}, $c->{c_distro_release});

    $c->print(0, 'configuring as an ', $c->{c_distro}, ' system');

    # FIXME  This is causing the plugin it die.  Weirdness.
    #
    #$c->get_configdir($c->{c_distro_dir});

    # The RPM DB is "automagically" closed by the RPM2 XS code when it passes
    # from scope(actually via the DESTROY method).  Therefore there it isn't
    # necessary to explicitly close it or undef it, though that's good for
    # the sake of explicitness.
    #
    # rtilder    Fri Apr  8 12:41:49 PDT 2005

    undef $db;

    return PLUGIN_SUCCESS;
}


# We don't care much about epoch at the moment.
sub _pkg_vr
{
    my $pkg = shift;

    my $pname = $pkg->tag('name');
    my $pver  = $pkg->tag('version');
    my $prel  = $pkg->tag('release');

    return "$pname-$pver-$prel";
}


#
# Cute trick:
#
# In /proc/cpuinfo, the "clflush" flag is visible even in a 32bit only kernel.
# However, the "clflush size" entry is only available on 64 bit x86
# kernel, no matter if it's AMD or Intel.
#
# rtilder    Fri May  5 13:39:31 PDT 2006
#
sub get_hw_arch
{
    my $c = shift;
    $c->{c_arch} = 'x86';

    my $cpuinfo = new IO::File('< /proc/cpuinfo');

    if (not defined($cpuinfo)) {
        die "Coundn't open /proc/cpuinfo: $!";
    }

    while (<$cpuinfo>) {
        if (m/^clflush size.*/) {
            $c->{c_arch} = 'x86_64';
            last;
        }
    }

    $cpuinfo->close();

    $c->print(0, 'running on a ', $c->{c_arch}, ' kernel.');

    return PLUGIN_SUCCESS;
}


sub get_num_procs
{
    my $c = shift;
    my $getconf = qq(/usr/bin/getconf);

    $c->{c_num_procs} = 1;

    if (-f GETCONF and -x GETCONF) {
        $c->{c_num_procs} = `$getconf _NPROCESSORS_ONLN`;
    }
    else {
        my $cpuinfo = new IO::File('< /proc/cpuinfo');
        my $nprocs = 0;

        unless (defined($cpuinfo)) {
            $c->{c_failure} = "Failed to open /proc/cpuinfo";
            return PLUGIN_FATAL;
        }

        # Try to determine the number of processors
        while(<$cpuinfo>) {
            $nprocs++ if m/^processor\s+:\s+\d+/i;
        }

        $cpuinfo->close();

        $c->{c_num_procs} = $nprocs;
    }

    return PLUGIN_SUCCESS;
}

#
# This is a hack until the Hardware plugin is completed to give us
# some basic idea of what type of system we are running on.
#
sub get_hardware_platform
{

    my $c = shift;

    my $fh = new IO::File('/usr/sbin/dmidecode |');

    if (not $fh) {
        $c->{c_failure} = "Failed to run dmidecode: $!";
        return PLUGIN_FATAL;
    }

    my $sys_section = 0;
    my $hardware_platform = 'UNKNOWN';

    foreach my $line (<$fh>) {
        # We need to find the "Product Name:" key under 'DMI type 1'
        # (which is the "System Information" section).
        if ($line =~ m/DMI type 1/i) {
            $sys_section = 1;
            next;
        }

        # If we are in the sys_section, look for "Product Name:"
        if ($sys_section and $line =~ m/Product Name:/i) {
            (undef, $hardware_platform) = split(': ', $line, 2);
            $hardware_platform =~ s/^\s+|\s+$//g;
            $hardware_platform = 'UNKNOWN' if $hardware_platform eq '';
            last;
        } 

        # If we enter another DMI section we are done.
        last if ($sys_section and $line =~ m/DMI type/i);
    }
    $fh->close();

    $c->{c_hardware_platform} = $hardware_platform;
    return PLUGIN_SUCCESS;
}

sub get_current_kernel_version
{
    my $c = shift;
    my $release_file = qq(/proc/sys/kernel/osrelease);
    my $fh = new IO::File("< $release_file");

    unless (defined($fh)) {
        $c->error("Couldn't open $release_file: $!", 'err');
        return PLUGIN_FATAL;
    }

    my $running_kernel = $fh->getline();
    chomp $running_kernel;
    $fh->close();

    $c->print(3, "detected running kernel \[$running_kernel\]");

    $c->set('c_current_kernel_version', $running_kernel);

    return PLUGIN_SUCCESS;
}


1;
