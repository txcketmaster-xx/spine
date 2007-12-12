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

package Spine::ConfigSource::ISO9660;
our ($VERSION, $ERROR);

use base qw(Spine::ConfigSource::FileSystem Spine::ConfigSource::HTTPFile);

use Digest::MD5;
use File::Temp qw(:mktemp);
use Storable qw(thaw);

@ISA = qw(Spine::ConfigSource);
$VERSION = sprintf("%d.%02d", q$Revision$ =~ /(\d+)\.(\d+)/);

# See END block at the end of this file.
my @__MOUNTS;

sub new
{
    my $klass = shift;
    my %args = @_;

    my $self = new Spine::ConfigSource::HTTPFile(@_);

    # We want to override the default FileSystem contstructor
    bless $self, $klass;

    # See END block at end of this file.
    push @__MOUNTS, $self;
    return $self;
}


sub error {
    my $self = shift;

    if (scalar(@_) > 0)
    {
        $ERROR .= join("\n", @_) . "\n";
    }

    return $ERROR;
}


sub _mount_isofs
{
    my $self = shift;
    my $filename = shift;

    if (not defined($filename))
    {
        $filename = $self->{_cache}->get($self->{filename});
    }

    if ($filename =~ m/^\s*$/ or not -f $filename or not -r $filename)
    {
        $self->{error} = "Nonexistent or unreadable ISO ball filename: \"$filename\"";
        return undef;
    }

    # FIXME  Genericize decompression and start using File::MimeInfo::Magic to
    #        determine file types
    if ($filename =~ m/\.gz$/)
    {
        my $tmpfile = mktemp('/tmp/isofsball.XXXXXX');

        if (not defined($tmpfile) or $tmpfile eq '')
        {
            $self->{error} = "Couldn't create tempfile for uncompressed ISO FS ball: $!";
            goto mount_error;
        }

        my $cmd = "/bin/zcat $filename > $tmpfile";

        my $rc = system($cmd);

        if ($rc >> 8)
        {
            $self->error("Failed to decompress ISO FS ball!");
            goto mount_error;
        }

        $filename = $tmpfile;
        $self->{_tmpfile} = $tmpfile;
    }

    # Create a tempdir to mount under
    my $mount = mkdtemp('/tmp/isofsball.XXXXXX');

    if (not defined($mount))
    {
        $self->error("Couldn't create a temporary directory for mounting!");
        goto mount_error;
    }

    my $cmd = "/bin/mount -o loop -t iso9660 $filename $mount";

    my $rc = system($cmd);

    if ($rc >> 8)
    {
        $self->error("Failed to mount the ISO FS ball!");
        goto mount_error
    }

    $self->{Path} = $mount;

    return $mount;

 mount_error:
    if (-d $mount)
    {
        rmdir($mount);
    }

    if ($filename =~ m|^/tmp/isofsball\.|)
    {
        unlink($filename);
    }
    undef $filename;
    undef $mount;
    return undef;
}


sub _umount_isofs
{
    my $self = shift;
    my $path = shift;

    if (not defined($path))
    {
        $path = $self->{Path};
    }

    if (! -d $path)
    {
        $self->error("Can't unmount $path: doesn't exist!");
        return undef;
    }

    my $cmd = "/bin/umount $path";

    my $rc = system($cmd);

    if ($rc >> 8)
    {
        $self->error("Failed to unmount the ISO FS ball!");
        return undef;
    }

    if (exists($self->{_tmpfile}) and defined($self->{_tmpfile}))
    {
        unlink($self->{_tmpfile});
    }

    rmdir($path);

    return 1;
}


sub config_root
{
    my $self = shift;

    if (not $self->{_mounted})
    {
        if (not $self->_mount_isofs())
        {
            $self->error("Failed to mount $self->{filename}!");
            return undef;
        }
        $self->{_mounted} = 1;
    }

    $self->{Release} = $self->_check_release();

    if (not defined($self->{Release}))
    {
        $self->error("Couldn't verify release data in ISO9660::config_root()");
        $self->_umount_isofs();
        return undef;
    }

    return $self->{Path};
}


sub clean
{
    my $self = shift;

    return $self->_umount_isofs();
}


sub source_info
{
    my $self = shift;

    return "ISO9660 configball(cached in $self->{Destination})";
}


# XXX  Probably far nicer than calling clean() everywhere but hard to do
#      without setting up module level var just for cleaning.
#
END {
    foreach my $self (@__MOUNTS) {
        $self->clean();
    }
}


1;
