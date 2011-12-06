# -*- mode: perl; cperl-set-style: BSD; index-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Util.pm 240 2009-08-25 17:48:58Z richard $

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

package Spine::Util;

use strict;

use base qw(Exporter);

use File::Basename;
use File::Copy;
use File::Spec::Functions;
use File::stat;
use File::Temp;
use Net::DNS;
use Template;
use Scalar::Util;
use Spine::Util::Exec;
use Scalar::Util qw(blessed);

use Spine::Constants qw(:basic);

our ($VERSION, @EXPORT_OK, @EXPORT_FAIL);

@EXPORT_OK = qw(mkdir_p makedir safe_copy touch resolve_address do_rsync
                exec_command exec_initscript octal_conv uid_conv gid_conv
                find_exec simple_exec create_exec);
@EXPORT_FAIL = qw(_old_do_rsync);



sub mkdir_p
{
    my $dir = shift;
    my $perm = shift || 0755;

    # it has to be absolute
    unless (file_name_is_absolute($dir)) {
        return 0;
    }
    
    my $part = "";
    for my $piece (File::Spec->splitdir($dir))
    {
        die if (! defined $dir);
        $part = File::Spec->catdir($part, $piece);
        # Save our umask and wipe it so permissions are absolute
        my $mask = umask oct(0000);
        mkdir($part, $perm) unless (-d "$dir");
        # Reset our umask
        umask $mask;
    }

    if (-d $dir)
    { return 1; }

    return 0;
}

# Routine that creates directory, default mask 0777 - used for making
# mountpoints
sub makedir
{
    my $dir = shift;
    my $perm = shift || 0777;
    
    if (mkdir_p($dir, $perm)) {
        return $dir;
    }
    
    return 0;
}


sub safe_copy
{
    my $srcfile = shift;
    my $dstfile = shift;

    if (-d "$dstfile")
    {
	my $basename = basename($srcfile);
	$dstfile .= "/" . $basename;
	$dstfile =~ s@//@/@g;
    }

    return 1 if (-f "$dstfile");
    copy("$srcfile", "$dstfile") || return 0;
    return 1;
}


sub touch
{
    my $dstfile = shift;
    open(TOUCH, ">> $dstfile");
    close(TOUCH);
}


sub resolve_address
{
    my $host = shift;

    my $res  = Net::DNS::Resolver->new;
    my $query = $res->search($host);

    if ($query)
    {
        foreach my $rr ($query->answer)
        {
            next unless $rr->type eq "A";
            return $rr->address;
        }
    }
}


sub do_rsync
{
    my %args = @_;
    my $c = $args{Config};
    my ($tmpfh, $tmpfn);

    # Should eventually be replaced with File::Rsync.
    my @rsync_opts;

    #
    # If we weren't passed rsync command line options on the stack, populate
    # some defaults
    #
    if (defined($args{Options})
            and ref($args{Options}) eq 'ARRAY'
            and scalar($args{Options}) > 0)
    {
        @rsync_opts = @{$args{Options}};
    }
    else
    {
        if (defined($c->getvals('rsync_opts')))
        {
            @rsync_opts = @{$c->getvals('rsync_opts')};
        }

	if ($c->getval('c_verbosity') > 5)
	{
	    push @rsync_opts, '-v';
	}
	else
	{
	    push @rsync_opts, '-q';
	}
    }

    # But we always add --archive, just to be safe
    push @rsync_opts, '--archive';

    # Process the excludes list.
    if (exists($args{Excludes}) and defined($args{Excludes})
	and (scalar @{$args{Excludes}} > 0))
    {
	$tmpfh = new File::Temp(UNLINK => 0);
	
	if (not defined($tmpfh))
	{
	    $c->error("do_rsync: failed to create tempfile for excludes: $!",
		      'err');
	    return SPINE_FAILURE;
	}

	$tmpfn = $tmpfh->filename();

	if (not $tmpfh->print(join("\n", @{$args{Excludes}})))
	{
	    $tmpfh->close();
	    $c->error("do_rsync: failed to write excludes to tempfile: $!",
		      'err');
	    unlink($tmpfn);
	    return SPINE_FAILURE;
	}

	$tmpfh->close();
	push @rsync_opts, "--exclude-from=$tmpfn"
    }
  
    my $inert = exists $args{Inert} ? $args{Inert} : 0; 
    my @result = simple_exec(c           => $c,
                             exec        => 'rsync',
                             merge_error => 1,
			     inert	 => $inert,
                             args        => [@rsync_opts,
                                             $args{Source},
                                             $args{Target}]);

    unless ($? == 0) {
        $c->error("rsync failed from $args{Source} [".join("", @result)."]",
                  "err");
        unlink($tmpfn);
        return SPINE_FAILURE;
    }

    $c->cprint("rsync completed from $args{Source}", 4);

    # Hand back the output for processing if requested
    if (defined($args{Output}) and ref($args{Output}) eq 'SCALAR')
    {
        ${$args{Output}} = join("", @result);
    }

    unlink($tmpfn);
    return SPINE_SUCCESS;
}


sub exec_initscript
{
    my ($c, $service, $function, $report_error, $inert) = @_;

    return 0 unless simple_exec(c      => $c,
                                exec   => 'service',
                                args   => [ $service,  $function ],
                                inert  => $inert,
                                quiet  => $report_error ? 0 : 1);
    return 1;
}

# wraper to Spine::Util::Exec::simple
sub simple_exec {
    return  Spine::Util::Exec->simple(@_);
}

# wraper to Spine::Util::Exec::new
sub create_exec {
    return  Spine::Util::Exec->new(@_);
}

# wraper to Spine::Util::Exec::find_exec
sub find_exec {
    return  Spine::Util::Exec->find_exec(@_);
}

# DEPRECIATE: for support of old implementation (used in templates)
sub exec_command {
    my ($c, $command, $report_error, $inert, $merror) = @_;
    
    # Work out what the command is vs arguments
    $command =~ m/^([\S]+)(?:\s+(.*))?$/;
    my ($cmd, $args) = ($1, $2);
    
    #TODO This should be uncommented in a few releases time
    #$c->error('use of depreciated "exec_command" please use "simple_exec"',
    #          'warning');

    return simple_exec(exec        => $cmd,
                       args        => $args,
                       inert       => $inert,
                       quiet       => $report_error ? 0 : 1,
                       c           => $c,
                       merge_error => defined $merror ? $merror : 1);
    
}



sub octal_conv
{
    my $int = shift;
    return sprintf "%04o", $int & 07777;
}


sub uid_conv
{
    my $uid = shift;
    my $username = getpwuid($uid);
    return $username if (defined $username);
    return $uid;
}


sub gid_conv
{
    my $gid = shift;
    my $group = getgrgid($gid);
    return $group if (defined $group);
    return $gid;
}



1;
