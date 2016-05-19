# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: SystemInfo.pm 271 2009-11-04 20:14:58Z cfb $

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
use Spine::Util qw(simple_exec);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf('%d', q$Revision: 271 $ =~ /(\d+)/);
$DESCRIPTION = 'Spine::Plugin system information harvester';

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'DISCOVERY/populate' => [ { name => 'sysinfo',
                                                   code => \&get_sysinfo },
                                                 { name => 'wwn_id',
                                                   code => \&get_wwn_id },
                                                 { name => 'netinfo',
                                                   code => \&get_netinfo },
                                                 { name => 'cpu_architecture',
                                                   code => \&get_cpu_arch },
                                                 { name => 'os_architecture',
                                                   code => \&get_os_arch },
                                                 { name => 'is_virtual',
                                                   code => \&is_virtual },
                                                 { name => 'cpu_info',
                                                   code => \&get_cpu_info } ,
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
use Spine::Util qw(resolve_address);

sub get_wwn_id
{
    my $c = shift;
    $c->cprint('determining disk IDs', 3);

    my @devices = glob("/dev/sd?");
    foreach my $file (@devices)
    {
        my (undef, undef, $dev) = split(/\//, $file);
        my ($wwn) = simple_exec(c     => $c,
                                exec  => '/lib/udev/scsi_id',
                                args  => [ "-g", "-u", $file ],
                                quiet => 1,
                                inert => 1);
        if ($? == 0)
        {
            chomp $wwn;
            $c->{c_devices}->{dev}->{$dev}->{wwn}=$wwn;
            if (! exists $c->{c_devices}->{wwn}->{$wwn})
            {
                $c->{c_devices}->{wwn}->{$wwn} = [];
            }
            push @{$c->{c_devices}->{wwn}->{$wwn}}, $dev;
        }
    }    

    my @devices = glob("/dev/sd*");
    my @output = simple_exec(c     => $c,
                             exec  => 'blkid',
                             args  => [ @devices ],
                             inert => 1);
    foreach my $line (@output)
    {
        my ($dev, $label, $uuid, $type) = split(' ', $line);
        $dev =~ s|^/dev/(sd.+):$|$1|g;
        $label =~ s/^LABEL="(.*)"$/$1/g;
        $uuid =~ s/^UUID="(.+)"$/$1/g;
        $type =~ s/^TYPE="(.+)"$/$1/g;
        my $part = $dev;
        $part =~ s/^sd.+(\d+)$/$1/g;
        $dev =~ s/^(sd.+)\d+$/$1/g;
        $c->{c_devices}->{dev}->{$dev}->{$part}->{label}=$label;
        $c->{c_devices}->{dev}->{$dev}->{$part}->{uuid}=$uuid;
        $c->{c_devices}->{dev}->{$dev}->{$part}->{type}=$type;
        if (! exists $c->{c_devices}->{label}->{$label})
        {
            $c->{c_devices}->{label}->{$label} = [];
        }
        push @{$c->{c_devices}->{label}->{$label}}, "$dev$part";
        if (! exists $c->{c_devices}->{uuid}->{$uuid})
        {
            $c->{c_devices}->{uuid}->{$uuid} = [];
        }
        push @{$c->{c_devices}->{uuid}->{$uuid}}, "$dev$part";
    }
}

sub get_sysinfo
{
    my $c = shift;
    my ($ip_address, $bcast, $netmask, $netcard);

    $c->cprint('retrieving system information', 3);

    my ($platform) = simple_exec(c     => $c,
                                 exec  => 'uname',
                                 inert => 1);
    return PLUGIN_FATAL unless ($? == 0);                               
   
    chomp $platform;
    $platform = lc($platform);
    $c->{c_platform} = $platform;

    if ($platform =~ m/linux/i)
    {
        # Use lsb_release to figure out some basic info about our distro
        $c->{c_os_vendor} = 'UNKNOWN';
        $c->{c_os_description} = 'UNKNOWN';
        $c->{c_os_release} = 'UNKNOWN';
        $c->{c_os_codename} = 'UNKNOWN';
        my @lsb_res = simple_exec(c        => $c,
                                   exec     => 'lsb_release',
                                   args     => '-a',
                                   inert    => 1);
        if ($? == 0)
        {
            foreach my $line (@lsb_res)
            {
                use feature "switch";
                given ($line) {
                    when (/^Distributor ID:\s*(.*)$/) {
                        $c->{c_os_vendor} = lc($1);
                    }
                    when (/^Description:\s*(.*)$/) {
                        $c->{c_os_description} = lc($1);
                    }
                    when (/^Release:\s*(.*)$/) {
                        $c->{c_os_release} = lc($1);
                    }
                    when (/^Codename:\s*(.*)$/) {
                        $c->{c_os_codename} = lc($1);
                    }
                }
            }
        }
    }
    return PLUGIN_SUCCESS;
}

# TODO replace this with something more generic
#      expecting there to be a network directory doesn't
#      make sense.
sub get_netinfo
{
    my $c = shift;
    my $c_root = $c->getval('c_croot');
    my $network_path = $c->getval('network_path') || 'network';
    $c->print(3, 'examining local network');

    # First lets get the IP address in DNS for our hostname.
    $c->{c_ip_address} = resolve_address("$c->{c_hostname}");
    unless ($c->{c_ip_address}) {
        $c->error("Unable to resolve IP address for \"$c->{c_hostname}\"",
                  'crit');
        return PLUGIN_FATAL;
    }

    # Now we need a more usable form of the IP address.
    my ($subnet, $network, $netmask, $bcast, @nets);
    my $nobj = new NetAddr::IP($c->getval('c_ip_address'));

    # FIXME  Incorrect and confusing error message here
    unless (defined($nobj)) {
        $c->error("Error interpreting IP \"$c->{c_hostname}\" (NetAddr::IP)",
                  'crit');
        return PLUGIN_FATAL;
    }
     
    # it will all fall apart if this in not there so lets
    # make life easy for the user and let them know.
    if ( ! -d "${c_root}/${network_path}/" ) {
        $c->error("no \"$c_root/$network_path/\" config directory exists.", 'crit');
        return PLUGIN_FATAL;
    }        

    # Populate an ordered hierarchy of networks that our address is a member
    # of

    foreach my $net (<${c_root}/${network_path}/*>)
    {
        next unless ($net !~ m/^(?:\d{1,3}\.){3}(?:\d{1,3})-\d{1,2}/);
        $net = basename($net);
        $net =~ s@-@/@g;

        my $sobj = new NetAddr::IP($net);

        unless (defined($sobj)) {
            $net =~ s@/@-@g;
            $c->error("Invalid network definition \"$net\"", 'err');
            return PLUGIN_FATAL
        }

        if ($nobj->within($sobj)) {
            push @nets, $sobj;
        }
    }

    @nets = sort { $a->within($b) and return 1;
                   $b->within($a) and return -1;
                   return 0; } @nets;

    $nobj = $nets[-1];
    unless (ref($nobj) eq 'NetAddr::IP') {
        $c->error("unable to find a matching network within \"${c_root}/${network_path}/\"",
                     " for \"$c->{c_ip_address}\"",
                  'crit');
        return PLUGIN_FATAL;
    }

    $c->{c_subnet} = "$nobj"; # stringification of a NetAddr::IP object
    $c->{c_network} = $nobj->network->addr;
    $c->{c_bcast} = $nobj->broadcast->addr;
    $c->{c_netmask} = $nobj->mask();

    $c->{c_network_hierarchy} = [];
    foreach my $net (@nets) {
        $net = "$net";
        $net =~ s@/@-@g;
        push @{$c->{c_network_hierarchy}}, $net;
    }

    $c->print(5, "c_network_hierarchy == \"@{$c->{c_network_hierarchy}}\"");

    unless (defined $c->{c_subnet})
    {
        $c->error("error caculating subnet for \"$c->{c_ip_address}\" ".
                      "using \"$network_path/$nets[-1]\"", 'crit');
        return PLUGIN_FATAL;
    }

    return PLUGIN_SUCCESS;
}

#
# This function detects if the current system is s Vmware or Xen VM
# and the subtype of Xen VM (para virt vs. full hardware emmulation).
#
# Variables:
# c_virtual_type = undef for physical, "vmware" for VMWare, "xen-para" for 
#                  para-virtualized Xen, and "xen-hvm" for full hardware
#                  virtualization under Xen.
#
sub is_virtual
{

    my $c = shift;
    my $xen_indicator = $c->getval('xen_indicator') || qq(/proc/xen/xenbus);

    # First detect xen-para because it is easy
    if ( -f $xen_indicator )
    {
        $c->{c_virtual_type} = 'xen-para';

        return PLUGIN_SUCCESS;
    }
    my @lspci_res = simple_exec(c     => $c,
                                exec  => 'lspci',
                                args  => '-n',
                                inert => 1);
    return PLUGIN_FATAL unless ($? == 0);

    foreach my $line (@lspci_res) {
        # 15ad is the PCI vendor ID for VMWare
        #
        # rtilder   Thu Nov  6 09:45:33 PST 2008
        if ( $line =~ m/\s+15ad:[\da-f]{4}/i ) {
            $c->{c_virtual_type} = 'vmware';
            last;
        }
        # 5853 is the vendor ID for Xen Source (who contribute a lot of
        # code to the Xen project) and 0001 is the device ID for their
        # virtual SCSI adapter so "5853:0001" is a Xen HVM
        if ( $line =~ m/\s+5853:[\da-f]{4}/i ) {
            $c->{c_virtual_type} = 'xen-hvm';
            last;
        }
    }

    return PLUGIN_SUCCESS;
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
# This may not be true, there are reports of people with 32-bit CPUs
# and a cflush size value of 64.
#
# cfb        Tue Oct 25 21:56:00 PDT 2011A
#
sub get_cpu_arch
{
    my $c = shift;
    $c->{c_cpu_arch} = '32-bit';

    my $cpuinfo = new IO::File('< /proc/cpuinfo');

    if (not defined($cpuinfo)) {
        $c->error("Couldn't open /proc/cpuinfo: $!", 'crit');
        return PLUGIN_FATAL;
    }

    while (<$cpuinfo>) {
        if (m/^clflush size.*/) {
            $c->{c_cpu_arch} = '64-bit';
            last;
        }
    }

    $cpuinfo->close();

    return PLUGIN_SUCCESS;
}

sub get_os_arch
{
    my $c = shift;
    my ($uname_res) = simple_exec(c     => $c,
                                  exec  => 'uname',
                                  args  => '-i',
                                  inert => 1);
    return PLUGIN_FATAL unless ($? == 0);

    chomp $uname_res;
    $c->{c_os_arch} = $uname_res;

    $c->print(0, 'running on a ', $c->{c_os_arch}, ' kernel.');
    return PLUGIN_SUCCESS;
}

sub get_cpu_info
{
    my $c = shift;

    my $cpuinfo = new IO::File('< /proc/cpuinfo');

    unless (defined($cpuinfo)) {
        $c->error('Failed to open /proc/cpuinfo', 'err');
        return PLUGIN_FATAL;
    }

    my %cores;
    my $fake_id = 1;
    my $xthreads = 0;
    my $physical_id = -1;
    my $cpu_cores = -1;

    # Parse the data
    while(<$cpuinfo>) {
        if (m/^processor\s+:\s+(\d+)/i) {
            $xthreads++;
            next;
        }
        if (m/^physical id\s+:\s+(\d+)/i) {
            $physical_id = $1;
            next;
        }
        if (m/^cpu[ _]cores\s+:\s+(\d+)/i) {
            $cpu_cores = $1;
            next;
        }
        if (m/^$/i) {
            # End of the entry, do the data keeping.
            if ($physical_id != -1) {
                if (! exists $cores{$physical_id}) {
                    $cores{$physical_id} = 1;
                }
                if ($cpu_cores > 0) {
                    $cores{$physical_id} = $cpu_cores;
                }
            }
            else {
                # If we don't have a physical ID we just assume
                # its a unique proc with 1 core.

                # We need to generate a unique ID.
                $physical_id = "UNKNOWN_" . $fake_id;
                $fake_id++;
                $cores{$physical_id} = 1;
            }
            # Done with record keeping, reset;
            $physical_id = -1;
            $cpu_cores = -1;
        }
    }

    $cpuinfo->close();
    
    $c->{c_num_cpus} = scalar(keys %cores);
    $c->{c_num_x_threads} = $xthreads;
   
    $cpu_cores = 0;
    foreach my $key (keys %cores) {
        $cpu_cores = $cpu_cores + $cores{$key};
    }
    $c->{c_num_cores} = $cpu_cores;

    return PLUGIN_SUCCESS;
}

#
# This is a hack until the Hardware plugin is completed to give us
# some basic idea of what type of system we are running on.
#
sub get_hardware_platform
{

    my $c = shift;

    # If we are are running on a virtual system just return the 
    # the virtual_type
    if (defined $c->{c_virtual_type})
    {
        $c->{c_hardware_platform} = $c->{c_virtual_type};
    }
    else
    {
        $c->{c_hardware_platform} = 'UNKNOWN';
        my @output = simple_exec(c     => $c,
                                 exec  => 'dmidecode',
                                 args  => '--string system-product-name',
                                 inert => 1);
        return PLUGIN_FATAL unless ($? == 0);


        foreach my $line (@output)
        {
            next unless ($line !~ m/^#.*/);
            chomp $line;
            $c->{c_hardware_platform} = $line;
            last;
        }
    }
    return PLUGIN_SUCCESS;
}

sub get_current_kernel_version
{
    my $c = shift;
    my $release_file = qq(/proc/sys/kernel/osrelease);
    my $fh = new IO::File("< $release_file");

    unless (defined($fh))
    {
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
