# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: ISO9660.pm 239 2009-08-24 17:29:05Z richard $

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
our ($VERSION, @ISA, $ERROR);

use Digest::MD5;
use File::Temp qw(:mktemp);
use HTTP::Request;
use LWP::UserAgent;
use Spine::ConfigSource;
use Spine::ConfigSource::Cache;
use Storable qw(thaw);
use JSON::Syck;

@ISA = qw(Spine::ConfigSource);
$VERSION = sprintf("%d", q$Revision: 239 $ =~ /(\d+)/);

# See END block at the end of this file.
my @__MOUNTS;

sub new
{
    my $klass = shift;
    my %args = @_;

    my $self = new Spine::ConfigSource(%args);

    bless $self, $klass;

    $self->{Destination} = $args{Destination};
    $self->{URL} = $args{URL};
    $self->{PreviousRelease} = $args{PreviousRelease};

    # If we were passed a Spine::ConfigFile object, use it to populate most of
    # our settings
    if (exists($args{Config}) and defined($args{Config}))
    {
        my $section = $args{Config}->{ISO9660};

        foreach my $item (qw(Destination URL Timeout))
        {
            if ( ( not exists($self->{$item})
                   or not defined($self->{$item}) )
                 and exists($section->{$item}))
            {
                $self->{$item} = $section->{$item};
            }
        }
    }

    # Now some quick sanity checks
    if (not defined($self->{Destination})
        and not defined($self->{URL}))
    {
        $ERROR = "You must specify a source URL and a destination dir for ISO9660 fsballs!\n";
        undef $self;
        return undef;
    }

    if (not exists($self->{Timeout}) or not defined($self->{Timeout}))
    {
        $self->{Timeout} = 30;
    }

    # If the destination directory doesn't exist, create it
    if (not -d $self->{Destination} and not mkdir($self->{Destination}))
    {
        $ERROR = "Failed to created destination directory: $!";
        return undef;
    }

    $self->{UA} = exists($args{UserAgent}) ? $args{UserAgent} :
        new LWP::UserAgent(timeout => $self->{Timeout});

    $self->{_cache} = new Spine::ConfigSource::Cache(Directory => $self->{Destination},
                                                     Method => Spine::ConfigSource::Cache::MAX_FILES,
                                                     Ignore => '^\.');

    if (not defined($self->{_cache}))
    {
        $ERROR = "Cache driver failed to instantiate!";
        return undef;
    }

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


sub _http_request
{
    my $self = shift;
    my $url  = shift;
    my $file = shift;
    my $content = undef;
    my $response;

    my $request = new HTTP::Request('GET', $url);

    #
    # We use the request() method instead of the simple_request() method here
    # because the simple_request() method won't transparently follow
    # redirects, which we definitely want to have happen.
    #
    # rtilder    Wed Apr 13 14:06:56 PDT 2005
    #

    if (defined($file))
    {
        $response = $self->{UA}->request($request, $file);
    }
    else
    {
        $response = $self->{UA}->request($request);
    }

    # Check to be sure it's good
    if ($response->code() != 200)
    {
        $self->{error} = "Bad response code for URL $url: " . $response->code . ' '
            . $response->message;
        return undef;
    }

    return $response;
}


sub _mount_isofs
{
    my $self = shift;
    my $filename = shift;

    if (not defined($filename))
    {
        $filename = $self->{_cache}->get($self->{_filename});
    }

    if ($filename =~ m/^\s*$/ or not -f $filename or not -r $filename)
    {
        $self->{error} = "Nonexistent or unreadable ISO ball filename: \"$filename\"";
        return undef;
    }

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

    my $cmd = "/bin/mount -o loop,ro -t iso9660 $filename $mount";

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


sub check_for_update
{
    my $self = shift;
    my $prev = shift;
    my $file = shift;
    my $check = "$self->{URL}?a=check&prev=$prev";

    my $resp = $self->_http_request($check);

    my $version_data = undef;

    if (not defined($resp))
    {
        goto check_error;
    }

    my $ctype = $resp->header('Content-Type');

    # Deserialize the payload
    if ($ctype eq 'application/perl-storable')
    {
        $version_data = thaw($resp->content);
    }
    elsif ($ctype eq 'application/json')
    {
        $version_data = JSON::Syck::Load($resp->content);
    }
    else
    {
        $self->error("Invalid content type for response for ISO9660::check_for_update: $ctype");
        goto check_error;
    }

    if (not defined($version_data))
    {
        $self->error("Failed to deserialize payload for ISO9660::check_for_update()!");
        goto check_error;
    }

    if ($version_data->{latest_release} > $prev)
    {
        undef $resp;
        return $version_data->{latest_release};
    }

    undef $resp;
    return $prev;

 check_error:
    undef $resp;
    return undef;
}


sub retrieve
{
    my $self = shift;
    my $release = shift;
    my $retrieve = "$self->{URL}?a=gimme&release=$release";
    my $file = "spine-config-$release.iso.gz";
    # Check to see if we have it cached locally first
    my $cached = $self->{_cache}->get($file);

    if ($cached)
    {
        # Lame but for some reason I cant get Cache.pm to work with Exporter
        $self->{_filename} = Spine::ConfigSource::Cache::filename($cached);
        return 1;
    }

    my $resp = $self->_http_request($retrieve);

    if (not defined($resp))
    {
        goto retrieve_error;
    }

    my $ctype = $resp->header('Content-Type');

    if ($ctype ne 'application/x-gzip')
    {
        $self->error("Invalid content type for response in ISO9660::retrieve($release): $ctype");
        goto retrieve_error;
    }
    
    # Since the Cache code currently only loads spine-config-$release.iso.gz
    # this code has been removed. 
    ## It's shame that there isn't a method in the URI class that'll give you
    ## the file name.
    #my @f = split(m|/|, $resp->base->path);
    #$file = pop @f;

    if (not defined($self->{_cache}->add(Buffer => $resp->content,
                                         Filename => $file)))
    {
        print STDERR "Failed to save file to cache!\n";
        goto retrieve_error;
    }

    $self->{_filename} = $file;

    # We don't mount the ISO ball here.  We do it when config_head is first
    # called.
    undef $resp;
    return 1;

 retrieve_error:
    undef $resp;
    return undef;
}


sub retrieve_latest
{
    my $self = shift;

    return $self->retrieve($self->check_for_update());
}


sub config_root
{
    my $self = shift;

    if (not $self->{_mounted})
    {
        if (not $self->_mount_isofs())
        {
            $self->error("Failed to mount $self->{_filename}!");
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
