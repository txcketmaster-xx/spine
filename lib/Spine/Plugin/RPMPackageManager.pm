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

package Spine::Plugin::RPMPackageManager;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);
$DESCRIPTION = "RPM package management using the apt-get for RPM utility";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { APPLY => [ { name => 'install_packages',
                                    code => \&install_packages } ],
                       CLEAN => [ { name => 'clean_packages',
                                    code => \&clean_packages } ]
                     },
          };


use File::Spec::Functions;
use IO::Handle;
use IPC::Open3;
use Spine::RPM;
use Spine::Util qw(mkdir_p);

my $DRYRUN = 0;

sub install_packages
{
    my $c = shift;
    my $rval = 0;
    my $packages = $c->getvals("packages");
    $DRYRUN = $c->getval('c_dryrun');

    apt_exec($c, 'autoclean', '', 0) or $rval++;
    apt_exec($c, 'update', '', 0) or $rval++;
    apt_exec($c, 'dist-upgrade', '', 1) or $rval++;
    apt_exec($c, 'update', '', 0) or $rval++;

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
    my $aptget_bin = $c->getval("aptget_bin");
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
                            /var/state/apt/lists/partial
                            /var/lib/apt/lists/partial))
        {
            unless (Spine::Util::mkdir_p(catfile($overlay, $dir)))
            {
                $c->error("Failed to create directory $dir", 'err');
                return PLUGIN_ERROR;
            }
        }

        my $apt_conf_ovrl = catfile($overlay, qw(etc apt));

        push @aptget_args, '--option Dir=' . $c->getval('c_tmpdir');

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

        my @apt_cmd = ($aptget_bin, @aptget_args, '--dry-run', $apt_func,
                       $apt_func_args);

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

        my @apt_cmd = ($aptget_bin, @aptget_args, '-qq', $apt_func,
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

    if (ref($_[0]) eq 'ARRAY')
    {
        # The plus sign is so that we actually call the shift function
        @cmdline = @{ +shift };
    }

    my $cmdline = join(' ', @cmdline);
    $c->print(5, "Command line is: $cmdline");

    # Reset our fh handles
    my $stdin  = new IO::Handle();
    my $stdout = new IO::Handle();
    my $stderr = new IO::Handle();

    #
    # IPC::Open3::open3() is stupid.  If the filehandles you pass in are
    # IO::Handle objects and the command to run is pass in as an array,
    # it won't exec the command line properly.  However, if you join() it
    # head of time, it'll run just fine.  So broken.
    #
    # rtilder    Tue Apr 10 09:27:46 PDT 2007
    #
    eval { $pid = open3($stdin, $stdout, $stderr, $cmdline); };

    if ($@)
    {
        $c->error("Some sort of exec'ing problem with apt-get: $@", 'err');
        return undef;
    }

    # Siphon off output and error data so we can then waitpid() to reap
    # the child process
    $stdin->close();

    my @foo = $stdout->getlines();
    $stdout = [@foo];

    @foo = $stderr->getlines();
    $stderr = [@foo];

    my $rc = waitpid($pid, 0);

    if ($rc != $pid)
    {
        $c->error('apt-get failed to run it seems', 'err');
        return undef;
    }

    # If there was an error, print it out
    if ($? >> 8 != 0)
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
            $c->error("failed command \[$cmdline\]", 'err');
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


sub clean_packages
{
    my $c = shift;
    my $rval = 0;
    my $rpm_bin = $c->getval('rpm_bin');
    my $rpm_opts = $c->getval('rpm_opts') || qq('');

    # apt understands package.arch but RPM does not. The Spine RPM module
    # uses the "name" tag from the installed RPM and compares that to the 
    # values of the package key. package != package.arch so it will 
    # uninstall the package. We strip off the .arch portion before 
    # calling the keep function. Thanks to Nic for the idea.
    # 
    # cfb       Thu Jun 18 17:55:12 PDT 2009
    #
    my @packages;
    foreach my $package (@{$c->getvals('packages')})
    {
	my ($clean, undef) = split(/#|=/, $package);
        $clean =~ s/\.(32bit|noarch)$//;
	push @packages, $clean;	
    }

    $c->print(2, "checking for unauthorized packages");
    my @remove = Spine::RPM->new->keep(@packages);

    if ( scalar @remove > 0 )
    {
	my $remv = join (" ", @remove);
	$c->print(2, "removing packages \[$remv\]");

	unless ($c->getval('c_dryrun'))
	{
	    my $result = `$rpm_bin -e $rpm_opts $remv 2>&1`;
	    if ($? > 0)
	    {
	        $c->error("package removal failed \[$result\]", 'err');
	        $rval++;
	    }
	}
    }

    return $rval ? PLUGIN_ERROR : PLUGIN_SUCCESS;
}


1;
