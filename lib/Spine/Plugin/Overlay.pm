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

package Spine::Plugin::Overlay;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE, $DONTDELETE, $TMPDIR, @ENTRIES);

$VERSION = sprintf("%d.%02d", q$Revision$ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Builds the temporary working copy we emit to";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { PREPARE => [ { name => 'build_overlay',
                                      code => \&build_overlay } ],
                       APPLY => [ { name => 'apply_overlay',
                                    code => \&apply_overlay } ],
                       CLEAN => [ { name => 'clean_overlay',
                                    code => \&clean_overlay } ]
                     },
            cmdline => { options => { 'keep-overlay' => \$DONTDELETE } }
          };

use Digest::MD5;
use File::Find;
use File::Spec::Functions;
use File::stat;
use File::Touch;
use Fcntl qw(:mode);
use IO::File;
use Spine::Constants qw(:basic);
use Spine::Util qw(do_rsync mkdir_p);
use Text::Diff;

my $DRYRUN;
my $c; 

sub build_overlay
{
    #
    # I can't for the life of me recall what I was going to use this for.
    #
    # rtilder    Tue Dec 19 08:38:10 PST 2006
    #
    my $self = __PACKAGE__->new();

    $c = shift;
    my $croot = $c->getval('c_croot');
    my $tmpdir = $c->getval('c_tmpdir');
    my $tmplink = $c->getval('c_tmplink');
    my @excludes = @{$c->getvals('build_overlay_excludes')}
        if ($c->getval('build_overlay_excludes'));
    my $masochist = $c->getval_last('masochistic_build_overlay');
    my $rval = 0;
    my $youve_been_warned = 0;

    $DRYRUN = $c->getval('c_dryrun');

    remove_tmpdir($tmpdir);
    unless (mkdir_p($tmpdir, 0755))
    {
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
    for my $dir ( @{$c->getvals("c_descend_order")} )
    {
        my @overlay_map = ('overlay:/');
        if ( exists $c->{'overlay_map'} )
        {
           @overlay_map = @{$c->getvals("overlay_map")}; 
        }
        for my $element ( @overlay_map )
        {
            (my $overlay, my $target) = split( /:/, $element);
            my $overlay = "${dir}/${overlay}/";

            unless (file_name_is_absolute($dir)) {
                $overlay = catfile($croot, $overlay);
                $overlay .= '/'; # catfile() removes trailing slashes
            }

            if ( -d $overlay )
            {
                $c->print(4, "performing overlay from $dir");
                unless (do_rsync(Config => $c,
                                 Source => $overlay,
                                 Target => catfile($tmpdir, $target),
                                 Excludes => \@excludes)) {
                    $rval++;
                }
            }

            # If we've had errors, then we should quit.
            if ($rval) {
                unless ($masochist) {
                    return PLUGIN_FATAL;
                }

                unless ($youve_been_warned) {
                    $youve_been_warned++;
                    $c->print(1, "You're an idiot because you have the ",
                              'masochistic_build_overlay key set to something ',
                              'other than 0.');
                    $c->print(1, "Prepare for PAIN!");
                }
            }
        }
    }

    # If $rval isn't 0 then we've had errors and we should return PLUGIN_ERROR
    #
    # This should always return PLUGIN_SUCCESS because any errors should be
    # caught earlier on.
    return $rval ? PLUGIN_ERROR : PLUGIN_SUCCESS;
}


sub apply_overlay
{
    $c = shift;
    my $tmpdir = $c->getval('c_tmpdir');
    my $tmplink = $c->getval('c_tmplink');
    my $overlay_root = $c->getval('overlay_root');
    my $excludes = $c->getvals('apply_overlay_excludes');
    my $max_diff_lines = $c->getval('max_diff_lines_to_print');
    my $touch = File::Touch->new( no_create => 1 );
    my %rsync_args = (Config => $c, Source => $tmpdir, Output => undef,
                      Target => $overlay_root, Options => [qw(-c)],
                      Excludes => $excludes);

    $TMPDIR = $tmpdir;
    $DRYRUN = $c->getval('c_dryrun');
    @ENTRIES = ();

    if ($overlay_root eq '')
    {
        $c->error('overlay_root key does not exist, no changes will be'
                    . 'applied!', 'alert');
    }

    unless (-d $tmpdir)
    {
	$c->error("temp directory [$tmpdir] does not exist", 'crit');
	return PLUGIN_FATAL;
    }

    # Make sure that the source matches rsync's include pattern rules.
    unless ($tmpdir =~ m|/$|) {
        $rsync_args{Source} = "$tmpdir/";
    }

    # Populates @ENTRIES via the find_changed() callback
    find( { follow => 0, no_chdir => 1, wanted => \&find_changed },
          $tmpdir);

    foreach my $srcfile (@ENTRIES)
    {
        chomp $srcfile; # most likely redundant
        my $destfile = $srcfile;

        if ($srcfile !~ m!^$tmpdir!)
        {
            $srcfile = $tmpdir . $srcfile;
        }
        else
        {
            (undef, $destfile) = split(/$tmpdir/, $srcfile);
        }
        next if $destfile =~ /^$/;

        sync_attribs($c, $srcfile, $destfile) if (-e $destfile);

        # Compare the source and destination files.  If nothing
        # has changed, delete the source file from the temp overlay.
        if ( (-f $destfile) && (-f $srcfile) )
        {
            # if the source/dest file is binary, don't bother calculating
            # diffs, since they are likely undisplayable anyways
            if ( (-B $destfile && ! -z $destfile)
                  || (-B $srcfile && ! -z $srcfile) )
            {
                $c->print(2, "Patching binary file $destfile");
                next;
            }

            my $diff = diff($destfile, $srcfile);
            my @diff = split(/\n/, $diff);

            if (length($diff))
            {
                $c->print(2, "updating $destfile");

                my $size = scalar(@diff);

                if (defined($max_diff_lines)
                    and $max_diff_lines > 0
                    and $size >= $max_diff_lines)
                {
                    $c->print(2, "Changes to $destfile are too large to print("
                                  . "$size >= $max_diff_lines lines)");
                }
                else
                {
                    foreach my $line (@diff)
                    {
                        $line =~ s/$tmpdir/spine-overlay/g;
                        $c->cprint("    $line", 2, 0) if ($line =~ /^[+-]/);
                    }
                }
                $touch->touch($srcfile);
            }
        }
        elsif (not -e $destfile)
        {
            my $src_stat = lstat($srcfile);

            $c->print(2, "creating $destfile"
                      . ' [mode ' . octal_conv($src_stat->mode) . ' |'
                      . ' owner/group ' . uid_conv($src_stat->uid) . ':'
                      . gid_conv($src_stat->gid) . ']');
        }
    }

    unless ($DRYRUN)
    {
        if (do_rsync(%rsync_args) != SPINE_SUCCESS)
        {
            # These particular return values don't necessarily indicate that
            # the transfer wasn't at least partially successful.  See the
            # rsync man page for more information.  Necessary because /media
            # is read only almost everywhere but the mount point needs to be
            # created if the filesystem
            #
            # rtilder    Wed Jun  6 14:08:49 PDT 2007
            my $rc = $? >> 8;

            if ($rc == 23 or $rc == 24)
            {
                $c->error("rsync partial failure!  This is probably very bad.",
                          'err');

                if ($c->getval('partial_rsync_ok'))
                {
                    return PLUGIN_SUCCESS;
                }
            }

            $c->error("rsync failed!  Couldn't apply filesystem changes",
                      'err');
            return PLUGIN_FATAL;
        }
    }

    return PLUGIN_SUCCESS;
}


sub sync_attribs
{
    $c = shift;
    my ($srcfile, $destfile) = @_;

    my $src_stat = lstat($srcfile);
    my $dest_stat = lstat($destfile);

    unless ($src_stat->mode eq $dest_stat->mode)
    {
       $c->print(2, "updating permissions on $destfile from " .
                 octal_conv($dest_stat->mode) . " to " .
                 octal_conv($src_stat->mode));

        chmod $src_stat->mode, $destfile
            unless ($DRYRUN);
    }

    unless ( ($src_stat->uid eq $dest_stat->uid) and
             ($src_stat->gid eq $dest_stat->gid) )
    {
        $c->print(2, "updating owner/group on $destfile from " .
                  uid_conv($dest_stat->uid) . ":" .
                  gid_conv($dest_stat->gid) . " to " .
                  uid_conv($src_stat->uid) . ":" .
                  gid_conv($src_stat->gid));
    }

    chown $src_stat->uid, $src_stat->gid, $destfile
        unless ($DRYRUN);
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


sub clean_overlay
{
    $c = shift;
    my $tmpdir = $c->getval('c_tmpdir');
    my $tmplink = $c->getval('c_tmplink');
    my $rc = 0;

    # If --keep-overlay was specified on the command line, pretend like we did
    if ($DONTDELETE) {
        $c->print(1, "Leaving overlay in \"$tmpdir\"");
        return PLUGIN_SUCCESS;
    }

    $rc = remove_tmpdir($tmpdir);
    unlink $tmplink;

    return PLUGIN_SUCCESS;
}


sub remove_tmpdir
{
    my $tmpdir = shift;

    # rm -rf paranoia.
    if ( ($tmpdir =~ m@^/tmp/.*@) and ($tmpdir =~ m@[^\.~]*@) )
    {
	my $result = `/bin/rm -rf $tmpdir 2>&1`;
	return 1;
    }

    return 0;
}


#
# @ENTRIES is a module level global
#
sub find_changed
{
    my $fname = $File::Find::name;
    # The target filename
    my (undef, $dest) = split(/$TMPDIR/, $fname);

    if ($fname eq $TMPDIR
        or $fname eq "$TMPDIR/")
    {
        return;
    }

    my $lstat = lstat($fname);
    my $dstat = lstat($dest);

    # Destination doesn't exist?
    unless (defined($dstat))
    {
        goto changed;
    }

    #
    # HAHA!  I'm evil!  unless ( ) { ... } elsif ( ) { ... } else { ... }
    #
    # rtilder    Tue May  1 11:55:41 PDT 2007
    #

    # rdev seems unreliable on 2.4 kernels
    my $kernel_version = $c->getval('c_current_kernel_version');
    my $rdev = 0;
    if ($kernel_version =~ /^2\.4\./)
    {
        $rdev = 1;
    }
    elsif ($lstat->rdev == $dstat->rdev)
    {
       $rdev = 1;
    }

    # Any change in the important stat data?  We disregard A, C, and M times
    # for the newly created overlay for obvious reasons
    unless ($lstat->mode == $dstat->mode
            and $lstat->uid == $dstat->uid
            and $lstat->gid == $dstat->gid
            and $lstat->size == $dstat->size
            and $rdev)
    {
        goto changed;
    }
    # If it's a file, are the contents the same?
    elsif (S_ISREG($lstat->mode) and S_ISREG($dstat->mode)) {
        my $currfh = new IO::File($dest);
        my $newfh  = new IO::File($fname);
        my $curr = new Digest::MD5();
        my $new  = new Digest::MD5();

        binmode $currfh;
        binmode $newfh;

        $curr->addfile($currfh);
        $new->addfile($newfh);

        $currfh->close();
        $newfh->close();
        undef $currfh;
        undef $newfh;

        unless ($curr->hexdigest() eq $new->hexdigest())
        {
            goto changed;
        }

        undef $curr;
        undef $new;
    }
    elsif (S_ISLNK($lstat->mode) and S_ISLNK($dstat->mode)) {
        my $curr_target = readlink $fname;
        my $new_target = readlink $dest;

        if ((defined($curr_target) and defined($new_target))
            and $curr_target ne $new_target) {
            goto changed;
        }
    }

    utime $dstat->atime, $dstat->mtime, $fname;
    return;

  changed:
    push @ENTRIES, $dest;
    return;
}


1;
