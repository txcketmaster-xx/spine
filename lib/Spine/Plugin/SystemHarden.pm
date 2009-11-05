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

package Spine::Plugin::SystemHarden;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ( $VERSION, $DESCRIPTION, $MODULE );

$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);
$DESCRIPTION = "Removes setuid and setgid bits from all files not listed in the privfiles key";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { CLEAN => [ { name => 'system_harden',
                                    code => \&system_harden } ]
                     }
          };


use File::Spec::Functions;
use File::Find;
use File::stat;
use Fcntl qw(:mode);

my @HARDEN;
my $c;

sub system_harden
{
    $c = shift;
    my $root = shift;

    my $rval = 0;
    my $find_bin = $c->getval("find_bin");
    my $chmod_bin = $c->getval("chmod_bin");
    my $overlay_root = $c->getval("overlay_root");
    my $croot = $c->getval("c_croot");

    unless ($c->check_exec($find_bin, $chmod_bin)) { return 1; }

    $c->cprint(" searching for SUID/SGID files", 2);

    find( { wanted => \&_find_wanted, no_chdir => 1 }, $overlay_root );

    foreach my $file (@HARDEN)
    {
	next if $file =~ /^\Q$croot\E/;
	next if ( grep {/$file/} @{$c->getvals("privfiles")} );

	$c->cprint("stripping suid/sgid bits from $file", 2);

	next if ($c->getval('c_dryrun'));

        my $sb = lstat($file);
        my $result = chmod $sb->mode & ~(S_ISUID|S_ISGID), $file;

        unless ($result == 1)
        {
            $c->error("$result", "err");
            $rval++;
        }
    }

    return $rval;
}

sub _find_wanted 
{

    my $st = lstat($_);

    # If the file isn't on the local filesystem, ignore it.
    if (-d $_ and $st->dev != $File::Find::topdev)
    {
        $File::Find::prune = 1;
        return;
    }

    # If its a link log a warning, else if its a file push it onto the list.
    if (-l $_ and ($st->mode & (S_ISUID|S_ISGID)))
    {
        $c->cprint("skipping symlink ($_) found with SUID/SGID bit set", 2);
    }
    elsif (-f $_ and ($st->mode & (S_ISUID|S_ISGID)))
    {
        push @HARDEN, $_;
    }
}

1;
