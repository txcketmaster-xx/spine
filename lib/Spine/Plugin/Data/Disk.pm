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

package Spine::Plugin::Data::Disk;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use File::Spec::Functions;
use File::Basename;
use Spine::Util qw(simple_exec do_rsync mkdir_p octal_conv uid_conv gid_conv);

our ( $VERSION, $DESCRIPTION, $MODULE, $DONTDELETE, $TMPDIR, @ENTRIES );

$VERSION     = sprintf( "%d", q$Revision$ =~ /(\d+)/ );
$DESCRIPTION = "Disk based data.";

$MODULE = { author      => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version     => $VERSION,
            hooks       => {
                       "PARSE/branch" => [ { name => "load_disk_config",
                                             code => \&parse_branch } ], } };

use Spine::Constants qw(:basic :plugin);

sub parse_branch {
    my $c      = shift;
    my $branch = shift;

    my $fatal =
        exists $branch->{fatal_if_missing}
      ? exists $branch->{fatal_if_missing}
      : 0;

    return PLUGIN_SUCCESS unless $branch->{uri_scheme} eq "file";
    
    $branch = $branch->{uri_path};

    unless ( -d $branch ) {
        # is it ok if it's missing?
        if ($fatal) {
            $c->error( "required branch is missing \"$branch\"", 'crit' );
            return PLUGIN_FATAL;
        }
        return PLUGIN_SUCCESS;
    }

    if ( not _get_values( $c, $branch, $fatal ) ) {
        return PLUGIN_ERROR;
    }

#### XXX removed as this is pointless now that the c_hierachy key tracks this
#    # Store the paths we actually managed to descend
#    # in the exact order that we did so.
#    push( @{ $c->{c_descend_order} }, $branch );

    return PLUGIN_SUCCESS;
}

sub _get_values {
    my $c         = shift;
    my $directory = shift;
    my $fatal     = shift;
    my $keys_dir  = $c->getval_last('config_keys_dir') || 'config';

    unless ( defined $directory ) {
        $c->error( "_get_values(): no path passed to method", 'crit' );
        return SPINE_FAILURE;
    }

    $directory = catdir( $directory, $keys_dir );

    unless ( -d $directory ) {
        if ($fatal) {
            $c->error( "required config location is missing \"$directory\"",
                       'crit' );
            return SPINE_FAILURE;
        }
        return SPINE_SUCCESS;
    }

    # Iterate through each file in a hierarchial endpoint and
    # read the contents to extract values.
    my $dir = new IO::Dir($directory);

    unless ( defined($dir) ) {
        $c->error( "_get_values(): failed to open $directory: $!", 'crit' );
        return SPINE_FAILURE;
    }

    my @files = $dir->read();
    $dir->close();

    foreach my $keyfile ( sort(@files) ) {

        # Key names beginning with c_ are reserved for values
        # that are automatically populated by the this module.
        my $keyname = basename($keyfile);
        if ( $keyname eq '.' or $keyname eq '..' ) {
            next;
        }

        if ( $keyname =~ m/(?:(?:^(?:\.|c_\#).*)|(?:.*(?:~|\#)$))/ ) {
            $c->error(
                  "ignoring $directory/$keyname because of lame" . ' file name',
                  'err' );
            next;
        }

        $keyfile = "file:" . catfile( $directory, $keyfile );

        # Read the contents of a file.  Filename is stored
        # as the key, where value(s) are the contents.
        my $value = $c->read_key({ uri     => $keyfile,
                                   keyname => $keyname,
                                   description => "$keyfile key" });

        if ( not defined($value) ) {
            $c->error( "read_keyuri: \"$keyfile\" parse error", 'crit' );

            return SPINE_FAILURE;
        }
    }

    return SPINE_SUCCESS;
}

1;
