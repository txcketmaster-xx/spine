# -*- mode: perl; cperl-set-style: BSD; index-tabs-mode: nil; -*-
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

use Spine::Constants qw(:basic);

our ($VERSION, @EXPORT_OK, @EXPORT_FAIL, $dns_schema);

our $dns_schema = '
                ([-a-z\d_]+[a-z])(\d+)\.
                ([-a-z_]{2,})\.
                ([-a-z_]{2,}\d+)
                (?:\.([-a-z_]{2,}))
                (?:\.([-a-z_]+))?
                ';

@EXPORT_OK = qw(mkdir_p makedir safe_copy touch resolve_address do_rsync
                exec_command exec_initscript);
@EXPORT_FAIL = qw(_old_do_rsync);


sub mkdir_p
{
    my $dir = shift;
    my $perm = shift || 0755;

    my $part;
    for my $piece (split(/\//, $dir))
    {
        $part = $part . "/" . $piece;
        $part =~ s@//@/@g;
        mkdir($part, $perm) unless (-d "$dir");
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
    my $mask = 0777;
    $mask = shift if @_;

    my $pre = '/';
    foreach my $stub (split('/',$dir))
    {
        next unless $stub;
        unless (-d "$pre$stub")
        {
            unless (mkdir("$pre$stub",$mask))
            {
                return 0;
            }
        }
        $pre = $pre . $stub . '/';
    }
    return $dir;
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
    my $rsync_bin = $c->getval("rsync_bin");
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

    # But we always at --archive, just to be safe
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

    my $rsync_opts = join(' ', @rsync_opts);
    my $cmd = "$rsync_bin $rsync_opts $args{Source} $args{Target} 2>&1";
    $c->cprint("rsync command: \"$cmd\"", 4);

    my $result = `$cmd`;

    unless ($? == 0)
    {
        $c->error("rsync failed from $args{Source} [$result]", "err");
        unlink($tmpfn);
        return SPINE_FAILURE;
    }

    $c->cprint("rsync completed from $args{Source}", 4);

    # Hand back the output for processing if requested
    if (defined($args{Output}) and ref($args{Output}) eq 'SCALAR')
    {
        ${$args{Output}} = $result;
    }

    unlink($tmpfn);
    return SPINE_SUCCESS;
}


sub exec_initscript
{
    my ($c, $service, $function, $report_error) = @_;
    return 1 if $c->getval('c_dryrun');

    my $service_bin = $c->getval("service_bin");

    my $result = `$service_bin $service $function 2>&1`;
    if ($? > 0 and $report_error > 0)
    {
        $c->error("failed to $function $service", 'err');
        return 0;
    }
    return 1;
}


sub exec_command
{
    my ($c, $command, $report_error) = @_;
    return 1 if $c->getval('c_dryrun');

    my $result = `$command 2>&1`;
    if ($? > 0 and $report_error > 0)
    {
        $c->error("failed to execute $command", 'err');
        return 0;
    }
    return 1;
}

1;
