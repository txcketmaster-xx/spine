# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=4:expandtab:textwidth=78:softtabstop=4:ai:

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

package Spine::Plugin::Overlay::Emitter;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d.%02d", q$Revision$ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Emits the temporary working copy, interpolating variables in file names and symlink targets";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { PREPARE => [ { name => 'build_overlay',
                                      code => \&build_overlay } ] }
          };


##############################################################################
#
# Features needed:
#
#   - Abstraction!  Stop using File::Find::find() and lstat() and start
#     pulling that data via an API from Spine::ConfigSource(that needs to be
#     defined.
#   - *WAY* better error reporting
#
#
##############################################################################


use File::Copy;
use File::Find;
use File::Spec::Functions;
use File::stat;
use Fcntl qw(:mode);
use Spine::Plugin::Interpolate qw(interpolate_value);

my ($C, $CROOT, $DRYRUN, $OVERLAY_SOURCE, $OVERLAY_TARGET, $TMPDIR) = undef;

sub build_overlay
{
    my $c = $C = shift;
    my $croot = $CROOT = $c->getval('c_croot');
    my $tmpdir = $TMPDIR = $c->getval('c_tmpdir');
    my $tmplink = $c->getval('c_tmplink');
    my $class = $c->getval('c_class');
    my $instance = $c->getval('c_instance');
    my @excludes = @{$c->getvals('build_overlay_excludes')}
        if ($c->getval('build_overlay_excludes'));
    my $masochist = $c->getval_last('masochistic_build_overlay');
    my $overlay_map = $c->getvals_as_hash('overlay_map');

    my $rval = 0;
    my $youve_been_warned = 0;

    $DRYRUN = $c->getval('c_dryrun');

    unless (mkdir_p($tmpdir, 0755)) {
        # Return a fatal error to the caller.
        $c->error("could not create temp directory", 'crit');
        return PLUGIN_FATAL;
    }

    # Create a symlink pointing to the most recent overlay.
    unlink $tmplink if (-l $tmplink);
    symlink $tmpdir, $tmplink;

    # This is a for loop instead of a foreach because I want to manipulate the
    # $dir variable without affecting the Spine::Data object's data members
    #
    # rtilder    Tue Dec 19 14:11:38 PST 2006
    for my $dir ( @{$c->getvals("c_descend_order")} ) {
        unless (file_name_is_absolute($dir)) {
            $dir = catdir($croot, $dir);
        }

        while (my ($source, $target) = each(%{$overlay_map})) {
            if (-d catdir($dir, $source)) {
                $OVERLAY_SOURCE = catdir($dir, $source);
                $OVERLAY_TARGET = catdir($dir, $target);
                find( { follow => 0, no_chdir => 1,
                        wanted => \&walk_overlay_source }, $OVERLAY_SOURCE);
            }
        }
        $OVERLAY_SOURCE = $OVERLAY_TARGET = undef;
    }

    return PLUGIN_SUCCESS;
}


#
# FIXME   Needs to handle excludes, too!
#
# $C, $OVERLAY_SOURCE, and $OVERLAY_TARGET are module level globals
#
sub walk_overlay_source
{
    my $fname = $File::Find::name;

    # The target filename
    my (undef, $dest) = split(/$OVERLAY_SOURCE/, $fname);

    #
    # Create our destination name based on OVERLAY_TARGET and while we're 
    # munging it do any interpolation as necessary.
    #
    $dest = catdir($OVERLAY_TARGET, interpolate_value($C, $dest));

    interpolate_and_emit_filesystem_entry($fname, $OVERLAY_TARGET);
}


#
# Doesn't handle but probably should:
#
#  - Extended attributes
#  - FS ACL extensions
#  - SELinux contexts
#
sub interpolate_and_emit_filesystem_entry
{
    my ($source, $target) = @_;
    my $lstat = lstat($source);

    #
    # Create our destination name based on OVERLAY_TARGET and while we're
    # munging it do any interpolation as necessary.
    #
    $target = interpolate_value($C, $target);

    if (S_ISDIR($lstat->mode)) {
        mkdir($target) or die("Failed to create directory $target: $!");
    }
    # XXX  Should we have an optional warning for missing link targets?
    elsif (S_ISLNK($lstat->mode)) {
        symlink(interpolate_value($C, readlink($source)), $target)
            or die("Failed to create symlink $target: SUCK! $!");
    }
    # Since we have to call out to mknod we just do all three
    elsif (S_ISCHR($lstat->mode)
           or S_ISBLK($lstat->mode)
           or S_ISFIFO($lstat->mode)) {
        my $cmd = "/bin/mknod $target";

        if (S_ISCHR($lstat->mode)) {
            $cmd .= ' c ';
        }
        elsif (S_ISBLK($lstat->mode)) {
            $cmd .= ' b ';
        }
        elsif (S_ISFIFO($lstat->mode)) {
            $cmd .= ' p ';
        }

        $cmd .= major($lstat->rdev) . ' ' . minor($lstat->rdev);

        system($cmd) || die("Failed to create device: $target! \"$cmd\": $!");
    }
    elsif (S_ISREG($lstat->mode)) {
        copy($fname, $target) || die("Failed to copy $fname to $target: $!");
    }

    chmod($lstat->mode, $target) or die("Failed to chmod $target: $!");
    # FIXME  Need to support usernames.  Blech
    chown($lstat->uid, $lstat->gid, $target) or die("Failed to chown $target:"
        . " $!");
}


# These only work for Linux for certain, though it's probably very portable
sub major($)
{
    return (($_ >> 8) & 0xfff) | (($_ >> 32) & ~0xfff)
}


sub minor($)
{
    return ($_ & 0xff) | (($_ >> 12) & ~0xff)
}


1;
