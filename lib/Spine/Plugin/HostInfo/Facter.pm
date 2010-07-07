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

package Spine::Plugin::HostInfo::Facter;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin :basic :keys);
use YAML::Syck;
use Spine::Util qw(simple_exec);

our ( $VERSION, $DESCRIPTION, $MODULE, $DONTDELETE, $TMPDIR, @ENTRIES );

$VERSION = sprintf( "%d", q$Revision: 318 $ =~ /(\d+)/ );

$DESCRIPTION = "Facter support";

$MODULE = {
    author      => 'osscode@ticketmaster.com',
    description => $DESCRIPTION,
    version     => $VERSION,
    hooks       => {
        "DISCOVERY/populate" => [ { name => 'get facter data',
                                    code => \&init } ],

             } };

sub init {
    my $c = shift;

    my @fdata = ( simple_exec( c     => $c,
                               exec  => "facter",
                               args  => '--yaml',
                               inert => 1 ) );
    unless ( scalar(@fdata) ) {
        $c->error( "Unable to run 'facter'", "err" );
        return PLUGIN_ERROR;
    }

    $c->set( 'c_facter', YAML::Syck::Load( join( "", @fdata ) ) );

    return PLUGIN_SUCCESS;
}

1;

