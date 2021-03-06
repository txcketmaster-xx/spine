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

#
# FIXME
#
# This should really be renamed to something more like BootLoaderConfig since
# that's all its ever done.
#
# rtilder    Tue May 29 12:42:25 PDT 2007
#

use strict;

package Spine::Plugin::Finalize;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use Spine::Util qw(simple_exec);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);
$DESCRIPTION = "Spine::Plugin skeleton";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { APPLY => [ { name => 'boot_loader_config',
                                    code => \&boot_loader_config } ]
                     },
          };


my $DRYRUN = 0;

sub boot_loader_config
{
    my $c = shift;
    my $rval = 0;

    my $kernel_version = $c->getval('kernel_version');
    my $kernel_path = $c->getval('kernel_path') || qq(/boot);
    my $kernel_prefix = $c->getval('kernel_prefix') || qq(vmlinuz-);
    my ($result, @cmdline);

    # i386 and x86_64 are currently 256 in 2.4 and 2.6 but may change (grow)
    my $kernel_cmdline_max = $c->getval('kernal_cmdline_max') || qq(256);

    $DRYRUN = $c->getval('c_dryrun');
    
    #
    # First: we gather the information we want from the running kernel and
    # existing /boot/grub/grub.conf
    #
    # Factored out to improve readability and maintainability.
    #
    # rtilder    Fri Apr 13 09:31:53 PDT 2007
    #

    # Check what the running kernel args are
    my @current_cmdline = get_current_cmdline($c->getvals('kernel_args_to_ignore'));

    # Check to see if we are running an smp kernel
    my $running_kernel = $c->getval('c_current_kernel_version');

    # Check to see what grub thinks our default booting kernel is
    my $grub_default_info = get_grub_default_kernel($c);

    # Determine whether or not we should use an SMP kernel
    my $kernel_type = determine_smp_disposition($c, $running_kernel,
                                                $grub_default_info->{kernel});

    #
    # Second: set our new default kernel, if necessary
    #

    my $kernel_version_full = $kernel_version . $kernel_type;
    my $kernel_file = $kernel_path . "/" . $kernel_prefix
        . $kernel_version_full;

    $c->print(3, "chosen kernel is \[$kernel_file\]");

    # Should the default kernel change?
    if ( $grub_default_info->{default_kernel} ne $kernel_file )
    {
        $c->print(2, "setting default kernel to ${kernel_file}");

        unless ($DRYRUN)
        {
            # Don't bother doing anything unless we can find the specified
            # kernel on the filesystem
            if ( ($kernel_version_full) and (-f $kernel_file) )
            {
                if (run_grubby($c, 'could not set default kernel', 0,
                               "--set-default=${kernel_file}"))
                {
                    return PLUGIN_ERROR;
                }
            }
            else
            {
                $c->error('could not set default kernel to non-existent file'
                          . " \[$kernel_file\]", 'err');
                return PLUGIN_ERROR;
            }
        }

        # We can positivily determing if the running kernels version is 
        # different than the configured kernels version (aka
        # 2.6.18-92.1.10.el5xen vs. 2.6.18-92.1.11.el5xen). 
        if ( $running_kernel ne $kernel_version_full )
        {
            $c->print(2, 'reboot needed - running kernel does not match '
                . 'version specified by spine');
        }
        else
        {
            # There appears to be no way to determing the full path of
            # the running kernel. The best we can do in the is warn that
            # the configured kernel changed during this run and that a
            # reboot *might* be necessary.
            $c->print(2, 'possible reboot needed - default kernel in grub '
                . 'does not match kernel specified by spine');
        }

    }

    #
    # Third: do some validation of the args we're planning on providing
    #

    # Pull out the wanted args from spine
    my $new_kernel_args = $c->getvals('kernel_args');

    # No additional kernel args?  Hooray!
    unless (defined($new_kernel_args) and scalar(@{$new_kernel_args}))
    {
        $c->print(3, 'No kernel arguments to add.');
        return PLUGIN_SUCCESS;
    }

    # You can not have spaces within kernel arguments
    foreach (@{$new_kernel_args})
    {
        if (m/\S*=["'][^"']*\s[^"']*["']/ ) {
            $c->error("space detected in kernel argument: \[$_\]", 'err');
            $rval++;
        }
    }

    # Check that the arguments are not too long
    my $l = length(join(' ', 'root=' . $grub_default_info->{root},
                        @{$new_kernel_args}));
    if ( $l > $kernel_cmdline_max ) {
        $c->error("kernel arguments are longer($l) than $kernel_cmdline_max "
                  . 'characters', 'err');
        $rval++;
    }
    undef $l;

    # If the above changes had problems then give up doing the rest
    if ( $rval > 0 )
    {
        $c->error('skipping processing of kernel arguments due to earlier'
                  . ' errors', 'err');
        return PLUGIN_ERROR;
    }

    # Do a quick comparison of the two different kernel arguments lists to see
    # if we need to bother changing them
    if (join(' ', sort(@{$new_kernel_args})) eq
        join(' ', sort(@{$grub_default_info->{args_array}})))
    {
        $c->print(3, 'no changes to kernel arguments.');
        return PLUGIN_SUCCESS;
    }

    # Get the arguments currently set for the default kernel
    $c->print(3, "detected default kernel args \[$grub_default_info->{args}\]");

    $c->print(3, "appending kernel args \[@{$new_kernel_args}\]");
    $new_kernel_args = join(' ', @{$new_kernel_args});

    # Since we may be changing args without changing the kernel we always run
    # through this unless we failed to change the kernel, we don't want to for
    # the args on the wrong kernel
    $c->print(2, "changing kernel args from \[$grub_default_info->{args}\] to "
               . "\[$new_kernel_args\]");

    if ( ! $DRYRUN )
    {
        # Remove the args first this we could work out the changes
        # but this keeps it simple
        my $current_args = $grub_default_info->{args};
        $current_args =~ s/'/\\'/;

        $rval += run_grubby($c, 'could not clear kernel args', 0,
                            "--update-kernel=${kernel_file}",
                            "--remove-args='${current_args}'");

        # Add the args we want back in
        $new_kernel_args =~ s/'/\\'/;

        $rval += run_grubby($c, 'could not set kernel args',0,
                            "--update-kernel=${kernel_file}",
                            "--args='${new_kernel_args}'");
    }

    if ( get_current_cmdline() ne $new_kernel_args )
    {
        $c->print(2, 'reboot needed - running kernel arguments do not match'
                   . ' grub.conf');
    }

    return $rval ? PLUGIN_ERROR : PLUGIN_SUCCESS;
}


sub get_grub_default_kernel
{
    my $c = shift;
    my $info = {};

    my ($default_kernel) = simple_exec(merge_error => 1,
                                       args        => "--default-kernel",
                                       exec        => 'grubby',
                                       inert       => 1,
                                       c           => $c);
    chomp($default_kernel);

    # Fetch our bootloader info via grubby before we mangle the $default_kernel
    # variable a smidge
    my @data = simple_exec(exec        => 'grubby',
                           args        => "--info=${default_kernel}",
                           merge_error => 1,
                           inert       => 1,
                           c           => $c);

    # Stash the original value before we start mucking with it.
    $info->{default_kernel} = $default_kernel;

#    (undef, $default_kernel) = split(m/-/, $default_kernel, 2);

    $c->cprint("current default kernel is \[$default_kernel\]", 3);

    foreach (@data)
    {
        chomp;
        my ($k, $v) = split(m/=/, $_, 2);

        # Excessively paranoid.  Almost certainly won't ever happen
        if (exists($info->{$k}))
        {
            $c->error("Weirdness!  grubby has odd data for ${default_kernel}",
                      'err');
            return undef;
        }

        # Massage the arguments a little bit
        if ($k eq 'args')
        {
            $v =~ s/^"\s*(.*)\s*"$/$1/;
            my @v = split(m/\s+/, $v);
            $info->{args_array} = \@v;
        }

        $info->{$k} = $v;
    }

    # We add a 'version' data member to the hash to make some comparisons
    # easier
#    $info->{version} = $default_kernel;

    return $info;
}


sub get_current_cmdline
{
    my @cmdline;

    if (ref($_[0]) eq 'ARRAY')
    {
        @_ = @{$_[0]};
    }

    open(KARGS, "< /proc/cmdline");
    my @current_cmdline = split(m/\s+/, <KARGS>);
    close(KARGS);

    # Strip out arguments we know we're going to ignore("single", etc)
    foreach my $ignore (@_)
    {
        foreach (@current_cmdline)
        {
            unless (m/$ignore/) {
                push @cmdline, $_;
            }
        }
    }
    undef @current_cmdline;

    return wantarray ? @cmdline : join(' ', @cmdline);
}


sub determine_smp_disposition
{
    my ($c, $running_kernel, $grub_default) = @_;

    my $disposition = $c->getval_last('smp_disposition');

    # If it's been explicitly defined, just return it.  This permits overrides
    # for things like the largesmp kernels that are needed for more than 8
    # cores on x86_64 boxes like the Sun x4600 servers used for the U.S.
    # TDBs beginning in April 2007. </run on>
    #
    # rtilder    Tue Apr 24 13:08:41 PDT 2007
    #
    if (defined($disposition))
    {
        # So retarded and yet so entertaining
        if ($disposition eq $c->getval_last('magic_unified_smp_value')) {
            return '';
        }

        return $disposition;
    }

    my $running_smp = 1 if ($running_kernel =~ m/smp$/i);	
    my $grub_smp = 1 if ($grub_default =~ m/smp$/);
    my $processors = $c->getval_last('c_num_procs');

    # Use an SMP kernel if we have more than one processor
    if ((not $running_smp and $grub_smp) or $processors > 1)
    {
        $disposition = 'smp';
    }

    return $disposition;
}


sub run_grubby
{
    my $c = shift;
    my $msg = shift;
    my $inert = shift;
    my $opts = join(' ', @_);

    my @result = simple_exec(merge_error => 1,
                             exec        => 'grubby',
                             inert       => $inert,
                             args        => [ @_ ],
                             c           => $c);

    if (($? >> 8) > 0)
    {
        $c->error("${msg} \[".join("", @result)."\]", 'err');
    }

    return $? >> 8;
}


1;
