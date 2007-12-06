# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Cache.pm,v 1.3.2.1.2.2 2007/09/13 16:15:15 rtilder Exp $

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

package Spine::ConfigSource::Cache;
our ($VERSION, $ERROR);

$VERSION = sprintf("%d.%02d", q$Revision: 1.3.2.1.2.2 $ =~ /(\d+)\.(\d+)/);


#
# This is a pretty lame file caching engine.
#
# rtilder    Fri Apr 29 13:03:16 PDT 2005
#

#
# TODO:
#
# - Finish expire()'s basic functionality
#

use Digest::MD5 qw(md5_hex);
use File::Basename;
use File::Path;
use File::Spec::Functions;
use File::stat;
use IO::File;
use IO::Dir;

use constant {
    BUFSIZ       => 256 * 1024,
    MAX_FILES    => 1,
    KEEP_NEWEST  => 2,
};

our $DEBUG = $ENV{RBX_CONFIGSOURCE_DEBUG} || 0;


sub new
{
    my $klass = shift;
    my %args  = @_;

    my $problems = 0;

    my $self = bless { _path   => $args{Directory},
                       _match  => $args{Match},
                       _ignore => $args{Ignore} || qr/(?:^\.|~$)/o,
                       _method => $args{Method} || MAX_FILES,
                       _m_data => $args{Params} || 10,
                       _f2h    => {},
                       _h2f    => {}
                     }, $klass;

    if (not -d $self->{_path}) {
        if (not -e $self->{_path}) {
            mkpath($self->{_path}, 0, 0755);
        }
        else {
            warn "$self->{_path} exists but is not a directory";
            return undef;
        }
    }

    my $d = new IO::Dir($self->{_path});
    if (not defined($d)) {
        warn "Could not open $self->{_path}: $!";
        return undef;
    }

    # Walk the list and populate our cache info
    while (defined(my $entry = $d->read())) {
        my $path = catfile($self->{_path}, $entry);

        next if (not -f $path or $entry =~ m/$self->{_ignore}/ );

        my $contents = _file_contents($path);

        if (not defined($contents)) {
            $problems++;
            next;
        }

        my $hash = md5_hex($contents);

        $self->{_f2h}->{$entry} = $hash;
        $self->{_h2f}->{$hash}  = $entry;
    }

    return $problems ? undef : $self;
}


sub get
{
    my $self = shift;
    my $name = basename(shift);

    my $path = $self->get_file_by_name($name);

    if (not $path) {
        $path = $self->get_file_by_hash($name);
    }

    # If $path still not defined, try treating it as just a release number
    unless (defined($path)) {
        foreach my $fname (keys(%{$self->{_f2h}})) {
            if ($fname =~ m/$name/o) {
                $path = catfile($self->{_path}, $fname);
                last;
            }
        }
    }

    return $path;
}


sub get_file_by_name
{
    my $self = shift;
    my $name = basename(shift);

    if (not exists($self->{_f2h}->{$name})) {
        return '';
    }

    return catfile($self->{_path}, $name);
}


sub get_file_by_hash
{
    my $self = shift;
    my $hash = shift;

    if (ref($hash) eq 'Digest::MD5') {
	$hash = $hash->hexdigest;
    }
    elsif (ref($hash) ne '') {
	warn "Invalid hash passed to get_file_by_hash!\n";
	return undef;
    }

    if (not exists($self->{_h2f}->{lc($hash)})) {
        return '';
    }

    return catfile($self->{_path}, $self->{_h2f}->{lc($hash)});
}


sub add
{
    my $self = shift;
    my $arg = shift;

    # If it's a ref to a scalar, we assume it's a buffer
    if (ref($arg)) {
        if (ref($arg) eq 'SCALAR') {
            # FIXME  Should we require a filename?  Might we just not request
            #        by hash?
            if (scalar(@_) != 1) {
                warn "Filename argument is required when passing in a buffer";
                return undef;
            }

            return $self->_add_to_cache(basename(+shift), $arg);
        }
        else {
            warn "Unsupported argument configuration passed to add()\n";
            return undef;
        }
    }
    elsif ($arg) { # Copy an existing file into the cache
	# Make sure we have a valid filename
        my $contents = _file_contents($arg);

        if (not defined($contents)) {
            warn "Couldn't add \"$arg\" to cache.";
            return undef;
        }

        return $self->_add_to_cache(basename($arg), $contents);
    }
    else {
        warn "Invalid argument passed to add()!\n";
    }

    return undef;
}


#
# FIXME  expire() should really have knowledge of what release, if any, this
#        box is frozen on.
#
sub expire
{
    my $self = shift;

    my $p = $self->{_path};

    if ($self->{_method} == MAX_FILES) {
        my $max_files = $self->{Params};
        my @files = sort { stat(catfile($p, $b))->mtime <=> stat(catfile($p, $a))->mtime } keys(%{self->{_f2h}});

        if (scalar(@files) <= $max_files) {
            return;
        }

        # Remove anything over the 
        for (my $i = $max_files - 1; $i < $#files; $i++) {
            my $fname = $files[$i];
            delete $self->{_h2f}->{$self->{_f2h}->{$fname}};
            delete $self->{_f2h}->{$fname};
            unlink catfile($p, $fname);
        }
    }
    elsif ($self->{_method} == KEEP_NEWEST) {
        return;
    }

    #warn 'Unsupported expiration algo type: ' . $self->{_method};
    return undef;
}


# FIXME  Should this be an END block instead/as well?
sub DESTROY
{
    my $self = shift;

    $self->expire();
}


sub _file_contents
{
    my $fname = shift;

    # Get our buffer
    my ($buf, $final);
    my $fh = new IO::File("<$fname");

    if (not defined($fh)) {
        warn "Failed to open \"$fname\" for reading: $!\n";
        return undef;
    }

    while ($fh->read($buf, BUFSIZ) > 0) {
        $final .= $buf;
    }

    $fh->close();

    return $final;
}


sub _add_to_cache
{
    my $self = shift;
    my %args = @_;

    my ($fname, $buf);
    while (($fname, $buf) = each(%args)) {
        if (ref($buf) eq 'SCALAR') {
            $buf = ${$buf};
        }

        my $dest = catfile($self->{_path}, $fname);
        my $hash = md5_hex($buf);

        # Check to make sure we don't already have an entry for this filename
        if (exists($self->{_f2h}->{$fname})) {
            if ($hash ne $self->{_f2h}->{$fname}) {
                warn "Same filename with two different hashes!  Overwriting.";
            }
            else {  # Almost certainly the same file
                if (-f $dest) {
                    unlink($dest);
                }
                else {
                    warn "Shouldn't reach here unless there's a cache bug.";
                    next;
                }
            }
        }

        # Check to make sure we don't already have an entry for this hash
        if (exists($self->{_h2f}->{$hash})) {
            if ($fname ne $self->{_h2f}->{$hash}) {
                warn "Two different files with the same hash.  Duplicate data?";
            }
        }

        # Should be able to add this as a new entry
        my $fh = new IO::File("> $dest");

        if (not defined($fh)) {
            warn "Couldn't open cache destination $dest for writing: $!";
            next;
        }

        if (syswrite($fh, $buf, length($buf)) < length($buf)) {
            warn "Short write to cache destination $dest: $!";
            $fh->close();
            undef $fh;
            next;
        }

        $fh->close();

        # Add the cache entries
        $self->{_f2h}->{$fname} = $hash;
        $self->{_h2f}->{$hash}  = $fname;
    }

    return 1;
}


1;
