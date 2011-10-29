# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: DebianPackageManager.pm 266 2009-11-04 00:25:50Z cfb $

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

package Spine::Plugin::DebianPackageManager;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d", q$Revision: 266 $ =~ /(\d+)/);
$DESCRIPTION = "Debian package management using the apt-get";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { APPLY => [ { name => 'install_packages',
                                    code => \&install_packages } ]
                     },
          };


use File::Spec::Functions;
use IO::Handle;
use IPC::Open3;
use Spine::Util qw(mkdir_p create_exec simple_exec);

my $DRYRUN = 0;

sub install_packages
{
    my $c = shift;
    my $rval = 0;
    my $packages = $c->getvals("packages");
    
    unless ($packages) {
	$c->print(2, 'skipping, no "packages" key defined');
        return PLUGIN_SUCCESS;
    }
    
    $DRYRUN = $c->getval('c_dryrun');

    apt_exec($c, 'autoclean', '', 0) or $rval++;

    unless (exists $ENV{'SPINE_NO_APT_UPDATE'}) {
        apt_exec($c, 'update', '', 0) or $rval++;
    }

    apt_exec($c, 'dist-upgrade', '', 1) or $rval++;

    unless (scalar(@{$packages}) <= 0)
    {
	my $packages_flat = join(" ", @{$packages});
	apt_exec($c, 'install', $packages_flat, 1) or $rval++;
    }

    return $rval ? PLUGIN_ERROR : PLUGIN_SUCCESS;
}


sub apt_exec
{
    my ($c, $apt_func, $apt_func_args, $run_test) = @_;
    
    my @aptget_args = ();

    if ($DRYRUN)
    {
        #
        # We need to create the full /var/state/apt/... and /var/cache/apt/...
        # hierarchy in the overlay so we can completely compartmentalize our
        # dry runs.
        #
        my $overlay = $c->getval('c_tmpdir');

        foreach my $dir (qw(/var/cache/apt/archives/partial
                            /var/lib/apt/lists/partial))
        {
            unless (Spine::Util::mkdir_p(catfile($overlay, $dir)))
            {
                $c->error("Failed to create directory $dir", 'err');
                return PLUGIN_ERROR;
            }
        }

        #
        # Prevent the apt stuff from getting copied.
        #
        $c->set('apply_overlay_excludes', '/var/cache/apt');
        $c->set('apply_overlay_excludes', '/var/lib/apt');

        my $apt_conf_ovrl = catfile($overlay, qw(etc apt));

        push @aptget_args, '--option', 'Dir=' . $c->getval('c_tmpdir');
        push @aptget_args, '--option', 'Dpkg::Options::="--force-confold"';

        foreach my $file ( ( [ '--option Dir::Etc::parts',
                               'apt.conf.d' ],
                             [ '--option Dir::Etc::sourceparts',
                               'sources.list.d'],
                             [ '--option Dir::Etc::sourcelist',
                               'sources.list' ] ) )
        {
            my $conffile = catfile($apt_conf_ovrl, $file->[1]);

            unless (-s $conffile)
            {
                $conffile = '/etc/apt/' . $file->[1];
            }

            push @aptget_args, "$file->[0]=$conffile";
        }
    }

    if ($run_test)
    {
	$c->print(2, "testing $apt_func");

        my @apt_cmd = (@aptget_args, '--dry-run',
                       $apt_func, $apt_func_args);

        my $out = _exec_apt($c, $apt_func, \@apt_cmd);

        unless (defined($out))
        {
            # Error reporting handled by _exec_apt()
            return PLUGIN_ERROR;
        }

        my $status_msgs = parse_apt_output($out);

        foreach my $msg (@{$status_msgs}) {
            $c->print(2, "$msg")
        }
    }

    if ( (not $DRYRUN) or ($apt_func =~ /update/) )
    {
        $c->print(2, "applying $apt_func");

        my @apt_cmd = (@aptget_args, '-qq', $apt_func,
                       $apt_func_args);

        unless (defined(_exec_apt($c, $apt_func, \@apt_cmd)))
        {
            # Error reporting handled by _exec_apt()
	    return PLUGIN_ERROR;
        }
    }

    return PLUGIN_SUCCESS;
}


