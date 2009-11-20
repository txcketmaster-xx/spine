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

package Spine::Plugin::PackageManager::Default;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ( $VERSION, $DESCRIPTION, $MODULE );
my $CPATH;

$VERSION     = sprintf( "%d.%02d", q$Revision: 22 $ =~ /(\d+)\.(\d+)/ );
$DESCRIPTION = "PackageManager::Default, some default packagemanager functions";

$MODULE = { author      => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version     => $VERSION,
            hooks       => {
                       "PKGMGR/CalcMissing/Default" => [
                                        { name => 'PackageManager CalcMissing',
                                          code => \&calc_missing } ],
                       "PKGMGR/CalcRemove/Default" => [
                                         { name => 'PackageManager CalcRemove',
                                           code => \&calc_remove } ],
                       "PKGMGR/Report/Default" => [
                                             { name => 'PackageManager Report',
                                               code => \&report } ],
                       "PKGMGR/ResolveInstalled/Default" => [
                                    { name => 'PackageManager ResolveInstaled',
                                      code => \&resolve_deps } ], } };

# Take a list of installed and to install and build a list
# of to remove and missing, taking account of deps and new_deps
sub calc_missing {
    my ( $c, $instance_conf, undef, ) = @_;
    my $s = $instance_conf->{store};

    my $node;

    # Need to be installed
    foreach ( $s->find_node('install') ) {
        unless (
              $s->find_node( 'installed', 'name', $s->get_node_val( 'name', $_ )
                           ) )
        {
            $node = $s->create_node('missing');
            $s->copy_node( $_, $node );
        }
    }
    return PLUGIN_FINAL;
}

sub calc_remove {
    my ( $c, $instance_conf, undef ) = @_;
    my $s = $instance_conf->{store};
    my $name;

    foreach ( $s->find_node('installed') ) {
        $name = $s->get_node_val( 'name', $_ );
        unless (    $s->find_node( 'deps', 'name', $name )
                 || $s->find_node( 'install',  'name', $name )
                 || $s->find_node( 'new_deps', 'name', $name ) )
        {
            $s->copy_node( $_, $s->create_node('remove') );
        }
    }
    return PLUGIN_FINAL;
}

# For the list of packages that is to be kept on the system
# work out what packages they need so we don't remove them
# XXX it will not make sure all dpes are met. IF a dep is not
# installed (which would mean something is broken it will neither
# notice or report)
sub resolve_deps {
    my ( $c, $instance_conf, undef ) = @_;

    # TODO: make this cleaner
    my $s = $instance_conf->{store};

    my @installed = $s->find_node('installed');
    my $pkg;

    # build out a hash provides and packages names mapped to package
    # and a list of what packages depend on
    my %prov_lookup;
    my %dep_lookup;
    my %installed;
    foreach $pkg (
            $s->get_node_val( [ 'name', 'provides', 'requires' ], @installed ) )
    {
        $installed{ $pkg->[0] } = undef;
        foreach ( @{ $pkg->[1] } ) {
            unless ( exists $prov_lookup{$_} ) {
                $prov_lookup{$_} = [];
            }
            push @{ $prov_lookup{$_} }, $pkg->[0];
        }
        $dep_lookup{ $pkg->[0] } = $pkg->[2];
    }

    my %missing =
      map { $_ => undef } $s->get_node_val( 'name', $s->find_node('missing') );
    my @pkgs = $s->get_node_val( 'name', $s->find_node('install') );
    my %install = map { $_ => undef } @pkgs;
    my %processed;
    while (@pkgs) {
        my @new_pkgs;
        foreach (@pkgs) {

            # We only do installed deps
            next if ( exists $missing{$_} );
            foreach ( @{ $dep_lookup{$_} } ) {

                # This deals with deps where there is an '|' (OR)
                # XXX: used in DEB pkgs. Not sure if this should be here
                #      maybe make it flexable...
                foreach ( split( /\s*\|\s*/, $_ ) ) {

                    # have processed this one before.
                    next if exists $processed{$_};
                    if ( exists $installed{$_} ) {
                        $s->copy_node( $s->find_node( 'installed', 'name', $_ ),
                                       $s->create_node('deps') );
                        push @new_pkgs, $_;
                        $processed{$_} = undef;
                        next;
                    }
                    foreach $pkg ( @{ $prov_lookup{$_} } ) {

                      # No point marking a dep for something in the install list
                        next if exists $install{$pkg};
                        $s->copy_node( $s->find_node( 'installed', 'name', $pkg
                                                    ),
                                       $s->create_node('deps') );

                        # use to resolve it's deps next run;
                        push @new_pkgs, $pkg;
                        $processed{$pkg} = undef;
                    }
                }
            }
        }
        @pkgs = @new_pkgs;
    }

    return PLUGIN_FINAL;
}

# Basic report of what is about to happen
sub report {
    my ( $c, $instance_conf, undef ) = @_;
    my $s = $instance_conf->{store};

    $c->cprint("Going to....");
    my @names;
    foreach my $report ( [ '  update:', 'updates' ],
                         [ '     add:', 'missing' ],
                         [ 'add deps:', 'new_deps' ],
                         [ '  remove:', 'remove' ], )
    {
        my $list = join(
            ' ',
            $s->get_node_val( 'name',
                              $s->find_node( $report->[1] )
                            ) );
                            
        next unless ($list);

        # Try not to have really long lines
        while ($list =~ m/(.{1,55})(?:\s|$)/sog) {
            $c->cprint($report->[0] . " " .  $1);
            $report->[0] =~ s/./ /g;
        }
    }

    return PLUGIN_FINAL;
}

1;
