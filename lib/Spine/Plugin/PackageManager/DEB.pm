
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
use Spine::Util qw(getbin);

our ($VERSION, $DESCRIPTION, $MODULE);
my $CPATH;

$VERSION = sprintf("%d.%02d", q$Revision: 22 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "PackageManager::DEB, DEB implementation";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => {
                       "PKGMGR/Lookup"           => [ { name => 'DEB LookupInstalled',
                                                        code => \&_get_installed } ],
            },

          };

our $PKGPLUGNAME = 'DEB';

# Get information about the installed packages
sub _get_installed {
    my ($c, $instance_conf, undef, $section) = @_;

    # Are we to deal with this?
    unless (exists $section->{$PKGPLUGNAME}) {
        return PLUGIN_SUCCESS;
    }

    # TODO: remove lameness, at least it's easy
    my $query_bin = getbin('dpkg-query', $c->getvals('dpkg-query_bin'));
    unless (defined $query_bin && -x $query_bin) {
        $c->error('Could not find dpkg-query executable');
        return PLUGIN_ERROR;
    }
    my $output = `$query_bin --showformat='\${status}\t\${Package}\\t\${Architecture}\\t\${Version}\\t\${Provides}\\t\${Pre-Depends}\\t\${Depends}\\n' -W`;
    unless ($? eq 0) {
        $c->error('Error running dpkg-query');
        return PLUGIN_ERROR;
    }
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
