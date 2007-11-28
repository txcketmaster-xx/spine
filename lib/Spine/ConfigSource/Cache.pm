# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Cache.pm,v 1.3.14.1 2007/10/02 22:01:33 phil Exp $

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

$VERSION = sprintf("%d.%02d", q$Revision: 1.3.14.1 $ =~ /(\d+)\.(\d+)/);


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
use IO::File;
use IO::Dir;

use constant BUFSIZ       => 256 * 1024;
use constant MAX_FILES    => 0;
use constant KEEP_LARGEST => 1;
use constant KEEP_NEWEST  => 2;

use constant DEBUG => 1;

sub new
{
    my $klass = shift;
    my %args  = @_;

    my $problems = 0;

    my $self = bless { _path   => $args{Directory},
                       _match  => $args{Match},
                       _ignore => $args{Ignore},
		       _method => $args{Method},
                       _m_data => $args{Params},
		       _f2h    => {},
		       _h2f    => {}
		     }, $klass;

    if (not -d $self->{_path}) {
        warn "$self->{_path} is not a directory";
        return undef;
    }

    my $d = new IO::Dir($self->{_path});
    if (not defined($d)) {
        warn "Could not open $self->{_path}: $!";
        return undef;
    }


    # Walk the list and populate our cache info
    while (defined(my $entry = $d->read())) {
        my $path = "$self->{_path}/$entry";

        if (not -f $path) {
            next;
        }

        if ( defined($self->{_ignore})
             and $entry =~ m/$self->{_ignore}/ ) {
            next;
        }

#        if ( defined($self->{_match})
#             and $entry =~ m/$self->{}/ ) {
#            $problems++;
#            next;
#        }

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
    my $name = filename(shift);

    my $path = $self->get_file_by_name($name);

    if (not $path) {
        $path = $self->get_file_by_hash($name);
    }

    return $path;
}


sub get_file_by_name
{
    my $self = shift;
    my $name = filename(shift);

    if (not exists($self->{_f2h}->{$name})) {
        return '';
    }

    return "$self->{_path}/$name";
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

    return $self->{_path} . '/' . $self->{_h2f}->{lc($hash)};
}


sub add
{
    my $self = shift;
    my %args = @_;

    # Copying an existing file into the cache
    if (exists($args{Source})) {
	if (not -f $args{Source}) {
	    warn "Can't add non-existent file $args{Source}.\n";
	    return undef;
	}

	# Make sure we have a valid filename
	my $fname;
	if (exists($args{Filename})) {
	    $fname = $args{Filename};
	}
	else {
	    $fname = filename($args{Source});
	}

        my $contents = _file_contents($args{Source});

        if (not defined($contents)) {
            warn "Couldn't add $args{Source} to cache.";
            return undef;
        }

	return $self->_add_to_cache($fname, $contents);
    }
    elsif (exists($args{Buffer})) {
        # FIXME  Should we require a filename?  Might we just not request by
        #        hash?
	if (not exists($args{Filename})) {
	    warn "A Filename argument is required when passing in a buffer";
	    return undef;
	}

	return $self->_add_to_cache(filename($args{Filename}), $args{Buffer});
    }

    return undef;
}

# FIXME  This really needs to get written
sub expire
{
    my $self = shift;

    if ($self->{_method} == MAX_FILES) {

    }
    elsif ($self->{_method} == KEEP_LARGEST) {

    }
    elsif ($self->{_method} == KEEP_NEWEST) {

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
	my $dest = "$self->{_path}/$fname";
	my $hash = md5_hex($buf);

	# Check to make sure we don't already have an entry for this filename
	if (exists($self->{_f2h}->{$fname})) {
	    if ($hash ne $self->{_f2h}->{$fname}) {
		warn "Same filename with two different hashes!  Overwriting.";
	    }
	    else {  # Almost certainly the same file
		if (-f $dest) {
		    undef $fname;
		    undef $buf;
		    return 1;
		}
		else {
		    warn "Shouldn't reach here unless there's a cache bug.";
		    return undef;
		}
	    }
	}

	# Check to make sure we don't already have an entry for this filename
	if (exists($self->{_h2f}->{$hash})) {
	    if ($fname ne $self->{_h2f}->{$hash}) {
		warn "Two different files with the same hash.  Duplicate data?";
	    }
	    else { # Almost certainly the same file
		if (-f $dest) {
		    undef $fname;
		    undef $buf;
		    return 1;
		}
		else {
		    warn "Shouldn't reach here unless there's a cache bug.";
		    return undef;
		}
	    }
	}

	# Should be able to add this as a new entry
	my $fh = new IO::File("> $dest");

	if (not defined($fh)) {
	    warn "Couldn't open cache destination $dest for writing: $!";
	    return undef;
	}

	if (syswrite($fh, $buf, length($buf)) < length($buf)) {
	    warn "Short write to cache destination $dest: $!";
	    $fh->close();
	    undef $fh;
	    return undef;
	}

	$fh->close();

	# Add the cache entries
	$self->{_f2h}->{$fname} = $hash;
	$self->{_h2f}->{$hash}  = $fname;
    }

    return 1;
}


sub filename
{
    my $incoming = shift;

    if ($incoming =~ m|/|) {
	my $fname;
	my @s = split(m|/|, $incoming);

	$fname = pop(@s);
	chomp($fname);

	return $fname;
    }

    return $incoming;
}

1;