# Actually handles the exec'ing and IO
sub _exec_apt
{
    my $c = shift;
    my $apt_func = shift;
    my @cmdline = @_;
    my $pid = -1;

    # Eliminate interactive prompts from dpkg.
    $ENV{'DEBIAN_FRONTEND'} = 'noninteractive';

    if (ref($_[0]) eq 'ARRAY')
    {
        # The plus sign is so that we actually call the shift function
        @cmdline = @{ +shift };
    }
    
    # NOTE: there is a split in the bellow lines because of an
    #       apt-get 'feature'.
    #          - If you pass arguments to apt-get as a single
    #            argv then open3 splits it and it works.
    #          - If you split them all out it also works.
    #          - If you do a mixture it apt-get gets very upset.
    # NOTE: passing blank arguments causes strange apt-get errors
    #       like "E: Line 1 too long in source list" (it lies)
    # rpounder Tue Aug 25 2009
    #
    my @fixed_cmdline;
    foreach my $cmdpart (@cmdline) {
        push (@fixed_cmdline, split(' ', $cmdpart)) unless ($cmdpart eq '');
    }

    my $exec_c = create_exec(inert => 1,
                             c     => $c,
                             exec  => 'apt-get',
                             args  => \@fixed_cmdline);

    unless ($exec_c->start())
    {
        $c->error('apt-get failed to run it seems', 'err');
        return undef;
    }
    
    $exec_c->closeinput();
    
    my @foo = $exec_c->readlines();
    my $stdout = [@foo];
    
    @foo = $exec_c->readerrorlines();
    my $stderr = [@foo];

    $exec_c->wait();
   
    # If there was an error, print it out
    if ($exec_c->exitstatus() >> 8 != 0)
    {
        my $errormsg = extract_apt_error($c, $stderr);

        $c->error("apt-get $apt_func failed \[$errormsg\]", 'err');

        my $verb = $c->getval('c_verbosity');

        if ($verb > 1)
        {
            foreach (@{$stdout})
            {
                $c->error("\t$_", 'err');
            }
        }

        if ($verb > 2)
        {
            $c->error("failed command \[".join(" ", "apt-get", @cmdline)."\]", 'err');
        }

        return undef;
    }

    return $stdout;
}


sub extract_apt_error
{
    my $c = shift;
    my $errs = shift;
    my @errors;

    foreach (@{$errs})
    {
        chomp;
        if (m/^E:\s+(.*)/)
        {
            push @errors, $1;
        }
    }

    if (scalar(@errors))
    {
        return wantarray ? @errors : join("\n", @errors);
    }

    return "unknown";
}


sub parse_apt_output
{
    my $result = shift;
    my %opmap = qw(Inst installing Remv removing Upgr upgrading);
    my (@msgs, %todo);

    foreach my $line (@{$result})
    {
	if ($line =~ m/(Inst|Remv)\s+(\S+)\s+\((\S+)\s+([^\)]+)\)/i)
	{
	    my ($op, $packagename, $version, $repository) = ($1, $2, $3, $4);

	    my $msg = "$opmap{$op} $packagename $version";
	    push(@{$todo{$op}}, $msg);
	}
	elsif ($line =~ m/(Inst)\s+(\S+)\s+\[([^\]]+)\]\s+
			\((\S+)\s+(\S+).*/xi)
	{
            my ($op, $packagename, $old_version, $new_version, $repository)
		= ($1, $2, $3, $4, $5);

	    my $msg = "$opmap{Upgr} $packagename $old_version -> $new_version";
	    push(@{$todo{$op}}, $msg);
        }

    }

    if (exists $todo{Inst})
    {
	my $count = scalar(@{$todo{Inst}});
	push(@msgs, "installing $count packages", @{$todo{Inst}});
    }
    if (exists $todo{Remv})
    {
	my $count = scalar(@{$todo{Remv}});
	push(@msgs, "removing $count packages", @{$todo{Remv}});
    }

    return \@msgs;
}

1;
