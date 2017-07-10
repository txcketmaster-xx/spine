# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

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
# (C) Copyright Metacloud, Inc. 2012
#

use strict;

package Spine::Plugin::DevelHooks;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = 3.1415926535;
$DESCRIPTION = 'Behavioral changes needed for dev environments';

$MODULE = { author => 'nic@metacloud.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { PREPARE => [ { name => 'fixup_overlay',
                                      code => \&fixup_overlay } ]
                     },
          };

use XML::Simple;
use Data::Dumper;
use Spine::Util qw(simple_exec);

sub fixup_overlay
{
    my $c = shift;
    my $croot = $c->getval('c_croot');
    my $tmpdir = $c->getval('c_tmpdir');
    my $errors;

    my $property_map = make_property_map($c);
    foreach my $file (keys %{ $property_map }) {
        # Perl doesn't implement lchown/lchmod, and these attributes
        # aren't of much use on symlinks anyhow.  Ignore them
        next if -l "$tmpdir/$file";
        $c->print(3, $file);
        if (exists $property_map->{$file}->{'spine:ugid'}) {
            my ($uid, $gid) = @{ $property_map->{$file}->{'spine:ugid'} };
            $c->print(3, "    uid($uid) gid($gid)");
            my $res = chown $uid, $gid, "$tmpdir/$file";
            unless ($res) {
                $c->error("$tmpdir/$file chown failed: $!");
                $errors++;
            }
        }
        if (exists $property_map->{$file}->{'spine:perms'}) {
            $c->print(3, sprintf('    mode(%#o)', $property_map->{$file}->{'spine:perms'}));
            my $res = chmod $property_map->{$file}->{'spine:perms'}, "$tmpdir/$file";
            unless ($res) {
                $c->error("$tmpdir/$file chmod failed: $!");
                $errors++;
            }
        }
    }
    return $errors ? PLUGIN_ERROR : PLUGIN_SUCCESS;
}

# use simple_exec and the command-line tools (with XML output) to
# collect up the Subversion properties on the files.  Alows a Subversion
# tree to be used as a croot without fidgeting with owners and modes
#
sub make_property_map {
    my %property_map;
    my $c = shift;
    my $croot = $c->getval('c_croot');
    my @hier = map { -d "$croot/$_/overlay" && "$croot/$_/overlay" } @{ $c->getvals('c_hierarchy') };

    foreach my $prop (qw( spine:ugid spine:perms ) ) {
        # what... no "chdir before running" option?
        my @res = simple_exec(c     => $c,
                              exec  => 'svn',
                              args  => "pg --xml -R $prop @hier",
                              inert => 1,
        );
        my $input = XMLin(join("\n", @res));

        foreach my $target (@{ $input->{'target'} }) {
            $target->{'path'} =~ s#^.*?overlay/?##;
            $property_map{$target->{'path'}} = {}
               	unless exists $property_map{$target->{'path'}};
            my $p = $target->{'property'};

            if ($p->{'name'} eq 'spine:ugid') {
                $property_map{$target->{'path'}}{$p->{'name'}} =
                    [ split(':', $p->{'content'}, 2) ];
            }
            elsif ($p->{'name'} eq 'spine:perms') {
                $property_map{$target->{'path'}}{$p->{'name'}} =
                    oct("0" . $p->{'content'});
            }
        }
    }
    $c->print(5, Dumper(\%property_map));
    return \%property_map;
}

1;
