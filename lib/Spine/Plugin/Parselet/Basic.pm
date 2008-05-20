
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

package Spine::Plugin::Parselet::Basic;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

# TODO: a whole lot more error checking and reporting of errors

our ($VERSION, $DESCRIPTION, $MODULE);
my $CPATH;

$VERSION = sprintf("%d.%02d", q$Revision: 22 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Parselet::Basic, processes Basic keys";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'PARSE/key' => [ { name => "Basic", 
                                          code => \&_parse_basic_key,
                                          position => HOOK_END } ],
                     },
          };

sub _parse_basic_key {
    my ($self, $data) = @_;

    # Skip refs, only scalars
    if (ref($data->{obj})) {
        return PLUGIN_SUCCESS;
    }
    
    my $obj = [split(m/\n/o, $data->{obj})];
    my $keyname = $data->{keyname};

    if (exists($self->{$keyname})) {
        my $existing = ref($self->{$keyname});
        unless ($existing eq 'ARRAY') {
            $self->error("Mismatched types for $keyname: It seems that "
                         . "you're trying to use a list on a \""
                         . lc($existing) . '"', 'crit');
            return undef;
        }
    } else {
        # Don't create empty keys
        if ($keyname) {
             $self->{$keyname} = [];
        }
    }

    my @final;

    # Now walk the list looking for control characters and interpreting
    # where necessary.  Otherwise, just append it to the list
    foreach (@{$obj}) {
        # Ignore comments and blank lines.
        if (m/^\s*$/o or m/^\s*#/o) {
            next;
        }

        # We allow several metacharacters to manipulate
        # pre-existing values in a key.  -regex removes
        # matching values for the key in question.
        if ($keyname && m/^-(.*)$/o) {
            next unless defined @{$self->{$keyname}};

            my $rm_regex = $1;
            @{$self->{$keyname}} = grep(!/$rm_regex/, @{$self->{$keyname}});

            next;
        }

        # If equals (=) is the first and only character of
        # a line, clear the array.  This is used to set
        # absolute values.
        elsif ($keyname && m/^=\s*$/o) {
            delete $self->{$keyname} if defined($keyname);
            next;
        }

        # If there isn't a control character, just append it.
        #push @{$self->{$keyname}}, $_;
        push @final, $_;
    }
    $data->{obj} = \@final;

    return PLUGIN_FINAL;
}

1;
