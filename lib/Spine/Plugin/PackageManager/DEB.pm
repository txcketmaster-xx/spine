
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Skeleton.pm 22 2007-12-12 00:35:55Z phil@ipom.com $

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

package Spine::Plugin::PackageManager::DEB;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);
my $CPATH;

$VERSION = sprintf("%d.%02d", q$Revision: 22 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "PackageManager::DEB, DEB implementation";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => {
                       "PKGMGR/ResolveInstalled" => [ { name => 'DEB ResolveInstaledDeps',
                                                        code => \&_resolve_deps } ],
                       "PKGMGR/Lookup"           => [ { name => 'DEB LookupInstalled',
                                                        code => \&_get_installed } ],
            },

          };

our $PKGPLUGNAME = 'DEB';

# For the list of packages that is to be kept on the system
# work out what packages they need so we don't remove them
# XXX: build out 'deps'
sub _resolve_deps {
    my ($c, $instance_conf, undef, $section) = @_;

    # Are we to deal with this?
    unless (exists $section->{$PKGPLUGNAME}) {
        return PLUGIN_SUCCESS;
    }

    # TODO: make this cleaner
    my $s = $instance_conf->{store};

    my @installed = $s->find_node('installed');
    my $pkg;

    # build out a hash provides and packages names mapped to package
    # and a list of what packages depend on
    my %prov_lookup;
    my %dep_lookup;
    my %installed;
    foreach $pkg ($s->get_node_val([ 'name', 'provides', 'requires'], @installed)){
        $installed{$pkg->[0]} = undef;
        foreach (@{$pkg->[1]}) {
            unless (exists $prov_lookup{$_}) {
                $prov_lookup{$_} = [];
            }
            push @{$prov_lookup{$_}}, $pkg->[0];
        }
        $dep_lookup{$pkg->[0]} = $pkg->[2];
    }

    my %missing = map { $_ => undef } $s->get_node_val('name', $s->find_node('missing'));
    my @pkgs = $s->get_node_val('name', $s->find_node('install'));
    my %install = map { $_ => undef } @pkgs;
    my %processed;
    while(@pkgs) {
        my @new_pkgs;
        foreach (@pkgs) {
            # We only do installed deps
            next if (exists $missing{$_});
            foreach (@{$dep_lookup{$_}}) {
                # This deals with deps where there is an '|' (OR)
                foreach (split(/\s*\|\s*/, $_)) {
                    # have processed this one before.
                    next if exists $processed{$_};
                    if (exists $installed{$_}) {
                        $s->copy_node($s->find_node('installed', 'name', $_),
                                      $s->create_node('deps'));
                        push @new_pkgs, $_;
                        $processed{$_} = undef;
                        next;
                    }
                    foreach $pkg (@{$prov_lookup{$_}}) {
                        # No point marking a dep for something in the install list
                        next if exists $install{$pkg};
                        $s->copy_node($s->find_node('installed', 'name', $pkg),
                                      $s->create_node('deps'));
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


# Get information about the installed packages
sub _get_installed {
    my ($c, $instance_conf, undef, $section) = @_;

    # Are we to deal with this?
    unless (exists $section->{$PKGPLUGNAME}) {
        return PLUGIN_SUCCESS;
    }

    # TODO: remove lameness, at least it's easy
    my $output = `dpkg-query --showformat='\${status}\t\${Package}\\t\${Architecture}\\t\${Version}\\t\${Provides}\\t\${Pre-Depends}\\t\${Depends}\\n' -W`;
    my $s = $instance_conf->{store};

    foreach (split('\n', $output)) {
            my ($status, $name, $arch, $version, $provides, $pre_deps, $deps) = split('\t', $_);
            next unless $status =~ m/^install ok installed$/;
            $deps =~ s/\s+\([^\)]+\)//g;
            $pre_deps =~ s/\s+\([^\)]+\)//g;
            my @deps = split(/,\s*/, $pre_deps);
            push @deps, split(/,\s*/, $deps);
            my @provides = split(/,\s*/, $provides);
            $s->create_node('installed', 'name', $name,
                                         'version', $version,
                                         'arch', $arch,
                                         'provides', \@provides,
                                         'requires', \@deps);
    }

    return PLUGIN_FINAL;
}
1;
