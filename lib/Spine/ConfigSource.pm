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

package Spine::ConfigSource;
our ($VERSION, $ERROR);

$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);

use IO::File;

#
# FIXME
#
#  - Definitely need something like a Spine::Config class for a spine script
#    config file parser and storage.  Then pass it into new()
#
sub new
{
    my $klass = shift;
    my %args  = @_;

    my $self = bless { Config => $args{Config},
                       Release => $args{Release} || undef,
                       Path => $args{Path} || undef,
                     }, $klass;

    return $self;
}


#
# All methods for Spine::ConfigSource objects should return:
#
#   - true when there is new config data
#   - false when there is no new config data
#   - undef for error
#


#
# Check for any new releases
#
sub check_for_update
{
    my $self         = shift;
    my $previous_rev = shift;

    return undef;
}


#
# Retrieve a specific version of the config, if possible
#
sub retrieve
{
    my $self = shift;
    my $release = shift;

    return undef;
}


#
# Retrieve the latest version of the config
#
sub retrieve_latest
{
    my $self = shift;

    return undef;
}


#
# Return the filesystem path to the top of the config hierarchy
#
sub config_root
{
    my $self = shift;

    return $self->{Path};
}


#
# Clean up any tempfiles, etc.
#
sub clean
{
    my $self = shift;

    return 1;
}


#
# Returns configuration location information
#
sub source_info
{
    my $self = shift;

    return 'Spine::ConfigSource::source_info() must be overridden!';
}


#
# Reads in the release number of the configuration tree we're pointing to
#
sub _check_release
{
    my $self  = shift;

    unless (exists($self->{Release}) and defined($self->{Release}))
    {
        my $rfile = $self->{Path} . '/Release';

        unless (-f $rfile and -r $rfile) {
            $ERROR = "Release file \"$rfile\" doesn't exist or isn't readable!";
            $self->{error} = $ERROR;
            return undef;
        }

        my $fh = new IO::File("< $rfile");

        if (not defined($fh))
        {
            $ERROR = "Failed to open release file \"$rfile\": $!";
            $self->{error} = $ERROR;
            return undef;
        }

        # Should be only one line
        my @lines = <$fh>;

        $fh->close();

        my $rel = join('', @lines);

        chomp($rel);

        if ($rel =~ m/\d+/)
        {
            $self->{Release} = $rel;
        }
        # If it's on the filesystem, there's a good chance it'll look like
        # the following:
        elsif ($rel =~ m/^Spine configuration release:\s*(\d+)\s*$/)
        {
            $self->{Release} = $1;
        }
        else
        {
            $ERROR = "Couldn't parse the release file: \"" . join("\n", @lines) . "\"";
            $self->{error} = $ERROR;
            return undef;
        }
    }

    return $self->{Release};
}


sub release
{
    my $self = shift;

    return $self->{Release};
}


1;
